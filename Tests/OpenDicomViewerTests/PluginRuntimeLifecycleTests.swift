// PluginRuntimeLifecycleTests.swift
// OpenDicomViewer
//
// Covers the runtime behaviour that only shows up end to end: one-shot
// admission not counting its own requester, cancellation reaching processes
// and health polls, concurrent starts sharing one process, partial downloads
// not passing for installed ones, and the prompt slice key following MPR and
// MIP navigation. The process tests spawn small shell scripts standing in for
// adapters; nothing loads a model or touches the network.
// Licensed under the MIT License. See LICENSE for details.

import XCTest
@testable import OpenDicomViewer

final class PluginRuntimeLifecycleTests: XCTestCase {

    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("odv-plugin-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot, FileManager.default.fileExists(atPath: temporaryRoot.path) {
            try FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    private var paths: PluginPaths {
        PluginPaths(root: temporaryRoot.appendingPathComponent("plugins", isDirectory: true))
    }

    private static let gemmaRef = PluginTaskRef(pluginID: "gemma-4-e4b", taskID: "analyze")
    private static let totalsegRef = PluginTaskRef(pluginID: "totalsegmentator", taskID: "total")

    /// A resident plugin and a one-shot one declaring TotalSegmentator's
    /// measured peak.
    private func writeManifest() throws -> URL {
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
                                 "repo": "mlx-community/gemma", "size_gb": 4.5 } ] }
              ]
            },
            {
              "id": "totalsegmentator", "name": "TotalSegmentator", "vendor": "USB",
              "summary": "CT segmentation.", "execution": "one-shot",
              "adapter_dir": "totalseg", "entry": "run_segment.py", "requirements": "requirements.txt",
              "ram_gb": 23.5, "disk_gb": 3.0, "requires_apple_silicon": false,
              "tasks": [
                { "id": "total", "label": "Total", "summary": "Whole body.",
                  "inputs": ["series3d"], "outputs": ["seg3d"],
                  "license": { "gate": "open", "identifier": "Apache-2.0" },
                  "weights": [ { "id": "Dataset297", "source": "totalseg-task",
                                 "task": "total", "size_gb": 0.25 } ],
                  "ram_gb": 23.5 }
              ]
            }
          ]
        }
        """
        let url = temporaryRoot.appendingPathComponent("manifest.json")
        try Data(json.utf8).write(to: url)
        return url
    }

    // MARK: - One-shot admission

    @MainActor
    func testOneShotAdmissionDoesNotCountTheRequesterTwice() throws {
        let runtime = PluginRuntime(paths: paths)
        runtime.load(manifestURL: try writeManifest())

        // `invoke` marks the requester busy before admission runs.
        runtime.beginInvocation(Self.totalsegRef, execution: .oneShot)
        defer { runtime.endInvocation(Self.totalsegRef) }

        XCTAssertEqual(runtime.residentSet().map(\.pluginID), ["totalsegmentator"],
                       "an in-flight one-shot is visible to admission of OTHER plugins")
        XCTAssertTrue(runtime.oneShotAdmissionResidents(for: "totalsegmentator").isEmpty,
                      "but not to its own admission")

        // 48 GiB: a 24 GiB budget holds one 23.5 GB job, not two.
        let arbiter = ResourceArbiter(probe: MemoryProbe.fixed(physicalGB: 48, availableGB: 40))
        let request = PluginResidency(pluginID: "totalsegmentator", declaredRamGB: 23.5)
        XCTAssertNotNil(arbiter.admitOneShot(request, residents: runtime.residentSet()).refusalError,
                        "the double-counted set is what refused every TotalSegmentator run")
        XCTAssertEqual(arbiter.admitOneShot(
            request, residents: runtime.oneShotAdmissionResidents(for: "totalsegmentator")), .admit)
    }

    @MainActor
    func testASecondConcurrentOneShotStillCountsTheFirst() throws {
        let runtime = PluginRuntime(paths: paths)
        runtime.load(manifestURL: try writeManifest())

        runtime.beginInvocation(Self.totalsegRef, execution: .oneShot)
        runtime.beginInvocation(Self.totalsegRef, execution: .oneShot)
        defer {
            runtime.endInvocation(Self.totalsegRef)
            runtime.endInvocation(Self.totalsegRef)
        }
        let residents = runtime.oneShotAdmissionResidents(for: "totalsegmentator")
        XCTAssertEqual(residents.map(\.pluginID), ["totalsegmentator"],
                       "the run already in flight holds its memory")
        XCTAssertEqual(residents.first?.isEvictable, false)
    }

    @MainActor
    func testBusyIsACountNotAFlag() throws {
        let runtime = PluginRuntime(paths: paths)
        runtime.load(manifestURL: try writeManifest())

        runtime.beginInvocation(Self.gemmaRef, execution: .residentServer)
        runtime.beginInvocation(Self.gemmaRef, execution: .residentServer)
        runtime.endInvocation(Self.gemmaRef)
        XCTAssertTrue(runtime.isBusy("gemma-4-e4b"),
                      "one finished invocation must not clear another still running")
        runtime.endInvocation(Self.gemmaRef)
        XCTAssertFalse(runtime.isBusy("gemma-4-e4b"))
        runtime.endInvocation(Self.gemmaRef)
        XCTAssertEqual(runtime.busyCount("gemma-4-e4b"), 0, "an unmatched end never goes negative")
    }

    // MARK: - One-shot budget

    func testTotalSegmentatorIsRunnableOnAThirtyTwoGigabyteMac() {
        let request = PluginResidency(pluginID: "totalsegmentator", declaredRamGB: 23.5)
        let idle = ResourceArbiter(probe: MemoryProbe.fixed(physicalGB: 32, availableGB: 27))
        XCTAssertEqual(idle.admitOneShot(request, residents: []), .admit)

        // Anything evictable makes way, as for any other admission.
        let gemma = PluginResidency(pluginID: "gemma-4-e4b", declaredRamGB: 5.0)
        let busyMachine = ResourceArbiter(probe: MemoryProbe.fixed(physicalGB: 32, availableGB: 22))
        XCTAssertEqual(busyMachine.admitOneShot(request, residents: [gemma]),
                       .evictThenAdmit(["gemma-4-e4b"]))

        // Live headroom still rules: a machine with little free is refused.
        let loaded = ResourceArbiter(probe: MemoryProbe.fixed(physicalGB: 32, availableGB: 12))
        XCTAssertNotNil(loaded.admitOneShot(request, residents: []).refusalError)

        // And the 16 GB machine is still refused outright.
        let small = ResourceArbiter(probe: MemoryProbe.fixed(physicalGB: 16, availableGB: 14))
        XCTAssertNotNil(small.admitOneShot(request, residents: []).refusalError)
    }

    func testTheLargerOneShotShareDoesNotLoosenResidentAdmission() {
        // A resident server is held to the shared half however large it is.
        let arbiter = ResourceArbiter(probe: MemoryProbe.fixed(physicalGB: 32, availableGB: 27))
        let big = PluginResidency(pluginID: "big", declaredRamGB: 20)
        XCTAssertNotNil(arbiter.admit(big, residents: []).refusalError)
    }

    // MARK: - Weight completion marker

    func testPartialDownloadIsNotInstalled() throws {
        let directory = temporaryRoot.appendingPathComponent("weights/w", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("config.json"))

        XCTAssertFalse(PluginInstaller.isCompleteDownload(at: directory),
                       "content without the marker is an interrupted download")

        try PluginInstaller.markDownloadComplete(at: directory)
        XCTAssertTrue(PluginInstaller.isCompleteDownload(at: directory))

        let staging = directory.appendingPathComponent(".cache/huggingface/download", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data().write(to: staging.appendingPathComponent("abc123.incomplete"))
        XCTAssertFalse(PluginInstaller.isCompleteDownload(at: directory),
                       "a leftover .incomplete file means a transfer did not finish")
        try FileManager.default.removeItem(at: staging.appendingPathComponent("abc123.incomplete"))
        XCTAssertTrue(PluginInstaller.isCompleteDownload(at: directory),
                      "the hub's own bookkeeping is ignored otherwise")

        PluginInstaller.clearDownloadMarker(at: directory)
        XCTAssertFalse(PluginInstaller.isCompleteDownload(at: directory))
    }

    func testMarkerAloneIsNotAModel() throws {
        let directory = temporaryRoot.appendingPathComponent("weights/empty", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try PluginInstaller.markDownloadComplete(at: directory)
        XCTAssertFalse(PluginInstaller.isCompleteDownload(at: directory))
    }

    func testPresentWeightsRequiresTheMarker() throws {
        let manifest = try PluginManifest.load(contentsOf: try writeManifest())
        let plugin = try XCTUnwrap(manifest.plugin(id: "gemma-4-e4b"))
        let task = try XCTUnwrap(plugin.task(id: "analyze"))
        let installer = PluginInstaller(
            locator: PluginEnvironmentLocator(adaptersRoot: temporaryRoot, paths: paths),
            store: PluginInstallStore(paths: paths))

        let directory = paths.weightDirectory(pluginID: plugin.id, weightID: "gemma-weights")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("shard".utf8).write(to: directory.appendingPathComponent("model.safetensors"))
        XCTAssertEqual(installer.presentWeights(plugin: plugin, task: task), [])

        try PluginInstaller.markDownloadComplete(at: directory)
        XCTAssertEqual(installer.presentWeights(plugin: plugin, task: task), ["gemma-weights"])
    }

    func testAdaptersAreToldWhereTheirWeightsAre() {
        let locator = PluginEnvironmentLocator(adaptersRoot: temporaryRoot, paths: paths)
        let environment = locator.processEnvironment(for: "sam2")
        XCTAssertEqual(environment[PluginHostEnvironment.weightsDirectory],
                       paths.weightsRoot("sam2").path)
        XCTAssertEqual(environment[PluginHostEnvironment.parentPID],
                       String(ProcessInfo.processInfo.processIdentifier))
        // The contract: weight <id> is at $ODV_WEIGHTS_DIR/<id>.
        XCTAssertEqual(
            URL(fileURLWithPath: environment[PluginHostEnvironment.weightsDirectory]!)
                .appendingPathComponent("sam2.1-hiera-small").path,
            paths.weightDirectory(pluginID: "sam2", weightID: "sam2.1-hiera-small").path)
    }

    // MARK: - Line assembly

    func testLineAssemblerKeepsAMultibyteCharacterSplitAcrossReads() {
        let collected = Collector()
        let assembler = PluginProcessRunner.LineAssembler(sink: { collected.append($0) })
        let bytes = Array("héllo — 완료\nnext\n".utf8)
        // Split inside the two-byte é and inside the three-byte 완.
        let cuts = [2, 11, bytes.count]
        var start = 0
        for cut in cuts {
            assembler.consume(Data(bytes[start..<cut]))
            start = cut
        }
        assembler.flush()
        XCTAssertEqual(collected.lines, ["héllo — 완료", "next"])
    }

    func testLineAssemblerDoesNotDropALineWithAnInvalidByte() {
        let collected = Collector()
        let assembler = PluginProcessRunner.LineAssembler(sink: { collected.append($0) })
        assembler.consume(Data([0x6F, 0x6B, 0xFF, 0x0A]))
        XCTAssertEqual(collected.lines.count, 1)
        XCTAssertTrue(collected.lines[0].hasPrefix("ok"))
    }

    // MARK: - Cancellation

    func testCancellingARunTerminatesTheChild() async throws {
        let started = Date()
        let task = Task {
            try await PluginProcessRunner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
                onStdoutLine: { _ in }, onStderrLine: { _ in })
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled run must throw")
        } catch is CancellationError {
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10,
                          "the child must be killed, not waited out")
    }

    func testCancellingBeforeLaunchNeverStartsTheChild() async throws {
        let marker = temporaryRoot.appendingPathComponent("ran")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PluginProcessRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/touch"), arguments: [marker.path],
                onStdoutLine: { _ in }, onStderrLine: { _ in })
        }
        do {
            _ = try await task.value
            XCTFail("a cancelled run must throw")
        } catch is CancellationError {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    /// A stand-in adapter that never answers /health, records each spawn,
    /// and takes a moment to exit on SIGTERM like a model mid-load.
    @MainActor
    private func makeHungRuntime(availableGB: Double = 48,
                                 crashWithCode exitCode: Int32? = nil) throws -> (PluginRuntime, spawns: URL) {
        let paths = self.paths
        let spawns = temporaryRoot.appendingPathComponent("spawns.log")
        let python = paths.venvPython("gemma-4-e4b")
        try FileManager.default.createDirectory(
            at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = exitCode.map { code in """
        #!/bin/sh
        echo spawned >> '\(spawns.path)'
        sleep 0.3
        exit \(code)
        """ } ?? """
        #!/bin/sh
        trap 'sleep 1; exit 0' TERM
        echo spawned >> '\(spawns.path)'
        while true; do sleep 0.2; done
        """
        try Data(script.utf8).write(to: python)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)

        let adapters = temporaryRoot.appendingPathComponent("adapters", isDirectory: true)
        let entry = adapters.appendingPathComponent("gemma/server.py")
        try FileManager.default.createDirectory(
            at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("# stand-in\n".utf8).write(to: entry)

        let runtime = PluginRuntime(
            paths: paths,
            locator: PluginEnvironmentLocator(adaptersRoot: adapters, paths: paths),
            arbiter: ResourceArbiter(probe: MemoryProbe.fixed(physicalGB: 64, availableGB: availableGB)),
            portProbe: { 1 })  // nothing listens on port 1: /health never answers
        runtime.load(manifestURL: try writeManifest())
        // After the load, whose re-verification would demote a record with no
        // weights on disk behind it.
        try runtime.store.setState(.ready, for: Self.gemmaRef)
        return (runtime, spawns)
    }

    @MainActor
    private func waitForState(_ runtime: PluginRuntime, _ state: PluginRuntimeState,
                              timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while runtime.runtimeState("gemma-4-e4b") != state && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(runtime.runtimeState("gemma-4-e4b"), state)
    }

    /// Wait until the stand-in has started and installed its TERM trap.
    private func waitForSpawn(_ spawns: URL, timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: spawns.path) && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: spawns.path), "the adapter never started")
    }

    /// `handleExit` clears the process entry as soon as the adapter dies, so
    /// a readiness loop that looked the process up there missed the exit and
    /// polled until its 300 s deadline, then reported a timeout.
    @MainActor
    func testAnAdapterThatDiesDuringStartupFailsPromptlyWithItsExitCode() async throws {
        let (runtime, _) = try makeHungRuntime(crashWithCode: 3)

        let started = Date()
        do {
            try await runtime.startPlugin("gemma-4-e4b")
            XCTFail("a start whose process exited must not report success")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("exited with code 3"),
                          error.localizedDescription)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
        guard case .error(let message) = runtime.runtimeState("gemma-4-e4b") else {
            return XCTFail("an adapter that crashed on startup is an error")
        }
        XCTAssertTrue(message.contains("exited with code 3"), message)
    }

    @MainActor
    func testStoppingAColdStartEndsThePollPromptlyAndIsNotAnError() async throws {
        let (runtime, spawns) = try makeHungRuntime()

        let started = Date()
        let start = Task { @MainActor in try await runtime.startPlugin("gemma-4-e4b") }
        try await waitForState(runtime, .starting)
        try await waitForSpawn(spawns)

        await runtime.stop("gemma-4-e4b")
        do {
            try await start.value
            XCTFail("a start that was stopped must not report success")
        } catch is CancellationError {
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 15,
                          "the health poll must end on cancellation, not at its deadline")
        XCTAssertEqual(runtime.runtimeState("gemma-4-e4b"), .stopped,
                       "a deliberate stop is not an error")
        XCTAssertFalse(runtime.log(for: "gemma-4-e4b").text.contains("Did not exit in time"),
                       "the adapter exits within the grace period and must be given it")
        XCTAssertEqual(try String(contentsOf: spawns).components(separatedBy: "\n")
                        .filter { !$0.isEmpty }.count, 1)
    }

    @MainActor
    func testStartAnywayOverridesALiveHeadroomRefusalOnce() async throws {
        // 64 GiB, but only 3 GiB free: the budget fits, the live reading does not.
        let (runtime, spawns) = try makeHungRuntime(availableGB: 3)

        do {
            try await runtime.startPlugin("gemma-4-e4b")
            XCTFail("a busy machine must refuse before the user agrees")
        } catch let error as PluginError {
            guard case .insufficientLiveMemory = error else {
                return XCTFail("expected an overridable refusal, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: spawns.path))

        runtime.allowLowMemoryStart("gemma-4-e4b")
        let start = Task { @MainActor in try await runtime.startPlugin("gemma-4-e4b") }
        try await waitForSpawn(spawns)
        await runtime.stop("gemma-4-e4b")
        do { try await start.value } catch is CancellationError {}

        // Consumed by that start: the next one is refused again.
        do {
            try await runtime.startPlugin("gemma-4-e4b")
            XCTFail("an override must not stay armed")
        } catch let error as PluginError {
            guard case .insufficientLiveMemory = error else { return XCTFail("\(error)") }
        }
    }

    @MainActor
    func testStartAnywayPromptIsOfferedOnlyForLiveHeadroom() throws {
        let runtime = PluginRuntime(paths: paths)
        runtime.load(manifestURL: try writeManifest())
        var asked = 0
        let saved = LowMemoryStartPrompt.ask
        LowMemoryStartPrompt.ask = { _, _ in asked += 1; return true }
        defer { LowMemoryStartPrompt.ask = saved }

        XCTAssertFalse(LowMemoryStartPrompt.offerOverride(
            for: PluginError.insufficientMemory(required: 40, available: 8),
            pluginID: "gemma-4-e4b", runtime: runtime),
            "a request over the physical budget is never a choice")
        XCTAssertEqual(asked, 0)
        XCTAssertTrue(LowMemoryStartPrompt.offerOverride(
            for: PluginError.insufficientLiveMemory(required: 5, available: 1),
            pluginID: "gemma-4-e4b", runtime: runtime))
        XCTAssertEqual(asked, 1)
    }

    @MainActor
    func testConcurrentStartsShareOneProcess() async throws {
        let (runtime, spawns) = try makeHungRuntime()

        let first = Task { @MainActor in try await runtime.startPlugin("gemma-4-e4b") }
        let second = Task { @MainActor in try await runtime.startPlugin("gemma-4-e4b") }
        try await waitForState(runtime, .starting)
        try await waitForSpawn(spawns)
        try await Task.sleep(nanoseconds: 500_000_000)

        let spawned = try String(contentsOf: spawns).components(separatedBy: "\n")
            .filter { !$0.isEmpty }.count
        XCTAssertEqual(spawned, 1, "two callers must not spawn two servers")

        await runtime.stop("gemma-4-e4b")
        for task in [first, second] {
            do { try await task.value } catch is CancellationError {}
        }
    }

    @MainActor
    func testTheGracePeriodSurvivesACancelledCaller() async throws {
        let (runtime, spawns) = try makeHungRuntime()

        _ = Task { @MainActor in try await runtime.startPlugin("gemma-4-e4b") }
        try await waitForState(runtime, .starting)
        try await waitForSpawn(spawns)

        // Stop from a task that is already cancelled, as an eviction reached
        // from a superseded prompt is.
        let stopper = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await runtime.stop("gemma-4-e4b")
        }
        await stopper.value

        XCTAssertFalse(runtime.log(for: "gemma-4-e4b").text.contains("Did not exit in time"),
                       "a cancelled caller must not turn SIGTERM into an immediate SIGKILL")
        XCTAssertEqual(runtime.runtimeState("gemma-4-e4b"), .stopped)
    }

    // MARK: - Prompt slice key

    func testSliceKeyFollowsMPRAndMIPNavigation() {
        func key(_ mode: PanelMode, image: Int = 10, mpr: Int = 50,
                 slab: Int = 30, thickness: Int = 10) -> String {
            PromptSliceKey.make(seriesIndex: 0, imageIndex: image, mode: mode,
                                mprSliceIndex: mpr, mipSlabPosition: slab,
                                mipSlabThickness: thickness)
        }

        // The panel mode and plane are part of the identity.
        let modes: [PanelMode] = [.slice2D, .mprSagittal, .mprCoronal, .mip]
        XCTAssertEqual(Set(modes.map { key($0) }).count, modes.count)

        // Scrolling an MPR panel moves mprSliceIndex, not imageIndex.
        XCTAssertNotEqual(key(.mprSagittal, mpr: 50), key(.mprSagittal, mpr: 51))
        XCTAssertNotEqual(key(.mprCoronal, mpr: 50), key(.mprCoronal, mpr: 51))
        // Scrolling a MIP panel moves the slab; resizing it changes the pixels.
        XCTAssertNotEqual(key(.mip, slab: 30), key(.mip, slab: 31))
        XCTAssertNotEqual(key(.mip, thickness: 10), key(.mip, thickness: 20))
        // Axial still follows the image index.
        XCTAssertNotEqual(key(.slice2D, image: 10), key(.slice2D, image: 11))

        // State that does not change the displayed slice leaves the key alone,
        // so an open session is not thrown away for nothing.
        XCTAssertEqual(key(.slice2D, mpr: 1), key(.slice2D, mpr: 2))
        XCTAssertEqual(key(.mprSagittal, image: 1), key(.mprSagittal, image: 2))
    }

    func testSliceKeyReadsThePanel() {
        let panel = PanelState()
        panel.seriesIndex = 2
        panel.imageIndex = 7
        let axial = PromptSliceKey.make(for: panel)
        panel.panelMode = .mprCoronal
        panel.mprSliceIndex = 40
        let coronal = PromptSliceKey.make(for: panel)
        XCTAssertNotEqual(axial, coronal)
        panel.mprSliceIndex = 41
        XCTAssertNotEqual(coronal, PromptSliceKey.make(for: panel))
    }

    // MARK: - Series staging

    func testStagingPresentsExactlyTheSelectedFiles() throws {
        let a = temporaryRoot.appendingPathComponent("a", isDirectory: true)
        let b = temporaryRoot.appendingPathComponent("b", isDirectory: true)
        for directory in [a, b] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // Same file name in two folders, plus an unrelated series file that
        // shares a folder with the selection and must not be staged.
        let files = [a.appendingPathComponent("IM0001"), b.appendingPathComponent("IM0001")]
        for file in files { try Data("dicom".utf8).write(to: file) }
        try Data("other series".utf8).write(to: a.appendingPathComponent("OTHER"))

        let staged = try PluginSeriesStaging.stage(files, under: temporaryRoot)
        let contents = try FileManager.default.contentsOfDirectory(atPath: staged.path)
        XCTAssertEqual(contents.count, 2)
        for name in contents {
            let link = staged.appendingPathComponent(name)
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
            XCTAssertTrue(files.map(\.path).contains(target))
        }

        PluginSeriesStaging.discard(staged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertTrue(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
                      "discarding the staging must not touch the sources")
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func append(_ line: String) { lock.lock(); storage.append(line); lock.unlock() }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    }
}
