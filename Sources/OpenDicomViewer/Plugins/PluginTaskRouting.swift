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

/// Asks whether to start a plugin the arbiter refused for lack of free memory.
///
/// Offered only for `PluginError.insufficientLiveMemory`: the declared budget
/// fits and the refusal rests on a live reading of a busy machine. A request
/// larger than the plugin share of physical memory is `insufficientMemory`
/// and never reaches the user as a choice.
@MainActor
enum LowMemoryStartPrompt {

    /// Replaceable so tests can answer without a modal.
    static var ask: (_ pluginName: String, _ message: String) -> Bool = { name, message in
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(name) may not have enough memory"
        alert.informativeText = message
        alert.addButton(withTitle: "Start Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// If `error` is an overridable memory refusal and the user agrees, arm a
    /// one-time override on `runtime` and return true; the caller retries.
    static func offerOverride(for error: Error, pluginID: String,
                              runtime: PluginRuntime) -> Bool {
        guard let pluginError = error as? PluginError,
              case .insufficientLiveMemory = pluginError else { return false }
        let name = runtime.manifest.plugin(id: pluginID)?.name ?? pluginID
        guard ask(name, pluginError.localizedDescription) else { return false }
        runtime.allowLowMemoryStart(pluginID)
        return true
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
    ///
    /// Results and errors land in the same panel state the built-in AI uses,
    /// and the AI inspector is opened so they are seen. Like the built-in
    /// path, results are bound to the slice they were computed on, replace the
    /// previous results of this task kind on that slice, and are dropped if a
    /// different study was loaded meanwhile.
    func runPluginTask(_ ref: PluginTaskRef, for panel: PanelState) {
        guard !panel.aiAnalysisInProgress else { return }

        let runtime = PluginRuntime.shared
        guard let plugin = runtime.manifest.plugin(id: ref.pluginID),
              let task = plugin.task(id: ref.taskID) else {
            panel.aiError = PluginError.unknownTask(ref).localizedDescription
            return
        }
        // Slice tasks report into the AI inspector; volumetric ones (a SEG)
        // into the derived-object list, which needs no inspector.
        if task.inputs.contains(.slice2d) { showAIInspector = true }

        // A slice task runs on the frame on screen (cine stopped) at its
        // displayed aspect; see captureAIInput.
        let input = task.inputs.contains(.slice2d) ? captureAIInput(for: panel) : nil
        let invocation: PluginInvocation
        let staged: URL?
        do {
            (invocation, staged) = try buildInvocation(for: task, panel: panel, image: input?.image)
        } catch {
            panel.aiError = error.localizedDescription
            return
        }
        guard AIService.shared.confirmDisclaimerIfNeeded() else {
            if let staged { PluginSeriesStaging.discard(staged) }
            return
        }

        let slice = input?.slice ?? panel.currentSlice
        let seriesID = input?.seriesID ?? (allSeries.indices.contains(panel.seriesIndex)
            ? allSeries[panel.seriesIndex].id : nil)

        panel.aiAnalysisInProgress = true
        panel.aiError = nil

        Task {
            defer { if let staged { PluginSeriesStaging.discard(staged) } }
            let outcome: Result<PluginResult, Error>
            do {
                outcome = .success(try await runtime.invoke(ref, invocation))
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run {
                panel.aiAnalysisInProgress = false
                defer { self.objectWillChange.send() }
                // A slice result describes nothing on screen once the study
                // changed. A SEG is a file about its own series and is kept.
                if task.inputs.contains(.slice2d),
                   !Self.sameStudy(seriesIndex: slice.seriesIndex, seriesID: seriesID,
                                   in: self.allSeries.map(\.id)) {
                    return
                }
                switch outcome {
                case .success(let result):
                    self.apply(result, from: task, to: panel, slice: slice)
                case .failure(let error):
                    if LowMemoryStartPrompt.offerOverride(for: error, pluginID: ref.pluginID,
                                                          runtime: runtime) {
                        self.runPluginTask(ref, for: panel)
                    } else {
                        panel.aiError = error.localizedDescription
                    }
                }
            }
        }
    }

    /// Whether the series a run started on is still the one at that index.
    nonisolated static func sameStudy(seriesIndex: Int, seriesID: String?, in ids: [String]) -> Bool {
        guard let seriesID, ids.indices.contains(seriesIndex) else { return false }
        return ids[seriesIndex] == seriesID
    }

    // MARK: - Inputs

    /// Assemble the inputs a task declares from current panel state.
    ///
    /// A task asking for something the panel cannot supply fails here, before a
    /// model is started, rather than as a confusing error from the adapter.
    ///
    /// Returns, alongside the invocation, any directory staged for it, which
    /// the caller removes once the run is over.
    private func buildInvocation(for task: PluginTask, panel: PanelState,
                                 image captured: NSImage?) throws -> (PluginInvocation, URL?) {
        var invocation = PluginInvocation()
        var staged: URL?

        for kind in task.inputs {
            switch kind {
            case .slice2d:
                guard let image = captured ?? panel.image,
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

            case .roi:
                // A menu-driven run describes the region the built-in
                // Describe ROI uses: the latest ROI Stats rectangle on the
                // slice on screen. Without one the adapter could only fail.
                guard let roi = normalizedROIForAI(in: panel) else {
                    throw PluginError.notReady(
                        "Draw a region with the ROI Stats tool (S) on this slice first, then run \(task.label).")
                }
                invocation.roi = roi

            case .points, .box:
                // Prompt inputs are supplied by the interaction tools, which
                // call the runtime directly with a populated invocation. A
                // menu-driven run leaves them empty and the adapter decides
                // whether it can proceed.
                continue
            }
        }

        // The analysis mode chosen in the AI inspector applies to the plugin
        // too, when the task offers that option and the value.
        if let option = task.options?["mode"], option.type == .enum,
           option.values?.contains(AIService.shared.selectedMode) == true {
            invocation.options["mode"] = .string(AIService.shared.selectedMode)
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
    ///
    /// `slice` binds the result to the slice it was computed on (nil leaves
    /// annotations unbound, for callers without one). Boxes go through the
    /// same sanitizer as the built-in AI, and a new result replaces the AI
    /// annotations of the same kind already on that slice instead of piling
    /// up beside them.
    func apply(_ result: PluginResult, from task: PluginTask, to panel: PanelState,
               slice: AnnotationSlice? = nil) {
        for kind in task.outputs {
            switch kind {
            case .text:
                if let text = result.text, !text.isEmpty {
                    panel.aiDescription = text
                    panel.aiDescriptionSlice = slice
                }

            case .bbox:
                panel.annotations.removeAll { annotation in
                    guard annotation.isAI, annotation.slice == slice else { return false }
                    switch annotation.type {
                    case .aiStructure, .aiFinding: return true
                    default: return false
                    }
                }
                for box in result.bboxes {
                    // AI annotations are stored normalized; the annotation layer
                    // scales them to pixels at draw time, as it does for the
                    // boxes the Gemma path already produces.
                    guard let rect = AIBoxSanitizer.normalizedRect(
                        x: box.x, y: box.y, width: box.width, height: box.height) else { continue }
                    let type: AnnotationType = box.severity.map {
                        .aiFinding(rect: rect, description: box.label,
                                   severity: AISeverity(parsing: $0).rawValue)
                    } ?? .aiStructure(rect: rect, label: box.label,
                                      confidence: AIBoxSanitizer.confidence(box.confidence))
                    panel.annotations.append(Annotation(type: type, isAI: true, slice: slice))
                }
                panel.showAIAnnotations = true

            case .mask2d:
                panel.annotations.removeAll { annotation in
                    guard annotation.isAI, annotation.slice == slice else { return false }
                    if case .aiMask = annotation.type { return true }
                    return false
                }
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
                        isAI: true,
                        slice: slice))
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
