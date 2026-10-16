// AIReviewFollowupTests.swift
// OpenDicomViewer
//
// Retry targets of failed AI runs, the Gemma plugin on small Macs, the
// "needs reinstalling" state after a dependency update, per-interpreter
// built-in venvs, the setup-lock timeout, and empty plugin text clearing the
// previous description.
// Licensed under the MIT License. See LICENSE for details.

import XCTest
@testable import OpenDicomViewer

final class AIReviewFollowupTests: XCTestCase {

    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("odv-ai-followup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot, FileManager.default.fileExists(atPath: temporaryRoot.path) {
            try FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    // MARK: - Retry target

    @MainActor
    func testFailedPluginTaskRetriesThatTaskNotTheBuiltInAnalysis() {
        let model = DICOMModel()
        let panel = PanelState()
        let ref = PluginTaskRef(pluginID: "no-such-plugin", taskID: "total")
        model.runPluginTask(ref, for: panel)

        XCTAssertNotNil(panel.aiError)
        XCTAssertEqual(panel.lastAIAction, .pluginTask(ref))
        XCTAssertNotEqual(panel.lastAIAction.retryTitle, "Retry Analysis")
        XCTAssertEqual(panel.lastAIAction.retryTitle, "Retry total")
    }

    @MainActor
    func testGemmaRoutedRunKeepsTheUserFacingRetry() {
        let model = DICOMModel()
        let panel = PanelState()
        model.runPluginTask(PluginTaskRef(pluginID: "no-such-plugin", taskID: "x"),
                            for: panel, retryAs: .detectAbnormalities)
        XCTAssertEqual(panel.lastAIAction, .detectAbnormalities)
    }

    @MainActor
    func testRetryTitles() {
        XCTAssertEqual(AIAction.analyze.retryTitle, "Retry Analysis")
        XCTAssertNil(AIAction.none.retryTitle)
        XCTAssertEqual(AIAction.reinstallPlugin(AIAnalysisEngine.pluginID, then: .analyze).retryTitle,
                       "Reinstall Gemma Plugin")
    }

    // MARK: - Empty plugin text

    @MainActor
    func testEmptyPluginTextClearsThePreviousDescription() throws {
        let model = DICOMModel()
        let panel = PanelState()
        let task = try JSONDecoder().decode(PluginTask.self, from: Data("""
            {"id":"analyze","label":"Analyze","summary":"","inputs":["slice2d"],
             "outputs":["text"],"license":{"gate":"open","identifier":"MIT"},"weights":[]}
            """.utf8))
        model.apply(PluginResult(text: "old answer", bboxes: []), from: task, to: panel)
        XCTAssertEqual(panel.aiDescription, "old answer")
        model.apply(PluginResult(text: "", bboxes: []), from: task, to: panel)
        XCTAssertNil(panel.aiDescription)
        XCTAssertNil(panel.aiDescriptionSlice)
    }

    // MARK: - Gemma plugin on small Macs

    func testGemmaPluginIsUnsupportedBelowTwelveGBWithAPointerToTheBuiltInEngine() throws {
        let reason = try XCTUnwrap(GemmaPluginSupport.unsupportedReason(physicalGB: 8))
        XCTAssertTrue(reason.contains("8 GB"))
        XCTAssertTrue(reason.contains("12 GB"))
        XCTAssertTrue(reason.contains("built-in"))
        XCTAssertNil(GemmaPluginSupport.unsupportedReason(physicalGB: 12))
        XCTAssertNil(GemmaPluginSupport.unsupportedReason(physicalGB: 16))
        // The threshold is the built-in engine's low-memory threshold.
        XCTAssertEqual(GemmaPluginSupport.minimumPhysicalBytes, AIServerManager.lowMemoryThresholdBytes)
    }

    func testStoreShowsTheGemmaReasonOnAnEightGBMac() throws {
        let manifest = try PluginManifest.load(contentsOf: repoRoot
            .appendingPathComponent("Sources/OpenDicomViewer/Resources/plugins.json"))
        let gemma = try XCTUnwrap(manifest.plugin(id: AIAnalysisEngine.pluginID))
        let small = PluginMachineProfile(isAppleSilicon: true, architectureName: "Apple Silicon",
                                         physicalMemoryGB: 8)
        let reason = try XCTUnwrap(PluginStore.unsupportedReason(for: gemma, machine: small,
                                                                 arbiter: ResourceArbiter()))
        XCTAssertTrue(reason.contains("built-in AI engine"))
        let large = PluginMachineProfile(isAppleSilicon: true, architectureName: "Apple Silicon",
                                         physicalMemoryGB: 16)
        XCTAssertNil(PluginStore.unsupportedReason(for: gemma, machine: large, arbiter: ResourceArbiter()))
    }

    func testLowMemoryWarningStatesNeedAgainstTheMachine() {
        let text = AIServerManager.lowMemoryWarningText(
            physicalBytes: 8 * 1_073_741_824, availableGB: 3.2,
            unrunnablePlugins: ["Gemma 4 E4B (MLX)", "TotalSegmentator"])
        XCTAssertTrue(text.contains("5 GB"))
        XCTAssertTrue(text.contains("12 GB"))
        XCTAssertTrue(text.contains("8 GB in total"))
        XCTAssertTrue(text.contains("3.2 GB"))
        XCTAssertTrue(text.contains("TotalSegmentator"))
        XCTAssertFalse(AIServerManager.lowMemoryWarningText(
            physicalBytes: 8 * 1_073_741_824, availableGB: nil, unrunnablePlugins: [])
            .contains("Not available"))
    }

    // MARK: - Dependency-update demotion

    @MainActor
    func testRequirementsDemotionIsReportedAsNeedsReinstall() throws {
        let paths = PluginPaths(root: temporaryRoot.appendingPathComponent("plugins", isDirectory: true))
        let adapters = temporaryRoot.appendingPathComponent("adapters", isDirectory: true)
        let adapter = adapters.appendingPathComponent("gemma", isDirectory: true)
        try FileManager.default.createDirectory(at: adapter, withIntermediateDirectories: true)
        try Data("mlx-vlm==2\n".utf8).write(to: adapter.appendingPathComponent("requirements.txt"))

        let pluginID = AIAnalysisEngine.pluginID
        let venv = paths.venv(pluginID)
        try FileManager.default.createDirectory(at: venv, withIntermediateDirectories: true)
        try Data("stale-digest".utf8).write(to: paths.requirementsMarker(pluginID))
        let weights = paths.weightDirectory(pluginID: pluginID, weightID: "gemma-weights")
        try FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
        try Data().write(to: weights.appendingPathComponent(PluginPaths.weightCompletionMarker))

        let ref = PluginTaskRef(pluginID: pluginID, taskID: "analyze")
        let store = PluginInstallStore(paths: paths)
        try store.update(ref) {
            $0.installState = .ready
            $0.venvPath = venv.path
            $0.weightPaths = ["gemma-weights": weights.path]
        }

        let runtime = PluginRuntime(paths: paths,
                                    locator: PluginEnvironmentLocator(adaptersRoot: adapters, paths: paths))
        runtime.load(manifestURL: try writeGemmaManifest())
        XCTAssertEqual(runtime.installState(ref), .notInstalled, "demoted by the requirements change")
        XCTAssertTrue(runtime.needsReinstall(ref))

        // A plugin preference survives: the engine stays the plugin.
        XCTAssertEqual(AIAnalysisEngine.resolve(preference: .gemmaPlugin, pluginInstalled: true,
                                                builtInSetUp: true), .gemmaPlugin)

        // A never-installed task is not "needs reinstall".
        let digest = try XCTUnwrap(PluginInstaller.requirementsDigest(
            at: adapter.appendingPathComponent("requirements.txt")))
        try Data(digest.utf8).write(to: paths.requirementsMarker(pluginID))
        runtime.reloadInstallStates()
        XCTAssertFalse(runtime.needsReinstall(ref), "a venv matching its requirements is not stale")
        XCTAssertFalse(runtime.needsReinstall(PluginTaskRef(pluginID: pluginID, taskID: "other")))
    }

    // MARK: - Built-in venv per interpreter

    func testBuiltInVenvIsKeyedByInterpreter() {
        let base = URL(fileURLWithPath: "/tmp/odv/mlx-server")
        let a = AIServerManager.bundledVenvDirectory(
            base: base, interpreterPath: "/Applications/ODV.app/Contents/Resources/python/bin/python3",
            legacyUsable: false)
        let b = AIServerManager.bundledVenvDirectory(
            base: base, interpreterPath: "/Users/x/Downloads/ODV.app/Contents/Resources/python/bin/python3",
            legacyUsable: false)
        XCTAssertNotEqual(a, b, "two app copies never share (and --clear) one venv")
        XCTAssertEqual(a.deletingLastPathComponent().path, base.path)
        XCTAssertTrue(a.lastPathComponent.hasPrefix(".venv-"))
        XCTAssertEqual(a, AIServerManager.bundledVenvDirectory(
            base: base, interpreterPath: "/Applications/ODV.app/Contents/Resources/python/bin/python3",
            legacyUsable: false), "stable")

        // An existing shared venv that already belongs to this interpreter is kept.
        XCTAssertEqual(AIServerManager.bundledVenvDirectory(
            base: base, interpreterPath: "/Applications/ODV.app/Contents/Resources/python/bin/python3",
            legacyUsable: true).lastPathComponent, ".venv")
        XCTAssertEqual(AIServerManager.bundledVenvDirectory(
            base: base, interpreterPath: nil, legacyUsable: false).lastPathComponent, ".venv")

        // Locks are per venv.
        XCTAssertNotEqual(AIServerManager.setupLockURL(forVenv: a), AIServerManager.setupLockURL(forVenv: b))
        XCTAssertEqual(AIServerManager.setupLockURL(forVenv: base.appendingPathComponent(".venv"))
            .lastPathComponent, ".odv-setup.lock")
    }

    // MARK: - Setup lock timeout

    func testSetupLockWaitTimesOut() async throws {
        let url = temporaryRoot.appendingPathComponent(".odv-setup.lock")
        let holder = try XCTUnwrap(SetupLock(url: url))
        let waiter = try XCTUnwrap(SetupLock(url: url))
        XCTAssertTrue(holder.tryAcquire())

        let start = Date()
        let acquired = await waiter.acquire(timeout: 0.3, pollInterval: 0.05)
        XCTAssertFalse(acquired, "a wait that never ends must give up")
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)

        holder.release()
        let later = await waiter.acquire(timeout: 1, pollInterval: 0.05)
        XCTAssertTrue(later)
        waiter.release()

        XCTAssertTrue(AIServerManager.setupLockTimeoutMessage.contains("Retry"))
        XCTAssertGreaterThan(AIServerManager.setupLockTimeout, 0)
    }

    // MARK: - Helpers

    private var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }

    private func writeGemmaManifest() throws -> URL {
        let json = """
        {
          "schema_version": 1,
          "protocol": 1,
          "plugins": [
            {
              "id": "gemma-4-e4b", "name": "Gemma", "vendor": "Google",
              "summary": "Vision-language model.", "execution": "resident-server",
              "adapter_dir": "gemma", "entry": "server.py", "requirements": "requirements.txt",
              "ram_gb": 5.0, "disk_gb": 4.8, "requires_apple_silicon": false,
              "tasks": [
                { "id": "analyze", "label": "Analyze", "summary": "Describe.",
                  "inputs": ["slice2d"], "outputs": ["text"],
                  "license": { "gate": "open", "identifier": "Apache-2.0" },
                  "weights": [ { "id": "gemma-weights", "source": "huggingface",
                                 "repo": "mlx-community/gemma", "size_gb": 4.5 } ] },
                { "id": "other", "label": "Other", "summary": "Other.",
                  "inputs": ["slice2d"], "outputs": ["text"],
                  "license": { "gate": "open", "identifier": "Apache-2.0" },
                  "weights": [] }
              ]
            }
          ]
        }
        """
        let url = temporaryRoot.appendingPathComponent("manifest.json")
        try Data(json.utf8).write(to: url)
        return url
    }
}
