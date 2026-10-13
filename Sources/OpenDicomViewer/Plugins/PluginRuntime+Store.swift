// PluginRuntime+Store.swift
// OpenDicomViewer
//
// Conforms the concrete runtime to the narrow slice of it the store depends on.
//
// The store is written against `PluginRuntimeFacade` rather than against
// `PluginRuntime` so it can be built and tested without process supervision,
// virtualenv creation, or an HTTP client. This file is the only place the two
// meet, which keeps the seam explicit and reviewable.
// Licensed under the MIT License. See LICENSE for details.

import Combine
import Foundation

// MARK: - Install cancellation

/// Tracks in-flight installs so the store's Cancel action has something to act
/// on, and serializes installs that share a virtualenv.
///
/// Cancelling the task is sufficient to stop the work: the process runner
/// terminates pip and the weight hook when its task is cancelled. The record is
/// left in whatever state the installer wrote last, and `reverify()` demotes a
/// half-built environment on next launch.
///
/// Every task of a plugin installs into the plugin's one venv, so two of them
/// running at once had two pips writing the same site-packages. Installs are
/// therefore chained per plugin: a second one waits for the first to finish
/// (or to unwind after a cancel) and then finds the venv and shared weights
/// already in place.
@MainActor
private final class InstallTaskRegistry {
    private var tasks: [PluginTaskRef: Task<Void, Never>] = [:]
    /// The most recently queued install per plugin; the next one waits on it.
    private var tails: [String: Task<Void, Never>] = [:]

    func enqueue(_ ref: PluginTaskRef,
                 work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        // Re-installing the same task supersedes the earlier attempt.
        tasks[ref]?.cancel()
        let previous = tails[ref.pluginID]
        let task = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled else { return }
            await work()
        }
        tasks[ref] = task
        tails[ref.pluginID] = task
        return task
    }

    func finish(_ ref: PluginTaskRef, task: Task<Void, Never>) {
        if tasks[ref] == task { tasks[ref] = nil }
        if tails[ref.pluginID] == task { tails[ref.pluginID] = nil }
    }

    func cancel(_ ref: PluginTaskRef) {
        tasks[ref]?.cancel()
        tasks[ref] = nil
    }
}

@MainActor
private let installRegistry = InstallTaskRegistry()

// MARK: - Facade conformance

extension PluginRuntime: PluginRuntimeFacade {

    func installState(for ref: PluginTaskRef) -> PluginInstallState {
        installState(ref)
    }

    func runtimeState(for pluginID: String) -> PluginRuntimeState {
        runtimeStates[pluginID] ?? .stopped
    }

    /// Where a manually supplied checkpoint must be placed.
    ///
    /// Only `.manual` weights have a user-facing location; everything else is
    /// fetched into a host-owned directory the user never needs to see.
    func checkpointLocation(for ref: PluginTaskRef) -> PluginCheckpointLocation? {
        guard let plugin = manifest.plugin(id: ref.pluginID),
              let task = plugin.task(id: ref.taskID),
              let weight = task.weights.first(where: { $0.source == .manual })
        else { return nil }

        let path = manualWeightPath(pluginID: plugin.id, weight: weight)
        return PluginCheckpointLocation(fileURL: URL(fileURLWithPath: path))
    }

    func installLog(for ref: PluginTaskRef) -> String {
        log(for: ref.pluginID).text
    }

    /// Runs the install as a cancellable task so the store's Cancel action has
    /// a handle on it. The work itself lives in `performInstall`.
    func install(_ ref: PluginTaskRef, licenseKey: String?) async {
        let task = installRegistry.enqueue(ref) { [weak self] in
            await self?.performInstall(ref, licenseKey: licenseKey)
        }
        await task.value
        installRegistry.finish(ref, task: task)
    }

    func cancelInstall(_ ref: PluginTaskRef) async {
        installRegistry.cancel(ref)
        log(for: ref.pluginID).line("Install cancelled.")
        reloadInstallStates()
    }

    /// The store treats removal as advisory: a failure leaves the task where it
    /// was and surfaces in the log rather than as a thrown error it cannot act
    /// on.
    func remove(_ ref: PluginTaskRef) async {
        do {
            try await removeTask(ref)
        } catch {
            log(for: ref.pluginID).line("Remove failed: \(error.localizedDescription)")
            reloadInstallStates()
        }
    }

    @discardableResult
    func verifyCheckpoint(for ref: PluginTaskRef) async -> Bool {
        guard let location = checkpointLocation(for: ref) else { return false }
        let present = FileManager.default.fileExists(atPath: location.path)
        log(for: ref.pluginID).line(
            present
                ? "Checkpoint found at \(location.path)."
                : "Checkpoint not found at \(location.path).")
        reloadInstallStates()
        return present
    }

    func start(_ pluginID: String) async {
        do {
            try await startPlugin(pluginID)
        } catch {
            if LowMemoryStartPrompt.offerOverride(for: error, pluginID: pluginID, runtime: self) {
                await start(pluginID)
                return
            }
            log(for: pluginID).line("Start failed: \(error.localizedDescription)")
        }
    }

    var stateDidChange: AnyPublisher<Void, Never> {
        objectWillChange.eraseToAnyPublisher()
    }
}
