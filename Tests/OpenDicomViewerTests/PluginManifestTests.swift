// PluginManifestTests.swift
// Verifies the shipped plugins.json decodes into the contract types and that
// every declared plugin satisfies the invariants PLUGIN_PROTOCOL.md states.

import XCTest
@testable import OpenDicomViewer

final class PluginManifestTests: XCTestCase {

    /// Locate the repo's plugins.json without depending on bundle resources
    /// being staged for the test binary.
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

    private func loadManifest() throws -> PluginManifest {
        try PluginManifest.load(contentsOf: try manifestURL())
    }

    func testManifestDecodes() throws {
        let manifest = try loadManifest()
        XCTAssertEqual(manifest.protocolVersion, kPluginProtocolVersion)
        XCTAssertFalse(manifest.plugins.isEmpty)
    }

    func testExpectedPluginsPresent() throws {
        let manifest = try loadManifest()
        let ids = Set(manifest.plugins.map(\.id))
        XCTAssertTrue(ids.isSuperset(of: ["gemma-4-e4b", "sam2", "totalsegmentator"]),
                      "missing a core plugin; found \(ids.sorted())")
    }

    func testPluginIDsAndTaskIDsAreUnique() throws {
        let manifest = try loadManifest()
        let ids = manifest.plugins.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate plugin id")
        for plugin in manifest.plugins {
            let taskIDs = plugin.tasks.map(\.id)
            XCTAssertEqual(taskIDs.count, Set(taskIDs).count,
                           "duplicate task id in \(plugin.id)")
        }
    }

    func testEveryTaskDeclaresResourcesAndOutputs() throws {
        let manifest = try loadManifest()
        for plugin in manifest.plugins {
            XCTAssertGreaterThan(plugin.ramGB, 0, "\(plugin.id) declares no RAM")
            XCTAssertFalse(plugin.tasks.isEmpty, "\(plugin.id) declares no tasks")
            for task in plugin.tasks {
                let ref = PluginTaskRef(pluginID: plugin.id, taskID: task.id)
                XCTAssertFalse(task.inputs.isEmpty, "\(ref) declares no inputs")
                XCTAssertFalse(task.outputs.isEmpty, "\(ref) declares no outputs")
                XCTAssertFalse(task.weights.isEmpty, "\(ref) declares no weights")
                XCTAssertGreaterThan(task.weightsSizeGB, 0, "\(ref) weights have no size")
            }
        }
    }

    /// A gated task the store cannot explain is a dead end for the user, so the
    /// manifest must carry the terms URL and instructions for every gate that
    /// is not `open`.
    func testGatedTasksCarryUserFacingGuidance() throws {
        let manifest = try loadManifest()
        for plugin in manifest.plugins {
            for task in plugin.tasks where task.license.gate != .open {
                let ref = PluginTaskRef(pluginID: plugin.id, taskID: task.id)
                XCTAssertNotNil(task.license.termsURL, "\(ref) is gated but has no terms URL")
                XCTAssertNotNil(task.license.instructions,
                                "\(ref) is gated but has no instructions")
                XCTAssertFalse(task.license.identifier.isEmpty,
                               "\(ref) has no license identifier")
            }
        }
    }

    func testSessionPluginsBoundTheirSessionCache() throws {
        let manifest = try loadManifest()
        for plugin in manifest.plugins where plugin.execution == .session {
            XCTAssertNotNil(plugin.maxSessions,
                            "\(plugin.id) is a session plugin but does not bound its cache")
            XCTAssertGreaterThan(plugin.maxSessions ?? 0, 0)
        }
    }

    func testKnownGates() throws {
        let manifest = try loadManifest()
        let heart = manifest.plugin(id: "totalsegmentator")?.task(id: "heartchambers_highres")
        XCTAssertEqual(heart?.license.gate, .licenseKey)
        XCTAssertEqual(heart?.license.keyFormat, "aca_")

        let sam3 = manifest.plugin(id: "sam3")?.task(id: "prompt-mask")
        XCTAssertEqual(sam3?.license.gate, .gatedDownload)

        let analyze = manifest.plugin(id: "gemma-4-e4b")?.task(id: "analyze")
        XCTAssertEqual(analyze?.license.gate, .open)
        XCTAssertEqual(analyze?.outputs, [.text, .bbox])
    }

    func testExecutionModelsMatchDesign() throws {
        let manifest = try loadManifest()
        XCTAssertEqual(manifest.plugin(id: "gemma-4-e4b")?.execution, .residentServer)
        XCTAssertEqual(manifest.plugin(id: "sam2")?.execution, .session)
        XCTAssertEqual(manifest.plugin(id: "totalsegmentator")?.execution, .oneShot)
        XCTAssertFalse(PluginExecution.oneShot.isResident)
        XCTAssertTrue(PluginExecution.session.isResident)
    }

    func testProtocolMismatchIsRejected() throws {
        let json = """
        {"schema_version": 1, "protocol": 99, "plugins": []}
        """.data(using: .utf8)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bad-manifest-\(UUID().uuidString).json")
        try json.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try PluginManifest.load(contentsOf: url)) { error in
            guard case PluginError.protocolMismatch(let expected, let found) =
                    (error as? PluginError) ?? .manifestMissing else {
                return XCTFail("expected protocolMismatch, got \(error)")
            }
            XCTAssertEqual(expected, kPluginProtocolVersion)
            XCTAssertEqual(found, 99)
        }
    }

    // MARK: - Mask RLE

    func testMaskRLEDecodesRowMajorStartingWithBackground() {
        // 4x2 grid: 3 background, 2 foreground, 3 background.
        let mask = PluginMask2D(width: 4, height: 2, rle: [3, 2, 3],
                                label: "t", confidence: 1.0)
        let decoded = mask.decodeMask()
        XCTAssertEqual(decoded, [false, false, false, true,
                                 true, false, false, false])
    }

    func testMaskRLELeadingZeroMeansStartsForeground() {
        let mask = PluginMask2D(width: 2, height: 1, rle: [0, 2],
                                label: nil, confidence: nil)
        XCTAssertEqual(mask.decodeMask(), [true, true])
    }

    func testMaskRLERejectsWrongTotal() {
        let short = PluginMask2D(width: 4, height: 4, rle: [2, 2],
                                 label: nil, confidence: nil)
        XCTAssertNil(short.decodeMask(), "runs summing under the grid must be rejected")

        let long = PluginMask2D(width: 2, height: 2, rle: [2, 99],
                                label: nil, confidence: nil)
        XCTAssertNil(long.decodeMask(), "runs overflowing the grid must be rejected")
    }

    // MARK: - Install state

    func testInstallStateProgressAndBusy() {
        XCTAssertTrue(PluginInstallState.downloading(progress: 0.5).isBusy)
        XCTAssertTrue(PluginInstallState.installing(progress: 0.1).isBusy)
        XCTAssertFalse(PluginInstallState.ready.isBusy)
        XCTAssertFalse(PluginInstallState.resolvingLicense.isBusy)
        XCTAssertEqual(PluginInstallState.downloading(progress: 0.42).progress, 0.42)
        XCTAssertNil(PluginInstallState.ready.progress)
        XCTAssertTrue(PluginInstallState.ready.isReady)
    }

    func testPointEncodesLabelAsInt() throws {
        let point = PluginPoint(x: 0.25, y: 0.75, isForeground: false)
        let data = try JSONEncoder().encode(point)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["label"] as? Int, 0)

        let round = try JSONDecoder().decode(PluginPoint.self, from: data)
        XCTAssertEqual(round, point)
    }
}
