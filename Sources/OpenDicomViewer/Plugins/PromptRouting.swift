// PromptRouting.swift
// OpenDicomViewer
//
// Connects panel gestures to a promptable-segmentation session and the returned
// mask back to the panel's annotation layer.
//
// One session per panel, keyed by panel identity: two panels showing different
// slices each need their own cached embedding, and sharing one would decode
// prompts against the wrong pixels.
// Licensed under the MIT License. See LICENSE for details.

import AppKit
import Combine
import CoreGraphics
import Foundation

/// Identifies the pixels a panel is displaying, for prompt-session invalidation.
///
/// Everything that changes which pixels are on screen belongs in the key. The
/// series and image indices alone describe only the axial view: in a sagittal
/// or coronal panel the visible slice is `mprSliceIndex`, and in a MIP panel it
/// is the slab, so scrolling an MPR or MIP panel left the key unchanged and the
/// next prompt was decoded against the embedding of an image no longer shown.
/// Window/level and zoom are deliberately absent: they change the rendering,
/// not the anatomy a mask is drawn on.
enum PromptSliceKey {
    static func make(seriesIndex: Int, imageIndex: Int, mode: PanelMode,
                     mprSliceIndex: Int, mipSlabPosition: Int,
                     mipSlabThickness: Int) -> String {
        let base = "s\(seriesIndex)"
        switch mode {
        case .slice2D:
            return "\(base)/axial/i\(imageIndex)"
        case .mprSagittal:
            return "\(base)/sagittal/m\(mprSliceIndex)"
        case .mprCoronal:
            return "\(base)/coronal/m\(mprSliceIndex)"
        case .mip:
            return "\(base)/mip/p\(mipSlabPosition)x\(mipSlabThickness)"
        }
    }

    static func make(for panel: PanelState) -> String {
        make(seriesIndex: panel.seriesIndex, imageIndex: panel.imageIndex,
             mode: panel.panelMode, mprSliceIndex: panel.mprSliceIndex,
             mipSlabPosition: panel.mipSlabPosition,
             mipSlabThickness: panel.mipSlabThickness)
    }

    /// Fires whenever any input to the key may have changed.
    ///
    /// `@Published` emits before the property is written, so subscribers read
    /// the panel on the next main-queue turn rather than from inside the sink.
    static func changes(of panel: PanelState) -> AnyPublisher<Void, Never> {
        Publishers.MergeMany(
            panel.$seriesIndex.map { _ in () }.eraseToAnyPublisher(),
            panel.$imageIndex.map { _ in () }.eraseToAnyPublisher(),
            panel.$panelMode.map { _ in () }.eraseToAnyPublisher(),
            panel.$mprSliceIndex.map { _ in () }.eraseToAnyPublisher(),
            panel.$mipSlabPosition.map { _ in () }.eraseToAnyPublisher(),
            panel.$mipSlabThickness.map { _ in () }.eraseToAnyPublisher()
        )
        // Each @Published replays its current value on subscribe; those
        // arrive with an unchanged key, which `sliceChanged` ignores.
        .receive(on: DispatchQueue.main)
        .eraseToAnyPublisher()
    }
}

@MainActor
extension DICOMModel {

    /// Which installed plugin serves promptable segmentation.
    ///
    /// Resolved by declared capability rather than by a hardcoded id, so a
    /// future adapter that declares the task can serve prompts without a change
    /// here. Preference order follows the manifest, and only ready plugins are
    /// considered.
    var promptCapablePluginID: String? {
        let runtime = PluginRuntime.shared
        for plugin in runtime.manifest.plugins where plugin.execution == .session {
            let ref = PluginTaskRef(pluginID: plugin.id,
                                    taskID: PromptSession.taskID)
            guard plugin.task(id: PromptSession.taskID) != nil else { continue }
            if runtime.installState(ref).isReady { return plugin.id }
        }
        return nil
    }

    /// Identifies the pixels currently displayed in a panel.
    ///
    /// Used to invalidate a cached embedding when the user scrolls: a mask
    /// decoded against a stale embedding would look plausible and be wrong.
    func sliceKey(for panel: PanelState) -> String {
        PromptSliceKey.make(for: panel)
    }

    /// The session for a panel, created on first use.
    ///
    /// A new session watches its panel, and the panel list, from the moment it
    /// exists. Before, a session learned of a slice change only when the next
    /// prompt arrived, so a user who clicked once and scrolled away left the
    /// adapter's embedding cached -- and, holding an open session, the plugin
    /// non-evictable -- until they happened to prompt again.
    func promptSession(for panel: PanelState) -> PromptSession? {
        prunePromptSessions()
        if let existing = promptSessions[panel.id] {
            existing.sliceChanged(to: sliceKey(for: panel))
            return existing
        }
        guard let pluginID = promptCapablePluginID else { return nil }
        let session = PromptSession(runtime: PluginRuntime.shared,
                                    pluginID: pluginID,
                                    sliceKey: sliceKey(for: panel))
        promptSessions[panel.id] = session

        let panelID = panel.id
        session.observe(
            PromptSliceKey.changes(of: panel).sink { [weak self, weak panel, weak session] in
                guard let panel, let session else { return }
                // A panel that has been dropped from the layout is torn down
                // rather than tracked.
                guard self?.panels.contains(where: { $0.id == panelID }) ?? false else {
                    self?.discardPromptSession(for: panelID)
                    return
                }
                session.sliceChanged(to: PromptSliceKey.make(for: panel))
            })
        session.observe(
            $panels.receive(on: DispatchQueue.main).sink { [weak self] _ in
                self?.prunePromptSessions()
            })
        return session
    }

    /// Close the sessions of panels that are no longer in the layout.
    ///
    /// Layout changes replace `panels` wholesale without notifying anything
    /// prompt-related, so the session of a removed panel kept its adapter-side
    /// embedding and kept its plugin pinned against eviction indefinitely.
    func prunePromptSessions() {
        let live = Set(panels.map(\.id))
        for panelID in promptSessions.keys where !live.contains(panelID) {
            discardPromptSession(for: panelID)
        }
    }

    private func discardPromptSession(for panelID: UUID) {
        guard let session = promptSessions.removeValue(forKey: panelID) else { return }
        session.tearDown()
    }

    /// Add a click prompt at a pixel location in the panel's image.
    func addPromptPoint(_ pixel: CGPoint, isForeground: Bool, for panel: PanelState) {
        guard let session = promptSession(for: panel) else {
            panel.aiError = "Install a promptable segmentation plugin "
                + "(SAM 2 or SAM 3) from the Plugin Store first."
            return
        }
        guard let normalized = normalizedPoint(pixel, in: panel) else { return }

        session.addPoint(normalized, isForeground: isForeground,
                         sliceKey: sliceKey(for: panel),
                         slicePNG: { [weak self] in
                             self?.encodedSlicePNG(for: panel)
                         },
                         onMask: { [weak self] mask in
                             self?.applyPromptMask(mask, to: panel)
                         })
    }

    /// Submit a box prompt covering a pixel-space rect.
    func addPromptBox(_ rect: CGRect, for panel: PanelState) {
        guard let session = promptSession(for: panel) else {
            panel.aiError = "Install a promptable segmentation plugin "
                + "(SAM 2 or SAM 3) from the Plugin Store first."
            return
        }
        let width = max(1, CGFloat(panel.displayImageWidth))
        let height = max(1, CGFloat(panel.displayImageHeight))
        let normalized = CGRect(x: rect.minX / width, y: rect.minY / height,
                                width: rect.width / width, height: rect.height / height)
        guard normalized.width > 0, normalized.height > 0 else { return }

        session.setBox(normalized, sliceKey: sliceKey(for: panel),
                       slicePNG: { [weak self] in
                           self?.encodedSlicePNG(for: panel)
                       },
                       onMask: { [weak self] mask in
                           self?.applyPromptMask(mask, to: panel)
                       })
    }

    /// Discard prompts for a panel and release its cached embedding.
    func clearPrompts(for panel: PanelState) {
        promptSessions[panel.id]?.clear()
        panel.annotations.removeAll {
            if case .aiMask = $0.type { return true }
            return false
        }
    }

    // MARK: - Internals

    /// The panel's current slice as a base64 PNG, encoded lazily so a repeated
    /// prompt on an already-open session does not pay for it again.
    private func encodedSlicePNG(for panel: PanelState) -> String? {
        guard let image = panel.image else { return nil }
        return Self.base64PNG(image)
    }

    private func normalizedPoint(_ pixel: CGPoint, in panel: PanelState) -> CGPoint? {
        let width = max(1, CGFloat(panel.displayImageWidth))
        let height = max(1, CGFloat(panel.displayImageHeight))
        let point = CGPoint(x: pixel.x / width, y: pixel.y / height)
        // A click outside the image is a miss rather than a clamped edge prompt,
        // which would silently segment a corner the user did not indicate.
        guard (0...1).contains(point.x), (0...1).contains(point.y) else { return nil }
        return point
    }

    /// Replace any existing prompt mask with the new one.
    ///
    /// Prompt masks replace rather than accumulate: successive prompts refine
    /// one region, so keeping the earlier masks would stack overlapping
    /// translucent overlays of the same structure.
    private func applyPromptMask(_ mask: PluginMask2D, to panel: PanelState) {
        guard let decoded = mask.decodeMask() else {
            panel.aiError = "The plugin returned a malformed mask."
            return
        }
        panel.annotations.removeAll {
            if case .aiMask = $0.type { return true }
            return false
        }
        let bounds = Self.maskBounds(decoded, width: mask.width, height: mask.height)
        guard bounds.width > 0, bounds.height > 0 else {
            panel.aiError = "The prompt produced an empty mask."
            return
        }
        panel.annotations.append(Annotation(type: .aiMask(
            mask: decoded, width: mask.width, height: mask.height,
            bounds: bounds,
            label: mask.label ?? "Prompt",
            confidence: mask.confidence ?? 1.0)))
        panel.showAIAnnotations = true
        panel.aiError = nil
    }
}
