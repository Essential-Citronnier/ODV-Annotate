// PluginRuntime+Lifecycle.swift
// OpenDicomViewer
//
// Ties the plugin runtime to the application's lifetime: the manifest is loaded
// at launch, and every adapter process is taken down at quit.
//
// Kept here rather than in App.swift so the app entry point needs a single
// call, and so everything the runtime does at the edges of the process is
// reviewable in one place.
// Licensed under the MIT License. See LICENSE for details.

import AppKit
import Foundation

extension PluginRuntime {

    private static var terminationObserver: NSObjectProtocol?

    /// Load the manifest and install-state, and arrange for adapters to be
    /// stopped when the app quits. Idempotent.
    ///
    /// Without the load the manifest stayed empty for the life of the app, so
    /// the store listed nothing and every invocation failed with `unknownTask`.
    static func bootstrapForApplication() {
        guard terminationObserver == nil else { return }
        shared.load()
        connectBuiltInServer()

        // `willTerminate` is delivered on the main thread, and the process
        // exits shortly after observers return, so the shutdown has to be
        // synchronous: an async `stopAll()` scheduled from here would not run.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                PluginRuntime.shared.terminateAllForQuit()
                // Installs and one-shot runs in progress: pip and its build
                // subprocesses, weight downloads, a segmentation.
                PluginProcessRunner.ProcessControl.terminateAllForQuit()
            }
        }
    }

    /// Identifier the built-in AI server goes by in admission decisions.
    static let builtInServerID = "builtin-ai-server"

    /// Make the built-in AI server and the plugins aware of each other. The
    /// built-in server is counted by the arbiter at the model's declared
    /// memory (evictable when idle), and the built-in server and the Gemma
    /// plugin are mutually exclusive: starting either stops the other, so the
    /// same 5 GB model is never resident twice.
    private static func connectBuiltInServer() {
        let runtime = shared
        let server = AIServerManager.shared
        runtime.externalResidents = {
            guard server.isServerRunning else { return [] }
            return [PluginResidency(
                pluginID: builtInServerID,
                declaredRamGB: AIServerManager.declaredRamGB,
                lastUsed: server.lastUsed,
                isEvictable: !AIService.shared.isInferencing && !server.hasPendingRun)]
        }
        runtime.stopExternalResident = { id in
            guard id == builtInServerID else { return }
            await server.stopAndWait()
        }
        runtime.willStartPlugin = { pluginID in
            guard pluginID == AIAnalysisEngine.pluginID, server.isServerRunning else { return }
            runtime.log(for: pluginID).line(
                "Stopping the built-in AI server: it holds the same model.")
            await server.stopAndWait()
        }
        server.willStartServer = {
            await runtime.makeRoomForBuiltInServer(id: builtInServerID,
                                                   declaredRamGB: AIServerManager.declaredRamGB)
        }
    }
}
