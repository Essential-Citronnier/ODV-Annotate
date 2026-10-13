// AIServerManager.swift
// OpenDicomViewer
//
// Manages the lifecycle of the Python MLX inference server process.
// Nothing happens at launch: the first time the user asks for AI, they are
// asked once whether to enable it (a ~6-7 GB download). Once enabled, the
// first AI request creates a Python venv in Application Support, installs the
// pinned dependencies, and starts the server, which downloads the model on its
// first run. Requests made meanwhile wait and run once the model is ready.
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

extension Notification.Name {
    /// Posted when the built-in AI server reports ready.
    static let odvAIServerReady = Notification.Name("odv.aiServerReady")
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
    /// The user's answer to "Enable local AI?": nil until asked. Persisted.
    @Published private(set) var aiEnabled: Bool? = AIServerManager.storedEnabledChoice() {
        didSet {
            if let aiEnabled {
                UserDefaults.standard.set(aiEnabled, forKey: Self.enabledKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.enabledKey)
            }
        }
    }

    private static let enabledKey = "LocalAIEnabled"

    private static func storedEnabledChoice() -> Bool? {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool
    }

    private var serverProcess: Process?
    /// PIDs of processes we asked to stop; their exit is not a failure.
    private var stoppingPIDs: Set<Int32> = []
    /// Work to run once a stopped process has actually exited (restart).
    private var afterExit: [Int32: [() -> Void]] = [:]
    /// Polls /health until the current process is ready.
    private var readinessTask: Task<Void, Never>?
    /// A server started outside the app (sharing our token) that we adopted.
    private var adoptedPID: Int32?
    /// The launch-time check (orphan sweep, adoption) runs once per process.
    /// It is triggered from each window's appearance, and running it again
    /// read this process's own PID record and killed its own server.
    private var didRunLaunchCheck = false
    /// Bumped by every stop, so a start still waiting for the plugin runtime
    /// to free the model does not spawn after the user stopped it.
    private var launchGeneration = 0
    /// The latest AI request made while the server was not ready; it runs
    /// once the model is ready. One slot: a burst of clicks runs once.
    private var pendingRun: (() -> Void)? {
        didSet { hasPendingRun = pendingRun != nil }
    }
    /// Whether an AI request is waiting for the server (shown in the UI).
    @Published private(set) var hasPendingRun = false
    /// When the server last finished a request or became ready, for the
    /// plugin arbiter's least-recently-used eviction order.
    private(set) var lastUsed: Date = .distantPast

    /// Hooks the plugin runtime installs so the built-in server and the Gemma
    /// plugin never hold the same model in memory at once: called before the
    /// built-in server starts, it stops (and awaits) any plugin that would.
    var willStartServer: (() async -> Void)?

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

    /// The model server.py loads, and the revision it pins. Kept in step with
    /// MODEL_ID / MODEL_REVISION there (a test compares them).
    static let modelRepo = "mlx-community/gemma-4-E4B-it-4bit"
    static var modelRevision: String {
        let override = ProcessInfo.processInfo.environment["ODV_MODEL_REVISION"] ?? ""
        return override.isEmpty ? "475b9088d29754a3379866cf5aeb6b41acd313c2" : override
    }
    /// Declared resident memory of the loaded model, as the plugin manifest
    /// declares it for the same model; the plugin arbiter counts this.
    static let declaredRamGB: Double = 5.0

    /// Whether the pinned model is already on disk -- in the Hugging Face
    /// cache, or installed by the Gemma plugin -- i.e. whether starting the
    /// server will download ~5 GB first.
    var isModelCached: Bool {
        sharedModelDirectory != nil
            || HuggingFaceCache.snapshotExists(repo: Self.modelRepo, revision: Self.modelRevision)
    }

    /// The Gemma plugin's installed copy of the pinned revision, when there is
    /// one. The server loads it (`ODV_MODEL_DIR`) instead of keeping a second
    /// 5.2 GB copy in the hub cache; see `SharedGemmaWeights`.
    var sharedModelDirectory: URL? {
        SharedGemmaWeights.installedDirectory(revision: Self.modelRevision)
    }

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
        // pip and huggingface_hub ignore the macOS proxy settings.
        return SystemProxyEnvironment.applying(to: env)
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

    /// Whether the venv exists, still belongs to the interpreter that would
    /// rebuild it, and a completed, current install is recorded.
    ///
    /// A venv created while the app ran from the DMG or an App Translocation
    /// path links to an interpreter that is gone (or stale) once the app runs
    /// from /Applications; such a venv is incomplete and setup rebuilds it.
    var isSetupComplete: Bool {
        guard PythonVenvCheck.isUsable(venv: venvDirectory, python: bundledPythonPath) else {
            return false
        }
        let marker = try? String(contentsOf: setupMarkerURL, encoding: .utf8)
        return Self.setupMarkerIsValid(markerContents: marker,
                                       requirementsHash: currentRequirementsHash)
    }

    func checkSetupState() {
        // Never clobber a running install with a filesystem snapshot taken
        // halfway through it.
        guard setupState != .installingDeps else { return }
        let complete = isSetupComplete
        setupState = complete ? .ready : .notSetup
        // Installs made before the enable prompt existed count as enabled.
        if complete && aiEnabled == nil { aiEnabled = true }
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

    /// Python packages (~1.5 GB installed) plus headroom.
    static let environmentDiskBytes: Int64 = 2_000_000_000
    /// The model snapshot (5.2 GB) plus headroom for the download.
    static let modelDiskBytes: Int64 = 6_000_000_000

    /// Free space needed for setup: ~8 GB on a first run, less when the model
    /// is already cached.
    static func requiredSetupBytes(modelCached: Bool) -> Int64 {
        environmentDiskBytes + (modelCached ? 0 : modelDiskBytes)
    }

    private func checkDiskSpace() -> String? {
        let cached = isModelCached
        return LocalAIDiskSpace.shortfallMessage(
            requiredBytes: Self.requiredSetupBytes(modelCached: cached),
            availableBytes: LocalAIDiskSpace.availableBytes(),
            what: cached ? "the Python packages"
                         : "the Python packages (~1.5 GB) and the AI model (~5.2 GB)")
    }

    /// Re-checked before a server start that will download the model: the
    /// disk may have filled up since setup.
    private func checkModelDiskSpace() -> String? {
        guard !isModelCached else { return nil }
        return LocalAIDiskSpace.shortfallMessage(
            requiredBytes: Self.modelDiskBytes,
            availableBytes: LocalAIDiskSpace.availableBytes(at: HuggingFaceCache.hubDirectory()),
            what: "the AI model download (~5.2 GB)")
    }

    // MARK: - Enabling

    /// Ask once whether to enable local AI. Returns whether it is enabled.
    @MainActor
    func confirmEnableIfNeeded() -> Bool {
        if aiEnabled == true { return true }
        if aiEnabled == nil && isSetupComplete {
            aiEnabled = true
            return true
        }
        // Declined before: the inspector offers the button instead of a modal.
        guard aiEnabled == nil else { return false }
        let alert = NSAlert()
        alert.messageText = "Enable local AI?"
        alert.informativeText = """
            The AI assistant runs Gemma 4 entirely on this Mac. Enabling it downloads \
            about 6–7 GB once: Python packages (~1.5 GB) and the model (~5.2 GB), \
            and needs about 8 GB of free disk space. Setup takes roughly 10–30 \
            minutes depending on your connection; you can keep working meanwhile.

            Images never leave this Mac.
            """
        alert.addButton(withTitle: "Enable Local AI")
        alert.addButton(withTitle: "Not Now")
        let enabled = alert.runModal() == .alertFirstButtonReturn
        aiEnabled = enabled
        return enabled
    }

    /// Enable from an explicit button (no prompt) and begin setup or start.
    func enableAndStart() {
        aiEnabled = true
        startServer()
    }

    /// Make sure the server is ready or on its way. Returns false when the
    /// user declined to enable local AI, or setup has failed (the inspector
    /// shows why, with Retry).
    @MainActor
    @discardableResult
    func ensureStarted() -> Bool {
        if aiService.serverStatus.isReady { return true }
        guard confirmEnableIfNeeded() else { return false }
        if setupState == .unknown { checkSetupState() }
        switch setupState {
        case .installingDeps:
            return true
        case .failed:
            return false
        case .notSetup, .ready, .unknown:
            if isServerRunning { return true }
            startServer()
            if case .failed = setupState { return false }
            return true
        }
    }

    /// Run `work` once the server is ready (replacing any earlier pending
    /// request), or now if it already is.
    func runWhenReady(_ work: @escaping () -> Void) {
        if aiService.serverStatus.isReady {
            work()
        } else {
            pendingRun = work
        }
    }

    private func serverBecameReady() {
        lastUsed = Date()
        let work = pendingRun
        pendingRun = nil
        NotificationCenter.default.post(name: .odvAIServerReady, object: nil)
        work?()
    }

    /// Forget a queued request: the server it was waiting for will not come.
    private func dropPendingRun() {
        pendingRun = nil
    }

    func noteUsed() {
        lastUsed = Date()
    }

    /// A short hint for a setup failure, read from the tail of the log.
    static func setupFailureHint(log: String) -> String {
        let tail = log.split(separator: "\n").suffix(40).joined(separator: "\n").lowercased()
        if tail.contains("no space left") {
            return "The disk ran out of space during installation."
        }
        if tail.contains("proxyerror") || tail.contains("407 proxy") {
            return "The network proxy refused the connection. Check the proxy settings in System Settings › Network."
        }
        if tail.contains("certificate verify failed") || tail.contains("sslerror") {
            return "A secure connection to the package index failed (often a network filter or proxy intercepting HTTPS)."
        }
        let networkMarkers = ["could not find a version", "connectionerror", "connection refused",
                              "timed out", "name resolution", "nodename nor servname",
                              "network is unreachable", "max retries exceeded",
                              "temporary failure in name resolution"]
        if networkMarkers.contains(where: tail.contains) {
            return "The package index could not be reached. Check your internet connection (and proxy) and try again."
        }
        return "See the log below for the cause."
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
        aiEnabled = true

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
            if let proxy = env["HTTPS_PROXY"] ?? env["https_proxy"] {
                await MainActor.run { self.appendSetupLog("Using proxy: \(proxy)\n") }
            } else if SystemProxyEnvironment.usesAutoConfig(SystemProxyEnvironment.currentSettings()) {
                await MainActor.run {
                    self.appendSetupLog("Note: this Mac uses a proxy auto-config (PAC) file, which Python cannot read. If downloads fail, set HTTPS_PROXY.\n")
                }
            }
            let log: @Sendable (String) -> Void = { str in
                Task { @MainActor [weak self] in self?.appendSetupLog(str) }
            }

            // Create the virtual environment from scratch every time. A venv
            // made from an interpreter that has since moved (app run from the
            // DMG or a translocated path) has dangling links that a plain
            // `venv` over the top leaves in place, so setup failed forever.
            await MainActor.run { self.appendSetupLog("Creating virtual environment...\n") }
            let venvOK = await self.runSetupProcess(
                executable: python3,
                arguments: ["-m", "venv", "--clear", venvDir.path],
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
                let hint = await MainActor.run { Self.setupFailureHint(log: self.setupLog) }
                await self.failSetup("Failed to install Python dependencies.\n\(hint)")
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
            self.dropPendingRun()
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
    /// Starting is an explicit request, so it also counts as enabling AI.
    func startServer() {
        aiEnabled = true
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
        // A start already waiting for the plugin runtime to free the model.
        guard !(isServerRunning && serverProcess == nil && adoptedPID == nil) else {
            appendLog("Server already starting.")
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

        if let diskError = checkModelDiskSpace() {
            appendLog("ERROR: \(diskError)")
            setupState = .failed(diskError)
            dropPendingRun()
            return
        }

        aiService.serverStatus = .starting
        aiService.loadProgress = nil
        isServerRunning = true
        if let willStartServer {
            // Stop the Gemma plugin first so the model is never resident twice.
            let generation = launchGeneration
            Task { @MainActor in
                await willStartServer()
                guard self.launchGeneration == generation else { return }
                self.spawnServerProcess(serverScript: serverScript)
            }
        } else {
            spawnServerProcess(serverScript: serverScript)
        }
    }

    private func spawnServerProcess(serverScript: String) {
        guard serverProcess == nil || serverProcess?.isRunning != true else { return }
        appendLog("Starting MLX server…")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: venvPythonPath)
        process.arguments = [serverScript]
        process.currentDirectoryURL = serverDirectory
        var env = buildPythonEnvironment()
        env["ODV_AI_TOKEN"] = launchToken
        env["ODV_AI_PORT"] = String(Self.port)
        env["ODV_PARENT_PID"] = String(getpid())
        env["PYTHONUNBUFFERED"] = "1"
        if let shared = sharedModelDirectory {
            env["ODV_MODEL_DIR"] = shared.path
            appendLog("Using the model installed by the Gemma plugin at \(shared.path)")
        }
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
            isServerRunning = false
            aiService.serverStatus = .error("Launch failed")
            dropPendingRun()
        }
    }

    /// Delay before the n-th extra readiness poll after the initial window.
    /// Capped low so download progress keeps moving and readiness is noticed
    /// within seconds.
    static func readinessBackoff(attempt: Int) -> TimeInterval {
        min(5, 2 * pow(2, Double(min(attempt, 10))))
    }

    /// Poll until `process` is ready. The first run downloads ~5 GB, which
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
                                        + "(the first run downloads ~5 GB); still waiting…")
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
                self.appendLog("Server is ready!")
                self.serverBecameReady()
            }
        }
    }

    /// The server is alive but unusable (model load error, port conflict):
    /// surface the reason with Retry and stop the process.
    private func failServer(_ process: Process, reason: String) {
        guard serverProcess === process else { return }
        appendLog("ERROR: \(reason)")
        setupState = .failed("AI server could not start:\n\(reason)")
        dropPendingRun()
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
        dropPendingRun()
        aiService.loadProgress = nil
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
        dropPendingRun()
        launchGeneration += 1

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
            if isServerRunning { appendLog("Server start cancelled.") }
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

    /// Stop the server and wait until it has exited. Used by the plugin
    /// runtime before the Gemma plugin loads the same model.
    @MainActor
    func stopAndWait() async {
        guard isServerRunning || serverProcess != nil || adoptedPID != nil else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            stopServer(then: { continuation.resume() })
        }
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
        // The record may already describe a server this process started (the
        // user asked for AI before the launch check got here). Never kill it.
        let ownPID = await MainActor.run { self.serverProcess?.processIdentifier }
        guard recorded.pid != ownPID else { return false }
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

    /// Called when a window appears. The first call per process sweeps a
    /// server orphaned by an earlier crash and adopts one already running
    /// with our token (launch.sh). Nothing is installed or started here: the
    /// server starts on first AI use (`ensureStarted`).
    func checkExistingServer() {
        // A launch-time check must not reset an install already under way,
        // and must not run twice (see didRunLaunchCheck).
        guard setupState != .installingDeps, !didRunLaunchCheck else { return }
        didRunLaunchCheck = true
        checkSetupState()
        guard serverProcess == nil, adoptedPID == nil else { return }
        Task {
            _ = await terminateOrphanedServer()
            let probe = await aiService.probeHealth()
            await MainActor.run {
                guard self.setupState != .installingDeps, self.serverProcess == nil,
                      !self.isServerRunning else { return }
                switch probe {
                case .ours(_, let pid, _, _):
                    self.adoptedPID = pid
                    self.isServerRunning = true
                    self.appendLog("Connected to existing MLX server\(pid.map { " (PID \($0))" } ?? "").")
                    Task {
                        let ready = await self.aiService.waitForReady(timeout: Self.initialReadyTimeout)
                        if ready { await MainActor.run { self.serverBecameReady() } }
                    }
                case .foreign:
                    self.aiService.serverStatus = .error("Port \(Self.port) is used by another process")
                    self.appendLog("ERROR: Port \(Self.port) is in use by a process that is not this app's AI server. Not connecting to it.")
                case .unreachable:
                    break
                }
            }
        }
    }

    // MARK: - Retry Setup

    /// Retry after a failure: relaunch the server if the environment is
    /// complete, otherwise rerun setup.
    func retrySetup() {
        guard setupState != .installingDeps else { return }
        aiEnabled = true
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
