// ReleaseReadinessTests.swift
// OpenDicomViewer Tests
//
// The pieces outside users hit on a first install: what the model is sent,
// how server errors read, a second copy of the app, a half-downloaded model,
// low-memory Macs, running from the disk image, and Finder open requests.
// Licensed under the MIT License. See LICENSE for details.

import XCTest
import AppKit
@testable import OpenDicomViewer

final class ReleaseReadinessTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("odv-release-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - Image sent to the model

    func testTargetSizeKeepsAspectAndCapsTheLongestSide() throws {
        let small = try XCTUnwrap(AIImagePreparation.targetSize(width: 512, height: 256))
        XCTAssertEqual(small, CGSize(width: 512, height: 256))
        let big = try XCTUnwrap(AIImagePreparation.targetSize(width: 3000, height: 2400))
        XCTAssertEqual(big.width, 1120)
        XCTAssertEqual(big.height, 896)
        XCTAssertNil(AIImagePreparation.targetSize(width: 0, height: 10))
        XCTAssertNil(AIImagePreparation.targetSize(width: .nan, height: 10))
    }

    /// An MPR image: 100x50 voxels shown at 100x100 points. The model must
    /// see the displayed shape, not the squashed voxel grid.
    func testMPRImageIsRedrawnAtItsDisplayedAspect() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 50, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let image = NSImage(size: NSSize(width: 100, height: 100))
        image.addRepresentation(rep)

        let rendered = try XCTUnwrap(AIImagePreparation.render(image, width: 100, height: 100))
        let tiff = try XCTUnwrap(rendered.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        XCTAssertEqual(bitmap.pixelsWide, 100)
        XCTAssertEqual(bitmap.pixelsHigh, 100)
    }

    // MARK: - Server errors

    func testErrorDetailIsDecoded() {
        XCTAssertEqual(AIService.errorDetail(from: Data(#"{"detail": "RuntimeError: [metal::malloc]"}"#.utf8)),
                       "RuntimeError: [metal::malloc]")
        XCTAssertEqual(AIService.errorDetail(from: Data(#"{"detail": [{"msg": "field required"}]}"#.utf8)),
                       "field required")
        XCTAssertEqual(AIService.errorDetail(from: Data("Internal Server Error".utf8)),
                       "Internal Server Error")
        XCTAssertEqual(AIService.errorDetail(from: Data()), "Unknown error")
    }

    func testTimeoutMessageNamesTheRemedy() {
        let message = AIServiceError.transport(URLError(.timedOut)).errorDescription ?? ""
        XCTAssertTrue(message.contains("10 minutes"), message)
        XCTAssertGreaterThanOrEqual(AIService.inferenceTimeout, 600)
    }

    // MARK: - Second app instance

    func testOwnedPIDRecordRoundTripsAndLegacyRecordsStillParse() throws {
        let server = AIServerManager.PIDRecord(pid: 1234, startSeconds: 10, startMicroseconds: 5)
        let owner = try XCTUnwrap(AIServerManager.PIDRecord.current(pid: getpid()))
        let owned = AIServerManager.OwnedPIDRecord(server: server, owner: owner)
        XCTAssertEqual(AIServerManager.OwnedPIDRecord(serialized: owned.serialized), owned)

        let legacy = try XCTUnwrap(AIServerManager.OwnedPIDRecord(serialized: "1234 10 5"))
        XCTAssertEqual(legacy.server, server)
        XCTAssertNil(legacy.owner)
        XCTAssertNil(AIServerManager.OwnedPIDRecord(serialized: "garbage"))
    }

    func testOnlyServersWhoseAppIsGoneAreSwept() throws {
        let server = AIServerManager.PIDRecord(pid: 1234, startSeconds: 10, startMicroseconds: 5)
        let owner = AIServerManager.PIDRecord(pid: 99, startSeconds: 1, startMicroseconds: 1)
        let owned = AIServerManager.OwnedPIDRecord(server: server, owner: owner)
        XCTAssertFalse(owned.isOrphaned(serverAlive: true, ownerAlive: true),
                       "another running copy's server must survive")
        XCTAssertTrue(owned.isOrphaned(serverAlive: true, ownerAlive: false))
        XCTAssertFalse(owned.isOrphaned(serverAlive: false, ownerAlive: false))
        let legacy = AIServerManager.OwnedPIDRecord(server: server, owner: nil)
        XCTAssertTrue(legacy.isOrphaned(serverAlive: true, ownerAlive: false))

        // The live owner check really looks at the process.
        XCTAssertTrue(try XCTUnwrap(AIServerManager.PIDRecord.current(pid: getpid())).isAlive)
        XCTAssertFalse(AIServerManager.PIDRecord(pid: getpid(), startSeconds: 1,
                                                 startMicroseconds: 1).isAlive)
    }

    func testSetupLockIsExclusive() throws {
        let url = scratch.appendingPathComponent(".odv-setup.lock")
        let first = try XCTUnwrap(SetupLock(url: url))
        let second = try XCTUnwrap(SetupLock(url: url))
        XCTAssertTrue(first.tryAcquire())
        XCTAssertFalse(second.tryAcquire(), "a second setup must wait")
        first.release()
        XCTAssertTrue(second.tryAcquire())
        second.release()
    }

    // MARK: - Snapshot completeness

    func testShardedSnapshotNeedsEveryIndexedShard() throws {
        let environment = ["HF_HUB_CACHE": scratch.path]
        let snapshot = scratch.appendingPathComponent("models--org--model/snapshots/abc")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: snapshot.appendingPathComponent("config.json"))
        let index = #"{"weight_map": {"a": "model-00001-of-00002.safetensors", "b": "model-00002-of-00002.safetensors"}}"#
        try Data(index.utf8).write(to: snapshot.appendingPathComponent("model.safetensors.index.json"))
        try Data("w".utf8).write(to: snapshot.appendingPathComponent("model-00001-of-00002.safetensors"))
        XCTAssertFalse(HuggingFaceCache.snapshotExists(repo: "org/model", revision: "abc",
                                                       environment: environment),
                       "one shard of two is an interrupted download")
        try Data("w".utf8).write(to: snapshot.appendingPathComponent("model-00002-of-00002.safetensors"))
        XCTAssertTrue(HuggingFaceCache.snapshotExists(repo: "org/model", revision: "abc",
                                                      environment: environment))
    }

    // MARK: - Memory and install location

    func testLowMemoryThreshold() {
        let gib: UInt64 = 1024 * 1024 * 1024
        XCTAssertTrue(AIServerManager.isLowMemory(physicalBytes: 8 * gib))
        XCTAssertFalse(AIServerManager.isLowMemory(physicalBytes: 16 * gib))
        XCTAssertEqual(AIServerManager.memoryGBText(8 * gib), "8 GB")
    }

    func testDiskImageAndTranslocatedPathsAreDetected() {
        XCTAssertTrue(AIServerManager.isRunningFromDiskImageOrTranslocation(
            bundlePath: "/Volumes/ODV-Annotate/ODV-Annotate.app"))
        XCTAssertTrue(AIServerManager.isRunningFromDiskImageOrTranslocation(
            bundlePath: "/private/var/folders/xy/T/AppTranslocation/ABC/d/ODV-Annotate.app"))
        XCTAssertFalse(AIServerManager.isRunningFromDiskImageOrTranslocation(
            bundlePath: "/Applications/ODV-Annotate.app"))
    }

    // MARK: - Results

    func testNewBoxesReplaceOnlyThatSlicesBoxes() {
        let panel = PanelState()
        let here = AnnotationSlice(seriesIndex: 0, panelMode: .slice2D, index: 3, frame: 0, slab: 0)
        let there = AnnotationSlice(seriesIndex: 0, panelMode: .slice2D, index: 4, frame: 0, slab: 0)
        let rect = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        panel.annotations = [
            Annotation(type: .aiStructure(rect: rect, label: "old", confidence: 0.5), isAI: true, slice: here),
            Annotation(type: .aiFinding(rect: rect, description: "old", severity: "mild"), isAI: true, slice: here),
            Annotation(type: .aiROILabel(rect: rect, label: "roi", description: "", confidence: 0.5),
                       isAI: true, slice: here),
            Annotation(type: .aiStructure(rect: rect, label: "other", confidence: 0.5), isAI: true, slice: there),
            Annotation(type: .ruler(start: .zero, end: CGPoint(x: 1, y: 1), distanceMM: 1), slice: here),
        ]
        panel.replaceAIBoxes(on: here)
        XCTAssertEqual(panel.annotations.count, 3)
        XCTAssertFalse(panel.annotations.contains { annotation in
            if case .aiStructure(_, "old", _) = annotation.type { return true }
            return false
        })
    }

    // MARK: - Finder open requests

    func testOpenTargetForFinderSelections() {
        let a = URL(fileURLWithPath: "/data/study/a.dcm")
        let b = URL(fileURLWithPath: "/data/study/b.dcm")
        let folder = URL(fileURLWithPath: "/data/study", isDirectory: true)
        XCTAssertNil(AppOpenDelegate.loadTarget(for: []))
        XCTAssertEqual(AppOpenDelegate.loadTarget(for: [a]), a)
        XCTAssertEqual(AppOpenDelegate.loadTarget(for: [a, b])?.path, folder.path)
        let elsewhere = URL(fileURLWithPath: "/other/c.dcm")
        XCTAssertEqual(AppOpenDelegate.loadTarget(for: [a, elsewhere]), a)
    }

    func testUpdateCheckFailuresReadAsSentences() {
        XCTAssertTrue(UpdateChecker.statusMessage(404).contains("No published release"))
        XCTAssertTrue(UpdateChecker.statusMessage(403).contains("rate limit"))
    }
}
