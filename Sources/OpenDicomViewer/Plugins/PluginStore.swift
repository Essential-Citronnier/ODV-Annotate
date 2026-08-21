// PluginStore.swift
// OpenDicomViewer
//
// View model for the plugin store: turns the bundled manifest plus live
// runtime state into a stable, filterable list of installable tasks, and
// routes user actions to the runtime through a narrow facade.
// See PLUGIN_PROTOCOL.md sections 6 and 7 for the gates and the install
// lifecycle this mirrors.
// Licensed under the MIT License. See LICENSE for details.

import Foundation
import Combine

// MARK: - Runtime facade

/// Where a `gated-download` task expects its checkpoint to be placed.
///
/// The store shows this path verbatim: a user who has to fetch a file by hand
/// cannot succeed unless the destination is unambiguous.
struct PluginCheckpointLocation: Equatable, Sendable {
    let directory: URL
    let filename: String

    init(directory: URL, filename: String) {
        self.directory = directory
        self.filename = filename
    }

    /// Split a full destination path, which is the form the installer computes.
    init(fileURL: URL) {
        self.init(directory: fileURL.deletingLastPathComponent(),
                  filename: fileURL.lastPathComponent)
    }

    var url: URL { directory.appendingPathComponent(filename) }
    var path: String { url.path }
}

/// The slice of the plugin runtime the store depends on.
///
/// Declared here, and deliberately narrow, so the store can be built, previewed
/// and tested against a mock without pulling in process supervision, virtualenv
/// creation, or the HTTP client. The concrete runtime conforms to it.
@MainActor
protocol PluginRuntimeFacade: AnyObject {
    /// The bundled manifest. Fixed for the lifetime of the process.
    var manifest: PluginManifest { get }

    func installState(for ref: PluginTaskRef) -> PluginInstallState
    func runtimeState(for pluginID: String) -> PluginRuntimeState

    /// Destination for a manually placed checkpoint, or nil when the task's
    /// weights are downloaded rather than supplied by the user.
    func checkpointLocation(for ref: PluginTaskRef) -> PluginCheckpointLocation?

    /// Streamed installer output for one task, oldest line first.
    func installLog(for ref: PluginTaskRef) -> String

    /// Install a task's environment and weights.
    ///
    /// `licenseKey` is passed straight through to the adapter's install step and
    /// must not be retained, logged, or written next to the manifest.
    func install(_ ref: PluginTaskRef, licenseKey: String?) async
    func cancelInstall(_ ref: PluginTaskRef) async
    func remove(_ ref: PluginTaskRef) async

    /// Re-check that a manually placed checkpoint is present, promoting the
    /// task out of `resolvingLicense` when it is. Returns presence.
    @discardableResult
    func verifyCheckpoint(for ref: PluginTaskRef) async -> Bool

    func start(_ pluginID: String) async
    func stop(_ pluginID: String) async

    /// Signals that install or runtime state may have changed. The store
    /// rebuilds its rows from this rather than polling.
    ///
    /// Must be sent on the main actor. It may fire either side of the mutation:
    /// an `ObservableObject` conformance will naturally forward
    /// `objectWillChange`, which fires first, so the store re-derives both
    /// synchronously and on the next runloop turn.
    var stateDidChange: AnyPublisher<Void, Never> { get }
}

// MARK: - Machine profile

/// What the store needs to know about the host machine to decide whether a
/// plugin can run here at all.
struct PluginMachineProfile: Equatable, Sendable {
    let isAppleSilicon: Bool
    /// Reported for the disabled-reason string, e.g. "Intel" or "Apple Silicon".
    let architectureName: String
    let physicalMemoryGB: Double

    static var current: PluginMachineProfile {
        let memoryGB = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
        #if arch(arm64)
        return PluginMachineProfile(isAppleSilicon: true,
                                    architectureName: "Apple Silicon",
                                    physicalMemoryGB: memoryGB)
        #else
        return PluginMachineProfile(isAppleSilicon: false,
                                    architectureName: "Intel",
                                    physicalMemoryGB: memoryGB)
        #endif
    }
}

// MARK: - Row model

/// The action the primary button on a row performs, derived from install state
/// and license gate together. The view renders a title and an accessibility
/// label from this rather than re-deriving the decision.
enum PluginStoreAction: Equatable, Sendable {
    case install
    case retryInstall
    /// Gate is `license-key`: collect a key before installing.
    case resolveLicenseKey
    /// Gate is `gated-download`: point the user at the terms and the drop path.
    case acquireCheckpoint
    case cancel
    case remove
    /// The machine cannot run this plugin; the button is inert.
    case unavailable

    var title: String {
        switch self {
        case .install: return "Install"
        case .retryInstall: return "Retry"
        case .resolveLicenseKey, .acquireCheckpoint: return "Resolve License"
        case .cancel: return "Cancel"
        case .remove: return "Remove"
        case .unavailable: return "Unavailable"
        }
    }

    /// Whether the action opens a gate sheet rather than acting immediately.
    var opensGateSheet: Bool {
        self == .resolveLicenseKey || self == .acquireCheckpoint
    }

    var isDestructive: Bool { self == .remove }
}

/// One installable task, flattened with everything the row needs to render.
struct PluginStoreRow: Identifiable, Equatable, Sendable {
    let ref: PluginTaskRef
    let pluginName: String
    let vendor: String
    let execution: PluginExecution
    let taskLabel: String
    let taskSummary: String
    /// Download size of this task's weights, in GB.
    let sizeGB: Double
    /// Declared peak resident memory of the owning plugin, in GB.
    let ramGB: Double
    let license: PluginLicense
    let requiresAppleSilicon: Bool
    let installState: PluginInstallState
    let runtimeState: PluginRuntimeState
    let checkpointLocation: PluginCheckpointLocation?
    /// False when the machine cannot run this plugin at all.
    let isSupported: Bool
    /// Why the action is blocked, phrased for display. Nil when it is not.
    let disabledReason: String?
    let action: PluginStoreAction

    var id: String { ref.description }

    var pluginID: String { ref.pluginID }
    var isInstalled: Bool { installState.isReady }

    /// Formatted for a badge: sub-gigabyte weights read better in MB.
    var sizeText: String {
        sizeGB < 1
            ? String(format: "%.0f MB", sizeGB * 1024)
            : String(format: "%.1f GB", sizeGB)
    }

    var ramText: String { String(format: "%.1f GB RAM", ramGB) }
}

/// A plugin and its tasks. Runtime lifecycle is per plugin, not per task, so
/// Start and Stop live on the group header.
struct PluginStoreGroup: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let vendor: String
    let summary: String
    let execution: PluginExecution
    let runtimeState: PluginRuntimeState
    let rows: [PluginStoreRow]

    /// A resident plugin can only be started once at least one of its tasks is
    /// installed; a one-shot plugin has no process to start.
    var canStart: Bool {
        execution.isResident && rows.contains(where: \.isInstalled)
    }

    var isRunning: Bool {
        runtimeState == .ready || runtimeState == .starting
    }
}

// MARK: - License key validation

/// Result of checking a typed license key against the manifest's declared
/// format. Validation is a courtesy to the user, not a security boundary: the
/// adapter remains the authority on whether a key works.
enum PluginLicenseKeyValidation: Equatable, Sendable {
    case valid
    case empty
    case wrongPrefix(expected: String)

    var isValid: Bool { self == .valid }

    var message: String? {
        switch self {
        case .valid: return nil
        case .empty: return "Enter the license number issued to you."
        case .wrongPrefix(let expected):
            return "This license number should begin with \"\(expected)\"."
        }
    }
}

// MARK: - Store

@MainActor
final class PluginStore: ObservableObject {

    /// All rows, grouped by plugin and filtered by the current query. Rebuilt
    /// whenever the runtime reports a transition.
    @Published private(set) var groups: [PluginStoreGroup] = []
    @Published var searchText: String = "" { didSet { refresh() } }
    @Published var showInstalledOnly: Bool = false { didSet { refresh() } }
    @Published var expandedPluginIDs: Set<String> = []

    let machine: PluginMachineProfile

    /// The store the application's own surfaces share.
    ///
    /// The menu and the sidebar live in different view trees, and a separate
    /// instance per tree would give each its own expansion, filter, and derived
    /// row state over the same underlying runtime — so an install begun from one
    /// would not be reflected in the other. Tests and previews construct their
    /// own instances against a mock facade instead.
    static let shared = PluginStore(facade: PluginRuntime.shared)

    private let facade: any PluginRuntimeFacade
    private var cancellables: Set<AnyCancellable> = []

    init(facade: any PluginRuntimeFacade,
         machine: PluginMachineProfile = .current) {
        self.facade = facade
        self.machine = machine
        // Everything ships expanded: the store lists a handful of plugins, and
        // a collapsed row hides exactly the size and license information the
        // user opened the store to compare.
        self.expandedPluginIDs = Set(facade.manifest.plugins.map(\.id))
        // Re-derive twice per signal, and deliberately so. A facade that sends
        // after mutating is served by the synchronous pass, which keeps the row
        // in step with the call that changed it; a facade that forwards
        // `objectWillChange` fires before the mutation, and only the deferred
        // pass sees the new value. Deriving rows is a pure fold over a handful
        // of manifest entries, so paying for it twice is cheaper than leaving
        // one of the two conformances subtly stale.
        facade.stateDidChange
            .sink { [weak self] in
                MainActor.assumeIsolated { self?.refresh() }
            }
            .store(in: &cancellables)
        facade.stateDidChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                MainActor.assumeIsolated { self?.refresh() }
            }
            .store(in: &cancellables)
        refresh()
    }

    // MARK: Derivation

    /// Rebuild the row list from the manifest and current runtime state.
    ///
    /// Sorting is by name with the identifier as tie-break, so a refresh
    /// triggered mid-install cannot reshuffle rows under the pointer.
    func refresh() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let plugins = facade.manifest.plugins.sorted {
            ($0.name, $0.id) < ($1.name, $1.id)
        }

        groups = plugins.compactMap { descriptor in
            let rows = descriptor.tasks
                .sorted { ($0.label, $0.id) < ($1.label, $1.id) }
                .map { row(for: $0, in: descriptor) }
                .filter { matches($0, descriptor: descriptor, query: query) }
            guard !rows.isEmpty else { return nil }
            return PluginStoreGroup(
                id: descriptor.id,
                name: descriptor.name,
                vendor: descriptor.vendor,
                summary: descriptor.summary,
                execution: descriptor.execution,
                runtimeState: facade.runtimeState(for: descriptor.id),
                rows: rows)
        }
    }

    /// Flat view of the filtered rows, in display order.
    var rows: [PluginStoreRow] { groups.flatMap(\.rows) }

    func row(for ref: PluginTaskRef) -> PluginStoreRow? {
        rows.first { $0.ref == ref }
    }

    private func row(for task: PluginTask,
                     in descriptor: PluginDescriptor) -> PluginStoreRow {
        let ref = PluginTaskRef(pluginID: descriptor.id, taskID: task.id)
        let state = facade.installState(for: ref)
        let reason = unsupportedReason(for: descriptor)
        return PluginStoreRow(
            ref: ref,
            pluginName: descriptor.name,
            vendor: descriptor.vendor,
            execution: descriptor.execution,
            taskLabel: task.label,
            taskSummary: task.summary,
            sizeGB: task.weightsSizeGB,
            ramGB: descriptor.declaredRAMGB(forTask: task.id),
            license: task.license,
            requiresAppleSilicon: descriptor.requiresAppleSilicon,
            installState: state,
            runtimeState: facade.runtimeState(for: descriptor.id),
            checkpointLocation: facade.checkpointLocation(for: ref),
            isSupported: reason == nil,
            disabledReason: reason,
            action: reason == nil
                ? Self.action(for: state, gate: task.license.gate)
                : .unavailable)
    }

    /// The single reason this machine cannot run the plugin, or nil.
    ///
    /// Only hard blocks belong here. A plugin that merely competes for memory
    /// is the arbiter's problem at run time, not the store's at install time;
    /// a plugin whose declared peak exceeds installed RAM can never succeed and
    /// is worth saying so before a multi-gigabyte download.
    private func unsupportedReason(for descriptor: PluginDescriptor) -> String? {
        if descriptor.requiresAppleSilicon && !machine.isAppleSilicon {
            return "\(descriptor.name) requires Apple Silicon. "
                + "This Mac reports \(machine.architectureName)."
        }
        // Compared against the LIGHTEST task, so a plugin is called unsupported
        // only when nothing it offers can run. A per-task declaration can exceed
        // this Mac while a sibling task still fits, and that case belongs on the
        // row rather than on the whole plugin.
        let lightest = descriptor.tasks
            .map { descriptor.declaredRAMGB(forTask: $0.id) }
            .min() ?? descriptor.ramGB
        if lightest > machine.physicalMemoryGB {
            return String(
                format: "%@ declares %.1f GB peak memory for its smallest task; "
                    + "this Mac has %.1f GB.",
                descriptor.name, lightest, machine.physicalMemoryGB)
        }
        return nil
    }

    /// Install state and license gate together decide the button. Kept static
    /// and total so the mapping is testable in isolation.
    static func action(for state: PluginInstallState,
                       gate: PluginLicenseGate) -> PluginStoreAction {
        switch state {
        case .ready:
            return .remove
        case .downloading, .installing:
            return .cancel
        case .resolvingLicense:
            return gateAction(for: gate)
        case .notInstalled:
            return gate == .open ? .install : gateAction(for: gate)
        case .failed:
            return gate == .open ? .retryInstall : gateAction(for: gate)
        }
    }

    private static func gateAction(for gate: PluginLicenseGate) -> PluginStoreAction {
        switch gate {
        case .open: return .install
        case .licenseKey: return .resolveLicenseKey
        case .gatedDownload: return .acquireCheckpoint
        }
    }

    private func matches(_ row: PluginStoreRow,
                         descriptor: PluginDescriptor,
                         query: String) -> Bool {
        if showInstalledOnly && !row.isInstalled { return false }
        guard !query.isEmpty else { return true }
        let haystack = [descriptor.name, descriptor.vendor, descriptor.summary,
                        row.taskLabel, row.taskSummary, row.license.identifier]
        return haystack.contains {
            $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    // MARK: Actions

    /// Perform a row's primary action, for the cases that do not need a gate
    /// sheet first. Gate actions are presented by the view and land back here
    /// through `submitLicenseKey` or `verifyCheckpoint`.
    func perform(_ action: PluginStoreAction, on ref: PluginTaskRef) async {
        switch action {
        case .install, .retryInstall:
            await facade.install(ref, licenseKey: nil)
        case .cancel:
            await facade.cancelInstall(ref)
        case .remove:
            await facade.remove(ref)
        case .resolveLicenseKey, .acquireCheckpoint, .unavailable:
            break
        }
    }

    /// Validate a typed key against the manifest's declared prefix.
    func validate(licenseKey key: String, for ref: PluginTaskRef)
        -> PluginLicenseKeyValidation {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard let expected = license(for: ref)?.keyFormat, !expected.isEmpty else {
            return .valid
        }
        guard trimmed.hasPrefix(expected), trimmed.count > expected.count else {
            return .wrongPrefix(expected: expected)
        }
        return .valid
    }

    /// Hand a validated key to the runtime and begin the install.
    ///
    /// The key is a parameter and never becomes store state: nothing here is
    /// published, persisted, or written to the install log.
    @discardableResult
    func submitLicenseKey(_ key: String, for ref: PluginTaskRef) async -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validate(licenseKey: trimmed, for: ref).isValid else { return false }
        await facade.install(ref, licenseKey: trimmed)
        return true
    }

    @discardableResult
    func verifyCheckpoint(for ref: PluginTaskRef) async -> Bool {
        await facade.verifyCheckpoint(for: ref)
    }

    func start(_ pluginID: String) async { await facade.start(pluginID) }
    func stop(_ pluginID: String) async { await facade.stop(pluginID) }

    func installLog(for ref: PluginTaskRef) -> String { facade.installLog(for: ref) }

    func license(for ref: PluginTaskRef) -> PluginLicense? {
        facade.manifest.plugin(id: ref.pluginID)?.task(id: ref.taskID)?.license
    }

    // MARK: Menu availability

    /// Whether a task can be invoked right now, and if not, the short reason to
    /// show beside the disabled menu item.
    ///
    /// Lives here rather than in the menu view because it is the same judgement
    /// the store's action column makes, and the two must not drift: a menu item
    /// that offers to run a task the store calls uninstalled is a bug report.
    struct MenuAvailability: Equatable, Sendable {
        let isRunnable: Bool
        /// Nil exactly when `isRunnable` is true.
        let reason: String?
    }

    func menuAvailability(for row: PluginStoreRow) -> MenuAvailability {
        if !row.isSupported {
            return MenuAvailability(isRunnable: false, reason: "unavailable on this Mac")
        }
        if !row.isInstalled {
            let reason: String
            switch row.installState {
            case .resolvingLicense: reason = "license required"
            case .downloading, .installing: reason = "installing"
            case .failed: reason = "install failed"
            default: reason = "not installed"
            }
            return MenuAvailability(isRunnable: false, reason: reason)
        }
        // A one-shot plugin is spawned per invocation and needs no running
        // process; a resident or session plugin must already be up.
        if row.execution.isResident && !row.runtimeState.isReady {
            return MenuAvailability(isRunnable: false, reason: "plugin not running")
        }
        return MenuAvailability(isRunnable: true, reason: nil)
    }

    // MARK: Disclosure

    func isExpanded(_ pluginID: String) -> Bool {
        expandedPluginIDs.contains(pluginID)
    }

    func setExpanded(_ expanded: Bool, for pluginID: String) {
        if expanded {
            expandedPluginIDs.insert(pluginID)
        } else {
            expandedPluginIDs.remove(pluginID)
        }
    }

    // MARK: Standing text

    /// Shown in the store footer at all times, not behind a disclosure.
    ///
    /// The wording is deliberate and load-bearing: it is the user-facing
    /// statement of PLUGIN_PROTOCOL.md invariants 1 and 3, and it must stay
    /// true of every plugin the manifest can ever list.
    static let privacyStatement =
        "Installing a plugin downloads model weights and Python packages only. "
        + "Inference runs entirely on this Mac: images, DICOM metadata, and any "
        + "masks, measurements, or text derived from them are never transmitted "
        + "off the machine."

    static let researchUseStatement =
        "Plugin output is for research use only. It is not a diagnosis and must "
        + "not be used as the basis for clinical decisions."
}

// MARK: - Mock facade

/// In-memory facade for SwiftUI previews and tests.
///
/// It models the state machine of PLUGIN_PROTOCOL.md section 7 closely enough
/// to drive the UI, and records the license key it was handed so tests can
/// assert the key reached the install call without the store retaining it.
@MainActor
final class MockPluginRuntimeFacade: PluginRuntimeFacade {
    let manifest: PluginManifest

    private(set) var installStates: [PluginTaskRef: PluginInstallState] = [:]
    private(set) var runtimeStates: [String: PluginRuntimeState] = [:]
    private var logs: [PluginTaskRef: String] = [:]
    private var checkpointsPresent: Set<PluginTaskRef> = []

    /// Call record for tests.
    private(set) var installCalls: [(ref: PluginTaskRef, licenseKey: String?)] = []
    private(set) var removeCalls: [PluginTaskRef] = []
    private(set) var cancelCalls: [PluginTaskRef] = []
    private(set) var startCalls: [String] = []
    private(set) var stopCalls: [String] = []
    private(set) var verifyCalls: [PluginTaskRef] = []

    private let subject = PassthroughSubject<Void, Never>()
    var stateDidChange: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }

    private let checkpointRoot: URL

    init(manifest: PluginManifest,
         checkpointRoot: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/OpenDicomViewer/Plugins")) {
        self.manifest = manifest
        self.checkpointRoot = checkpointRoot
    }

    func installState(for ref: PluginTaskRef) -> PluginInstallState {
        installStates[ref] ?? .notInstalled
    }

    func runtimeState(for pluginID: String) -> PluginRuntimeState {
        runtimeStates[pluginID] ?? .stopped
    }

    func checkpointLocation(for ref: PluginTaskRef) -> PluginCheckpointLocation? {
        guard let task = manifest.plugin(id: ref.pluginID)?.task(id: ref.taskID),
              let weight = task.weights.first(where: { $0.source == .manual }),
              let filename = weight.filename else { return nil }
        return PluginCheckpointLocation(
            directory: checkpointRoot.appendingPathComponent(ref.pluginID),
            filename: filename)
    }

    func installLog(for ref: PluginTaskRef) -> String { logs[ref] ?? "" }

    func install(_ ref: PluginTaskRef, licenseKey: String?) async {
        installCalls.append((ref, licenseKey))
        // The key is used and dropped; only its presence is ever recorded.
        logs[ref, default: ""] += "Resolving weights for \(ref)\n"
        set(.downloading(progress: 0), for: ref)
    }

    func cancelInstall(_ ref: PluginTaskRef) async {
        cancelCalls.append(ref)
        set(.notInstalled, for: ref)
    }

    func remove(_ ref: PluginTaskRef) async {
        removeCalls.append(ref)
        logs[ref] = ""
        set(.notInstalled, for: ref)
    }

    @discardableResult
    func verifyCheckpoint(for ref: PluginTaskRef) async -> Bool {
        verifyCalls.append(ref)
        let present = checkpointsPresent.contains(ref)
        set(present ? .ready : .resolvingLicense, for: ref)
        return present
    }

    func start(_ pluginID: String) async {
        startCalls.append(pluginID)
        setRuntime(.ready, for: pluginID)
    }

    func stop(_ pluginID: String) async {
        stopCalls.append(pluginID)
        setRuntime(.stopped, for: pluginID)
    }

    // MARK: Test drivers

    func set(_ state: PluginInstallState, for ref: PluginTaskRef) {
        installStates[ref] = state
        subject.send()
    }

    func setRuntime(_ state: PluginRuntimeState, for pluginID: String) {
        runtimeStates[pluginID] = state
        subject.send()
    }

    func setCheckpointPresent(_ present: Bool, for ref: PluginTaskRef) {
        if present { checkpointsPresent.insert(ref) } else { checkpointsPresent.remove(ref) }
    }

    func appendLog(_ line: String, for ref: PluginTaskRef) {
        logs[ref, default: ""] += line + "\n"
        subject.send()
    }
}
