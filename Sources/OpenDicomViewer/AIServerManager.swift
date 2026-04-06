// AIServerManager.swift
// OpenDicomViewer
//
// Manages the lifecycle of the Python MLX inference server process.
// On first use, automatically creates a Python venv in Application Support
// and installs dependencies before launching the server.
// Licensed under the MIT License. See LICENSE for details.

import SwiftUI

// MARK: - Setup State

enum AISetupState: Equatable {
    /// Haven't checked yet
    case unknown
    /// Python venv is missing — setup required
    case notSetup
    /// pip install in progress
    case installingDeps
    /// venv ready, server can be started
    case ready
    /// Setup failed with a message
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
    private let aiService = AIService.shared

    private init() {}

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

    // MARK: - Setup State Check

    func checkSetupState() {
        if FileManager.default.fileExists(atPath: venvPythonPath) {
            setupState = .ready
        } else {
            setupState = .notSetup
        }
    }

    // MARK: - Find System Python 3

    private func findSystemPython3() -> String? {
        let candidates = [
            "/opt/homebrew/bin/python3",  // Homebrew on Apple Silicon
            "/usr/local/bin/python3",     // Homebrew on Intel
            "/usr/bin/python3",           // macOS built-in (CLT shim)
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - Setup Environment

    /// Creates the Python venv and installs all requirements.
    /// Automatically calls `startServer()` on success.
    func setupEnvironment() {
        guard setupState == .notSetup || setupState == .unknown else { return }
        setupState = .installingDeps
        setupLog = ""
        isFirstRun = true

        // Capture value types before entering background task
        let venvDir = venvDirectory
        let serverDir = serverDirectory

        Task.detached { [weak self] in
            guard let self else { return }

            // Ensure the parent directory exists (Application Support path)
            let parentDir = venvDir.deletingLastPathComponent()
            try? FileManager.default.createDirectory(
                at: parentDir, withIntermediateDirectories: true
            )

            // Locate Python 3
            guard let python3 = self.findSystemPython3() else {
                await MainActor.run {
                    self.setupState = .failed(
                        "Python 3 not found.\nInstall Python 3.10+ from python.org or via Homebrew, then try again."
                    )
                    self.appendSetupLog("ERROR: python3 not found in standard locations.\n")
                }
                return
            }
            await MainActor.run { self.appendSetupLog("Python: \(python3)\n") }

            // Create virtual environment
            await MainActor.run { self.appendSetupLog("Creating virtual environment...\n") }
            let venvOK = await self.runSetupProcess(
                executable: python3,
                arguments: ["-m", "venv", venvDir.path],
                onOutput: { str in Task { @MainActor [weak self] in self?.appendSetupLog(str) } }
            )
            guard venvOK else {
                await MainActor.run {
                    self.setupState = .failed("Failed to create Python virtual environment.")
                }
                return
            }

            // Upgrade pip silently
            let pip = venvDir.appendingPathComponent("bin/pip").path
            await MainActor.run { self.appendSetupLog("Upgrading pip...\n") }
            _ = await self.runSetupProcess(
                executable: pip,
                arguments: ["install", "--upgrade", "pip", "-q"],
                onOutput: { _ in }
            )

            // Install project requirements
            let requirementsPath = serverDir.appendingPathComponent("requirements.txt").path
            await MainActor.run {
                self.appendSetupLog(
                    "Installing dependencies — this may take several minutes…\n" +
                    "(mlx + mlx-vlm are large packages)\n\n"
                )
            }
            let installOK = await self.runSetupProcess(
                executable: pip,
                arguments: ["install", "-r", requirementsPath],
                onOutput: { str in Task { @MainActor [weak self] in self?.appendSetupLog(str) } }
            )
            guard installOK else {
                await MainActor.run {
                    self.setupState = .failed("Failed to install Python dependencies.\nCheck your network connection and try again.")
                }
                return
            }

            await MainActor.run {
                self.setupState = .ready
                self.appendSetupLog("\nEnvironment ready — starting server…\n")
                self.launchServerProcess()
            }
        }
    }

    // MARK: - Process Helper

    private func runSetupProcess(
        executable: String,
        arguments: [String],
        onOutput: @escaping @Sendable (String) -> Void
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                    onOutput(str)
                }
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                    onOutput(str)
                }
            }

            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus == 0)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: false)
            }
        }
    }

    // MARK: - Start Server

    /// Public entry point. Runs setup first if the venv is missing.
    func startServer() {
        if setupState == .unknown { checkSetupState() }

        switch setupState {
        case .notSetup:
            setupEnvironment()
        case .installingDeps:
            appendLog("Setup already in progress…")
        case .ready, .unknown:
            launchServerProcess()
        case .failed:
            // Let the user retry setup explicitly via the UI button
            break
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

        guard FileManager.default.fileExists(atPath: venvPythonPath) else {
            appendLog("ERROR: Python venv not found — triggering setup.")
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
        process.environment = ProcessInfo.processInfo.environment

        let pipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errorPipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                Task { @MainActor in self?.appendLog(str) }
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                Task { @MainActor in self?.appendLog(str) }
            }
        }

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                self?.isServerRunning = false
                self?.aiService.serverStatus = .stopped
                self?.appendLog("Server exited with code \(proc.terminationStatus)")
                self?.serverProcess = nil
            }
        }

        do {
            try process.run()
            serverProcess = process
            isServerRunning = true
            appendLog("Server process started (PID \(process.processIdentifier))")

            Task {
                let ready = await aiService.waitForReady(timeout: 300)
                await MainActor.run {
                    if ready {
                        self.isFirstRun = false
                        appendLog("Server is ready!")
                    } else if isServerRunning {
                        appendLog("Server started but model may still be loading…")
                    }
                }
            }
        } catch {
            appendLog("ERROR: Failed to start server: \(error.localizedDescription)")
            aiService.serverStatus = .error("Launch failed")
        }
    }

    // MARK: - Stop Server

    func stopServer() {
        guard let process = serverProcess, process.isRunning else {
            appendLog("Server is not running.")
            serverProcess = nil
            isServerRunning = false
            aiService.serverStatus = .stopped
            return
        }

        appendLog("Stopping server (PID \(process.processIdentifier))…")
        process.terminate()

        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
            if process.isRunning { process.interrupt() }
            Task { @MainActor in
                self?.serverProcess = nil
                self?.isServerRunning = false
                self?.aiService.serverStatus = .stopped
            }
        }
    }

    // MARK: - Restart

    func restartServer() {
        stopServer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.startServer()
        }
    }

    // MARK: - Check Existing Server

    /// Called on app launch to detect a server already running (e.g. started externally).
    func checkExistingServer() {
        checkSetupState()
        Task {
            await aiService.checkHealth()
            await MainActor.run {
                if aiService.serverStatus.isReady {
                    isServerRunning = true
                    appendLog("Connected to existing MLX server.")
                }
            }
        }
    }

    // MARK: - Retry Setup

    func retrySetup() {
        setupState = .notSetup
        setupLog = ""
        setupEnvironment()
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
