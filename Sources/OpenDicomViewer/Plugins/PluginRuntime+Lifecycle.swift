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
            }
        }
    }
}
