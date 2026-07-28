// PluginInstaller.swift
// OpenDicomViewer
//
// Acquisition: per-plugin virtualenv creation, dependency installation, and
// weight retrieval. Generalizes the single-engine setup path in
// AIServerManager to any adapter satisfying PLUGIN_PROTOCOL.md section 7.
// Licensed under the MIT License. See LICENSE for details.

import Foundation

// MARK: - Log buffer

/// A bounded, observable log for one plugin.
///
/// Bounded because pip and the Hugging Face downloader both emit progress bars
/// as thousands of carriage-return-terminated fragments; an unbounded buffer
/// would grow without limit during a single install and drag the SwiftUI text
/// view down with it.
@MainActor
final class PluginLogBuffer: ObservableObject {
    @Published private(set) var text: String = ""

    private let maxLines: Int
    private let trimToLines: Int

    init(maxLines: Int = 600, trimToLines: Int = 400) {
        self.maxLines = maxLines
        self.trimToLines = trimToLines
    }

    func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        text += chunk
        let lines = text.components(separatedBy: "\n")
        if lines.count > maxLines {
            text = lines.suffix(trimToLines).joined(separator: "\n")
        }
    }

    func line(_ message: String) {
        append(message.hasSuffix("\n") ? message : message + "\n")
    }

    func clear() {
        text = ""
    }
}

// MARK: - Process plumbing

/// Result of a supervised child process.
struct PluginProcessOutcome: Sendable {
    let exitCode: Int32
    var succeeded: Bool { exitCode == 0 }
}

/// Spawning and streaming, shared by the installer and the runtime.
///
/// This is `AIServerManager`'s `runSetupProcess` generalized: the stream handler
/// is per-line rather than per-chunk, because the one-shot contract
/// (PLUGIN_PROTOCOL.md section 4) requires the host to parse one JSON object per
/// stdout line, and reassembling lines at every call site would duplicate the
/// same buffering bug three times.
enum PluginProcessRunner {

    /// Run `executable` to completion, delivering stdout and stderr line by line.
    ///
    /// `onStdoutLine` receives complete lines with the terminator stripped;
    /// `onStderrLine` likewise. Both are called off the main actor.
    static func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        onStdoutLine: @escaping @Sendable (String) -> Void,
        onStderrLine: @escaping @Sendable (String) -> Void
    ) async throws -> PluginProcessOutcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        if let environment { process.environment = environment }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let outAssembler = LineAssembler(sink: onStdoutLine)
        let errAssembler = LineAssembler(sink: onStderrLine)
        outPipe.fileHandleForReading.readabilityHandler = { outAssembler.consume($0.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { errAssembler.consume($0.availableData) }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                // Detach the handlers before draining: leaving them attached keeps
                // the dispatch source alive and the file handles open.
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                outAssembler.consume(outPipe.fileHandleForReading.availableData)
                errAssembler.consume(errPipe.fileHandleForReading.availableData)
                outAssembler.flush()
                errAssembler.flush()
                continuation.resume(returning: PluginProcessOutcome(exitCode: proc.terminationStatus))
            }
            do {
                try process.run()
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                process.terminationHandler = nil
                continuation.resume(throwing: PluginError.transport(
                    "Could not launch \(executable.lastPathComponent): \(error.localizedDescription)"))
            }
        }
    }

    /// Reassembles pipe reads into whole lines.
    ///
    /// Pipe reads split wherever the kernel buffer happened to fill, so a JSON
    /// progress line can arrive in two pieces. Carriage returns are treated as
    /// terminators too, so pip's in-place progress bar surfaces as successive
    /// lines instead of one line that never ends.
    final class LineAssembler: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = ""
        private let sink: @Sendable (String) -> Void

        init(sink: @escaping @Sendable (String) -> Void) {
            self.sink = sink
        }

        func consume(_ data: Data) {
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            var complete: [String] = []
            lock.lock()
            pending += chunk
            while let index = pending.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                complete.append(String(pending[pending.startIndex..<index]))
                pending = String(pending[pending.index(after: index)...])
            }
            lock.unlock()
            for line in complete where !line.isEmpty { sink(line) }
        }

        func flush() {
            lock.lock()
            let remainder = pending
            pending = ""
            lock.unlock()
            if !remainder.isEmpty { sink(remainder) }
        }
    }
}

// MARK: - Python and adapter discovery

/// Locates the interpreter and the adapter sources.
///
/// The search order is `AIServerManager`'s, unchanged and for the same reason:
/// the Python bundled in `Resources/python` is the only one whose version and
/// wheels we control, and `/usr/bin/python3` is deliberately never used because
/// on a machine without the Command Line Tools it is a shim that pops a system
/// installation dialog instead of running.
struct PluginEnvironmentLocator: Sendable {
    /// Directory containing the `plugins/<adapter_dir>` tree.
    let adaptersRoot: URL
    let paths: PluginPaths
    /// Interpreter override, for tests.
    let pythonOverride: String?

    init(adaptersRoot: URL, paths: PluginPaths, pythonOverride: String? = nil) {
        self.adaptersRoot = adaptersRoot
        self.paths = paths
        self.pythonOverride = pythonOverride
    }

    /// The layout used by the running application: adapters from the source tree
    /// during development, from the bundle once packaged.
    static func standard(paths: PluginPaths = .standard) -> PluginEnvironmentLocator {
        PluginEnvironmentLocator(adaptersRoot: Self.discoverAdaptersRoot(), paths: paths)
    }

    private static func discoverAdaptersRoot() -> URL {
        let executable = Bundle.main.executableURL
            ?? URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])

        // Development: <project root>/plugins, three levels above .build/<config>/
        let development = executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("plugins", isDirectory: true)
        if FileManager.default.fileExists(atPath: development.path) { return development }

        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("plugins", isDirectory: true),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }

        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("plugins", isDirectory: true)
    }

    func adapterDirectory(for plugin: PluginDescriptor) -> URL {
        adaptersRoot.appendingPathComponent(plugin.adapterDir, isDirectory: true)
    }

    func entryScript(for plugin: PluginDescriptor) -> URL {
        adapterDirectory(for: plugin).appendingPathComponent(plugin.entry, isDirectory: false)
    }

    func requirementsFile(for plugin: PluginDescriptor) -> URL {
        adapterDirectory(for: plugin).appendingPathComponent(plugin.requirements, isDirectory: false)
    }

    /// Python bundled inside the .app, when there is one.
    var bundledPython: String? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let path = resources.appendingPathComponent("python/bin/python3").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// An interpreter capable of creating a venv, or nil.
    func findPython3() -> String? {
        if let pythonOverride { return pythonOverride }
        if let bundledPython { return bundledPython }
        for candidate in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"] {
            guard FileManager.default.fileExists(atPath: candidate) else { continue }
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: candidate)
            probe.arguments = ["--version"]
            probe.standardOutput = Pipe()
            probe.standardError = Pipe()
            do {
                try probe.run()
                probe.waitUntilExit()
                if probe.terminationStatus == 0 { return candidate }
            } catch { continue }
        }
        return nil
    }

    /// Environment for a child process belonging to `pluginID`.
    ///
    /// The plugin's venv precedes everything on PATH so that a subprocess the
    /// adapter spawns for itself resolves to the same interpreter, and HOME is
    /// restored because the hardened runtime can strip it and both pip and the
    /// Hugging Face cache resolve their directories from it.
    func processEnvironment(for pluginID: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        var pathComponents = [paths.venv(pluginID).appendingPathComponent("bin").path]
        if let bundledPython {
            pathComponents.append(URL(fileURLWithPath: bundledPython).deletingLastPathComponent().path)
        }
        if let existing = environment["PATH"] { pathComponents.append(existing) }
        environment["PATH"] = pathComponents.joined(separator: ":")
        if environment["HOME"] == nil {
            environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        }
        // Unbuffered stdout, so progress lines reach the host as they are printed
        // rather than when the child's block buffer happens to fill.
        environment["PYTHONUNBUFFERED"] = "1"
        return environment
    }
}

// MARK: - Installer

/// Weight acquisition hook, spawned as
/// `<venv python> <entry> --install-weights --weight-id <id> --source <source>
///  --dest <dir> [--repo <repo>] [--task <task>]`.
///
/// One documented hook rather than per-source host code: the host knows nothing
/// about Hugging Face authentication or TotalSegmentator's downloader, and
/// should not. It supplies a destination and reads the progress lines defined in
/// PLUGIN_PROTOCOL.md section 4.
enum PluginInstallHook {
    static let flag = "--install-weights"

    static func arguments(for weight: PluginWeight, destination: URL) -> [String] {
        var arguments = [flag,
                         "--weight-id", weight.id,
                         "--source", weight.source.rawValue,
                         "--dest", destination.path]
        if let repo = weight.repo { arguments += ["--repo", repo] }
        if let task = weight.task { arguments += ["--task", task] }
        return arguments
    }
}

/// Progress reported by a child process on stdout.
struct PluginProgressLine: Decodable, Equatable, Sendable {
    let progress: Double?
    let message: String?

    /// Parse a stdout line, returning nil for anything that is not a progress
    /// object. Section 4 is explicit that a non-JSON line is a log line, and
    /// nothing on stdout is parsed as a result.
    static func parse(_ line: String) -> PluginProgressLine? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
        guard let parsed = try? JSONDecoder().decode(PluginProgressLine.self, from: data),
              parsed.progress != nil else { return nil }
        return parsed
    }
}

/// A failure envelope printed by an install hook on stdout.
///
/// Distinct from a progress line by carrying `ok` rather than `progress`
/// (section 4b). Without this the host would see only a non-zero exit, and a
/// license-gated download — the case the store most needs to react to — would
/// surface as an unactionable "exit 1".
struct PluginErrorEnvelope: Equatable, Sendable {
    let code: PluginErrorCode
    let message: String

    private struct Wire: Decodable {
        struct Payload: Decodable {
            let code: String?
            let message: String?
        }
        let ok: Bool
        let error: Payload?
    }

    static func parse(_ line: String) -> PluginErrorEnvelope? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
              let wire = try? JSONDecoder().decode(Wire.self, from: data),
              wire.ok == false else { return nil }

        let code = wire.error?.code.flatMap(PluginErrorCode.init(rawValue:))
            ?? .internalError
        let message = wire.error?.message ?? "The plugin reported a failure."
        return PluginErrorEnvelope(code: code, message: message)
    }
}

/// Carries an envelope out of the process runner's stdout callback, which runs
/// on a reader queue rather than the caller's context.
final class ErrorEnvelopeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PluginErrorEnvelope?

    var value: PluginErrorEnvelope? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Creates and removes plugin environments.
///
/// Deliberately not an `ObservableObject`: the installer reports through the
/// callbacks the runtime supplies, so it can be driven from a test with no
/// SwiftUI or main-actor involvement at all.
struct PluginInstaller: Sendable {
    let locator: PluginEnvironmentLocator
    let store: PluginInstallStore

    /// Called with each state transition, on an arbitrary executor.
    typealias StateSink = @Sendable (PluginTaskRef, PluginInstallState) -> Void
    /// Called with each log line, on an arbitrary executor.
    typealias LogSink = @Sendable (String, String) -> Void

    var paths: PluginPaths { locator.paths }

    // MARK: Readiness inspection

    /// Whether the plugin's venv exists and looks usable.
    func hasVenv(_ pluginID: String) -> Bool {
        FileManager.default.fileExists(atPath: paths.venvPython(pluginID).path)
    }

    /// Destination directory for a weight, and for `.manual` weights the exact
    /// file the user must place there. The store shows this path verbatim.
    func expectedWeightPath(pluginID: String, weight: PluginWeight) -> URL {
        weight.source == .manual
            ? paths.manualWeightPath(pluginID: pluginID, weight: weight)
            : paths.weightDirectory(pluginID: pluginID, weightID: weight.id)
    }

    /// Weight ids of `task` whose files are present on disk.
    func presentWeights(plugin: PluginDescriptor, task: PluginTask) -> [String] {
        task.weights.filter { weight in
            let url = expectedWeightPath(pluginID: plugin.id, weight: weight)
            switch weight.source {
            case .manual:
                return FileManager.default.fileExists(atPath: url.path)
            case .huggingface, .totalsegTask:
                // A downloader that failed part way can leave the directory in
                // place, so presence alone is not enough; require content.
                let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path)
                return !(contents ?? []).isEmpty
            }
        }.map(\.id)
    }

    // MARK: License gate

    /// Whether the task's gate is satisfied and installation may proceed
    /// (PLUGIN_PROTOCOL.md section 6).
    func licenseSatisfied(plugin: PluginDescriptor, task: PluginTask, licenseKey: String?) -> Bool {
        switch task.license.gate {
        case .open:
            return true
        case .licenseKey:
            guard let key = licenseKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
                // Already acknowledged in a previous session: the key lives in the
                // underlying tool's own configuration, so its absence here is not
                // evidence the gate is unsatisfied.
                return store.record(for: PluginTaskRef(pluginID: plugin.id, taskID: task.id))?
                    .licenseAcknowledged ?? false
            }
            guard let prefix = task.license.keyFormat, !prefix.isEmpty else { return true }
            return key.hasPrefix(prefix)
        case .gatedDownload:
            // Satisfied by the checkpoint being where the instructions said, which
            // is the only thing the host can verify without handling the user's
            // credentials for the external site.
            return task.weights.allSatisfy { weight in
                weight.source != .manual
                    || FileManager.default.fileExists(
                        atPath: paths.manualWeightPath(pluginID: plugin.id, weight: weight).path)
            }
        }
    }

    // MARK: Install

    /// Bring `task` to `.ready`, or leave a `.failed` record explaining why.
    ///
    /// `licenseKey` is used for this invocation only: it is passed to the
    /// adapter through the environment, never through argv (where `ps` would
    /// expose it), never written to state.json, and never echoed to the log.
    /// What persists is the boolean acknowledgement.
    @discardableResult
    func install(
        plugin: PluginDescriptor,
        task: PluginTask,
        licenseKey: String? = nil,
        onState: @escaping StateSink,
        onLog: @escaping LogSink
    ) async -> PluginInstallState {
        let ref = PluginTaskRef(pluginID: plugin.id, taskID: task.id)

        let store = self.store
        // Both are called from the process runner's reader threads as well as
        // from this task, so they are explicitly concurrency-safe.
        let publish: @Sendable (PluginInstallState) -> Void = { state in
            _ = try? store.setState(state, for: ref)
            onState(ref, state)
        }
        let log: @Sendable (String) -> Void = { message in
            onLog(plugin.id, message)
        }
        func fail(_ message: String) -> PluginInstallState {
            log("ERROR: \(message)")
            publish(.failed(message))
            return .failed(message)
        }

        if plugin.requiresAppleSilicon {
            #if !arch(arm64)
            return fail("\(plugin.name) requires Apple Silicon.")
            #endif
        }

        guard licenseSatisfied(plugin: plugin, task: task, licenseKey: licenseKey) else {
            publish(.resolvingLicense)
            return .resolvingLicense
        }
        if task.license.gate != .open {
            _ = try? store.update(ref) { $0.licenseAcknowledged = true }
        }

        do {
            try paths.createDirectories(for: plugin.id)
        } catch {
            return fail("Could not create the plugin directory: \(error.localizedDescription)")
        }

        // Step 1: environment.
        if !hasVenv(plugin.id) {
            publish(.installing(progress: 0.02))
            guard let python = locator.findPython3() else {
                return fail("No usable Python 3 interpreter was found.")
            }
            log("Python: \(python)")
            log("Creating virtual environment for \(plugin.name)…")
            do {
                let outcome = try await PluginProcessRunner.run(
                    executable: URL(fileURLWithPath: python),
                    arguments: ["-m", "venv", paths.venv(plugin.id).path],
                    environment: locator.processEnvironment(for: plugin.id),
                    onStdoutLine: { log($0) },
                    onStderrLine: { log($0) })
                guard outcome.succeeded else {
                    return fail("Creating the virtual environment failed (exit \(outcome.exitCode)).")
                }
            } catch {
                return fail(error.localizedDescription)
            }
        }

        // Step 2: dependencies.
        let requirements = locator.requirementsFile(for: plugin)
        guard FileManager.default.fileExists(atPath: requirements.path) else {
            return fail("Adapter requirements not found at \(requirements.path).")
        }
        publish(.installing(progress: 0.1))
        log("Installing dependencies — this can take several minutes…")
        do {
            let pip = paths.venvPip(plugin.id)
            _ = try await PluginProcessRunner.run(
                executable: pip,
                arguments: ["install", "--upgrade", "pip", "-q"],
                environment: locator.processEnvironment(for: plugin.id),
                onStdoutLine: { _ in },
                onStderrLine: { _ in })
            let outcome = try await PluginProcessRunner.run(
                executable: pip,
                arguments: ["install", "-r", requirements.path],
                environment: locator.processEnvironment(for: plugin.id),
                onStdoutLine: { log($0) },
                onStderrLine: { log($0) })
            guard outcome.succeeded else {
                return fail("Installing dependencies failed (exit \(outcome.exitCode)). Check the log above.")
            }
        } catch {
            return fail(error.localizedDescription)
        }
        publish(.installing(progress: 0.35))

        // Step 3: weights.
        var weightPaths: [String: String] = [:]
        let totalWeights = max(1, task.weights.count)
        for (index, weight) in task.weights.enumerated() {
            let destination = expectedWeightPath(pluginID: plugin.id, weight: weight)
            weightPaths[weight.id] = destination.path
            let base = 0.35 + 0.6 * (Double(index) / Double(totalWeights))
            let span = 0.6 / Double(totalWeights)

            if weight.source == .manual {
                // Never fetched by the host: a gated checkpoint is the user's to
                // place, and attempting the download would mean handling their
                // credentials for the external site.
                guard FileManager.default.fileExists(atPath: destination.path) else {
                    log("Checkpoint not found at \(destination.path)")
                    publish(.resolvingLicense)
                    return .resolvingLicense
                }
                log("Found \(weight.id) at \(destination.path)")
                continue
            }

            if presentWeights(plugin: plugin, task: task).contains(weight.id) {
                log("\(weight.id) is already present.")
                continue
            }

            publish(.downloading(progress: base))
            log("Downloading \(weight.id) (\(String(format: "%.1f", weight.sizeGB)) GB)…")
            do {
                try FileManager.default.createDirectory(
                    at: paths.weightDirectory(pluginID: plugin.id, weightID: weight.id),
                    withIntermediateDirectories: true)
            } catch {
                return fail("Could not create the weights directory: \(error.localizedDescription)")
            }

            var environment = locator.processEnvironment(for: plugin.id)
            if let key = licenseKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
                environment["ODV_PLUGIN_LICENSE_KEY"] = key
            }

            // Captured from the adapter's stdout so a structured failure can be
            // acted on rather than reduced to an exit status.
            let reported = ErrorEnvelopeBox()

            do {
                let outcome = try await PluginProcessRunner.run(
                    executable: paths.venvPython(plugin.id),
                    arguments: [locator.entryScript(for: plugin).path]
                        + PluginInstallHook.arguments(for: weight, destination: destination),
                    workingDirectory: locator.adapterDirectory(for: plugin),
                    environment: environment,
                    onStdoutLine: { line in
                        if let progress = PluginProgressLine.parse(line) {
                            publish(.downloading(progress: base + span * (progress.progress ?? 0)))
                            if let message = progress.message { log(message) }
                        } else if let envelope = PluginErrorEnvelope.parse(line) {
                            reported.value = envelope
                            log(envelope.message)
                        } else {
                            log(line)
                        }
                    },
                    onStderrLine: { log($0) })
                guard outcome.succeeded else {
                    if let envelope = reported.value {
                        // A gated weight is not a broken install: the task waits
                        // at its licence gate for the user to satisfy it.
                        if envelope.code == .licenseRequired {
                            publish(.resolvingLicense)
                            return .resolvingLicense
                        }
                        return fail(envelope.message)
                    }
                    return fail("Downloading \(weight.id) failed (exit \(outcome.exitCode)).")
                }
            } catch {
                return fail(error.localizedDescription)
            }
        }

        // Step 4: verify and record.
        let present = Set(presentWeights(plugin: plugin, task: task))
        let missing = task.weights.map(\.id).filter { !present.contains($0) }
        guard missing.isEmpty else {
            return fail("Weights missing after installation: \(missing.joined(separator: ", ")).")
        }

        let bytes = PluginDiskUsage.bytes(at: paths.pluginRoot(plugin.id))
        do {
            _ = try store.update(ref) { record in
                record.installState = .ready
                record.installedWeightIDs = task.weights.map(\.id)
                record.weightPaths = weightPaths
                record.bytesOnDisk = bytes
                record.venvPath = paths.venvPython(plugin.id).path
                record.adapterPath = locator.entryScript(for: plugin).path
            }
        } catch {
            // The environment is genuinely installed; only the bookkeeping
            // failed, and the next launch's re-verification will find the files
            // and can be told about them again. Report it rather than claim a
            // clean install.
            return fail("Installed, but the install record could not be saved: "
                        + error.localizedDescription)
        }
        onState(ref, .ready)
        log("\(task.label) is ready.")
        return .ready
    }

    // MARK: Removal

    /// Remove a task's weights, and the plugin's venv when no sibling task still
    /// needs it.
    ///
    /// Everything deleted is beneath the subsystem's own directory in
    /// Application Support, and every path is derived from `PluginPaths` rather
    /// than from a record field, so a tampered state.json cannot direct a delete
    /// somewhere else.
    func remove(plugin: PluginDescriptor, task: PluginTask, onLog: LogSink? = nil) throws {
        let ref = PluginTaskRef(pluginID: plugin.id, taskID: task.id)
        let manager = FileManager.default

        // Weights shared with a sibling task that is still installed stay put.
        let siblingsInUse = Set(
            store.records(forPlugin: plugin.id)
                .filter { $0.taskID != task.id && $0.phase == .ready }
                .flatMap(\.installedWeightIDs))

        for weight in task.weights where !siblingsInUse.contains(weight.id) {
            let directory = paths.weightDirectory(pluginID: plugin.id, weightID: weight.id)
            if manager.fileExists(atPath: directory.path) {
                try manager.removeItem(at: directory)
                onLog?(plugin.id, "Removed \(weight.id).")
            }
        }

        let othersRemain = store.records(forPlugin: plugin.id)
            .contains { $0.taskID != task.id && $0.phase != .notInstalled }
        if !othersRemain {
            let venv = paths.venv(plugin.id)
            if manager.fileExists(atPath: venv.path) {
                try manager.removeItem(at: venv)
                onLog?(plugin.id, "Removed the \(plugin.name) environment.")
            }
        }

        try store.forget(ref)
    }
}
