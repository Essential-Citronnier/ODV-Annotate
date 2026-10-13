// PromptSession.swift
// OpenDicomViewer
//
// Interactive prompting for promptable-segmentation plugins (SAM family).
//
// The `session` execution model exists because encoding a slice costs far more
// than decoding a mask from a prompt. This controller is what makes that
// asymmetry visible to the user: the slice is encoded once, and each subsequent
// click re-decodes against the cached embedding.
// Licensed under the MIT License. See LICENSE for details.

import Combine
import CoreGraphics
import Foundation

/// Accumulated prompt state for one slice.
///
/// Prompts accumulate rather than replace, because refining a mask by adding a
/// background click to subtract a spilled region is the interaction the SAM
/// family is designed around. Replacing on each click would make refinement
/// impossible.
struct PromptState: Equatable {
    /// Identifies the slice these prompts belong to, so a slice change discards
    /// them rather than silently applying them to different pixels.
    var sliceKey: String
    var points: [PluginPoint] = []
    var box: CGRect?

    var isEmpty: Bool { points.isEmpty && box == nil }

    mutating func reset(sliceKey: String) {
        self.sliceKey = sliceKey
        points = []
        box = nil
    }
}

/// Drives a promptable-segmentation plugin for one panel.
///
/// Owns the session lifecycle so the viewer does not have to: a session is
/// opened lazily on the first prompt, reused for every later prompt on the same
/// slice, and closed when the slice changes or the panel goes away. Leaving a
/// session open costs the adapter's cached embedding, which is the largest part
/// of its memory footprint.
@MainActor
final class PromptSession: ObservableObject {

    /// The plugin task this session prompts. Fixed by the protocol's task id for
    /// promptable segmentation rather than by plugin identity, so any adapter
    /// declaring it can serve the interaction.
    nonisolated static let taskID = "prompt-mask"

    @Published private(set) var state: PromptState
    @Published private(set) var isBusy = false
    @Published private(set) var lastError: String?
    /// Round-trip time of the most recent decode, surfaced so the interaction's
    /// responsiveness is visible rather than inferred.
    @Published private(set) var lastDecodeMS: Int?

    private let runtime: PluginRuntime
    private let pluginID: String
    private var sessionID: String?
    /// Serialises prompts: a click arriving mid-decode would otherwise race, and
    /// the later mask could be overwritten by the earlier one's completion.
    private var inFlight: Task<Void, Never>?
    /// Bumped whenever the current session is abandoned. A session whose
    /// open completes after its slice was left is closed instead of adopted;
    /// otherwise the old slice's embedding would be bound to the new slice's
    /// prompts, producing a plausible mask of the wrong pixels.
    private var generation = 0
    /// Subscriptions to the owning panel, released with the session.
    private var observers: Set<AnyCancellable> = []

    /// `runtime` has no default: `PluginRuntime.shared` is main-actor isolated,
    /// and a default argument is evaluated in the caller's (nonisolated) context,
    /// which is an error under the Swift 6 language mode.
    init(runtime: PluginRuntime,
         pluginID: String,
         sliceKey: String) {
        self.runtime = runtime
        self.pluginID = pluginID
        self.state = PromptState(sliceKey: sliceKey)
    }

    var ref: PluginTaskRef {
        PluginTaskRef(pluginID: pluginID, taskID: Self.taskID)
    }

    // MARK: - Prompt accumulation

    /// Add a click prompt. `isForeground == false` subtracts a region.
    func addPoint(_ point: CGPoint, isForeground: Bool,
                  sliceKey: String, slicePNG: @escaping () -> String?,
                  onMask: @escaping (PluginMask2D) -> Void) {
        prepare(for: sliceKey)
        state.points.append(PluginPoint(x: Double(point.x), y: Double(point.y),
                                        isForeground: isForeground))
        submit(slicePNG: slicePNG, onMask: onMask)
    }

    /// Set the box prompt, replacing any previous one.
    ///
    /// Unlike points, a box replaces: two boxes have no defined composition in
    /// the SAM prompt interface.
    func setBox(_ box: CGRect, sliceKey: String,
                slicePNG: @escaping () -> String?,
                onMask: @escaping (PluginMask2D) -> Void) {
        prepare(for: sliceKey)
        state.box = box
        submit(slicePNG: slicePNG, onMask: onMask)
    }

    /// Discard prompts and close the session, e.g. when the user leaves the tool.
    func clear() {
        inFlight?.cancel()
        inFlight = nil
        state.reset(sliceKey: state.sliceKey)
        lastError = nil
        closeSession()
    }

    /// Keep a subscription alive for as long as this session is.
    func observe(_ cancellable: AnyCancellable) {
        observers.insert(cancellable)
    }

    /// Release everything: the panel went away.
    func tearDown() {
        observers.removeAll()
        clear()
    }

    /// Called when the panel's slice changes.
    ///
    /// The cached embedding belongs to the old pixels, so it is released rather
    /// than reused — a mask decoded from a stale embedding would be plausible
    /// and wrong, which is worse than no mask.
    func sliceChanged(to sliceKey: String) {
        guard sliceKey != state.sliceKey else { return }
        inFlight?.cancel()
        inFlight = nil
        state.reset(sliceKey: sliceKey)
        closeSession()
    }

    private func prepare(for sliceKey: String) {
        if sliceKey != state.sliceKey {
            state.reset(sliceKey: sliceKey)
            closeSession()
        }
    }

    // MARK: - Invocation

    private func submit(slicePNG: @escaping () -> String?,
                        onMask: @escaping (PluginMask2D) -> Void) {
        inFlight?.cancel()
        inFlight = Task { [weak self] in
            guard let self else { return }
            self.isBusy = true
            self.lastError = nil
            defer { self.isBusy = false }

            guard let png = slicePNG() else {
                self.lastError = "Could not render the current slice."
                return
            }

            do {
                let sessionID = try await self.ensureSession(slicePNG: png)
                if Task.isCancelled { return }

                var invocation = PluginInvocation()
                invocation.sessionID = sessionID
                invocation.slice2d = png
                invocation.points = self.state.points.isEmpty ? nil : self.state.points
                invocation.box = self.state.box

                let result = try await self.runtime.invoke(self.ref, invocation)
                if Task.isCancelled { return }

                self.lastDecodeMS = result.elapsedMS
                if let mask = result.masks.first {
                    onMask(mask)
                } else {
                    self.lastError = "The plugin returned no mask for this prompt."
                }
            } catch is CancellationError {
                return
            } catch {
                // A session that failed may no longer exist adapter-side; drop
                // our handle so the next prompt re-opens rather than prompting
                // against a session the adapter has forgotten.
                self.sessionID = nil
                if LowMemoryStartPrompt.offerOverride(for: error, pluginID: self.pluginID,
                                                      runtime: self.runtime) {
                    self.submit(slicePNG: slicePNG, onMask: onMask)
                    return
                }
                self.lastError = error.localizedDescription
            }
        }
    }

    private func ensureSession(slicePNG: String) async throws -> String {
        if let sessionID { return sessionID }
        let openedFor = generation
        var opening = PluginInvocation()
        opening.slice2d = slicePNG
        let opened = try await runtime.openSession(pluginID: pluginID,
                                                  invocation: opening)
        guard openedFor == generation, !Task.isCancelled else {
            // The slice changed (or the panel closed) while the encoder ran.
            let runtime = self.runtime
            let pluginID = self.pluginID
            Task { try? await runtime.closeSession(pluginID: pluginID, sessionID: opened) }
            throw CancellationError()
        }
        sessionID = opened
        return opened
    }

    private func closeSession() {
        generation += 1
        guard let sessionID else { return }
        self.sessionID = nil
        let runtime = self.runtime
        let pluginID = self.pluginID
        // Fire-and-forget: the user has already moved on, and a failure to close
        // costs the adapter's own LRU eviction rather than correctness.
        Task { try? await runtime.closeSession(pluginID: pluginID,
                                               sessionID: sessionID) }
    }
}
