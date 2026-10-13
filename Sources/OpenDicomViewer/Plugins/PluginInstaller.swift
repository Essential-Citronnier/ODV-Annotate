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
    ///
    /// Cancelling the calling task terminates the child (SIGTERM, then SIGKILL
    /// after a grace period) and the call throws `CancellationError` once the
    /// child has gone. Without this, cancelling an install only abandoned the
    /// awaiting task while pip or a multi-gigabyte download carried on in the
    /// background, writing into a venv the store had already declared idle.
    static func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        onStdoutLine: @escaping @Sendable (String) -> Void,
        onStderrLine: @escaping @Sendable (String) -> Void
    ) async throws -> PluginProcessOutcome {
        try Task.checkCancellation()

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

        let control = ProcessControl(process)

        let outcome: PluginProcessOutcome = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
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
                    guard try control.launch() else {
                        outPipe.fileHandleForReading.readabilityHandler = nil
                        errPipe.fileHandleForReading.readabilityHandler = nil
                        process.terminationHandler = nil
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    process.terminationHandler = nil
                    continuation.resume(throwing: PluginError.transport(
                        "Could not launch \(executable.lastPathComponent): \(error.localizedDescription)"))
                }
            }
        } onCancel: {
            control.cancel()
        }

        // A child killed on our behalf exits non-zero; report that as the
        // cancellation it was rather than as a failure the user must interpret.
        if control.wasCancelled || Task.isCancelled { throw CancellationError() }
        return outcome
    }

    /// Lets a cancellation handler, which may run on any thread and before the
    /// child has even launched, terminate it safely.
    ///
    /// `Process.terminate()` raises an Objective-C exception on a process that
    /// was never launched, so launch and cancel are serialized here: a cancel
    /// that arrives first prevents the launch instead.
    final class ProcessControl: @unchecked Sendable {
        private let lock = NSLock()
        private let process: Process
        private var launched = false
        private var cancelled = false

        /// How long a terminated child gets to exit before SIGKILL.
        static let gracePeriod: TimeInterval = 5

        init(_ process: Process) {
            self.process = process
        }

        var wasCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }

        /// Launch unless already cancelled. Returns false when cancelled first.
        func launch() throws -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled else { return false }
            try process.run()
            launched = true
            return true
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let running = launched && process.isRunning
            let pid = process.processIdentifier
            lock.unlock()
            guard running else { return }
            process.terminate()
            let process = self.process
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.gracePeriod) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }

    /// Reassembles pipe reads into whole lines.
    ///
    /// Pipe reads split wherever the kernel buffer happened to fill, so a JSON
    /// progress line can arrive in two pieces. Carriage returns are treated as
    /// terminators too, so pip's in-place progress bar surfaces as successive
    /// lines instead of one line that never ends.
    ///
    /// Buffering is done on bytes, not on decoded text. A read can also end in
    /// the middle of a multi-byte UTF-8 sequence -- TotalSegmentator's progress
    /// bars and any non-ASCII log text make that routine -- and decoding each
    /// chunk on its own failed for such a chunk and discarded all of it. Line
    /// terminators are single ASCII bytes that never occur inside a multi-byte
    /// sequence, so splitting on bytes first and decoding whole lines is exact.
    final class LineAssembler: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = Data()
        private let sink: @Sendable (String) -> Void

        init(sink: @escaping @Sendable (String) -> Void) {
            self.sink = sink
        }

        func consume(_ data: Data) {
            guard !data.isEmpty else { return }
            var complete: [Data] = []
            lock.lock()
            pending.append(data)
            var lineStart = pending.startIndex
            var index = pending.startIndex
            while index < pending.endIndex {
                let byte = pending[index]
                if byte == 0x0A || byte == 0x0D {
                    complete.append(pending.subdata(in: lineStart..<index))
                    lineStart = pending.index(after: index)
                }
                index = pending.index(after: index)
            }
            if lineStart > pending.startIndex {
                pending = pending.subdata(in: lineStart..<pending.endIndex)
            }
            lock.unlock()
            for line in complete where !line.isEmpty { sink(Self.decode(line)) }
        }

        func flush() {
            lock.lock()
            let remainder = pending
            pending = Data()
            lock.unlock()
            if !remainder.isEmpty { sink(Self.decode(remainder)) }
        }

        /// A whole line that is still not valid UTF-8 is shown with replacement
        /// characters rather than dropped: a garbled byte in a log line is no
        /// reason to lose the line.
        private static func decode(_ line: Data) -> String {
            String(decoding: line, as: UTF8.self)
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
        // pip and huggingface_hub ignore the macOS proxy settings.
        environment = SystemProxyEnvironment.applying(to: environment)
        // Unbuffered stdout, so progress lines reach the host as they are printed
        // rather than when the child's block buffer happens to fill.
        environment["PYTHONUNBUFFERED"] = "1"
        // Adapters are imported from inside the .app, which is code-signed as a
        // sealed resource set. A __pycache__ directory written next to the
        // adapter sources invalidates that signature — `codesign --verify`
        // reports "a sealed resource is missing or invalid" — and a broken
        // signature is a Gatekeeper rejection on a user's machine. Nothing is
        // gained by caching bytecode for a process that exits, so it is off.
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        // PLUGIN_PROTOCOL.md section 4d. The host owns the weight layout, so it
        // tells the adapter where that is instead of each adapter guessing at
        // Application Support -- four adapters guessed four slightly different
        // paths, and none of them was where the installer put the files.
        environment[PluginHostEnvironment.weightsDirectory] = paths.weightsRoot(pluginID).path
        // Lets an adapter notice that the app has gone (a crash or a force
        // quit skips the orderly shutdown) and exit rather than hold gigabytes
        // of model memory with nobody left to talk to.
        environment[PluginHostEnvironment.parentPID] = String(ProcessInfo.processInfo.processIdentifier)
        return environment
    }
}

/// Environment variables the host sets for every adapter process
/// (PLUGIN_PROTOCOL.md section 4d).
enum PluginHostEnvironment {
    /// The plugin's weights root. Weight `<id>` lives in
    /// `$ODV_WEIGHTS_DIR/<id>/`, the same directory `--dest` named at install.
    static let weightsDirectory = "ODV_WEIGHTS_DIR"
    /// The host's pid, for the adapter's parent-death watch.
    static let parentPID = "ODV_PARENT_PID"
    /// Section 4b; install hooks only.
    static let licenseKey = "ODV_PLUGIN_LICENSE_KEY"
}

// MARK: - Network preflight

enum PluginNetworkCheck {
    /// Probe each URL once (system proxy applies, as URLSession uses it) and
    /// describe the first that does not answer. Any HTTP status counts as an
    /// answer: the question is reachability, not what the server says.
    static let live: @Sendable ([URL]) async -> String? = { urls in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        for url in urls {
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            do {
                _ = try await session.data(for: request)
            } catch {
                return "Could not reach \(url.host ?? url.absoluteString) "
                    + "(\(error.localizedDescription)). Check your internet connection "
                    + "or proxy settings, then try again."
            }
        }
        return nil
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
        if let revision = weight.revision { arguments += ["--revision", revision] }
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
    /// Checks that the hosts an install needs answer, returning a message
    /// when one does not. Nil skips the check (tests, offline fixtures).
    var networkCheck: (@Sendable ([URL]) async -> String?)? = nil
    /// Free bytes on the volume holding a URL. Injectable so install tests do
    /// not pass or fail with the free space of the machine running them.
    var availableDiskBytes: @Sendable (URL) -> Int64? = { LocalAIDiskSpace.availableBytes(at: $0) }
    /// Whether a Hugging Face repo at a pinned commit is already complete in
    /// the hub cache, where the install hook links it from instead of
    /// downloading (see `SharedGemmaWeights`). Injectable for the same reason.
    var hubCacheHasSnapshot: @Sendable (_ repo: String, _ revision: String) -> Bool = {
        HuggingFaceCache.snapshotExists(repo: $0, revision: $1)
    }

    /// Called with each state transition, on an arbitrary executor.
    typealias StateSink = @Sendable (PluginTaskRef, PluginInstallState) -> Void
    /// Called with each log line, on an arbitrary executor.
    typealias LogSink = @Sendable (String, String) -> Void

    var paths: PluginPaths { locator.paths }

    // MARK: Readiness inspection

    /// Whether the plugin's venv exists and still belongs to the interpreter
    /// that would rebuild it. One made while the app ran from the DMG or a
    /// translocated path links to an interpreter that is gone once the app
    /// runs from /Applications; it is rebuilt rather than reused.
    func hasVenv(_ pluginID: String) -> Bool {
        PythonVenvCheck.isUsable(venv: paths.venv(pluginID),
                                 python: locator.pythonOverride == nil ? locator.bundledPython : nil)
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
                return Self.isCompleteDownload(at: url)
            }
        }.map(\.id)
    }

    /// Whether a downloaded weight directory holds a finished download.
    ///
    /// Content alone proves nothing: a download interrupted by a crash, a
    /// network drop, or the user's Cancel leaves a non-empty directory, and
    /// treating that as installed skipped the re-download and failed later at
    /// model load. The host therefore writes a completion marker only after the
    /// install hook exits 0 (which itself means the adapter verified its files,
    /// section 4b), and requires it here. Hugging Face's resumable downloads
    /// also stage `*.incomplete` files under `.cache/huggingface`; any of those
    /// left behind means a transfer is unfinished whatever the marker says.
    static func isCompleteDownload(at directory: URL) -> Bool {
        let manager = FileManager.default
        let marker = directory.appendingPathComponent(PluginPaths.weightCompletionMarker)
        guard manager.fileExists(atPath: marker.path) else { return false }

        let cache = directory.appendingPathComponent(".cache/huggingface", isDirectory: true)
        if let enumerator = manager.enumerator(atPath: cache.path) {
            for case let relative as String in enumerator where relative.hasSuffix(".incomplete") {
                return false
            }
        }

        // The marker on its own (beside nothing but the hub's bookkeeping)
        // is not a model either.
        let contents = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
        return contents.contains { $0 != PluginPaths.weightCompletionMarker && $0 != ".cache" }
    }

    /// Record that `directory` holds a finished download. See `isCompleteDownload`.
    /// The marker records `revision` (the commit the hook was told to pin) so
    /// the built-in AI server can tell whether the files are the model it pins.
    static func markDownloadComplete(at directory: URL, revision: String? = nil) throws {
        let marker = directory.appendingPathComponent(PluginPaths.weightCompletionMarker)
        try Data(PluginWeightCompletion.markerContents(revision: revision).utf8)
            .write(to: marker, options: .atomic)
    }

    /// Forget a previous completion before re-fetching into the same directory,
    /// so an interrupted re-download cannot inherit the old marker.
    static func clearDownloadMarker(at directory: URL) {
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent(PluginPaths.weightCompletionMarker))
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
        // A cancelled install is not a failed one: the user asked for it to
        // stop, the child processes have been terminated, and whatever was
        // left half-built is redone by the next install. The store logs the
        // cancellation itself.
        func cancelled() -> PluginInstallState {
            publish(.notInstalled)
            return .notInstalled
        }

        if Task.isCancelled { return cancelled() }

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

        // Step 0: preflight. Fail now, with a reason, rather than minutes
        // into a download that cannot finish.
        let needsVenv = !hasVenv(plugin.id)
        // A download finished before the completion marker existed is adopted
        // (marker written) rather than fetched again.
        for weight in task.weights where weight.source != .manual {
            let directory = paths.weightDirectory(pluginID: plugin.id, weightID: weight.id)
            let marker = directory.appendingPathComponent(PluginPaths.weightCompletionMarker)
            guard !FileManager.default.fileExists(atPath: marker.path) else { continue }
            if PluginWeightCompletion.adoptLegacyDownload(at: directory, weight: weight) {
                log("Found a finished earlier download of \(weight.id); reusing it.")
            }
        }
        let alreadyPresent = Set(presentWeights(plugin: plugin, task: task))
        let toFetch = task.weights.filter { $0.source != .manual && !alreadyPresent.contains($0.id) }
        // Weights the hook will link from the hub cache cost neither disk nor network.
        let toDownload = toFetch.filter { weight in
            guard weight.source == .huggingface, let repo = weight.repo,
                  let revision = weight.revision else { return true }
            return !hubCacheHasSnapshot(repo, revision)
        }
        let requiredBytes = Int64(
            (toDownload.reduce(0) { $0 + $1.sizeGB } * 1.1 + (needsVenv ? 2 : 0)) * 1_000_000_000)
        if requiredBytes > 0,
           let message = LocalAIDiskSpace.shortfallMessage(
            requiredBytes: requiredBytes,
            availableBytes: availableDiskBytes(paths.pluginRoot(plugin.id)),
            what: plugin.name) {
            return fail(message)
        }
        if let networkCheck {
            var hosts: [URL] = []
            if needsVenv { hosts.append(URL(string: "https://pypi.org/simple/pip/")!) }
            if toDownload.contains(where: { $0.source == .huggingface }) {
                hosts.append(URL(string: "https://huggingface.co/api/models")!)
            }
            if !hosts.isEmpty, let message = await networkCheck(hosts) {
                return fail(message)
            }
        }

        // Step 1: environment.
        if needsVenv {
            publish(.installing(progress: 0.02))
            guard let python = locator.findPython3() else {
                return fail("No usable Python 3 interpreter was found.")
            }
            log("Python: \(python)")
            log("Creating virtual environment for \(plugin.name)…")
            do {
                let outcome = try await PluginProcessRunner.run(
                    executable: URL(fileURLWithPath: python),
                    // --clear: a broken venv (dangling interpreter links) is
                    // rebuilt from scratch rather than patched over.
                    arguments: ["-m", "venv", "--clear", paths.venv(plugin.id).path],
                    environment: locator.processEnvironment(for: plugin.id),
                    onStdoutLine: { log($0) },
                    onStderrLine: { log($0) })
                guard outcome.succeeded else {
                    return fail("Creating the virtual environment failed (exit \(outcome.exitCode)).")
                }
            } catch is CancellationError {
                return cancelled()
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
        } catch is CancellationError {
            return cancelled()
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
                Self.clearDownloadMarker(at: destination)
            } catch {
                return fail("Could not create the weights directory: \(error.localizedDescription)")
            }

            var environment = locator.processEnvironment(for: plugin.id)
            if let key = licenseKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
                environment[PluginHostEnvironment.licenseKey] = key
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
            } catch is CancellationError {
                return cancelled()
            } catch {
                return fail(error.localizedDescription)
            }

            // Exit 0 is the adapter's statement that the files are complete
            // (section 4b); the marker is what lets a later launch tell this
            // directory apart from one a crash left half-written.
            do {
                try Self.markDownloadComplete(at: destination, revision: weight.revision)
            } catch {
                return fail("Could not record the completed download of \(weight.id): "
                            + error.localizedDescription)
            }
        }

        if Task.isCancelled { return cancelled() }

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
