// AIServerManager.swift
// OpenDicomViewer
//
// Manages the lifecycle of the Python MLX inference server process.
// On first use, automatically creates a Python venv in Application Support
// and installs dependencies before launching the server.
//
// Trust model: the server only answers requests carrying a per-launch random
// token, handed to it through ODV_AI_TOKEN. A listener on the port that
// rejects our token is not ours and is never adopted. The server's PID and
// start time are recorded so a server orphaned by a crash of an earlier
// launch can be recognized and terminated.
// Licensed under the MIT License. See LICENSE for details.

import SwiftUI
import AppKit
import CryptoKit
import Darwin

// MARK: - Setup State

enum AISetupState: Equatable {
    /// Haven't checked yet
    case unknown
    /// Python venv is missing or incomplete — setup required
    case notSetup
    /// pip install in progress
    case installingDeps
    /// venv ready, server can be started
    case ready
    /// Setup failed, or the server exited unexpectedly, with a message
    case failed(String)

    static func == (lhs: AISetupState, rhs: AISetupState) -> Bool {
        switch (lhs, rhs) {
        case (.unknown, .unknown), (.notSetup, .notSetup),
             (.installingDeps, .installingDeps), (.ready, .ready):
            return true
        case (.failed(let a), .failed(let b)):
            return a == b
        default:
            return false
        }
    }
}

// MARK: - Manager

class AIServerManager: ObservableObject {
    static let shared = AIServerManager()

    @Published var isServerRunning: Bool = false
    @Published var serverLog: String = ""

    /// Current state of the Python environment setup
    @Published var setupState: AISetupState = .unknown
    /// Streamed output from pip install (shown in the setup progress UI)
    @Published var setupLog: String = ""
    /// True from the moment setup completes until the server becomes ready;
    /// used to show the "first-run model download" hint.
    @Published var isFirstRun: Bool = false

    private var serverProcess: Process?
    /// PIDs of processes we asked to stop; their exit is not a failure.
    private var stoppingPIDs: Set<Int32> = []
    /// Work to run once a stopped process has actually exited (restart).
    private var afterExit: [Int32: [() -> Void]] = [:]
    /// Polls /health until the current process is ready.
    private var readinessTask: Task<Void, Never>?
    /// A server started outside the app (sharing our token) that we adopted.
    private var adoptedPID: Int32?

    /// pip / venv child process, so quitting mid-install does not orphan it.
    private let setupProcessLock = NSLock()
    private var activeSetupProcess: Process?

    private let aiService = AIService.shared

    /// Per-launch secret shared with the server. Developers running the server
    /// themselves (launch.sh) can export the same ODV_AI_TOKEN to both.
    let launchToken: String

    private static let port = 8741
    /// Initial readiness wait; polling continues with backoff afterwards.
    private static let initialReadyTimeout: TimeInterval = 300

    private init() {
        if let token = ProcessInfo.processInfo.environment["ODV_AI_TOKEN"], !token.isEmpty {
            launchToken = token
        } else {
            launchToken = Self.randomToken()
        }
        aiService.authToken = launchToken

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in
            AIServerManager.shared.terminateForQuit()
        }
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            return UUID().uuidString + UUID().uuidString
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Directory Paths

    /// Source directory containing server.py and requirements.txt.
    /// In development this is the writable source-tree mlx-server/.
    /// In a distributed bundle this is the read-only Resources/mlx-server/.
    private var serverDirectory: URL {
        let execURL = Bundle.main.executableURL
            ?? URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])

        // Development: adjacent to the Swift build output
        let devPath = execURL
            .deletingLastPathComponent()  // .build/release/ or debug/
            .deletingLastPathComponent()  // .build/
            .deletingLastPathComponent()  // project root
            .appendingPathComponent("mlx-server")
        if FileManager.default.fileExists(atPath: devPath.appendingPathComponent("server.py").path) {
            return devPath
        }

        // Bundled app: Resources/mlx-server/
        if let resourcePath = Bundle.main.resourceURL?.appendingPathComponent("mlx-server"),
           FileManager.default.fileExists(atPath: resourcePath.appendingPathComponent("server.py").path) {
            return resourcePath
        }

        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("mlx-server")
    }

    /// Writable directory for the Python venv.
    /// - Development: same as serverDirectory (source tree is writable)
    /// - Bundled app: ~/Library/Application Support/OpenDicomViewer/mlx-server/.venv
    private var venvDirectory: URL {
        let execURL = Bundle.main.executableURL
            ?? URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        let devMLXPath = execURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("mlx-server")
        if FileManager.default.fileExists(atPath: devMLXPath.appendingPathComponent("server.py").path) {
            return devMLXPath.appendingPathComponent(".venv")
        }
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("OpenDicomViewer")
            .appendingPathComponent("mlx-server")
            .appendingPathComponent(".venv")
    }

    private var venvPythonPath: String {
        venvDirectory.appendingPathComponent("bin/python3").path
    }

    /// Written only after pip install and an import probe succeed. Holds the
    /// hash of requirements.txt, so changed pins trigger a reinstall.
    private var setupMarkerURL: URL {
        venvDirectory.appendingPathComponent(".odv-setup-complete")
    }

    /// PID and start time of the server this app launched (see `PIDRecord`).
    private var pidFileURL: URL {
        venvDirectory.appendingPathComponent(".odv-server.pid")
    }

    private var requirementsURL: URL {
        serverDirectory.appendingPathComponent("requirements.txt")
    }

    /// Path to the standalone Python bundled inside the .app (Resources/python/bin/python3).
    private var bundledPythonPath: String? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let path = resourceURL.appendingPathComponent("python/bin/python3").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Whether we are running from an .app bundle (vs. a dev build).
    private var isAppBundle: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
    }

    /// Build an environment dictionary with correct PATH for bundled Python + venv.
    private func buildPythonEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        var pathParts: [String] = []
        pathParts.append(venvDirectory.appendingPathComponent("bin").path)
        if let bundled = bundledPythonPath {
            pathParts.append(URL(fileURLWithPath: bundled).deletingLastPathComponent().path)
        }
        if let existing = env["PATH"] {
            pathParts.append(existing)
        }
        env["PATH"] = pathParts.joined(separator: ":")
        // Ensure HOME is set (hardened runtime may strip it)
        if env["HOME"] == nil {
            env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        }
        return env
    }

    // MARK: - Setup State Check

    /// SHA-256 of requirements.txt, hex-encoded; nil if unreadable.
    static func requirementsHash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether a setup marker's contents certify the current requirements.
    static func setupMarkerIsValid(markerContents: String?, requirementsHash: String?) -> Bool {
        guard let marker = markerContents?.trimmingCharacters(in: .whitespacesAndNewlines),
              !marker.isEmpty else { return false }
        // Without a readable requirements file there is nothing to compare;
        // a marker still proves a completed install.
        guard let requirementsHash else { return true }
        return marker == requirementsHash
    }

    private var currentRequirementsHash: String? {
        (try? Data(contentsOf: requirementsURL)).map(Self.requirementsHash(of:))
    }

    /// Whether the venv exists and a completed, current install is recorded.
    var isSetupComplete: Bool {
        guard FileManager.default.fileExists(atPath: venvPythonPath) else { return false }
        let marker = try? String(contentsOf: setupMarkerURL, encoding: .utf8)
        return Self.setupMarkerIsValid(markerContents: marker,
                                       requirementsHash: currentRequirementsHash)
    }

    func checkSetupState() {
        // Never clobber a running install with a filesystem snapshot taken
        // halfway through it.
        guard setupState != .installingDeps else { return }
        setupState = isSetupComplete ? .ready : .notSetup
    }

    // MARK: - Find Python 3

    /// Locate a working Python 3 interpreter.
    /// Priority: 1) bundled Python in app Resources  2) system Python (dev only).
    /// Skips /usr/bin/python3 (macOS CLT shim that triggers an install dialog).
    private func findPython3() -> String? {
        // 1. Bundled Python — always preferred
        if let bundled = bundledPythonPath {
            return bundled
        }
        // 2. System Python — development builds only (never /usr/bin/python3)
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
        ]
        for candidate in candidates {
            guard FileManager.default.fileExists(atPath: candidate) else { continue }
            // Verify it actually runs (not a broken symlink / stub)
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

    // MARK: - Pre-flight Checks

    /// MLX requires Apple Silicon. Returns a user-friendly error message on Intel Macs.
    private func checkArchitecture() -> String? {
        #if !arch(arm64)
        return "This app requires Apple Silicon (M1 or later).\nMLX AI engine is not compatible with Intel Macs."
        #else
        return nil
        #endif
    }

    /// Check available disk space. Returns error message if below the required threshold.
    /// First-run needs ~5 GB: venv+packages (~500 MB) + model (~4.5 GB).
    private static let requiredDiskSpaceBytes: Int64 = 5_000_000_000  // 5 GB

    private func checkDiskSpace() -> String? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        do {
            let values = try homeDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let available = values.volumeAvailableCapacityForImportantUsage,
               available < Self.requiredDiskSpaceBytes {
                let availableGB = String(format: "%.1f", Double(available) / 1_000_000_000)
                return "Disk space insufficient: \(availableGB) GB available, ~5 GB required.\nFree up space and try again.\n(Python packages ~500 MB + AI model ~4.5 GB)"
            }
        } catch {}
        return nil
    }

    // MARK: - Setup Environment

    /// Creates the Python venv and installs all requirements.
    /// Automatically launches the server on success.
    func setupEnvironment() {
        guard setupState == .notSetup || setupState == .unknown else { return }

        // Architecture check — fail fast on Intel Macs
        if let archError = checkArchitecture() {
            setupState = .failed(archError)
            appendSetupLog("ERROR: \(archError)\n")
            return
        }

        // Disk space check — fail fast if insufficient
        if let diskError = checkDiskSpace() {
            setupState = .failed(diskError)
            appendSetupLog("ERROR: \(diskError)\n")
            return
        }

        setupState = .installingDeps
        setupLog = ""
        isFirstRun = true

        // Capture value types before entering background task
        let venvDir = venvDirectory
        let requirementsPath = requirementsURL.path
        let markerURL = setupMarkerURL
        let requirementsHash = currentRequirementsHash ?? "unknown-requirements"

        // An interrupted reinstall must not look complete.
        try? FileManager.default.removeItem(at: markerURL)

        Task.detached { [weak self] in
            guard let self else { return }

            // Ensure the parent directory exists (Application Support path)
            let parentDir = venvDir.deletingLastPathComponent()
            try? FileManager.default.createDirectory(
                at: parentDir, withIntermediateDirectories: true
            )

            // Locate Python 3
            guard let python3 = self.findPython3() else {
                let message = self.isAppBundle
                    ? "AI setup failed: Python runtime missing from app bundle.\nPlease re-download the application from the official source."
                    : "Python 3 not found.\nInstall Python 3.10+ from python.org or via Homebrew, then try again."
                await self.failSetup(message)
                return
            }
            await MainActor.run { self.appendSetupLog("Python: \(python3)\n") }

            let env = self.buildPythonEnvironment()
            let log: @Sendable (String) -> Void = { str in
                Task { @MainActor [weak self] in self?.appendSetupLog(str) }
            }

            // Create virtual environment
            await MainActor.run { self.appendSetupLog("Creating virtual environment...\n") }
            let venvOK = await self.runSetupProcess(
                executable: python3,
                arguments: ["-m", "venv", venvDir.path],
                environment: env,
                onOutput: log
            )
            guard venvOK else {
                await self.failSetup("Failed to create Python virtual environment.")
                return
            }

            // Upgrade pip silently
            let pip = venvDir.appendingPathComponent("bin/pip").path
            await MainActor.run { self.appendSetupLog("Upgrading pip...\n") }
            _ = await self.runSetupProcess(
                executable: pip,
                arguments: ["install", "--upgrade", "pip", "-q"],
                environment: env,
                onOutput: { _ in }
            )

            // Install project requirements
            await MainActor.run {
                self.appendSetupLog(
                    "Installing dependencies — this may take several minutes…\n" +
                    "(mlx + mlx-vlm are large packages)\n\n"
                )
            }
            let installOK = await self.runSetupProcess(
                executable: pip,
                arguments: ["install", "-r", requirementsPath],
                environment: env,
                onOutput: log
            )
            guard installOK else {
                await self.failSetup("Failed to install Python dependencies.\nCheck your network connection and try again.")
                return
            }

            // Prove the install is importable before declaring it complete.
            await MainActor.run { self.appendSetupLog("\nVerifying installation…\n") }
            let probeOK = await self.runSetupProcess(
                executable: venvDir.appendingPathComponent("bin/python3").path,
                arguments: ["-c", "import mlx_vlm, fastapi, uvicorn, PIL"],
                environment: env,
                onOutput: log
            )
            guard probeOK else {
                await self.failSetup("Python dependencies installed but could not be imported.\nTry Retry Setup; if it persists, delete \(venvDir.path) and retry.")
                return
            }

            do {
                try requirementsHash.write(to: markerURL, atomically: true, encoding: .utf8)
            } catch {
                await self.failSetup("Could not record setup completion: \(error.localizedDescription)")
                return
            }

            await MainActor.run {
                self.setupState = .ready
                self.appendSetupLog("\nEnvironment ready — starting server…\n")
                self.launchServerProcess()
            }
        }
    }

    private func failSetup(_ message: String) async {
        await MainActor.run {
            self.setupState = .failed(message)
            self.appendSetupLog("ERROR: \(message)\n")
        }
    }

    // MARK: - Process Helper

    /// Stream a pipe's output to `onOutput`, detaching the handler at EOF so
    /// it does not spin on an empty, closed descriptor.
    private static func streamOutput(of pipe: Pipe, to onOutput: @escaping @Sendable (String) -> Void) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                onOutput(str)
            }
        }
    }

    private func runSetupProcess(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        onOutput: @escaping @Sendable (String) -> Void
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let environment { process.environment = environment }

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            Self.streamOutput(of: outPipe, to: onOutput)
            Self.streamOutput(of: errPipe, to: onOutput)

            process.terminationHandler = { [weak self] proc in
                self?.setActiveSetupProcess(nil)
                continuation.resume(returning: proc.terminationStatus == 0)
            }

            do {
                try process.run()
                setActiveSetupProcess(process)
            } catch {
                continuation.resume(returning: false)
            }
        }
    }

    private func setActiveSetupProcess(_ process: Process?) {
        setupProcessLock.lock()
        activeSetupProcess = process
        setupProcessLock.unlock()
    }

    // MARK: - Start Server

    /// Public entry point. Runs setup first if the venv is missing.
    func startServer() {
        // Fail fast on Intel Macs
        if let archError = checkArchitecture() {
            setupState = .failed(archError)
            aiService.serverStatus = .error("Requires Apple Silicon")
            return
        }

        if setupState == .unknown { checkSetupState() }

        switch setupState {
        case .notSetup:
            setupEnvironment()
        case .installingDeps:
            appendLog("Setup already in progress…")
        case .ready, .unknown:
            launchServerProcess()
        case .failed:
            retrySetup()
        }
    }

    private func launchServerProcess() {
        guard serverProcess == nil || serverProcess?.isRunning != true else {
            appendLog("Server already running.")
            return
        }

        let serverScript = serverDirectory.appendingPathComponent("server.py").path
        guard FileManager.default.fileExists(atPath: serverScript) else {
            appendLog("ERROR: server.py not found at \(serverScript)")
            aiService.serverStatus = .error("server.py not found")
            return
        }

        guard isSetupComplete else {
            appendLog("Python environment incomplete — running setup.")
            checkSetupState()
            if setupState == .notSetup { setupEnvironment() }
            return
        }

        appendLog("Starting MLX server…")
        aiService.serverStatus = .starting

        let process = Process()
        process.executableURL = URL(fileURLWithPath: venvPythonPath)
        process.arguments = [serverScript]
        process.currentDirectoryURL = serverDirectory
        var env = buildPythonEnvironment()
        env["ODV_AI_TOKEN"] = launchToken
        env["ODV_AI_PORT"] = String(Self.port)
        env["ODV_PARENT_PID"] = String(getpid())
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env

        let pipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errorPipe
        let log: @Sendable (String) -> Void = { str in
            Task { @MainActor [weak self] in self?.appendLog(str) }
        }
        Self.streamOutput(of: pipe, to: log)
        Self.streamOutput(of: errorPipe, to: log)

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in self?.handleTermination(of: proc) }
        }

        do {
            try process.run()
            serverProcess = process
            adoptedPID = nil
            isServerRunning = true
            appendLog("Server process started (PID \(process.processIdentifier))")
            recordPID(process.processIdentifier)
            monitorReadiness(of: process)
        } catch {
            appendLog("ERROR: Failed to start server: \(error.localizedDescription)")
            aiService.serverStatus = .error("Launch failed")
        }
    }

    /// Delay before the n-th extra readiness poll after the initial window.
    static func readinessBackoff(attempt: Int) -> TimeInterval {
        min(60, 5 * pow(2, Double(min(attempt, 10))))
    }

    /// Poll until `process` is ready. The first run downloads ~4.5 GB, which
    /// can take far longer than the initial window, so polling continues with
    /// backoff for as long as the process is alive.
    private func monitorReadiness(of process: Process) {
        readinessTask?.cancel()
        let service = aiService
        readinessTask = Task { [weak self] in
            var ready = await service.waitForReady(timeout: Self.initialReadyTimeout)
            var attempt = 0
            while !ready && !Task.isCancelled {
                let current = await MainActor.run { () -> Bool in
                    guard let self else { return false }
                    return self.serverProcess === process && process.isRunning
                }
                guard current else { return }

                if case .error(let message) = service.serverStatus {
                    await MainActor.run { self?.failServer(process, reason: message) }
                    return
                }
                if attempt == 0 {
                    await MainActor.run {
                        self?.appendLog("Model still loading after \(Int(Self.initialReadyTimeout)) s "
                                        + "(the first run downloads ~4.5 GB); still waiting…")
                    }
                }
                try? await Task.sleep(nanoseconds: UInt64(Self.readinessBackoff(attempt: attempt) * 1e9))
                attempt += 1
                await service.checkHealth()
                ready = service.serverStatus.isReady
            }
            guard ready, !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.serverProcess === process else { return }
                self.isFirstRun = false
                self.appendLog("Server is ready!")
            }
        }
    }

    /// The server is alive but unusable (model load error, port conflict):
    /// surface the reason with Retry and stop the process.
    private func failServer(_ process: Process, reason: String) {
        guard serverProcess === process else { return }
        appendLog("ERROR: \(reason)")
        setupState = .failed("AI server could not start:\n\(reason)")
        stopServer()
    }

    private func handleTermination(of process: Process) {
        let pid = process.processIdentifier
        let expected = stoppingPIDs.remove(pid) != nil
        let callbacks = afterExit.removeValue(forKey: pid) ?? []
        defer { callbacks.forEach { $0() } }

        // A newer process may already be current (restart); this exit is old news.
        guard serverProcess === process else { return }

        serverProcess = nil
        isServerRunning = false
        readinessTask?.cancel()
        readinessTask = nil
        removePIDRecord()
        appendLog("Server exited with code \(process.terminationStatus)")

        if expected {
            if case .error = aiService.serverStatus {} else { aiService.serverStatus = .stopped }
            return
        }

        // Unexpected exit: e.g. port in use, import error, out of memory.
        let tail = serverLog
            .split(separator: "\n")
            .suffix(6)
            .joined(separator: "\n")
        aiService.serverStatus = .error("Server exited")
        setupState = .failed(
            "The AI server exited unexpectedly (code \(process.terminationStatus))."
            + (tail.isEmpty ? "" : "\n\n\(tail)")
        )
    }

    // MARK: - Stop Server

    /// Ask the server to exit (SIGTERM, then SIGKILL after a grace period).
    /// `completion` runs on the main actor once it has actually exited.
    func stopServer(then completion: (() -> Void)? = nil) {
        readinessTask?.cancel()
        readinessTask = nil

        if let pid = adoptedPID, serverProcess == nil {
            appendLog("Stopping adopted server (PID \(pid))…")
            kill(pid, SIGTERM)
            adoptedPID = nil
            isServerRunning = false
            aiService.serverStatus = .stopped
            // Not our child, so its exit cannot be observed; give it time to
            // release the port before anything relaunches.
            if let completion {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: completion)
            }
            return
        }

        guard let process = serverProcess, process.isRunning else {
            appendLog("Server is not running.")
            serverProcess = nil
            isServerRunning = false
            aiService.serverStatus = .stopped
            completion?()
            return
        }

        let pid = process.processIdentifier
        appendLog("Stopping server (PID \(pid))…")
        stoppingPIDs.insert(pid)
        if let completion { afterExit[pid, default: []].append(completion) }
        // serverProcess stays set until the exit is observed, so
        // handleTermination can tell this exit from a newer process's.
        process.terminate()

        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    // MARK: - Restart

    func restartServer() {
        stopServer(then: { [weak self] in self?.startServer() })
    }

    // MARK: - Quit

    /// Called synchronously from NSApplication.willTerminateNotification so
    /// the multi-GB server process never outlives the app.
    func terminateForQuit() {
        readinessTask?.cancel()

        setupProcessLock.lock()
        let setupProcess = activeSetupProcess
        setupProcessLock.unlock()
        setupProcess?.terminate()

        if let pid = adoptedPID { kill(pid, SIGTERM) }

        guard let process = serverProcess, process.isRunning else {
            removePIDRecord()
            return
        }
        stoppingPIDs.insert(process.processIdentifier)
        process.terminate()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        removePIDRecord()
    }

    // MARK: - PID Record

    /// Identity of a launched server: a PID alone can be reused after exit,
    /// so the kernel start time is recorded with it.
    struct PIDRecord: Equatable {
        let pid: Int32
        let startSeconds: Int
        let startMicroseconds: Int

        var serialized: String { "\(pid) \(startSeconds) \(startMicroseconds)" }

        init(pid: Int32, startSeconds: Int, startMicroseconds: Int) {
            self.pid = pid
            self.startSeconds = startSeconds
            self.startMicroseconds = startMicroseconds
        }

        init?(serialized: String) {
            let parts = serialized.split(whereSeparator: \.isWhitespace)
            guard parts.count == 3,
                  let pid = Int32(parts[0]), pid > 1,
                  let seconds = Int(parts[1]),
                  let micros = Int(parts[2]) else { return nil }
            self.init(pid: pid, startSeconds: seconds, startMicroseconds: micros)
        }

        /// The record for a live process, or nil if no such process exists.
        static func current(pid: Int32) -> PIDRecord? {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
                  size > 0 else { return nil }
            let start = info.kp_proc.p_un.__p_starttime
            return PIDRecord(pid: pid, startSeconds: Int(start.tv_sec),
                             startMicroseconds: Int(start.tv_usec))
        }
    }

    private func recordPID(_ pid: Int32) {
        guard let record = PIDRecord.current(pid: pid) else { return }
        try? record.serialized.write(to: pidFileURL, atomically: true, encoding: .utf8)
    }

    private func removePIDRecord() {
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    /// Terminate a server left running by an earlier launch of this app (e.g.
    /// after a crash). Only a process whose PID *and* start time match the
    /// record is touched. Returns whether one was found.
    private func terminateOrphanedServer() async -> Bool {
        guard let contents = try? String(contentsOf: pidFileURL, encoding: .utf8),
              let recorded = PIDRecord(serialized: contents) else { return false }
        defer { removePIDRecord() }
        guard PIDRecord.current(pid: recorded.pid) == recorded else { return false }

        await MainActor.run { appendLog("Stopping AI server left over from a previous session (PID \(recorded.pid))…") }
        kill(recorded.pid, SIGTERM)
        for _ in 0..<60 where PIDRecord.current(pid: recorded.pid) == recorded {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if PIDRecord.current(pid: recorded.pid) == recorded {
            kill(recorded.pid, SIGKILL)
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return true
    }

    // MARK: - Check Existing Server

    /// Called on app launch. Adopts a server already running only if it
    /// accepts this launch's token (i.e. it was started with our ODV_AI_TOKEN).
    /// On first install (no venv), automatically triggers setup + model download.
    /// If setup is already done but server is not running, auto-starts the server.
    func checkExistingServer() {
        // A launch-time check must not reset an install already under way.
        guard setupState != .installingDeps else { return }
        checkSetupState()
        Task {
            _ = await terminateOrphanedServer()
            let probe = await aiService.probeHealth()
            await MainActor.run {
                guard self.setupState != .installingDeps, self.serverProcess == nil else { return }
                switch probe {
                case .ours(_, let pid, _):
                    self.adoptedPID = pid
                    self.isServerRunning = true
                    self.appendLog("Connected to existing MLX server\(pid.map { " (PID \($0))" } ?? "").")
                    Task { _ = await self.aiService.waitForReady(timeout: Self.initialReadyTimeout) }
                case .foreign:
                    self.aiService.serverStatus = .error("Port \(Self.port) is used by another process")
                    self.appendLog("ERROR: Port \(Self.port) is in use by a process that is not this app's AI server. Not connecting to it.")
                case .unreachable:
                    // Auto-start based on current setup state so the user doesn't
                    // have to manually trigger anything after a fresh install.
                    switch self.setupState {
                    case .notSetup:
                        // First install: create venv, install deps, download model, start server.
                        self.setupEnvironment()
                    case .ready:
                        // Deps already installed; just launch the server process.
                        self.launchServerProcess()
                    default:
                        break
                    }
                }
            }
        }
    }

    // MARK: - Retry Setup

    /// Retry after a failure: relaunch the server if the environment is
    /// complete, otherwise rerun setup.
    func retrySetup() {
        guard setupState != .installingDeps else { return }
        if isSetupComplete {
            setupState = .ready
            aiService.serverStatus = .stopped
            launchServerProcess()
        } else {
            reinstallEnvironment()
        }
    }

    /// Rerun the full setup (venv + pip install) regardless of the marker.
    func reinstallEnvironment() {
        guard setupState != .installingDeps else { return }
        stopServer(then: { [weak self] in
            guard let self else { return }
            self.setupState = .notSetup
            self.setupLog = ""
            self.setupEnvironment()
        })
    }

    // MARK: - Logging

    private func appendLog(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        serverLog += trimmed + "\n"
        let lines = serverLog.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > 500 {
            serverLog = lines.suffix(300).joined(separator: "\n")
        }
    }

    func appendSetupLog(_ text: String) {
        setupLog += text
        let lines = setupLog.components(separatedBy: "\n")
        if lines.count > 300 {
            setupLog = lines.suffix(200).joined(separator: "\n")
        }
    }
}
