// WeightSharingTests.swift
// OpenDicomViewer
//
// The completion marker's recorded revision, adoption of weight directories
// downloaded before the marker existed, the one shared Gemma copy, and an
// install preflight that does not read the machine's real free disk space.
// Nothing here downloads or loads a model.
// Licensed under the MIT License. See LICENSE for details.

import XCTest
@testable import OpenDicomViewer

final class WeightSharingTests: XCTestCase {

    private var root: URL!
    private let pinned = "475b9088d29754a3379866cf5aeb6b41acd313c2"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("odv-weights-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private var paths: PluginPaths {
        PluginPaths(root: root.appendingPathComponent("plugins", isDirectory: true))
    }

    /// A Hugging Face weight small enough to stage on disk: 0.000002 GB is
    /// 2,000 bytes.
    private func hfWeight(revision: String? = nil) -> PluginWeight {
        PluginWeight(id: "gemma-4-e4b-it-4bit", source: .huggingface,
                     repo: "mlx-community/gemma-4-E4B-it-4bit", revision: revision,
                     task: nil, filename: nil, sizeGB: 0.000002)
    }

    private func write(_ bytes: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    /// The flat layout `snapshot_download(local_dir=...)` leaves, with the
    /// hub's per-file metadata recording `revision`.
    private func stageHubDownload(at directory: URL, revision: String = "475b9088d29754a3379866cf5aeb6b41acd313c2",
                                  shardBytes: Int = 2_100) throws {
        try write(100, to: directory.appendingPathComponent("config.json"))
        try write(shardBytes, to: directory.appendingPathComponent("model.safetensors"))
        let metadata = directory.appendingPathComponent(".cache/huggingface/download")
        for name in ["config.json", "model.safetensors"] {
            try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
            try Data("\(revision)\netag\n1700000000.0\n".utf8)
                .write(to: metadata.appendingPathComponent(name + ".metadata"))
        }
    }

    // MARK: - Marker

    func testMarkerRecordsTheRevision() throws {
        let directory = root.appendingPathComponent("w")
        try stageHubDownload(at: directory)
        try PluginInstaller.markDownloadComplete(at: directory, revision: pinned)
        XCTAssertTrue(PluginInstaller.isCompleteDownload(at: directory))
        let text = try String(contentsOf: directory.appendingPathComponent(
            PluginPaths.weightCompletionMarker), encoding: .utf8)
        XCTAssertEqual(PluginWeightCompletion.revision(inMarker: text), pinned)
        XCTAssertEqual(PluginWeightCompletion.recordedRevision(at: directory), pinned)
    }

    func testOldTimestampOnlyMarkerFallsBackToHubMetadata() throws {
        let directory = root.appendingPathComponent("w")
        try stageHubDownload(at: directory)
        try Data("2026-01-01T00:00:00Z".utf8).write(
            to: directory.appendingPathComponent(PluginPaths.weightCompletionMarker))
        XCTAssertNil(PluginWeightCompletion.revision(inMarker: "2026-01-01T00:00:00Z"))
        XCTAssertEqual(PluginWeightCompletion.recordedRevision(at: directory), pinned)
    }

    // MARK: - Pre-marker installs (item: migration)

    func testCompleteLegacyDownloadIsAdopted() throws {
        let directory = root.appendingPathComponent("w")
        try stageHubDownload(at: directory)
        XCTAssertFalse(PluginInstaller.isCompleteDownload(at: directory), "no marker yet")

        XCTAssertTrue(PluginWeightCompletion.adoptLegacyDownload(at: directory, weight: hfWeight(revision: pinned)))
        XCTAssertTrue(PluginInstaller.isCompleteDownload(at: directory))
        XCTAssertEqual(PluginWeightCompletion.recordedRevision(at: directory), pinned)
    }

    func testPartialLegacyDownloadIsNotAdopted() throws {
        // A staged .incomplete file means a transfer was cut short.
        let staged = root.appendingPathComponent("staged")
        try stageHubDownload(at: staged)
        try write(10, to: staged.appendingPathComponent(".cache/huggingface/download/x.incomplete"))
        XCTAssertFalse(PluginWeightCompletion.adoptLegacyDownload(at: staged, weight: hfWeight()))

        // Config without the weights.
        let noShards = root.appendingPathComponent("noShards")
        try write(5_000, to: noShards.appendingPathComponent("config.json"))
        XCTAssertFalse(PluginWeightCompletion.looksComplete(directory: noShards, weight: hfWeight()))

        // Far less on disk than the manifest declares.
        let small = root.appendingPathComponent("small")
        try stageHubDownload(at: small, shardBytes: 500)
        XCTAssertFalse(PluginWeightCompletion.looksComplete(directory: small, weight: hfWeight()))

        // A shard the index names is missing.
        let sharded = root.appendingPathComponent("sharded")
        try stageHubDownload(at: sharded)
        let index = #"{"weight_map": {"a": "model-00001-of-00002.safetensors", "b": "model-00002-of-00002.safetensors"}}"#
        try Data(index.utf8).write(to: sharded.appendingPathComponent("model.safetensors.index.json"))
        try write(2_000, to: sharded.appendingPathComponent("model-00001-of-00002.safetensors"))
        XCTAssertFalse(PluginWeightCompletion.looksComplete(directory: sharded, weight: hfWeight()))
        try write(2_000, to: sharded.appendingPathComponent("model-00002-of-00002.safetensors"))
        XCTAssertTrue(PluginWeightCompletion.looksComplete(directory: sharded, weight: hfWeight()))

        for directory in [staged, noShards, small] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(
                PluginPaths.weightCompletionMarker).path))
        }
    }

    func testLegacyDownloadOfADifferentRevisionIsNotAdopted() throws {
        let directory = root.appendingPathComponent("w")
        try stageHubDownload(at: directory, revision: String(repeating: "a", count: 40))
        XCTAssertFalse(PluginWeightCompletion.adoptLegacyDownload(at: directory, weight: hfWeight(revision: pinned)))
    }

    func testTotalSegmentatorLegacyDownloadIsAdoptedBySize() throws {
        let weight = PluginWeight(id: "Dataset297", source: .totalsegTask, repo: nil,
                                  task: "total", filename: nil, sizeGB: 0.000001)
        let directory = root.appendingPathComponent("ts")
        try write(1_000, to: directory.appendingPathComponent("Dataset297/fold_0/checkpoint_final.pth"))
        XCTAssertTrue(PluginWeightCompletion.adoptLegacyDownload(at: directory, weight: weight))
    }

    /// The launch re-check writes the marker instead of demoting the record.
    func testReverifyAdoptsAReadyPreMarkerInstall() throws {
        let manifestJSON = """
        { "schema_version": 1, "protocol": 1, "plugins": [ {
          "id": "gemma-4-e4b", "name": "Gemma", "vendor": "Google", "summary": "VLM.",
          "execution": "resident-server", "adapter_dir": "gemma", "entry": "server.py",
          "requirements": "requirements.txt", "ram_gb": 5.0, "disk_gb": 6.7, "requires_apple_silicon": false,
          "tasks": [ { "id": "analyze", "label": "Analyze", "summary": "Describe.",
            "inputs": ["slice2d"], "outputs": ["text"],
            "license": { "gate": "open", "identifier": "Apache-2.0" },
            "weights": [ { "id": "gemma-4-e4b-it-4bit", "source": "huggingface",
              "repo": "mlx-community/gemma-4-E4B-it-4bit",
              "revision": "475b9088d29754a3379866cf5aeb6b41acd313c2", "size_gb": 0.000002 } ] } ] } ] }
        """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(manifestJSON.utf8))
        let ref = PluginTaskRef(pluginID: "gemma-4-e4b", taskID: "analyze")
        let directory = paths.weightDirectory(pluginID: "gemma-4-e4b", weightID: "gemma-4-e4b-it-4bit")
        try stageHubDownload(at: directory)
        let venv = paths.venvPython("gemma-4-e4b")
        try write(10, to: venv)

        let store = PluginInstallStore(paths: paths)
        try store.update(ref) { record in
            record.installState = .ready
            record.venvPath = venv.path
            record.weightPaths = ["gemma-4-e4b-it-4bit": directory.path]
            record.installedWeightIDs = ["gemma-4-e4b-it-4bit"]
        }
        XCTAssertTrue(store.reverify(manifest: manifest).isEmpty)
        XCTAssertEqual(store.state(for: ref), .ready)
        XCTAssertTrue(PluginInstaller.isCompleteDownload(at: directory))

        // And a partial one is still demoted.
        try FileManager.default.removeItem(at: directory.appendingPathComponent(PluginPaths.weightCompletionMarker))
        try write(10, to: directory.appendingPathComponent(".cache/huggingface/download/m.incomplete"))
        _ = store.reverify(manifest: manifest)
        XCTAssertEqual(store.state(for: ref), .notInstalled)
    }

    // MARK: - One Gemma copy

    func testBuiltInServerReusesThePluginCopyOfThePinnedRevision() throws {
        let directory = SharedGemmaWeights.pluginDirectory(paths: paths)
        XCTAssertNil(SharedGemmaWeights.installedDirectory(revision: pinned, paths: paths))

        try stageHubDownload(at: directory)
        XCTAssertNil(SharedGemmaWeights.installedDirectory(revision: pinned, paths: paths),
                     "without the completion marker the copy may be partial")

        try PluginInstaller.markDownloadComplete(at: directory, revision: pinned)
        XCTAssertEqual(SharedGemmaWeights.installedDirectory(revision: pinned, paths: paths), directory)
        XCTAssertNil(SharedGemmaWeights.installedDirectory(
            revision: String(repeating: "b", count: 40), paths: paths),
            "a different pinned revision must download its own")
    }

    func testSharedDirectoryMatchesTheManifestAndTheServerPin() throws {
        let manifest = try PluginManifest.loadBundled()
        let plugin = try XCTUnwrap(manifest.plugin(id: SharedGemmaWeights.pluginID))
        let weight = try XCTUnwrap(plugin.tasks.first?.weights.first)
        XCTAssertEqual(weight.id, SharedGemmaWeights.weightID)
        XCTAssertEqual(weight.repo, AIServerManager.modelRepo)
        XCTAssertEqual(weight.revision, "475b9088d29754a3379866cf5aeb6b41acd313c2")
    }

    // MARK: - Install preflight

    private func gemmaFixture() throws -> (PluginDescriptor, PluginTask) {
        let json = """
        { "schema_version": 1, "protocol": 1, "plugins": [ {
          "id": "gemma-4-e4b", "name": "Gemma", "vendor": "Google", "summary": "VLM.",
          "execution": "resident-server", "adapter_dir": "gemma", "entry": "server.py",
          "requirements": "requirements.txt", "ram_gb": 5.0, "disk_gb": 6.7, "requires_apple_silicon": false,
          "tasks": [ { "id": "analyze", "label": "Analyze", "summary": "Describe.",
            "inputs": ["slice2d"], "outputs": ["text"],
            "license": { "gate": "open", "identifier": "Apache-2.0" },
            "weights": [ { "id": "gemma-4-e4b-it-4bit", "source": "huggingface",
              "repo": "mlx-community/gemma-4-E4B-it-4bit",
              "revision": "475b9088d29754a3379866cf5aeb6b41acd313c2", "size_gb": 5.2 } ] } ] } ] }
        """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        let plugin = try XCTUnwrap(manifest.plugins.first)
        return (plugin, try XCTUnwrap(plugin.tasks.first))
    }

    private func installer(freeBytes: Int64?, hubHasSnapshot: Bool,
                           pythonOverride: String = "/nonexistent/python3") -> PluginInstaller {
        let locator = PluginEnvironmentLocator(adaptersRoot: root, paths: paths,
                                               pythonOverride: pythonOverride)
        var installer = PluginInstaller(locator: locator, store: PluginInstallStore(paths: paths))
        installer.availableDiskBytes = { _ in freeBytes }
        installer.hubCacheHasSnapshot = { _, _ in hubHasSnapshot }
        return installer
    }

    func testInstallPreflightUsesTheInjectedFreeSpace() async throws {
        let (plugin, task) = try gemmaFixture()
        let state = await installer(freeBytes: 1_000_000, hubHasSnapshot: false)
            .install(plugin: plugin, task: task, onState: { _, _ in }, onLog: { _, _ in })
        guard case .failed(let message) = state else { return XCTFail("\(state)") }
        XCTAssertTrue(message.contains("Not enough disk space"), message)

        // Plenty of room: the preflight passes and the install proceeds to the
        // (here deliberately missing) interpreter instead.
        let roomy = await installer(freeBytes: 1_000_000_000_000, hubHasSnapshot: false)
            .install(plugin: plugin, task: task, onState: { _, _ in }, onLog: { _, _ in })
        guard case .failed(let next) = roomy else { return XCTFail("\(roomy)") }
        XCTAssertFalse(next.contains("disk space"), next)
    }

    func testModelInTheHubCacheNeedsNoDiskForWeights() async throws {
        let (plugin, task) = try gemmaFixture()
        // 3 GB free: short of 5.2 GB of weights plus a venv, enough for the venv
        // alone. With the snapshot already in the hub cache it is linked, so
        // only the venv counts.
        let state = await installer(freeBytes: 3_000_000_000, hubHasSnapshot: true)
            .install(plugin: plugin, task: task, onState: { _, _ in }, onLog: { _, _ in })
        guard case .failed(let message) = state else { return XCTFail("\(state)") }
        XCTAssertFalse(message.contains("disk space"), message)
    }
}
