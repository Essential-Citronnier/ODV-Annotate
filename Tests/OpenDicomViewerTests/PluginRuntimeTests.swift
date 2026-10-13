// PluginRuntimeTests.swift
// OpenDicomViewer
//
// Exercises the plugin runtime's pure logic: install-state persistence and
// re-verification, port assignment, memory admission, and payload decoding.
// Nothing here spawns a model, touches the network, or reads a weight file;
// every filesystem effect is confined to a temporary directory and every
// resource reading is injected.
// Licensed under the MIT License. See LICENSE for details.

import XCTest
@testable import OpenDicomViewer

final class PluginRuntimeTests: XCTestCase {

    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("odv-plugin-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot, FileManager.default.fileExists(atPath: temporaryRoot.path) {
            try FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    private func makePaths() -> PluginPaths {
        PluginPaths(root: temporaryRoot.appendingPathComponent("plugins", isDirectory: true))
    }

    // MARK: - Fixtures

    private static let gemmaRef = PluginTaskRef(pluginID: "gemma-4-e4b", taskID: "analyze")
    private static let totalsegRef = PluginTaskRef(pluginID: "totalsegmentator", taskID: "total")

    /// A two-plugin manifest covering an open task and a gated one, so the
    /// tests do not depend on the shipped plugins.json staying as it is today.
    private func fixtureManifest() throws -> PluginManifest {
        let json = """
        {
          "schema_version": 1,
          "protocol": 1,
          "plugins": [
            {
              "id": "gemma-4-e4b",
              "name": "Gemma",
              "vendor": "Google",
              "summary": "Vision-language model.",
              "execution": "resident-server",
              "adapter_dir": "gemma",
              "entry": "server.py",
              "requirements": "requirements.txt",
              "ram_gb": 5.0,
              "disk_gb": 4.8,
              "requires_apple_silicon": true,
              "tasks": [
                {
                  "id": "analyze",
                  "label": "Analyze Image",
                  "summary": "Describe the slice.",
                  "inputs": ["slice2d", "text"],
                  "outputs": ["text"],
                  "license": { "gate": "open", "identifier": "Apache-2.0" },
                  "weights": [
                    { "id": "gemma-weights", "source": "huggingface",
                      "repo": "mlx-community/gemma", "size_gb": 4.5 }
                  ]
                }
              ]
            },
            {
              "id": "sam3",
              "name": "SAM 3",
              "vendor": "Meta",
              "summary": "Promptable segmentation.",
              "execution": "session",
              "adapter_dir": "sam3",
              "entry": "server.py",
              "requirements": "requirements.txt",
              "ram_gb": 6.0,
              "disk_gb": 3.6,
              "max_sessions": 2,
              "requires_apple_silicon": false,
              "tasks": [
                {
                  "id": "prompt-mask",
                  "label": "Prompt Segmentation",
                  "summary": "Segment from a prompt.",
                  "inputs": ["slice2d", "points"],
                  "outputs": ["mask2d"],
                  "license": {
                    "gate": "gated-download",
                    "identifier": "SAM License (Meta)",
                    "terms_url": "https://example.invalid/terms"
                  },
                  "weights": [
                    { "id": "sam3-checkpoint", "source": "manual",
                      "filename": "sam3.pt", "size_gb": 3.4 }
                  ]
                }
              ]
            }
          ]
        }
        """
        return try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
    }

    // MARK: - Install state persistence

    func testInstallStateRoundTripsThroughDisk() throws {
        let paths = makePaths()
        let store = PluginInstallStore(paths: paths)

        try store.update(Self.gemmaRef) { record in
            record.installState = .ready
            record.installedWeightIDs = ["gemma-weights"]
            record.weightPaths = ["gemma-weights": "/tmp/gemma-weights"]
            record.bytesOnDisk = 4_800_000_000
            record.venvPath = paths.venvPython("gemma-4-e4b").path
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.stateFile.path),
                      "state.json was not written")

        let reopened = PluginInstallStore(paths: paths)
        XCTAssertTrue(reopened.load())
        let record = try XCTUnwrap(reopened.record(for: Self.gemmaRef))
        XCTAssertEqual(record.installState, .ready)
        XCTAssertEqual(record.installedWeightIDs, ["gemma-weights"])
        XCTAssertEqual(record.bytesOnDisk, 4_800_000_000)
        XCTAssertEqual(record.venvPath, paths.venvPython("gemma-4-e4b").path)
    }

    func testInstallStateTransitionsMapOntoPersistedPhases() throws {
        let store = PluginInstallStore(paths: makePaths())

        let sequence: [(PluginInstallState, PluginInstallPhase)] = [
            (.notInstalled, .notInstalled),
            (.resolvingLicense, .resolvingLicense),
            (.downloading(progress: 0.25), .downloading),
            (.installing(progress: 0.6), .installing),
            (.ready, .ready),
            (.failed("network unreachable"), .failed),
        ]

        for (state, expectedPhase) in sequence {
            let record = try store.setState(state, for: Self.gemmaRef)
            XCTAssertEqual(record.phase, expectedPhase)
            XCTAssertEqual(record.installState, state,
                           "\(state) did not survive the round trip through \(expectedPhase)")
        }

        XCTAssertEqual(store.state(for: Self.gemmaRef), .failed("network unreachable"))
        XCTAssertEqual(store.state(for: Self.totalsegRef), .notInstalled,
                       "an unseen task should default to not installed")
    }

    func testWriteIsAtomicAndLeavesNoTemporaryFiles() throws {
        let paths = makePaths()
        let store = PluginInstallStore(paths: paths)
        for index in 0..<25 {
            try store.setState(.installing(progress: Double(index) / 25), for: Self.gemmaRef)
        }
        try store.setState(.ready, for: Self.gemmaRef)

        let residue = try FileManager.default
            .contentsOfDirectory(atPath: paths.root.path)
            .filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(residue.isEmpty, "atomic write left temporary files: \(residue)")

        // The file on disk must be parseable after every one of those writes.
        let data = try Data(contentsOf: paths.stateFile)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(PluginInstallStateFile.self, from: data)
        XCTAssertEqual(file.version, PluginInstallStateFile.currentVersion)
        XCTAssertEqual(file.records.count, 1)
        XCTAssertEqual(file.records.first?.phase, .ready)
    }

    func testCorruptStateFileIsTreatedAsEmptyRatherThanFatal() throws {
        let paths = makePaths()
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try Data("{ not json at all".utf8).write(to: paths.stateFile)

        let store = PluginInstallStore(paths: paths)
        XCTAssertFalse(store.load())
        XCTAssertEqual(store.state(for: Self.gemmaRef), .notInstalled)
    }

    func testLicenseKeyIsNeverPersisted() throws {
        let paths = makePaths()
        let store = PluginInstallStore(paths: paths)
        try store.update(PluginTaskRef(pluginID: "totalsegmentator", taskID: "heartchambers_highres")) {
            $0.installState = .ready
            $0.licenseAcknowledged = true
        }
        let text = try String(contentsOf: paths.stateFile, encoding: .utf8)
        XCTAssertTrue(text.contains("license_acknowledged"))
        XCTAssertFalse(text.lowercased().contains("aca_"),
                       "state.json must never contain a license key")
        XCTAssertFalse(text.lowercased().contains("\"license_key\""))
    }

    // MARK: - Re-verification

    func testReverifyDemotesReadyTaskWhoseVenvVanished() throws {
        let paths = makePaths()
        let store = PluginInstallStore(paths: paths)
        let manifest = try fixtureManifest()

        try store.update(Self.gemmaRef) { record in
            record.installState = .ready
            record.venvPath = "/gone/.venv/bin/python3"
            record.weightPaths = ["gemma-weights": "/present/weights"]
            record.installedWeightIDs = ["gemma-weights"]
        }

        let changed = store.reverify(manifest: manifest) { path in path == "/present/weights" }
        XCTAssertEqual(changed, [Self.gemmaRef])
        XCTAssertEqual(store.state(for: Self.gemmaRef), .notInstalled)
    }

    func testReverifyDemotesReadyTaskWhoseWeightsVanished() throws {
        let store = PluginInstallStore(paths: makePaths())
        let manifest = try fixtureManifest()

        try store.update(Self.gemmaRef) { record in
            record.installState = .ready
            record.venvPath = "/present/.venv/bin/python3"
            record.weightPaths = ["gemma-weights": "/gone/weights"]
            record.installedWeightIDs = ["gemma-weights"]
        }

        _ = store.reverify(manifest: manifest) { $0.hasPrefix("/present") }
        XCTAssertEqual(store.state(for: Self.gemmaRef), .notInstalled,
                       "a ready task with missing weights must fall back rather than fail at first use")
    }

    func testReverifyLeavesAnIntactInstallAlone() throws {
        let store = PluginInstallStore(paths: makePaths())
        let manifest = try fixtureManifest()

        try store.update(Self.gemmaRef) { record in
            record.installState = .ready
            record.venvPath = "/present/.venv/bin/python3"
            record.weightPaths = ["gemma-weights": "/present/weights"]
            record.installedWeightIDs = ["gemma-weights"]
        }

        let changed = store.reverify(manifest: manifest) { _ in true }
        XCTAssertTrue(changed.isEmpty)
        XCTAssertEqual(store.state(for: Self.gemmaRef), .ready)
    }

    /// Section 7: a downloaded weight directory without the host's completion
    /// marker may hold a download a crash cut short; it is not ready.
    func testReverifyRequiresTheDownloadCompletionMarker() throws {
        let store = PluginInstallStore(paths: makePaths())
        let manifest = try fixtureManifest()

        try store.update(Self.gemmaRef) { record in
            record.installState = .ready
            record.venvPath = "/present/.venv/bin/python3"
            record.weightPaths = ["gemma-weights": "/present/weights"]
            record.installedWeightIDs = ["gemma-weights"]
        }

        let marker = "/present/weights/" + PluginPaths.weightCompletionMarker
        _ = store.reverify(manifest: manifest) { $0.hasPrefix("/present") && $0 != marker }
        XCTAssertEqual(store.state(for: Self.gemmaRef), .notInstalled)
    }

    func testReverifySendsAMissingManualCheckpointBackToTheLicenseGate() throws {
        let store = PluginInstallStore(paths: makePaths())
        let manifest = try fixtureManifest()
        let ref = PluginTaskRef(pluginID: "sam3", taskID: "prompt-mask")

        try store.update(ref) { record in
            record.installState = .ready
            record.licenseAcknowledged = true
            record.venvPath = "/present/.venv/bin/python3"
            record.weightPaths = ["sam3-checkpoint": "/present/sam3.pt"]
            record.installedWeightIDs = ["sam3-checkpoint"]
        }

        _ = store.reverify(manifest: manifest) { $0 != "/present/sam3.pt" }
        XCTAssertEqual(store.state(for: ref), .resolvingLicense,
                       "a gated checkpoint the host cannot re-fetch belongs back at the gate")
    }

    func testReverifyRestartsAnInterruptedInstall() throws {
        let store = PluginInstallStore(paths: makePaths())
        let manifest = try fixtureManifest()
        try store.setState(.downloading(progress: 0.4), for: Self.gemmaRef)

        _ = store.reverify(manifest: manifest) { _ in true }
        XCTAssertEqual(store.state(for: Self.gemmaRef), .notInstalled,
                       "no supervisor survived the interruption, so the environment is half-built")
    }

    func testReverifyDropsRecordsForTasksNoLongerInTheManifest() throws {
        let store = PluginInstallStore(paths: makePaths())
        let manifest = try fixtureManifest()
        let orphan = PluginTaskRef(pluginID: "retired-plugin", taskID: "gone")
        try store.setState(.ready, for: orphan)

        let changed = store.reverify(manifest: manifest) { _ in true }
        XCTAssertEqual(changed, [orphan])
        XCTAssertNil(store.record(for: orphan))
    }

    // MARK: - Filesystem layout

    func testPathsAreConfinedToTheSubsystemRoot() {
        let paths = makePaths()
        for identifier in ["../../etc", "/etc/passwd", "..", "a/b/c", ""] {
            let hostile = paths.pluginRoot(identifier).standardizedFileURL
            XCTAssertTrue(hostile.path.hasPrefix(paths.root.path + "/"),
                          "\(identifier) escaped the plugin root as \(hostile.path)")
            XCTAssertEqual(hostile.pathComponents.count, paths.root.pathComponents.count + 1,
                           "\(identifier) introduced extra path components")
        }
    }

    func testEachPluginGetsItsOwnVirtualenv() {
        let paths = makePaths()
        XCTAssertNotEqual(paths.venv("gemma-4-e4b"), paths.venv("sam2"),
                          "MLX and torch are not co-installable; envs must not be shared")
    }

    // MARK: - Port assignment

    func testPortAllocatorHandsOutDistinctPortsPerPlugin() throws {
        // Deliberately not the live probe: a plugin must never be told to bind a
        // port another plugin already holds, and that bookkeeping should be
        // provable without depending on what the kernel happens to offer.
        let offers = ScriptedProbe([51000, 51001, 51002])
        var allocator = PluginPortAllocator(probe: { offers.next() })
        let ids = ["gemma-4-e4b", "sam2", "sam3"]
        let assigned = try ids.map { try allocator.port(for: $0) }

        XCTAssertEqual(assigned, [51000, 51001, 51002])
        XCTAssertEqual(Set(assigned).count, ids.count, "ports collided: \(assigned)")
    }

    func testPortAllocatorIsStablePerPluginAndReleasable() throws {
        let offers = ScriptedProbe([51000, 51001])
        var allocator = PluginPortAllocator(probe: { offers.next() })
        let first = try allocator.port(for: "gemma-4-e4b")
        XCTAssertEqual(try allocator.port(for: "gemma-4-e4b"), first,
                       "a running plugin must keep the port it was started on")
        allocator.release("gemma-4-e4b")
        XCTAssertNil(allocator.assigned["gemma-4-e4b"])
        XCTAssertEqual(try allocator.port(for: "gemma-4-e4b"), 51001,
                       "a released plugin is re-probed rather than given its old port back")
    }

    func testLiveProbeReturnsAnEphemeralPort() throws {
        // Binding is denied under some build sandboxes; the allocator's contract
        // in that case is to report failure, which the injected-probe tests
        // already cover. Only assert the shape of a successful reading.
        guard let port = PluginPortAllocator.freeLoopbackPort() else {
            throw XCTSkip("this environment does not permit binding a loopback socket")
        }
        XCTAssertGreaterThan(port, 1024, "expected an ephemeral port, got \(port)")
        XCTAssertLessThanOrEqual(port, 65535)
        XCTAssertNotEqual(port, PluginPortAllocator.freeLoopbackPort() ?? port,
                          "successive probes should not return the same port")
    }

    func testPortAllocatorSkipsANumberItHasAlreadyReserved() throws {
        // A kernel that keeps offering the same port must not cause two plugins
        // to be told to bind it.
        let offers = ScriptedProbe([51000, 51000, 51000, 51001])
        var allocator = PluginPortAllocator(probe: { offers.next() })
        XCTAssertEqual(try allocator.port(for: "a"), 51000)
        XCTAssertEqual(try allocator.port(for: "b"), 51001)
    }

    func testPortAllocatorThrowsWhenNoPortCanBeReserved() {
        var allocator = PluginPortAllocator(probe: { nil })
        XCTAssertThrowsError(try allocator.port(for: "gemma-4-e4b"))
    }

    // MARK: - Resource arbitration

    /// A machine with plenty of free memory, so the live-headroom term never
    /// masks the declared-budget term the tests are aiming at.
    private func arbiter(physicalGB: Double, availableGB: Double? = nil) -> ResourceArbiter {
        ResourceArbiter(probe: MemoryProbe.fixed(
            physicalGB: physicalGB, availableGB: availableGB ?? physicalGB * 0.9))
    }

    private let gemma = PluginResidency(pluginID: "gemma-4-e4b", declaredRamGB: 5.0)
    private let totalseg = PluginResidency(pluginID: "totalsegmentator", declaredRamGB: 3.5)

    func testAdmitsIntoAnEmptyMachine() {
        XCTAssertEqual(arbiter(physicalGB: 16).admit(gemma, residents: []), .admit)
    }

    func testSixteenGigabyteMachineEvictsGemmaForTotalSegmentator() {
        // The case this design exists for. The 16 GiB budget is 8 GiB; Gemma's
        // 5 GB plus TotalSegmentator's 3.5 GB is 8.5 GB and does not fit, so
        // Gemma stops for the duration of the segmentation.
        let resident = PluginResidency(pluginID: "gemma-4-e4b", declaredRamGB: 5.0,
                                       lastUsed: Date().addingTimeInterval(-600))
        let decision = arbiter(physicalGB: 16).admitOneShot(totalseg, residents: [resident])
        XCTAssertEqual(decision, .evictThenAdmit(["gemma-4-e4b"]))
    }

    func testThirtyTwoGigabyteMachineRunsBothConcurrently() {
        let resident = PluginResidency(pluginID: "gemma-4-e4b", declaredRamGB: 5.0)
        XCTAssertEqual(arbiter(physicalGB: 32).admitOneShot(totalseg, residents: [resident]), .admit,
                       "5.0 + 3.5 GB fits inside a 16 GiB budget; nothing should be evicted")
    }

    func testEvictionOrderIsLeastRecentlyUsedFirst() {
        let now = Date()
        let oldest = PluginResidency(pluginID: "sam2", declaredRamGB: 3.0,
                                     lastUsed: now.addingTimeInterval(-900))
        let middle = PluginResidency(pluginID: "gemma-4-e4b", declaredRamGB: 5.0,
                                     lastUsed: now.addingTimeInterval(-300))
        let newest = PluginResidency(pluginID: "sam3", declaredRamGB: 6.0, lastUsed: now)

        // A 24 GiB budget is 12 GiB; 3 + 5 + 6 = 14 GB resident, and the newcomer
        // wants 3.5 GB. Dropping the two oldest leaves 6 + 3.5 = 9.5 GB, which
        // fits, so the newest survives.
        let decision = arbiter(physicalGB: 24).admitOneShot(
            totalseg, residents: [newest, middle, oldest])
        XCTAssertEqual(decision, .evictThenAdmit(["sam2", "gemma-4-e4b"]))
    }

    func testEvictionStopsAsSoonAsTheRequestFits() {
        let now = Date()
        let oldest = PluginResidency(pluginID: "sam2", declaredRamGB: 3.0,
                                     lastUsed: now.addingTimeInterval(-900))
        let newer = PluginResidency(pluginID: "gemma-4-e4b", declaredRamGB: 5.0, lastUsed: now)

        // An 8 GiB budget cannot hold 6 GB alongside anything else here, so both
        // residents go, oldest first.
        let sam3 = PluginResidency(pluginID: "sam3", declaredRamGB: 6.0)
        let decision = arbiter(physicalGB: 16).admit(sam3, residents: [oldest, newer])
        XCTAssertEqual(decision.evictions, ["sam2", "gemma-4-e4b"])

        // A 12 GiB budget needs only the oldest to go: 5 + 6 = 11 GB then fits.
        let roomier = arbiter(physicalGB: 24).admit(sam3, residents: [oldest, newer])
        XCTAssertEqual(roomier, .evictThenAdmit(["sam2"]),
                       "eviction must stop at the first arrangement that fits")

        // A 16 GiB budget holds all three at once.
        XCTAssertEqual(arbiter(physicalGB: 32).admit(sam3, residents: [oldest, newer]), .admit)
    }

    func testBusyPluginIsNotEvictedAndBlocksAdmission() {
        let busy = PluginResidency(pluginID: "gemma-4-e4b", declaredRamGB: 5.0,
                                   lastUsed: Date().addingTimeInterval(-900), isEvictable: false)
        let decision = arbiter(physicalGB: 16).admitOneShot(totalseg, residents: [busy])
        guard case .refuse = decision else {
            return XCTFail("work the user is waiting on must not be evicted; got \(decision)")
        }
        XCTAssertNotNil(decision.refusalError)
    }

    func testRefusalWhenTheRequestCannotFitAnEmptyMachine() {
        let huge = PluginResidency(pluginID: "enormous", declaredRamGB: 12.0)
        let decision = arbiter(physicalGB: 16).admit(huge, residents: [])
        guard case .refuse(let required, _) = decision else {
            return XCTFail("12 GB cannot fit an 8 GiB budget; got \(decision)")
        }
        XCTAssertEqual(required, 12.0)
    }

    func testLiveHeadroomRefusesEvenWhenTheDeclaredBudgetWouldAllowIt() {
        // A 64 GiB machine with almost nothing free: the declared budget says
        // yes, the machine says no, and the arbiter must side with the machine.
        let starved = ResourceArbiter(probe: MemoryProbe.fixed(physicalGB: 64, availableGB: 3.0))
        // The refusal is the overridable kind: the user may start anyway.
        guard case .refuseLiveHeadroom = starved.admit(gemma, residents: []) else {
            return XCTFail("3 GB available less a 2 GB margin cannot host a 5 GB model")
        }
    }

    func testEvictionReturnsMemoryToLiveHeadroom() {
        // Only 4 GB free, but the resident 5 GB plugin's memory comes back when
        // it stops, which is enough for the newcomer.
        let tight = ResourceArbiter(probe: MemoryProbe.fixed(physicalGB: 32, availableGB: 4.0))
        let resident = PluginResidency(pluginID: "gemma-4-e4b", declaredRamGB: 5.0,
                                       lastUsed: Date().addingTimeInterval(-60))
        XCTAssertEqual(tight.admit(totalseg, residents: [resident]),
                       .evictThenAdmit(["gemma-4-e4b"]))
    }

    func testAlreadyResidentPluginIsAdmittedWithoutDisturbingAnything() {
        let resident = PluginResidency(pluginID: "gemma-4-e4b", declaredRamGB: 5.0)
        XCTAssertEqual(arbiter(physicalGB: 8).admit(gemma, residents: [resident]), .admit,
                       "re-entering a running server must never evict it")
    }

    func testOneShotCountsAgainstAResidentSiblingOfTheSameIdentifier() {
        // A resident TotalSegmentator server would not share the subprocess's
        // memory, so the sibling has to be accounted for rather than skipped.
        let resident = PluginResidency(pluginID: "totalsegmentator", declaredRamGB: 3.5,
                                       lastUsed: Date().addingTimeInterval(-60))
        let other = PluginResidency(pluginID: "gemma-4-e4b", declaredRamGB: 5.0, lastUsed: Date())
        let decision = arbiter(physicalGB: 16).admitOneShot(totalseg, residents: [resident, other])
        XCTAssertFalse(decision.evictions.isEmpty,
                       "a one-shot peak lands on top of everything resident, siblings included")
    }

    func testEvictionPlanIsDeterministicForTiedTimestamps() {
        let tied = Date()
        let a = PluginResidency(pluginID: "aaa", declaredRamGB: 4.0, lastUsed: tied)
        let b = PluginResidency(pluginID: "bbb", declaredRamGB: 4.0, lastUsed: tied)
        // A 12 GiB budget needs one of the two 4 GB residents to go for a 5 GB
        // newcomer; which one is decided entirely by the tiebreak.
        let plan = arbiter(physicalGB: 24).evictionPlan(
            for: PluginResidency(pluginID: "new", declaredRamGB: 5.0), residents: [b, a])
        XCTAssertEqual(plan, ["aaa"], "ties must break on identifier so plans are reproducible")
    }

    func testMemoryProbeReportsAPlausibleMachine() {
        let status = MemoryProbe.system()
        XCTAssertGreaterThan(status.physicalGB, 0.5)
        XCTAssertGreaterThanOrEqual(status.availableGB, 0)
        XCTAssertLessThanOrEqual(status.availableGB, status.physicalGB + 0.001)
    }

    // MARK: - Session ledger

    func testSessionLedgerEvictsLeastRecentlyUsed() {
        var ledger = SessionLedger(limit: 2)
        XCTAssertTrue(ledger.touch("a").isEmpty)
        XCTAssertTrue(ledger.touch("b").isEmpty)
        XCTAssertEqual(ledger.touch("c"), ["a"])
        // Re-touching "b" makes "c" the oldest.
        XCTAssertTrue(ledger.touch("b").isEmpty)
        XCTAssertEqual(ledger.touch("d"), ["c"])
    }

    // MARK: - One-shot result parsing

    private func decode(_ json: String, relativeTo base: URL? = nil) throws -> PluginResult {
        try PluginPayloadCoder.decodeResult(
            Data(json.utf8), ref: Self.totalsegRef, relativeTo: base)
    }

    func testOneShotSuccessResultParsesAndResolvesRelativePaths() throws {
        let outputDirectory = URL(fileURLWithPath: "/tmp/run-1")
        let result = try decode("""
        { "ok": true,
          "outputs": { "seg3d": "segmentation.dcm",
                       "metrics": { "rv_lv_ratio": 1.12, "volume_ml": 340 } },
          "elapsed_ms": 154000 }
        """, relativeTo: outputDirectory)

        XCTAssertEqual(result.seg3dPath, "/tmp/run-1/segmentation.dcm")
        XCTAssertEqual(result.metrics["rv_lv_ratio"], 1.12)
        XCTAssertEqual(result.metrics["volume_ml"], 340)
        XCTAssertEqual(result.elapsedMS, 154000)
    }

    func testAbsoluteOutputPathIsLeftAlone() throws {
        let result = try decode("""
        { "ok": true, "outputs": { "seg3d": "/var/data/seg.dcm" } }
        """, relativeTo: URL(fileURLWithPath: "/tmp/run-1"))
        XCTAssertEqual(result.seg3dPath, "/var/data/seg.dcm")
    }

    func testTextAndBoundingBoxResultParses() throws {
        let result = try decode("""
        { "ok": true,
          "outputs": { "text": "No acute abnormality.",
                       "bbox": [{ "x": 0.1, "y": 0.2, "width": 0.3, "height": 0.2,
                                  "label": "opacity", "confidence": 0.85,
                                  "severity": "mild" }] },
          "elapsed_ms": 1840 }
        """)
        XCTAssertEqual(result.text, "No acute abnormality.")
        XCTAssertEqual(result.bboxes.count, 1)
        XCTAssertEqual(result.bboxes.first?.label, "opacity")
        XCTAssertEqual(result.bboxes.first?.severity, "mild")
    }

    func testMaskResultParsesAsASingleObjectOrAList() throws {
        let single = try decode("""
        { "ok": true, "outputs": { "mask2d": { "width": 2, "height": 2,
                                               "rle": [1, 2, 1], "label": "liver",
                                               "confidence": 0.9 } } }
        """)
        XCTAssertEqual(single.masks.count, 1)
        XCTAssertEqual(single.masks.first?.decodeMask(), [false, true, true, false])

        let many = try decode("""
        { "ok": true, "outputs": { "mask2d": [
            { "width": 2, "height": 2, "rle": [0, 4], "label": "a", "confidence": 0.5 },
            { "width": 2, "height": 2, "rle": [4], "label": "b", "confidence": 0.4 } ] } }
        """)
        XCTAssertEqual(many.masks.count, 2)
    }

    func testErrorResultBecomesAnAdapterError() throws {
        XCTAssertThrowsError(try decode("""
        { "ok": false, "error": { "code": "out_of_memory",
                                  "message": "Not enough memory to load the model.",
                                  "recoverable": true } }
        """)) { error in
            XCTAssertEqual(error as? PluginError,
                           .adapter(code: .outOfMemory,
                                    message: "Not enough memory to load the model."))
        }
    }

    func testLicenseRequiredSurfacesAsTheGateError() throws {
        XCTAssertThrowsError(try decode("""
        { "ok": false, "error": { "code": "license_required",
                                  "message": "An academic license number is required.",
                                  "recoverable": true } }
        """)) { error in
            guard case .licenseRequired(let ref, let message)? = error as? PluginError else {
                return XCTFail("license_required must route to the store's gate, got \(error)")
            }
            XCTAssertEqual(ref, Self.totalsegRef)
            XCTAssertEqual(message, "An academic license number is required.")
        }
    }

    func testNotReadyIsDistinctFromLicenseRequired() throws {
        XCTAssertThrowsError(try decode("""
        { "ok": false, "error": { "code": "not_ready", "message": "Weights are missing." } }
        """)) { error in
            XCTAssertEqual(error as? PluginError, .notReady("Weights are missing."))
        }
    }

    func testUnknownErrorCodeDegradesToInternalRatherThanFailingToParse() throws {
        XCTAssertThrowsError(try decode("""
        { "ok": false, "error": { "code": "teapot", "message": "Unexpected." } }
        """)) { error in
            XCTAssertEqual(error as? PluginError,
                           .adapter(code: .internalError, message: "Unexpected."))
        }
    }

    func testResultWithAnErrorButNoOkFlagIsStillAFailure() throws {
        XCTAssertThrowsError(try decode("""
        { "error": { "code": "internal", "message": "Crashed." } }
        """))
    }

    func testNonJSONResponseIsATransportError() {
        XCTAssertThrowsError(
            try PluginPayloadCoder.decodeResult(
                Data("Traceback (most recent call last):".utf8),
                ref: Self.totalsegRef, relativeTo: nil))
    }

    // MARK: - Protocol version enforcement

    func testHealthDecodesTheProtocolField() throws {
        let health = try JSONDecoder().decode(PluginHealth.self, from: Data("""
        { "status": "ready", "plugin_id": "gemma-4-e4b", "protocol": 1,
          "detail": "loaded", "memory_mb": 4512.0 }
        """.utf8))
        XCTAssertEqual(health.status, .ready)
        XCTAssertEqual(health.protocolVersion, kPluginProtocolVersion)
        XCTAssertEqual(health.memoryMB, 4512.0)
    }

    func testManifestDeclaringAnotherProtocolVersionIsRefused() throws {
        let url = temporaryRoot.appendingPathComponent("bad-manifest.json")
        try Data("""
        { "schema_version": 1, "protocol": 2, "plugins": [] }
        """.utf8).write(to: url)

        XCTAssertThrowsError(try PluginManifest.load(contentsOf: url)) { error in
            XCTAssertEqual(error as? PluginError,
                           .protocolMismatch(expected: kPluginProtocolVersion, found: 2))
        }
    }

    @MainActor
    func testRuntimeRefusesAManifestFromAnotherProtocolMajor() throws {
        let url = temporaryRoot.appendingPathComponent("v2-manifest.json")
        try Data("""
        { "schema_version": 1, "protocol": 2, "plugins": [] }
        """.utf8).write(to: url)

        let runtime = PluginRuntime(paths: makePaths())
        runtime.load(manifestURL: url)
        XCTAssertNotNil(runtime.loadError, "a v2 manifest must not be loaded by a v1 host")
        XCTAssertTrue(runtime.manifest.plugins.isEmpty)
    }

    // MARK: - Request construction

    func testTaskRequestBodyMatchesTheProtocolShape() throws {
        var invocation = PluginInvocation()
        invocation.sessionID = "s-01"
        invocation.text = "CT, chest"
        invocation.points = [PluginPoint(x: 0.5, y: 0.4, isForeground: true),
                             PluginPoint(x: 0.1, y: 0.2, isForeground: false)]
        invocation.roi = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        invocation.options = ["mode": .string("clinical"), "multimask": .bool(true)]

        let data = try PluginPayloadCoder.requestBody(invocation)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["session_id"] as? String, "s-01")
        let inputs = try XCTUnwrap(object["inputs"] as? [String: Any])
        XCTAssertEqual(inputs["text"] as? String, "CT, chest")
        let points = try XCTUnwrap(inputs["points"] as? [[String: Any]])
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0]["label"] as? Int, 1)
        XCTAssertEqual(points[1]["label"] as? Int, 0)
        let roi = try XCTUnwrap(inputs["roi"] as? [String: Double])
        XCTAssertEqual(roi["width"], 0.2)
        let options = try XCTUnwrap(object["options"] as? [String: Any])
        XCTAssertEqual(options["mode"] as? String, "clinical")
        XCTAssertEqual(options["multimask"] as? Bool, true)
        XCTAssertNil(inputs["slice2d"], "absent inputs must not appear in the body")
    }

    func testOneShotArgumentsFollowTheCLIContract() {
        var invocation = PluginInvocation()
        invocation.series3d = "/data/series-7"
        invocation.options = ["fast": .bool(true), "threshold": .number(0.5)]

        let arguments = PluginPayloadCoder.commandLineArguments(
            taskID: "total",
            outputDirectory: URL(fileURLWithPath: "/tmp/out"),
            invocation: invocation)

        XCTAssertEqual(Array(arguments.prefix(4)), ["--task", "total", "--out", "/tmp/out"])
        XCTAssertTrue(arguments.contains("--input-series3d"))
        XCTAssertTrue(arguments.contains("/data/series-7"))
        // Options are emitted in sorted key order so a spawn is reproducible.
        let fast = try? XCTUnwrap(arguments.firstIndex(of: "--opt-fast"))
        let threshold = try? XCTUnwrap(arguments.firstIndex(of: "--opt-threshold"))
        XCTAssertNotNil(fast)
        XCTAssertNotNil(threshold)
        if let fast, let threshold { XCTAssertLessThan(fast, threshold) }
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--opt-fast")! + 1], "true")
    }

    func testWeightInstallHookArgumentsAreComplete() throws {
        let weight = try JSONDecoder().decode(PluginWeight.self, from: Data("""
        { "id": "total-3mm", "source": "totalseg-task", "task": "total", "size_gb": 0.25 }
        """.utf8))
        let arguments = PluginInstallHook.arguments(
            for: weight, destination: URL(fileURLWithPath: "/tmp/weights/total-3mm"))
        XCTAssertEqual(arguments.first, PluginInstallHook.flag)
        XCTAssertTrue(arguments.contains("--source"))
        XCTAssertTrue(arguments.contains("totalseg-task"))
        XCTAssertTrue(arguments.contains("--task"))
        XCTAssertTrue(arguments.contains("--dest"))
        XCTAssertFalse(arguments.contains("--repo"), "an absent field must not become an empty flag")
    }

    // MARK: - Progress lines

    func testProgressLineParsingFollowsSectionFour() {
        let parsed = PluginProgressLine.parse(#"{"progress": 0.35, "message": "Running segmentation…"}"#)
        XCTAssertEqual(parsed?.progress, 0.35)
        XCTAssertEqual(parsed?.message, "Running segmentation…")

        // Anything that is not a progress object is a log line, not a result.
        XCTAssertNil(PluginProgressLine.parse("Loading weights from disk"))
        XCTAssertNil(PluginProgressLine.parse(#"{"ok": true, "outputs": {}}"#))
        XCTAssertNil(PluginProgressLine.parse(""))
    }

    func testLineAssemblerReassemblesSplitPipeReads() {
        let collected = LineCollector()
        let assembler = PluginProcessRunner.LineAssembler(sink: { collected.append($0) })
        assembler.consume(Data(#"{"progress": 0."#.utf8))
        assembler.consume(Data("5}\nnext line\r".utf8))
        assembler.consume(Data("trailing".utf8))
        assembler.flush()

        XCTAssertEqual(collected.lines,
                       [#"{"progress": 0.5}"#, "next line", "trailing"])
        XCTAssertEqual(PluginProgressLine.parse(collected.lines[0])?.progress, 0.5)
    }

    /// Replays a fixed sequence of port offers, standing in for the kernel.
    private final class ScriptedProbe: @unchecked Sendable {
        private let lock = NSLock()
        private let offers: [Int]
        private var index = 0

        init(_ offers: [Int]) { self.offers = offers }

        func next() -> Int? {
            lock.lock(); defer { lock.unlock() }
            guard index < offers.count else { return nil }
            defer { index += 1 }
            return offers[index]
        }
    }

    /// Thread-safe sink for the assembler, which calls back from arbitrary queues.
    private final class LineCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func append(_ line: String) {
            lock.lock(); storage.append(line); lock.unlock()
        }
        var lines: [String] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
    }

    // MARK: - Installer policy

    func testGatedDownloadIsUnsatisfiedUntilTheCheckpointIsPlaced() throws {
        let paths = makePaths()
        let manifest = try fixtureManifest()
        let plugin = try XCTUnwrap(manifest.plugin(id: "sam3"))
        let task = try XCTUnwrap(plugin.task(id: "prompt-mask"))
        let installer = PluginInstaller(
            locator: PluginEnvironmentLocator(adaptersRoot: temporaryRoot, paths: paths),
            store: PluginInstallStore(paths: paths))

        XCTAssertFalse(installer.licenseSatisfied(plugin: plugin, task: task, licenseKey: nil))

        let checkpoint = paths.manualWeightPath(pluginID: "sam3", weight: task.weights[0])
        try FileManager.default.createDirectory(
            at: checkpoint.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("checkpoint".utf8).write(to: checkpoint)

        XCTAssertTrue(installer.licenseSatisfied(plugin: plugin, task: task, licenseKey: nil))
        XCTAssertEqual(installer.presentWeights(plugin: plugin, task: task), ["sam3-checkpoint"])
    }

    func testLicenseKeyGateValidatesTheDeclaredPrefix() throws {
        let paths = makePaths()
        let json = """
        { "id": "heartchambers_highres", "label": "Heart Chambers", "summary": "Cardiac chambers.",
          "inputs": ["series3d"], "outputs": ["seg3d"],
          "license": { "gate": "license-key", "identifier": "Academic", "key_format": "aca_" },
          "weights": [ { "id": "heart", "source": "totalseg-task",
                         "task": "heartchambers_highres", "size_gb": 0.23 } ] }
        """
        let task = try JSONDecoder().decode(PluginTask.self, from: Data(json.utf8))
        let plugin = try XCTUnwrap(try fixtureManifest().plugin(id: "gemma-4-e4b"))
        let installer = PluginInstaller(
            locator: PluginEnvironmentLocator(adaptersRoot: temporaryRoot, paths: paths),
            store: PluginInstallStore(paths: paths))

        XCTAssertTrue(installer.licenseSatisfied(plugin: plugin, task: task, licenseKey: "aca_12345"))
        XCTAssertFalse(installer.licenseSatisfied(plugin: plugin, task: task, licenseKey: "12345"))
        XCTAssertFalse(installer.licenseSatisfied(plugin: plugin, task: task, licenseKey: "   "))
        XCTAssertFalse(installer.licenseSatisfied(plugin: plugin, task: task, licenseKey: nil),
                       "no key and no prior acknowledgement means the gate is unsatisfied")
    }

    func testOpenGateNeedsNoKey() throws {
        let paths = makePaths()
        let manifest = try fixtureManifest()
        let plugin = try XCTUnwrap(manifest.plugin(id: "gemma-4-e4b"))
        let task = try XCTUnwrap(plugin.task(id: "analyze"))
        let installer = PluginInstaller(
            locator: PluginEnvironmentLocator(adaptersRoot: temporaryRoot, paths: paths),
            store: PluginInstallStore(paths: paths))
        XCTAssertTrue(installer.licenseSatisfied(plugin: plugin, task: task, licenseKey: nil))
    }

    func testRemovalDeletesWeightsAndTheVenvWhenNothingElseNeedsThem() throws {
        let paths = makePaths()
        let manifest = try fixtureManifest()
        let plugin = try XCTUnwrap(manifest.plugin(id: "gemma-4-e4b"))
        let task = try XCTUnwrap(plugin.task(id: "analyze"))
        let store = PluginInstallStore(paths: paths)
        let installer = PluginInstaller(
            locator: PluginEnvironmentLocator(adaptersRoot: temporaryRoot, paths: paths),
            store: store)

        let weights = paths.weightDirectory(pluginID: plugin.id, weightID: "gemma-weights")
        let venvBin = paths.venvPython(plugin.id).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: venvBin, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: weights.appendingPathComponent("model.safetensors"))
        try Data("#!/bin/sh".utf8).write(to: paths.venvPython(plugin.id))

        XCTAssertGreaterThan(PluginDiskUsage.bytes(at: paths.pluginRoot(plugin.id)), 0)
        try store.update(Self.gemmaRef) {
            $0.installState = .ready
            $0.installedWeightIDs = ["gemma-weights"]
        }

        try installer.remove(plugin: plugin, task: task)

        XCTAssertFalse(FileManager.default.fileExists(atPath: weights.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.venv(plugin.id).path))
        XCTAssertNil(store.record(for: Self.gemmaRef))
    }

    func testRemovalKeepsTheVenvWhenASiblingTaskStillNeedsIt() throws {
        let paths = makePaths()
        let manifest = try fixtureManifest()
        let plugin = try XCTUnwrap(manifest.plugin(id: "gemma-4-e4b"))
        let task = try XCTUnwrap(plugin.task(id: "analyze"))
        let store = PluginInstallStore(paths: paths)
        let installer = PluginInstaller(
            locator: PluginEnvironmentLocator(adaptersRoot: temporaryRoot, paths: paths),
            store: store)

        try FileManager.default.createDirectory(
            at: paths.venvPython(plugin.id).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("#!/bin/sh".utf8).write(to: paths.venvPython(plugin.id))

        try store.setState(.ready, for: Self.gemmaRef)
        try store.update(PluginTaskRef(pluginID: plugin.id, taskID: "describe-roi")) {
            $0.installState = .ready
            $0.installedWeightIDs = ["gemma-weights"]
        }

        try installer.remove(plugin: plugin, task: task)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.venvPython(plugin.id).path),
                      "a sibling task still needs this environment")
    }

    // MARK: - Runtime wiring

    @MainActor
    func testRuntimeLoadsAManifestAndDefaultsEveryTaskToNotInstalled() throws {
        let url = temporaryRoot.appendingPathComponent("manifest.json")
        let encoder = JSONEncoder()
        try encoder.encode(fixtureManifest()).write(to: url)

        let runtime = PluginRuntime(paths: makePaths())
        runtime.load(manifestURL: url)

        XCTAssertNil(runtime.loadError)
        XCTAssertEqual(runtime.manifest.plugins.count, 2)
        XCTAssertEqual(runtime.installState(Self.gemmaRef), .notInstalled)
        XCTAssertEqual(runtime.runtimeState("gemma-4-e4b"), .stopped)
        XCTAssertTrue(runtime.residentSet().isEmpty, "nothing is running, so nothing is resident")
    }

    @MainActor
    func testRuntimeReportsTheManualCheckpointPathForAGatedPlugin() throws {
        let url = temporaryRoot.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(fixtureManifest()).write(to: url)

        let paths = makePaths()
        let runtime = PluginRuntime(paths: paths)
        runtime.load(manifestURL: url)

        let plugin = try XCTUnwrap(runtime.manifest.plugin(id: "sam3"))
        let weight = try XCTUnwrap(plugin.tasks.first?.weights.first)
        let shown = runtime.manualWeightPath(pluginID: plugin.id, weight: weight)

        XCTAssertTrue(shown.hasSuffix("sam3.pt"))
        XCTAssertTrue(shown.hasPrefix(paths.root.path))
    }

    @MainActor
    func testRuntimeRefusesToStartATaskThatIsNotInstalled() async throws {
        let url = temporaryRoot.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(fixtureManifest()).write(to: url)

        let runtime = PluginRuntime(paths: makePaths())
        runtime.load(manifestURL: url)

        do {
            // `start(_:)` is the store facade's non-throwing wrapper, which
            // routes failures into the log; the throwing spelling is the one
            // that reports refusal to a caller.
            try await runtime.startPlugin("gemma-4-e4b")
            XCTFail("starting an uninstalled plugin must throw")
        } catch let error as PluginError {
            guard case .notInstalled = error else {
                return XCTFail("expected notInstalled, got \(error)")
            }
        }
    }

    @MainActor
    func testRuntimeRefusesToInvokeATaskStillAtItsLicenseGate() async throws {
        let url = temporaryRoot.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(fixtureManifest()).write(to: url)

        let paths = makePaths()
        let runtime = PluginRuntime(paths: paths)
        let ref = PluginTaskRef(pluginID: "sam3", taskID: "prompt-mask")
        try runtime.store.setState(.resolvingLicense, for: ref)
        runtime.load(manifestURL: url)

        do {
            _ = try await runtime.invoke(ref, PluginInvocation())
            XCTFail("a gated task must not be invoked")
        } catch let error as PluginError {
            guard case .licenseRequired = error else {
                return XCTFail("expected licenseRequired, got \(error)")
            }
        }
    }

    @MainActor
    func testRuntimeUsesTheInjectedPortProbe() throws {
        let url = temporaryRoot.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(fixtureManifest()).write(to: url)

        let runtime = PluginRuntime(paths: makePaths(), portProbe: { 49999 })
        runtime.load(manifestURL: url)
        XCTAssertTrue(runtime.assignedPorts.isEmpty,
                      "ports are reserved at start, not at load")
    }
}
