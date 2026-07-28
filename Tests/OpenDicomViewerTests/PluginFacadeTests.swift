// PluginFacadeTests.swift
// Guards the seam between the runtime and the store.
//
// The facade requirements are satisfied by a mix of the runtime's own methods
// and wrappers in PluginRuntime+Store.swift. A wrapper that stops being the
// conformance — because a native method with the same signature shadows it —
// still compiles and still runs the install, but silently drops whatever the
// wrapper added. These tests assert the wrappers are actually on the path.

import XCTest
@testable import OpenDicomViewer

@MainActor
final class PluginFacadeTests: XCTestCase {

    private func runtimeAsFacade() -> PluginRuntimeFacade {
        PluginRuntime.shared
    }

    /// The store calls `install(_:licenseKey:)` through the facade. If that
    /// resolves to the runtime's own method rather than the cancellable
    /// wrapper, no task is registered and Cancel becomes a silent no-op.
    ///
    /// The distinguishing observable is the log line the wrapper writes on
    /// cancel: the native path has no such notion, so a bypassed wrapper leaves
    /// the log untouched. A test that merely called both methods would pass in
    /// either state and guard nothing.
    func testCancelInstallIsObservableThroughTheFacade() async throws {
        let runtime = PluginRuntime.shared
        runtime.load(manifestURL: try manifestURL())
        let facade: PluginRuntimeFacade = runtime

        let ref = PluginTaskRef(pluginID: "gemma-4-e4b", taskID: "analyze")
        let before = facade.installLog(for: ref)

        await facade.cancelInstall(ref)

        let after = facade.installLog(for: ref)
        XCTAssertNotEqual(after, before,
                          "cancelInstall produced no observable effect, which is what a "
                          + "bypassed wrapper looks like")
        XCTAssertTrue(after.contains("cancel") || after.contains("Cancel"),
                      "expected a cancellation note in the log, got: \(after.suffix(200))")
    }

    /// Cancelling a task that was never installed must be harmless rather than
    /// trapping, since the store offers Cancel from several states.
    func testCancelOnUnknownRefIsHarmless() async {
        let facade = runtimeAsFacade()
        let ref = PluginTaskRef(pluginID: "does-not-exist", taskID: "nope")
        await facade.install(ref, licenseKey: nil)
        await facade.cancelInstall(ref)
        XCTAssertEqual(facade.installState(for: ref), .notInstalled,
                       "an unresolvable ref must stay notInstalled")
    }

    func testFacadeExposesTheRuntimeManifest() {
        let facade = runtimeAsFacade()
        XCTAssertEqual(facade.manifest.protocolVersion,
                       PluginRuntime.shared.manifest.protocolVersion)
    }

    /// `checkpointLocation` must be nil for downloadable weights and non-nil
    /// for the manually supplied ones, since the store shows the path verbatim
    /// only in the gated-download flow.
    func testCheckpointLocationOnlyForManualWeights() throws {
        let manifest = try PluginManifest.load(contentsOf: try manifestURL())
        let facade = runtimeAsFacade()
        PluginRuntime.shared.load(manifestURL: try manifestURL())

        for plugin in manifest.plugins {
            for task in plugin.tasks {
                let ref = PluginTaskRef(pluginID: plugin.id, taskID: task.id)
                let isManual = task.weights.contains { $0.source == .manual }
                let location = facade.checkpointLocation(for: ref)
                if isManual {
                    XCTAssertNotNil(location,
                                    "\(ref) has a manual weight but no shown path")
                } else {
                    XCTAssertNil(location,
                                 "\(ref) downloads its weights but shows a path")
                }
            }
        }
    }

    /// Non-throwing facade wrappers must swallow rather than propagate, since
    /// the store has no error channel for them.
    func testStartOnUnknownPluginDoesNotTrap() async {
        let facade = runtimeAsFacade()
        await facade.start("no-such-plugin")
        await facade.stop("no-such-plugin")
    }

    private func manifestURL() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir
                .appendingPathComponent("Sources/OpenDicomViewer/Resources/plugins.json")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        throw XCTSkip("plugins.json not found relative to test source")
    }
}
