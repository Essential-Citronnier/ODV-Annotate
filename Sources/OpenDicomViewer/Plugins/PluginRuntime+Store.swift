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
/// on. The installer itself is structured-concurrency based, so cancelling the
/// task is sufficient; the record is left in whatever state the installer wrote
/// last, and `reverify()` demotes a half-built environment on next launch.
@MainActor
private final class InstallTaskRegistry {
    private var tasks: [PluginTaskRef: Task<Void, Never>] = [:]

    func register(_ ref: PluginTaskRef, task: Task<Void, Never>) {
        tasks[ref]?.cancel()
        tasks[ref] = task
    }

    func finish(_ ref: PluginTaskRef) {
        tasks[ref] = nil
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
    /// a handle on it. `PluginRuntime.install` itself takes a defaulted
    /// `licenseKey`, which already satisfies the facade requirement; this
    /// wrapper exists only to register the task.
    func beginInstall(_ ref: PluginTaskRef, licenseKey: String?) async {
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.install(ref, licenseKey: licenseKey)
            installRegistry.finish(ref)
        }
        installRegistry.register(ref, task: task)
        await task.value
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
            log(for: pluginID).line("Start failed: \(error.localizedDescription)")
        }
    }

    var stateDidChange: AnyPublisher<Void, Never> {
        objectWillChange.eraseToAnyPublisher()
    }
}
