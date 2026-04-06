// AIServerManager.swift
// OpenDicomViewer
//
// Manages the lifecycle of the Python MLX inference server process.
// Handles auto-start, stop, and health monitoring.
// Licensed under the MIT License. See LICENSE for details.

import SwiftUI

class AIServerManager: ObservableObject {
    static let shared = AIServerManager()

    @Published var isServerRunning: Bool = false
    @Published var serverLog: String = ""

    private var serverProcess: Process?
    private let aiService = AIService.shared

    private init() {}

    /// Path to the mlx-server directory (next to the app bundle or in source tree)
    private var serverDirectory: URL {
        // Check adjacent to executable first (for development)
        let execURL = Bundle.main.executableURL ?? URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        let devPath = execURL
            .deletingLastPathComponent()  // .build/debug/
            .deletingLastPathComponent()  // .build/
            .deletingLastPathComponent()  // project root
            .appendingPathComponent("mlx-server")
        if FileManager.default.fileExists(atPath: devPath.appendingPathComponent("server.py").path) {
            return devPath
        }

        // Check in app bundle Resources
        if let resourcePath = Bundle.main.resourceURL?.appendingPathComponent("mlx-server"),
           FileManager.default.fileExists(atPath: resourcePath.appendingPathComponent("server.py").path) {
            return resourcePath
        }

        // Fallback: relative to current working directory
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("mlx-server")
    }

    /// Find Python executable (venv first, then system)
    private var pythonPath: String {
        let venvPython = serverDirectory.appendingPathComponent(".venv/bin/python3").path
        if FileManager.default.fileExists(atPath: venvPython) {
            return venvPython
        }
        // Fallback to system python
        return "/usr/bin/env"
    }

    // MARK: - Start Server

    func startServer() {
        guard serverProcess == nil || serverProcess?.isRunning != true else {
            appendLog("Server already running.")
            return
        }

        let serverScript = serverDirectory.appendingPathComponent("server.py").path
        guard FileManager.default.fileExists(atPath: serverScript) else {
            appendLog("ERROR: server.py not found at \(serverScript)")
            appendLog("Run mlx-server/launch.sh first to set up the environment.")
            aiService.serverStatus = .error("server.py not found")
            return
        }

        let venvPython = serverDirectory.appendingPathComponent(".venv/bin/python3").path
        guard FileManager.default.fileExists(atPath: venvPython) else {
            appendLog("ERROR: Python venv not found. Run mlx-server/launch.sh --setup first.")
            aiService.serverStatus = .error("Python venv not found")
            return
        }

        appendLog("Starting MLX server...")
        aiService.serverStatus = .starting

        let process = Process()
        process.executableURL = URL(fileURLWithPath: venvPython)
        process.arguments = [serverScript]
        process.currentDirectoryURL = serverDirectory
        process.environment = ProcessInfo.processInfo.environment

        let pipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errorPipe

        // Read stdout async
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                Task { @MainActor in
                    self?.appendLog(str)
                }
            }
        }

        // Read stderr async
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                Task { @MainActor in
                    self?.appendLog(str)
                }
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

            // Poll for readiness
            Task {
                let ready = await aiService.waitForReady(timeout: 300)
                await MainActor.run {
                    if ready {
                        appendLog("Server is ready!")
                    } else if isServerRunning {
                        appendLog("Server started but model may still be loading...")
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

        appendLog("Stopping server (PID \(process.processIdentifier))...")
        process.terminate()

        // Give it a moment to exit gracefully
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
            if process.isRunning {
                process.interrupt()
            }
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

    // MARK: - Check External Server

    /// Check if a server is already running (e.g., started manually via launch.sh)
    func checkExistingServer() {
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

    // MARK: - Logging

    private func appendLog(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        serverLog += trimmed + "\n"
        // Keep log from growing unbounded
        let lines = serverLog.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > 500 {
            serverLog = lines.suffix(300).joined(separator: "\n")
        }
    }
}
