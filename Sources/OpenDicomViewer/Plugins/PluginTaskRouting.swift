// PluginTaskRouting.swift
// OpenDicomViewer
//
// Routes a plugin invocation from the viewer to the runtime and its result back
// into the panel that asked for it.
//
// The point of the plugin layer is that the viewer does not know which model it
// is talking to, so this file dispatches on the task's DECLARED output kinds
// rather than on the plugin's identity. Adding a plugin that emits masks needs
// no change here; adding a new output kind does.
// Licensed under the MIT License. See LICENSE for details.

import AppKit
import Foundation
import SwiftUI

/// Presents exactly one series to a plugin that takes a directory.
///
/// Studies are routinely stored with several series in one folder, and the
/// one-shot contract passes a directory (PLUGIN_PROTOCOL.md section 2). Handing
/// the adapter the folder of the panel's first image therefore handed it every
/// series in that folder, and TotalSegmentator's DICOM conversion segmented
/// whichever series it happened to pick -- not necessarily the one on screen.
/// The selected series' files are linked into a private directory instead, so
/// what the adapter reads is precisely what the user selected. Symbolic links
/// cost no copy of the pixel data.
enum PluginSeriesStaging {

    /// Link `files` into a new directory beneath `root` and return it.
    static func stage(_ files: [URL],
                      under root: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let manager = FileManager.default
        let directory = root.appendingPathComponent("odv-series-\(UUID().uuidString)",
                                                    isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        var seen = Set<String>()
        do {
            for (index, file) in files.enumerated() {
                let source = file.standardizedFileURL
                guard seen.insert(source.path).inserted else { continue }
                // Prefixed with the position so two files that share a name in
                // different source folders cannot collide.
                let name = String(format: "%06d-", index) + source.lastPathComponent
                try manager.createSymbolicLink(
                    at: directory.appendingPathComponent(name, isDirectory: false),
                    withDestinationURL: source)
            }
        } catch {
            discard(directory)
            throw error
        }
        return directory
    }

    /// Remove a staged directory. Only the links go; the sources are untouched.
    static func discard(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }
}

extension Notification.Name {
    /// Posted by the AI menu, which lives in a different view tree from the
    /// view that owns the store sheet.
    static let odvOpenPluginStore = Notification.Name("odv.openPluginStore")
}

@MainActor
extension DICOMModel {

    /// Run a plugin task against a panel and render whatever it returns.
    func runPluginTask(_ ref: PluginTaskRef, for panel: PanelState) {
        guard !panel.aiAnalysisInProgress else { return }

        let runtime = PluginRuntime.shared
        guard let plugin = runtime.manifest.plugin(id: ref.pluginID),
              let task = plugin.task(id: ref.taskID) else {
            panel.aiError = PluginError.unknownTask(ref).localizedDescription
            return
        }

        let invocation: PluginInvocation
        let staged: URL?
        do {
            (invocation, staged) = try buildInvocation(for: task, panel: panel)
        } catch {
            panel.aiError = error.localizedDescription
            return
        }

        panel.aiAnalysisInProgress = true
        panel.aiError = nil

        Task {
            defer { if let staged { PluginSeriesStaging.discard(staged) } }
            do {
                let result = try await runtime.invoke(ref, invocation)
                await MainActor.run {
                    self.apply(result, from: task, to: panel)
                    panel.aiAnalysisInProgress = false
                    self.objectWillChange.send()
                }
            } catch {
                await MainActor.run {
                    panel.aiError = error.localizedDescription
                    panel.aiAnalysisInProgress = false
                    self.objectWillChange.send()
                }
            }
        }
    }

    // MARK: - Inputs

    /// Assemble the inputs a task declares from current panel state.
    ///
    /// A task asking for something the panel cannot supply fails here, before a
    /// model is started, rather than as a confusing error from the adapter.
    ///
    /// Returns, alongside the invocation, any directory staged for it, which
    /// the caller removes once the run is over.
    private func buildInvocation(for task: PluginTask,
                                 panel: PanelState) throws -> (PluginInvocation, URL?) {
        var invocation = PluginInvocation()
        var staged: URL?

        for kind in task.inputs {
            switch kind {
            case .slice2d:
                guard let image = panel.image,
                      let encoded = Self.base64PNG(image) else {
                    throw PluginError.unsupportedInput(.slice2d)
                }
                invocation.slice2d = encoded

            case .series3d:
                guard let files = seriesFiles(for: panel) else {
                    throw PluginError.unsupportedInput(.series3d)
                }
                let directory = try PluginSeriesStaging.stage(files)
                staged = directory
                invocation.series3d = directory.path

            case .text:
                // Context, not a prompt: modality and series description are
                // what the viewer knows and the model cannot infer reliably.
                invocation.text = clinicalContext(for: panel)

            case .roi, .points, .box:
                // Prompt inputs are supplied by the interaction tools, which
                // call the runtime directly with a populated invocation. A
                // menu-driven run leaves them empty and the adapter decides
                // whether it can proceed.
                continue
            }
        }

        return (invocation, staged)
    }

    private func clinicalContext(for panel: PanelState) -> String {
        var parts: [String] = []
        if panel.seriesIndex >= 0 && panel.seriesIndex < allSeries.count {
            let description = allSeries[panel.seriesIndex].seriesDescription
            if !description.isEmpty { parts.append(description) }
        }
        if let modality = panel.tags
            .first(where: { $0.tag == DicomTag(group: 0x0008, element: 0x0060) })?
            .stringValue, !modality.isEmpty {
            parts.insert(modality, at: 0)
        }
        return parts.joined(separator: ", ")
    }

    /// The files of the panel's series and no other, for plugins that take a
    /// path rather than a rendered slice. See `PluginSeriesStaging`.
    private func seriesFiles(for panel: PanelState) -> [URL]? {
        guard panel.seriesIndex >= 0, panel.seriesIndex < allSeries.count else { return nil }
        let series = allSeries[panel.seriesIndex]
        let files = series.images.map(\.url)
        return files.isEmpty ? nil : files
    }

    static func base64PNG(_ image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        return png.base64EncodedString()
    }

    // MARK: - Outputs

    /// Render a result according to the kinds its task declared.
    func apply(_ result: PluginResult, from task: PluginTask, to panel: PanelState) {
        for kind in task.outputs {
            switch kind {
            case .text:
                if let text = result.text, !text.isEmpty {
                    panel.aiDescription = text
                }

            case .bbox:
                for box in result.bboxes {
                    // AI annotations are stored normalized; the annotation layer
                    // scales them to pixels at draw time, as it does for the
                    // boxes the Gemma path already produces.
                    let rect = CGRect(x: box.x, y: box.y,
                                      width: box.width, height: box.height)
                    let type: AnnotationType = box.severity.map {
                        .aiFinding(rect: rect, description: box.label, severity: $0)
                    } ?? .aiStructure(rect: rect, label: box.label,
                                      confidence: box.confidence)
                    panel.annotations.append(Annotation(type: type, isAI: true))
                }
                panel.showAIAnnotations = true

            case .mask2d:
                for mask in result.masks {
                    guard let bitmap = mask.decodeMask() else { continue }
                    let bounds = Self.maskBounds(bitmap,
                                                 width: mask.width,
                                                 height: mask.height)
                    panel.annotations.append(Annotation(
                        type: .aiMask(mask: bitmap,
                                      width: mask.width,
                                      height: mask.height,
                                      bounds: bounds,
                                      label: mask.label ?? "Segmentation",
                                      confidence: mask.confidence ?? 0),
                        isAI: true))
                }
                panel.showAIAnnotations = true

            case .seg3d:
                if let path = result.seg3dPath {
                    ingestSegmentation(at: URL(fileURLWithPath: path))
                }

            case .metrics:
                if !result.metrics.isEmpty {
                    panel.pluginMetrics = result.metrics
                }
            }
        }
    }

    /// Tight bounding rect of a decoded mask, in pixel space.
    static func maskBounds(_ mask: [Bool], width: Int, height: Int) -> CGRect {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where mask[row + x] {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return .zero }
        return CGRect(x: minX, y: minY,
                      width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Load a plugin-produced DICOM SEG through the same parser the viewer uses
    /// for SEG files found on disk, so plugin output and imported output render
    /// by exactly one code path.
    func ingestSegmentation(at url: URL) {
        guard let summary = DICOMDerivedObjectParser.parse(url: url) else { return }
        if !derivedObjects.contains(where: { $0.url == url }) {
            derivedObjects.append(summary)
        }
        if let object = DICOMAnnotationObjectParser.parse(url: url, kind: summary.kind),
           !annotationObjects.contains(where: { $0.url == url }) {
            annotationObjects.append(object)
        }
        selectedDerivedObjectID = url
    }
}
