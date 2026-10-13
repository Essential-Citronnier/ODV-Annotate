// PluginRuntime.swift
// OpenDicomViewer
//
// The plugin supervisor: process lifecycle, port assignment, health gating,
// and invocation routing for all three execution models in
// PLUGIN_PROTOCOL.md section 1. Generalizes AIServerManager, which supervises a
// single hard-coded engine on a fixed port.
// Licensed under the MIT License. See LICENSE for details.

import Foundation
import Darwin
import CoreGraphics

// MARK: - Port assignment

/// Hands out loopback ports for resident plugins.
///
/// Ports are obtained by binding to port 0 and asking the kernel what it chose,
/// which is the only way to get a port that is genuinely free rather than merely
/// unfashionable. Between the probe closing its socket and the adapter binding,
/// another process could in principle take the port; the allocator therefore
/// remembers what it has issued so it never hands the same number to two
/// plugins, and a plugin that loses the race fails its health poll and is
/// restarted rather than silently talking to a stranger.
///
/// The probe is injectable so tests can exercise the bookkeeping deterministically.
struct PluginPortAllocator: Sendable {
    private(set) var assigned: [String: Int] = [:]
    private var probe: @Sendable () -> Int?

    init(probe: @escaping @Sendable () -> Int? = { PluginPortAllocator.freeLoopbackPort() }) {
        self.probe = probe
    }

    /// The port already assigned to `pluginID`, or a newly reserved one.
    mutating func port(for pluginID: String) throws -> Int {
        if let existing = assigned[pluginID] { return existing }
        let taken = Set(assigned.values)
        // A handful of attempts covers the case where the kernel offers a port
        // this allocator has already reserved for a plugin that has not yet bound.
        for _ in 0..<16 {
            guard let candidate = probe() else { break }
            if !taken.contains(candidate) {
                assigned[pluginID] = candidate
                return candidate
            }
        }
        throw PluginError.transport("Could not reserve a local port for \(pluginID).")
    }

    mutating func release(_ pluginID: String) {
        assigned[pluginID] = nil
    }

    /// Ask the kernel for an unused loopback port.
    static func freeLoopbackPort() -> Int? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }

        var resolved = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &resolved) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else { return nil }
        return Int(UInt16(bigEndian: resolved.sin_port))
    }
}

// MARK: - Wire types

/// `GET /health` response (PLUGIN_PROTOCOL.md section 3).
struct PluginHealth: Decodable, Equatable, Sendable {
    enum Status: String, Decodable, Sendable {
        case loading, ready, error
    }

    let status: Status
    let pluginID: String?
    let protocolVersion: Int
    let detail: String?
    let memoryMB: Double?

    enum CodingKeys: String, CodingKey {
        case status, detail
        case pluginID = "plugin_id"
        case protocolVersion = "protocol"
        case memoryMB = "memory_mb"
    }
}

/// The error object shared by the HTTP and CLI contracts.
struct PluginErrorPayload: Decodable, Equatable, Sendable {
    let code: PluginErrorCode
    let message: String
    let recoverable: Bool?

    private enum CodingKeys: String, CodingKey { case code, message, recoverable }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // An adapter that invents a code should not take the whole result down;
        // an unrecognized code is an internal error as far as the host is concerned.
        let raw = try container.decodeIfPresent(String.self, forKey: .code) ?? "internal"
        code = PluginErrorCode(rawValue: raw) ?? .internalError
        message = try container.decodeIfPresent(String.self, forKey: .message)
            ?? "The plugin reported an error."
        recoverable = try container.decodeIfPresent(Bool.self, forKey: .recoverable)
    }

    init(code: PluginErrorCode, message: String, recoverable: Bool? = nil) {
        self.code = code
        self.message = message
        self.recoverable = recoverable
    }

    /// Map onto the host's error type. `license_required` becomes
    /// `PluginError.licenseRequired` so the store can route it to its gate UI
    /// instead of showing a generic failure (section 6).
    func asPluginError(ref: PluginTaskRef) -> PluginError {
        switch code {
        case .licenseRequired: return .licenseRequired(ref, message: message)
        case .notReady: return .notReady(message)
        default: return .adapter(code: code, message: message)
        }
    }
}

/// `POST /session/open` response.
struct PluginSessionHandle: Decodable, Equatable, Sendable {
    let sessionID: String
    let encodeMS: Int?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case encodeMS = "encode_ms"
    }
}

// MARK: - Payload coding

/// Builds request bodies and decodes result payloads.
///
/// Free functions over `Data`, deliberately, so the tests can drive the exact
/// shapes in PLUGIN_PROTOCOL.md sections 3 and 4 from fixtures without a
/// process or a socket anywhere in sight.
enum PluginPayloadCoder {

    /// Encode an invocation into a `POST /task/<id>` body.
    static func requestBody(_ invocation: PluginInvocation) throws -> Data {
        var body: [String: Any] = [:]
        if let sessionID = invocation.sessionID { body["session_id"] = sessionID }

        var inputs: [String: Any] = [:]
        if let slice = invocation.slice2d { inputs["slice2d"] = slice }
        if let series = invocation.series3d { inputs["series3d"] = series }
        if let text = invocation.text { inputs["text"] = text }
        if let roi = invocation.roi { inputs["roi"] = rect(roi) }
        if let box = invocation.box { inputs["box"] = rect(box) }
        if let points = invocation.points {
            inputs["points"] = points.map { ["x": $0.x, "y": $0.y, "label": $0.isForeground ? 1 : 0] }
        }
        if !inputs.isEmpty { body["inputs"] = inputs }

        if !invocation.options.isEmpty {
            body["options"] = invocation.options.mapValues(jsonValue)
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// Command-line arguments for a one-shot invocation (section 4).
    static func commandLineArguments(
        taskID: String, outputDirectory: URL, invocation: PluginInvocation
    ) -> [String] {
        var arguments = ["--task", taskID, "--out", outputDirectory.path]
        if let series = invocation.series3d { arguments += ["--input-series3d", series] }
        if let slice = invocation.slice2d { arguments += ["--input-slice2d", slice] }
        if let text = invocation.text { arguments += ["--input-text", text] }
        if let roi = invocation.roi { arguments += ["--input-roi", rectString(roi)] }
        if let box = invocation.box { arguments += ["--input-box", rectString(box)] }
        if let points = invocation.points, !points.isEmpty {
            arguments += ["--input-points", points
                .map { "\($0.x),\($0.y),\($0.isForeground ? 1 : 0)" }
                .joined(separator: ";")]
        }
        // Sorted so a spawn is reproducible and comparable in the log.
        for key in invocation.options.keys.sorted() {
            arguments += ["--opt-\(key)", stringValue(invocation.options[key]!)]
        }
        return arguments
    }

    /// Decode a task response or a `result.json`.
    ///
    /// `relativeTo` resolves the relative output paths the CLI contract uses;
    /// pass nil for HTTP responses, whose paths are already absolute.
    static func decodeResult(_ data: Data, ref: PluginTaskRef, relativeTo base: URL?) throws -> PluginResult {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PluginError.transport("The plugin returned a response that is not JSON.")
        }

        // `ok` absent is treated as success only when there is no error object:
        // an adapter that writes just `{"error": ...}` should not read as success.
        let ok = object["ok"] as? Bool ?? (object["error"] == nil)
        if !ok || object["error"] != nil {
            let payload: PluginErrorPayload
            if let errorObject = object["error"],
               let errorData = try? JSONSerialization.data(withJSONObject: errorObject),
               let decoded = try? JSONDecoder().decode(PluginErrorPayload.self, from: errorData) {
                payload = decoded
            } else {
                payload = PluginErrorPayload(code: .internalError,
                                             message: "The plugin reported an unspecified failure.")
            }
            throw payload.asPluginError(ref: ref)
        }

        var result = PluginResult()
        result.raw = String(data: data, encoding: .utf8)
        result.elapsedMS = object["elapsed_ms"] as? Int

        guard let outputs = object["outputs"] as? [String: Any] else { return result }

        result.text = outputs["text"] as? String

        if let boxes = outputs["bbox"],
           let boxData = try? JSONSerialization.data(withJSONObject: boxes),
           let decoded = try? JSONDecoder().decode([PluginBoundingBox].self, from: boxData) {
            result.bboxes = decoded
        }

        if let mask = outputs["mask2d"] {
            // Section 3 shows a single object; an adapter returning several
            // candidate masks is a compatible extension, so accept both.
            let container = mask is [Any] ? mask : [mask]
            if let maskData = try? JSONSerialization.data(withJSONObject: container),
               let decoded = try? JSONDecoder().decode([PluginMask2D].self, from: maskData) {
                result.masks = decoded
            }
        }

        if let seg = outputs["seg3d"] as? String {
            result.seg3dPath = resolve(path: seg, relativeTo: base)
        }

        if let metrics = outputs["metrics"] as? [String: Any] {
            result.metrics = metrics.compactMapValues { value in
                (value as? Double) ?? (value as? Int).map(Double.init) ?? (value as? NSNumber)?.doubleValue
            }
        }

        return result
    }

    /// Relative output paths are resolved against the run's output directory
    /// (section 4); absolute ones are taken as given.
    static func resolve(path: String, relativeTo base: URL?) -> String {
        guard let base, !path.hasPrefix("/") else { return path }
        return base.appendingPathComponent(path).path
    }

    // MARK: Helpers

    private static func rect(_ value: CGRect) -> [String: Double] {
        ["x": value.origin.x, "y": value.origin.y,
         "width": value.size.width, "height": value.size.height]
    }

    private static func rectString(_ value: CGRect) -> String {
        "\(value.origin.x),\(value.origin.y),\(value.size.width),\(value.size.height)"
    }

    private static func jsonValue(_ value: PluginOption.OptionValue) -> Any {
        switch value {
        case .string(let s): return s
        case .bool(let b): return b
        case .number(let d): return d
        }
    }

    static func stringValue(_ value: PluginOption.OptionValue) -> String {
        switch value {
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .number(let d): return d == d.rounded() ? String(Int(d)) : String(d)
        }
    }
}

// MARK: - Runtime

/// Supervises every installed plugin.
///
/// One instance owns the manifest, the install store, the installer, the
/// arbiter, and the processes. `AIServerManager` remains in place for the
/// legacy single-engine path; this type is what the plugin store and the AI
/// panel talk to.
@MainActor
final class PluginRuntime: ObservableObject {

    static let shared = PluginRuntime()

    // MARK: Published state

    @Published private(set) var manifest: PluginManifest = PluginManifest(
        schemaVersion: 1, protocolVersion: kPluginProtocolVersion, plugins: [])
    @Published private(set) var runtimeStates: [String: PluginRuntimeState] = [:]
    @Published private(set) var installStates: [PluginTaskRef: PluginInstallState] = [:]
    @Published private(set) var assignedPorts: [String: Int] = [:]
    /// Fractional progress of an in-flight one-shot invocation, per plugin.
    @Published private(set) var activityProgress: [String: Double] = [:]
    @Published private(set) var loadError: String?

    // MARK: Collaborators

    let paths: PluginPaths
    let store: PluginInstallStore
    let installer: PluginInstaller
    var arbiter: ResourceArbiter

    private var locator: PluginEnvironmentLocator
    private var ports: PluginPortAllocator
    private var processes: [String: Process] = [:]
    /// The start in progress per plugin. Concurrent callers await this one
    /// task rather than each racing to spawn and health-poll their own server.
    private var startTasks: [String: InFlightStart] = [:]
    /// Pids this runtime terminated on purpose, so their exit is reported as
    /// a stop rather than as a crash.
    private var deliberateStops: Set<Int32> = []
    private var logs: [String: PluginLogBuffer] = [:]
    private var lastUsed: [String: Date] = [:]
    /// Invocations in flight per plugin. These are not evicted out from under
    /// the user.
    ///
    /// A count rather than a set: two overlapping invocations of one plugin (a
    /// prompt decode while an analysis runs, say) each mark it busy, and with a
    /// set the first to finish cleared the flag while the second was still
    /// running, making a working plugin evictable.
    private var busyCounts: [String: Int] = [:]
    /// Task id of the one-shot invocation currently running for a plugin.
    ///
    /// Needed because a one-shot's declared footprint is per task, and residency
    /// accounting has to know WHICH task is running to budget against the right
    /// figure.
    private var runningOneShotTasks: [String: String] = [:]
    private var sessions: [String: SessionLedger] = [:]
    private let urlSession: URLSession

    // MARK: Init

    init(paths: PluginPaths = .standard,
         locator: PluginEnvironmentLocator? = nil,
         arbiter: ResourceArbiter = ResourceArbiter(),
         portProbe: (@Sendable () -> Int?)? = nil) {
        self.paths = paths
        let resolvedLocator = locator ?? PluginEnvironmentLocator.standard(paths: paths)
        self.locator = resolvedLocator
        let store = PluginInstallStore(paths: paths)
        self.store = store
        self.installer = PluginInstaller(locator: resolvedLocator, store: store)
        self.arbiter = arbiter
        self.ports = portProbe.map { PluginPortAllocator(probe: $0) } ?? PluginPortAllocator()

        let configuration = URLSessionConfiguration.ephemeral
        // A resident model can take tens of seconds to answer; the ceiling exists
        // to surface a wedged adapter, not to bound inference.
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 1800
        self.urlSession = URLSession(configuration: configuration)
    }

    // MARK: Loading

    /// Load the bundled manifest and reconcile persisted install state with the
    /// filesystem. Safe to call more than once.
    func load(manifestURL: URL? = nil) {
        do {
            manifest = try manifestURL.map { try PluginManifest.load(contentsOf: $0) }
                ?? PluginManifest.loadBundled()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
            return
        }

        store.load()
        store.reverify(manifest: manifest)
        refreshInstallStates()
        for plugin in manifest.plugins where runtimeStates[plugin.id] == nil {
            runtimeStates[plugin.id] = .stopped
            sessions[plugin.id] = SessionLedger(limit: plugin.maxSessions ?? 1)
        }
    }

    /// Re-derive install state from disk.
    ///
    /// Exposed for the store-facing conformance in PluginRuntime+Store.swift,
    /// which must refresh after actions the store drives.
    func reloadInstallStates() {
        refreshInstallStates()
    }

    private func refreshInstallStates() {
        var states: [PluginTaskRef: PluginInstallState] = [:]
        for plugin in manifest.plugins {
            for task in plugin.tasks {
                let ref = PluginTaskRef(pluginID: plugin.id, taskID: task.id)
                states[ref] = store.state(for: ref)
            }
        }
        installStates = states
    }

    // MARK: Accessors

    func plugin(_ id: String) throws -> PluginDescriptor {
        guard let plugin = manifest.plugin(id: id) else { throw PluginError.unknownPlugin(id) }
        return plugin
    }

    func resolve(_ ref: PluginTaskRef) throws -> (PluginDescriptor, PluginTask) {
        let plugin = try plugin(ref.pluginID)
        guard let task = plugin.task(id: ref.taskID) else { throw PluginError.unknownTask(ref) }
        return (plugin, task)
    }

    func installState(_ ref: PluginTaskRef) -> PluginInstallState {
        installStates[ref] ?? .notInstalled
    }

    func runtimeState(_ pluginID: String) -> PluginRuntimeState {
        runtimeStates[pluginID] ?? .stopped
    }

    /// Log buffer for a plugin, created on first request so the store can bind
    /// to it before anything has been installed.
    func log(for pluginID: String) -> PluginLogBuffer {
        if let existing = logs[pluginID] { return existing }
        let buffer = PluginLogBuffer()
        logs[pluginID] = buffer
        return buffer
    }

    /// The exact path a `gated-download` checkpoint must be placed at, for the
    /// store to show verbatim.
    func manualWeightPath(pluginID: String, weight: PluginWeight) -> String {
        paths.manualWeightPath(pluginID: pluginID, weight: weight).path
    }

    /// Disk currently attributable to a plugin.
    func bytesOnDisk(pluginID: String) -> Int64 {
        store.records(forPlugin: pluginID).map(\.bytesOnDisk).max() ?? 0
    }

    // MARK: Installation

    /// Install a task. `licenseKey` is forwarded to the adapter for this call
    /// only and is never persisted or logged.
    /// Perform the install synchronously with respect to the caller.
    ///
    /// Named distinctly from the store facade's `install(_:licenseKey:)`, which
    /// wraps this in a cancellable task so the store's Cancel action has a
    /// handle on it. Default arguments do not distinguish declarations, so the
    /// two cannot share a name.
    func performInstall(_ ref: PluginTaskRef, licenseKey: String? = nil) async {
        guard let (plugin, task) = try? resolve(ref) else { return }
        let buffer = log(for: plugin.id)
        buffer.line("Installing \(task.label)…")

        let installer = self.installer
        await installer.install(
            plugin: plugin,
            task: task,
            licenseKey: licenseKey,
            onState: { [weak self] ref, state in
                Task { @MainActor in self?.installStates[ref] = state }
            },
            onLog: { [weak self] pluginID, line in
                Task { @MainActor in self?.log(for: pluginID).line(line) }
            })
        refreshInstallStates()
    }

    /// Remove a task's weights, and the venv when no sibling task needs it.
    ///
    /// Named distinctly from the store facade's non-throwing `remove(_:)`,
    /// which delegates here; Swift cannot host both spellings on one type.
    func removeTask(_ ref: PluginTaskRef) async throws {
        let (plugin, task) = try resolve(ref)
        if runtimeState(plugin.id) != .stopped { await stop(plugin.id) }
        try installer.remove(plugin: plugin, task: task, onLog: { [weak self] pluginID, line in
            Task { @MainActor in self?.log(for: pluginID).line(line) }
        })
        refreshInstallStates()
    }

    // MARK: Residency accounting

    /// The arbiter's view of what currently holds memory.
    ///
    /// Includes plugins with an in-flight one-shot invocation. A one-shot never
    /// enters `runtimeStates` — it is spawned, counted in `busyCounts`, and reaped
    /// without ever becoming `.ready` — so filtering on runtime state alone hid
    /// it from admission, and the heaviest process on the machine was the one
    /// the arbiter could not see. On a memory-constrained machine that allowed a
    /// resident engine to start alongside a segmentation run, each invisible to
    /// the other.
    ///
    /// An in-flight one-shot is never evictable: stopping it would discard work
    /// already done, and unlike a resident server it cannot be transparently
    /// restarted.
    func residentSet(excluding pluginID: String? = nil) -> [PluginResidency] {
        manifest.plugins.compactMap { plugin -> PluginResidency? in
            guard plugin.id != pluginID else { return nil }

            let oneShotRunning = plugin.execution == .oneShot && isBusy(plugin.id)
            guard runtimeState(plugin.id) != .stopped || oneShotRunning else { return nil }

            // A one-shot's footprint is the task's, which can exceed the
            // plugin-wide figure several-fold.
            let declared = oneShotRunning
                ? (runningOneShotTasks[plugin.id].map { plugin.declaredRAMGB(forTask: $0) }
                    ?? plugin.ramGB)
                : plugin.ramGB

            return PluginResidency(
                pluginID: plugin.id,
                declaredRamGB: declared,
                lastUsed: lastUsed[plugin.id] ?? .distantPast,
                isEvictable: !oneShotRunning
                    && !isBusy(plugin.id)
                    && (sessions[plugin.id]?.order.isEmpty ?? true))
        }
    }

    /// What a one-shot invocation of `pluginID` must be admitted against.
    ///
    /// By the time admission runs, `invoke` has already marked the requester
    /// busy, so `residentSet()` reports it as an in-flight one-shot holding its
    /// declared peak. Admitting it against that set charged the declaration
    /// twice -- for TotalSegmentator 47 GB for a 23.5 GB job, refused on every
    /// machine below 96 GB. The requester is excluded unless another run of the
    /// same plugin was already in flight, which genuinely holds that memory.
    func oneShotAdmissionResidents(for pluginID: String) -> [PluginResidency] {
        busyCount(pluginID) > 1 ? residentSet() : residentSet(excluding: pluginID)
    }

    // MARK: Busy accounting

    func isBusy(_ pluginID: String) -> Bool {
        busyCount(pluginID) > 0
    }

    func busyCount(_ pluginID: String) -> Int {
        busyCounts[pluginID] ?? 0
    }

    /// Mark an invocation of `ref` as started. Paired with `endInvocation`.
    func beginInvocation(_ ref: PluginTaskRef, execution: PluginExecution) {
        busyCounts[ref.pluginID, default: 0] += 1
        if execution == .oneShot { runningOneShotTasks[ref.pluginID] = ref.taskID }
    }

    func endInvocation(_ ref: PluginTaskRef) {
        let remaining = max(0, busyCount(ref.pluginID) - 1)
        busyCounts[ref.pluginID] = remaining == 0 ? nil : remaining
        if remaining == 0 { runningOneShotTasks.removeValue(forKey: ref.pluginID) }
        lastUsed[ref.pluginID] = Date()
    }

    /// Apply an admission decision, stopping whatever it names.
    private func applyAdmission(_ decision: AdmissionDecision, requester: String) async throws {
        if let error = decision.refusalError {
            log(for: requester).line("Refused: \(error.localizedDescription)")
            throw error
        }
        for victim in decision.evictions {
            log(for: requester).line("Stopping \(victim) to free memory.")
            await stop(victim)
        }
    }

    // MARK: Start and stop

    /// Start a resident plugin and wait until it reports ready.
    ///
    /// Concurrent calls for one plugin share a single start: the second caller
    /// used to find a process already spawned and return at once, before the
    /// server was ready or even had a port, and its request then failed with
    /// "no assigned port". The shared start is an unstructured task, so a
    /// caller that is cancelled (a prompt superseded by the next click, say)
    /// stops waiting for it without tearing down a server that other callers
    /// -- and the user's next click -- still want. Only `stop` cancels a start.
    ///
    /// See `removeTask` on the naming.
    func startPlugin(_ pluginID: String) async throws {
        let plugin = try self.plugin(pluginID)
        guard plugin.execution.isResident else { return }
        if runtimeState(pluginID) == .ready, processes[pluginID] != nil { return }

        let start: Task<Void, Error>
        if let inFlight = startTasks[pluginID] {
            start = inFlight.task
        } else {
            let token = UUID()
            start = Task { @MainActor [weak self] in
                guard let self else { throw CancellationError() }
                // Cleared only if still ours: a stop drops a cancelled start
                // at once, and a restart may already have replaced it.
                defer {
                    if self.startTasks[pluginID]?.token == token { self.startTasks[pluginID] = nil }
                }
                try await self.launch(plugin)
            }
            startTasks[pluginID] = InFlightStart(token: token, task: start)
        }
        try await start.value
        try Task.checkCancellation()
    }

    /// The body of a start. Runs inside the shared task `startPlugin` creates.
    private func launch(_ plugin: PluginDescriptor) async throws {
        let pluginID = plugin.id
        if runtimeState(pluginID) == .ready, processes[pluginID] != nil { return }

        guard store.records(forPlugin: pluginID).contains(where: { $0.phase == .ready }) else {
            throw PluginError.notInstalled(
                PluginTaskRef(pluginID: pluginID, taskID: plugin.tasks.first?.id ?? ""))
        }

        // A process left over from a failed or wedged start is not ours to
        // reuse; clear it before admission counts it.
        if processes[pluginID] != nil { await stop(pluginID, cancelStart: false) }

        let decision = arbiter.admit(
            PluginResidency(pluginID: pluginID, declaredRamGB: plugin.ramGB),
            residents: residentSet(excluding: pluginID))
        try await applyAdmission(decision, requester: pluginID)
        // Evictions await; a stop issued meanwhile must not be undone by
        // spawning anyway.
        try Task.checkCancellation()

        let port = try ports.port(for: pluginID)
        assignedPorts[pluginID] = port
        runtimeStates[pluginID] = .starting

        let buffer = log(for: pluginID)
        let entry = locator.entryScript(for: plugin)
        guard FileManager.default.fileExists(atPath: entry.path) else {
            let message = "Adapter entry point not found at \(entry.path)."
            runtimeStates[pluginID] = .error(message)
            assignedPorts[pluginID] = nil
            ports.release(pluginID)
            throw PluginError.notReady(message)
        }

        let process = Process()
        process.executableURL = paths.venvPython(pluginID)
        process.arguments = [entry.path, "--port", String(port)]
        process.currentDirectoryURL = locator.adapterDirectory(for: plugin)
        var environment = locator.processEnvironment(for: pluginID)
        // Invariant 3: a running adapter loads from the installed weights and
        // never reaches the hub, whatever its library would otherwise try.
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let assemble: @Sendable (String) -> Void = { line in
            Task { @MainActor in buffer.line(line) }
        }
        let outAssembler = PluginProcessRunner.LineAssembler(sink: assemble)
        let errAssembler = PluginProcessRunner.LineAssembler(sink: assemble)
        outPipe.fileHandleForReading.readabilityHandler = { outAssembler.consume($0.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { errAssembler.consume($0.availableData) }

        process.terminationHandler = { [weak self] proc in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            outAssembler.flush()
            errAssembler.flush()
            let pid = proc.processIdentifier
            let code = proc.terminationStatus
            let signalled = proc.terminationReason == .uncaughtSignal
            Task { @MainActor in
                self?.handleExit(pluginID: pluginID, pid: pid, code: code, signalled: signalled)
            }
        }

        do {
            try process.run()
        } catch {
            let message = "Could not start \(plugin.name): \(error.localizedDescription)"
            runtimeStates[pluginID] = .error(message)
            assignedPorts[pluginID] = nil
            ports.release(pluginID)
            throw PluginError.transport(message)
        }

        processes[pluginID] = process
        buffer.line("Started \(plugin.name) on 127.0.0.1:\(port) (pid \(process.processIdentifier)).")

        do {
            try await waitUntilReady(pluginID: pluginID, port: port)
            runtimeStates[pluginID] = .ready
            lastUsed[pluginID] = Date()
        } catch is CancellationError {
            // Only `stop` cancels a start, and it is already taking the
            // process down; stopping again here would race it.
            throw CancellationError()
        } catch {
            await stop(pluginID, cancelStart: false)
            // Set after the stop, which leaves `.stopped`: the store must show
            // why the plugin is not running.
            runtimeStates[pluginID] = .error(error.localizedDescription)
            throw error
        }
    }

    /// Bookkeeping for a server process that has exited.
    ///
    /// Keyed on the pid as well as the plugin: a termination handler can fire
    /// after the plugin has been stopped and started again, and an exit from
    /// the previous process must not tear down the state of its replacement.
    private func handleExit(pluginID: String, pid: Int32, code: Int32, signalled: Bool) {
        let deliberate = deliberateStops.remove(pid) != nil
        guard let current = processes[pluginID], current.processIdentifier == pid else {
            log(for: pluginID).line(
                deliberate ? "Stopped (pid \(pid))." : "Earlier process \(pid) exited.")
            return
        }

        processes[pluginID] = nil
        assignedPorts[pluginID] = nil
        ports.release(pluginID)
        sessions[pluginID]?.removeAll()

        // A stop the host asked for is not an error, whatever status SIGTERM
        // or SIGKILL left behind; neither is a clean exit.
        if deliberate || code == 0 {
            runtimeStates[pluginID] = .stopped
            log(for: pluginID).line(deliberate ? "Stopped." : "Process exited.")
        } else if case .stopping = runtimeState(pluginID) {
            runtimeStates[pluginID] = .stopped
            log(for: pluginID).line("Stopped.")
        } else {
            let reason = signalled ? "was terminated by signal \(code)" : "exited with code \(code)"
            runtimeStates[pluginID] = .error("The plugin process \(reason).")
            log(for: pluginID).line("Process \(reason).")
        }
    }

    /// Stop a resident plugin, escalating to SIGKILL if it will not leave.
    func stop(_ pluginID: String) async {
        await stop(pluginID, cancelStart: true)
    }

    private func stop(_ pluginID: String, cancelStart: Bool) async {
        // A start in progress would otherwise carry on polling a process that
        // is being killed and then report it as a failed start.
        // Dropped as well as cancelled, so a start requested after this stop
        // gets a fresh attempt instead of joining the one being torn down.
        if cancelStart, let inFlight = startTasks.removeValue(forKey: pluginID) {
            inFlight.task.cancel()
        }

        guard let process = processes[pluginID], process.isRunning else {
            processes[pluginID] = nil
            runtimeStates[pluginID] = .stopped
            assignedPorts[pluginID] = nil
            ports.release(pluginID)
            sessions[pluginID]?.removeAll()
            return
        }
        let pid = process.processIdentifier
        deliberateStops.insert(pid)
        runtimeStates[pluginID] = .stopping
        log(for: pluginID).line("Stopping…")
        process.terminate()

        // A model mid-load ignores SIGTERM until it returns from a native call,
        // so give it a bounded grace period before forcing the issue. The arbiter
        // has already promised this memory to someone else.
        //
        // The wait must not be cut short by the caller's cancellation: stop is
        // routinely reached from a task that has just been cancelled (a
        // superseded prompt evicting a plugin, a cancelled start), and a
        // cancelled `Task.sleep` returns at once, which turned the grace
        // period into an immediate SIGKILL.
        let exited = await Self.waitForExit(process, timeout: 3)
        if !exited {
            kill(pid, SIGKILL)
            log(for: pluginID).line("Did not exit in time; terminated.")
        }

        // Only clear state that still belongs to this process: the exit
        // handler may already have run, and a new start may have begun.
        if processes[pluginID] === process {
            processes[pluginID] = nil
            assignedPorts[pluginID] = nil
            ports.release(pluginID)
            sessions[pluginID]?.removeAll()
            runtimeStates[pluginID] = .stopped
        }
    }

    /// Poll for a process to exit, immune to the caller's cancellation.
    ///
    /// The polling runs in a detached task, which does not inherit
    /// cancellation, and awaiting its value does not propagate it either.
    nonisolated private static func waitForExit(_ process: Process, timeout: TimeInterval) async -> Bool {
        let handle = UncheckedProcess(process)
        return await Task.detached {
            let deadline = Date().addingTimeInterval(timeout)
            while handle.process.isRunning && Date() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return !handle.process.isRunning
        }.value
    }

    /// Stop everything.
    func stopAll() async {
        for pluginID in Array(processes.keys) { await stop(pluginID) }
    }

    /// Stop everything synchronously, for application quit.
    ///
    /// `stopAll` is asynchronous, and nothing asynchronous scheduled from a
    /// `willTerminate` observer is guaranteed to run before the process exits.
    /// This signals every server at once, waits a short bounded time for all of
    /// them together, and kills whatever remains, all before returning.
    /// Adapters that outlive even this (a crash skips it entirely) are caught by
    /// their own parent-death watch (PLUGIN_PROTOCOL.md section 4d).
    func terminateAllForQuit(grace: TimeInterval = 2) {
        for inFlight in startTasks.values { inFlight.task.cancel() }
        let running = processes.values.filter(\.isRunning)
        for process in running {
            deliberateStops.insert(process.processIdentifier)
            process.terminate()
        }
        let deadline = Date().addingTimeInterval(grace)
        while running.contains(where: \.isRunning) && Date() < deadline {
            usleep(50_000)
        }
        for process in running where process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    // MARK: Health

    /// Poll `GET /health` until the adapter reports ready.
    ///
    /// Cancellation ends the poll at once with `CancellationError`. It used to
    /// be swallowed twice over -- a cancelled `Task.sleep` returned early and
    /// the cancelled request was filed as a transport error meaning "not bound
    /// yet" -- so a cancelled start spun on the main actor, issuing requests
    /// back to back until the five-minute deadline.
    private func waitUntilReady(pluginID: String, port: Int, timeout: TimeInterval = 300) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastDetail = "no response yet"

        while Date() < deadline {
            try Task.checkCancellation()
            if let process = processes[pluginID], !process.isRunning {
                throw PluginError.notReady("The plugin process exited during startup.")
            }
            do {
                let health = try await health(port: port)
                try verify(health: health, pluginID: pluginID)
                switch health.status {
                case .ready: return
                case .loading: lastDetail = health.detail ?? "loading"
                case .error: throw PluginError.notReady(health.detail ?? "The plugin reported an error.")
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as PluginError {
                // A protocol mismatch or a reported error is terminal; a transport
                // failure just means the server has not bound yet.
                if case .transport(let detail) = error {
                    lastDetail = detail
                } else {
                    throw error
                }
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw PluginError.notReady("Timed out waiting for the plugin to become ready (\(lastDetail)).")
    }

    private func health(port: Int) async throws -> PluginHealth {
        let data = try await get(path: "/health", port: port)
        guard let health = try? JSONDecoder().decode(PluginHealth.self, from: data) else {
            throw PluginError.notReady("The plugin returned a health response the host cannot read.")
        }
        return health
    }

    /// Refuse a plugin speaking a different major protocol version rather than
    /// attempting a call against it (PLUGIN_PROTOCOL.md section 8).
    private func verify(health: PluginHealth, pluginID: String) throws {
        guard health.protocolVersion == kPluginProtocolVersion else {
            throw PluginError.protocolMismatch(
                expected: kPluginProtocolVersion, found: health.protocolVersion)
        }
        if let reported = health.pluginID, reported != pluginID {
            // Either the port was taken between probe and bind, or the wrong
            // adapter was launched. Both mean this connection is not ours.
            throw PluginError.notReady(
                "Port is answering for \(reported), not \(pluginID).")
        }
    }

    // MARK: Sessions

    /// Open a session on a `session` plugin, evicting least-recently-used
    /// sessions to respect the adapter's declared `max_sessions`.
    @discardableResult
    func openSession(pluginID: String, invocation: PluginInvocation) async throws -> String {
        let plugin = try self.plugin(pluginID)
        guard plugin.execution == .session else {
            throw PluginError.notReady("\(plugin.name) does not hold sessions.")
        }
        try await startPlugin(pluginID)
        guard let port = assignedPorts[pluginID] else {
            throw PluginError.notReady("\(plugin.name) has no assigned port.")
        }

        let data = try await post(path: "/session/open", port: port,
                                  body: try PluginPayloadCoder.requestBody(invocation),
                                  ref: PluginTaskRef(pluginID: pluginID, taskID: "session"))
        guard let handle = try? JSONDecoder().decode(PluginSessionHandle.self, from: data) else {
            throw PluginError.transport("The plugin did not return a session identifier.")
        }

        var ledger = sessions[pluginID] ?? SessionLedger(limit: plugin.maxSessions ?? 1)
        let evicted = ledger.touch(handle.sessionID)
        sessions[pluginID] = ledger
        for stale in evicted { try? await closeSession(pluginID: pluginID, sessionID: stale) }

        lastUsed[pluginID] = Date()
        return handle.sessionID
    }

    func closeSession(pluginID: String, sessionID: String) async throws {
        sessions[pluginID]?.remove(sessionID)
        guard let port = assignedPorts[pluginID], runtimeState(pluginID) == .ready else { return }
        let body = try JSONSerialization.data(withJSONObject: ["session_id": sessionID])
        _ = try? await post(path: "/session/close", port: port, body: body,
                            ref: PluginTaskRef(pluginID: pluginID, taskID: "session"))
    }

    // MARK: Invocation

    /// Run a task and return its result.
    ///
    /// Routing is by execution model alone: the store, the AI panel, and the
    /// annotation tools call this and never learn whether the work happened over
    /// a socket or in a subprocess.
    func invoke(_ ref: PluginTaskRef, _ invocation: PluginInvocation) async throws -> PluginResult {
        let (plugin, task) = try resolve(ref)
        guard installState(ref).isReady else {
            if case .resolvingLicense = installState(ref) {
                throw PluginError.licenseRequired(
                    ref, message: task.license.instructions
                        ?? "This task requires a license before it can run.")
            }
            throw PluginError.notInstalled(ref)
        }

        beginInvocation(ref, execution: plugin.execution)
        defer { endInvocation(ref) }

        switch plugin.execution {
        case .residentServer, .session:
            return try await invokeResident(plugin: plugin, ref: ref, invocation: invocation)
        case .oneShot:
            return try await invokeOneShot(plugin: plugin, ref: ref, invocation: invocation)
        }
    }

    private func invokeResident(
        plugin: PluginDescriptor, ref: PluginTaskRef, invocation: PluginInvocation
    ) async throws -> PluginResult {
        try await startPlugin(plugin.id)
        guard let port = assignedPorts[plugin.id] else {
            throw PluginError.notReady("\(plugin.name) has no assigned port.")
        }
        let body = try PluginPayloadCoder.requestBody(invocation)
        let data = try await post(path: "/task/\(ref.taskID)", port: port, body: body, ref: ref)
        return try PluginPayloadCoder.decodeResult(data, ref: ref, relativeTo: nil)
    }

    private func invokeOneShot(
        plugin: PluginDescriptor, ref: PluginTaskRef, invocation: PluginInvocation
    ) async throws -> PluginResult {
        // A one-shot peak lands on top of whatever is resident, so it goes
        // through admission exactly like a server would. This is the case the
        // arbiter exists for: on a 16 GB machine, Gemma stops for the duration
        // of a TotalSegmentator run rather than the two thrashing.
        let decision = arbiter.admitOneShot(
            PluginResidency(pluginID: plugin.id,
                            declaredRamGB: plugin.declaredRAMGB(forTask: ref.taskID)),
            residents: oneShotAdmissionResidents(for: plugin.id))
        try await applyAdmission(decision, requester: plugin.id)

        let outputDirectory = paths.newRunDirectory(pluginID: plugin.id)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let buffer = log(for: plugin.id)
        let arguments = [locator.entryScript(for: plugin).path]
            + PluginPayloadCoder.commandLineArguments(
                taskID: ref.taskID, outputDirectory: outputDirectory, invocation: invocation)

        activityProgress[plugin.id] = 0
        defer { activityProgress[plugin.id] = nil }

        let outcome = try await PluginProcessRunner.run(
            executable: paths.venvPython(plugin.id),
            arguments: arguments,
            workingDirectory: locator.adapterDirectory(for: plugin),
            environment: oneShotEnvironment(for: plugin.id),
            onStdoutLine: { [weak self] line in
                Task { @MainActor in
                    guard let self else { return }
                    if let progress = PluginProgressLine.parse(line) {
                        self.activityProgress[plugin.id] = progress.progress
                        if let message = progress.message { buffer.line(message) }
                    } else {
                        buffer.line(line)
                    }
                }
            },
            onStderrLine: { line in Task { @MainActor in buffer.line(line) } })

        // result.json is authoritative even on a non-zero exit: section 4 asks
        // adapters to write the error there, and its message is far better than
        // an exit code.
        let resultURL = outputDirectory.appendingPathComponent("result.json")
        guard let data = try? Data(contentsOf: resultURL) else {
            throw PluginError.adapter(
                code: .internalError,
                message: outcome.succeeded
                    ? "The plugin exited successfully but wrote no result.json."
                    : "The plugin failed (exit \(outcome.exitCode)) and wrote no result.")
        }
        return try PluginPayloadCoder.decodeResult(data, ref: ref, relativeTo: outputDirectory)
    }

    private func oneShotEnvironment(for pluginID: String) -> [String: String] {
        var environment = locator.processEnvironment(for: pluginID)
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        return environment
    }

    // MARK: HTTP

    private func url(path: String, port: Int) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    private func get(path: String, port: Int) async throws -> Data {
        var request = URLRequest(url: url(path: path, port: port))
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        do {
            let (data, _) = try await urlSession.data(for: request)
            return data
        } catch {
            // URLSession reports a cancelled task as URLError.cancelled; that
            // is the caller's cancellation, not a server that is not up yet.
            if Task.isCancelled { throw CancellationError() }
            throw PluginError.transport(error.localizedDescription)
        }
    }

    private func post(path: String, port: Int, body: Data, ref: PluginTaskRef) async throws -> Data {
        var request = URLRequest(url: url(path: path, port: port))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw PluginError.transport(error.localizedDescription)
        }

        // Section 3: a non-200 carries the same error object as an `ok: false`
        // body, so both paths decode identically and license_required survives
        // whichever status the adapter chose.
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorObject = object["error"],
               let errorData = try? JSONSerialization.data(withJSONObject: errorObject),
               let payload = try? JSONDecoder().decode(PluginErrorPayload.self, from: errorData) {
                throw payload.asPluginError(ref: ref)
            }
            throw PluginError.transport("HTTP \(http.statusCode) from the plugin.")
        }
        return data
    }
}

/// A start shared by concurrent callers, tagged so its cleanup cannot clear a
/// newer start that replaced it.
private struct InFlightStart {
    let token: UUID
    let task: Task<Void, Error>
}

/// Carries a `Process` into a detached task. `Process` predates Sendable;
/// the only use is reading `isRunning`, which is thread-safe.
private struct UncheckedProcess: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}
