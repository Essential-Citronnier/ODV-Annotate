// LocalAISetupTests.swift
// OpenDicomViewer
//
// The new-user path to local Gemma: venv validity after the app moves, the
// system proxy handed to Python, disk requirements, failure hints, download
// progress from /health, engine routing, request serialization, and the pins
// that must agree between the built-in server and the Gemma plugin.
// Licensed under the MIT License. See LICENSE for details.

import XCTest
@testable import OpenDicomViewer

final class LocalAISetupTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("odv-localai-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    // MARK: - Venv validity

    func testPyvenvConfigParsing() {
        let config = PythonVenvCheck.parseConfig("""
            home = /Applications/ODV.app/Contents/Resources/python/bin
            include-system-site-packages = false
            version = 3.11.11
            executable = /Applications/ODV.app/Contents/Resources/python/bin/python3.11
            """)
        XCTAssertEqual(config["home"], "/Applications/ODV.app/Contents/Resources/python/bin")
        XCTAssertEqual(config["version"], "3.11.11")
        XCTAssertEqual(config["include-system-site-packages"], "false")
    }

    func testVenvMadeFromAnotherAppLocationDoesNotMatch() {
        let fromDMG = ["home": "/Volumes/ODV/ODV.app/Contents/Resources/python/bin",
                       "version": "3.11.11"]
        let installed = "/Applications/ODV.app/Contents/Resources/python/bin"
        XCTAssertFalse(PythonVenvCheck.configMatches(fromDMG, expectedHome: installed,
                                                     expectedMajorMinor: "3.11"))
        let here = ["home": installed, "version": "3.11.11"]
        XCTAssertTrue(PythonVenvCheck.configMatches(here, expectedHome: installed,
                                                    expectedMajorMinor: "3.11"))
        XCTAssertFalse(PythonVenvCheck.configMatches(here, expectedHome: installed,
                                                     expectedMajorMinor: "3.13"))
        // virtualenv spells it version_info.
        XCTAssertTrue(PythonVenvCheck.configMatches(
            ["home": installed, "version_info": "3.11.11.final.0"],
            expectedHome: installed, expectedMajorMinor: "3.11"))
        XCTAssertFalse(PythonVenvCheck.configMatches([:], expectedHome: installed,
                                                     expectedMajorMinor: nil))
    }

    /// The loop this fixes: a venv whose interpreter link dangles because the
    /// app it was made from (DMG, App Translocation) is gone.
    func testVenvWithDanglingInterpreterLinkIsNotUsable() throws {
        let python = try makeFakePythonLayout(named: "current", version: "3.11")
        let venv = scratch.appendingPathComponent("venv")
        try FileManager.default.createDirectory(at: venv.appendingPathComponent("bin"),
                                                withIntermediateDirectories: true)
        try "home = \(python.deletingLastPathComponent().path)\nversion = 3.11.9\n"
            .write(to: venv.appendingPathComponent("pyvenv.cfg"), atomically: true, encoding: .utf8)

        let link = venv.appendingPathComponent("bin/python3")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: scratch.appendingPathComponent("gone/bin/python3"))
        XCTAssertFalse(PythonVenvCheck.isUsable(venv: venv, python: python.path))

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: python)
        XCTAssertTrue(PythonVenvCheck.isUsable(venv: venv, python: python.path))
        XCTAssertEqual(PythonVenvCheck.majorMinorVersion(ofPythonAt: python.path), "3.11")

        // Same layout, different (moved) interpreter: rebuild.
        let moved = try makeFakePythonLayout(named: "moved", version: "3.11")
        XCTAssertFalse(PythonVenvCheck.isUsable(venv: venv, python: moved.path))
        // Development builds pass no bundled interpreter; only the link counts.
        XCTAssertTrue(PythonVenvCheck.isUsable(venv: venv, python: nil))
    }

    /// `<root>/<name>/bin/python3` plus `lib/pythonX.Y`, like the bundled runtime.
    private func makeFakePythonLayout(named name: String, version: String) throws -> URL {
        let root = scratch.appendingPathComponent(name)
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("lib/python\(version)"), withIntermediateDirectories: true)
        let python = bin.appendingPathComponent("python3")
        try Data().write(to: python)
        return python
    }

    // MARK: - System proxy

    func testSystemProxyBecomesPythonVariables() {
        let settings: [String: Any] = [
            "HTTPSEnable": NSNumber(value: 1), "HTTPSProxy": "proxy.corp", "HTTPSPort": NSNumber(value: 8443),
            "HTTPEnable": NSNumber(value: 1), "HTTPProxy": "proxy.corp", "HTTPPort": NSNumber(value: 8080),
            "ExceptionsList": ["*.local", "169.254/16"],
        ]
        let vars = SystemProxyEnvironment.variables(from: settings)
        XCTAssertEqual(vars["HTTPS_PROXY"], "http://proxy.corp:8443")
        XCTAssertEqual(vars["https_proxy"], "http://proxy.corp:8443")
        XCTAssertEqual(vars["HTTP_PROXY"], "http://proxy.corp:8080")
        let noProxy = vars["NO_PROXY"] ?? ""
        XCTAssertTrue(noProxy.contains("127.0.0.1"))
        XCTAssertTrue(noProxy.contains("localhost"))
        XCTAssertTrue(noProxy.contains(".local"))
    }

    func testHTTPOnlyProxyAlsoServesHTTPS() {
        let vars = SystemProxyEnvironment.variables(from: [
            "HTTPEnable": NSNumber(value: 1), "HTTPProxy": "10.0.0.1", "HTTPPort": NSNumber(value: 3128),
        ])
        XCTAssertEqual(vars["HTTPS_PROXY"], "http://10.0.0.1:3128")
    }

    func testDisabledProxyAndExplicitEnvironmentAreLeftAlone() {
        XCTAssertTrue(SystemProxyEnvironment.variables(from: [
            "HTTPSEnable": NSNumber(value: 0), "HTTPSProxy": "proxy.corp",
        ]).isEmpty)
        let settings: [String: Any] = [
            "HTTPSEnable": NSNumber(value: 1), "HTTPSProxy": "proxy.corp", "HTTPSPort": NSNumber(value: 1),
        ]
        let explicit = SystemProxyEnvironment.applying(to: ["HTTPS_PROXY": "http://mine:1"],
                                                       settings: settings)
        XCTAssertEqual(explicit["HTTPS_PROXY"], "http://mine:1")
        XCTAssertNil(explicit["NO_PROXY"])
        let applied = SystemProxyEnvironment.applying(to: ["PATH": "/bin"], settings: settings)
        XCTAssertEqual(applied["HTTPS_PROXY"], "http://proxy.corp:1")
        XCTAssertEqual(applied["PATH"], "/bin")
    }

    // MARK: - Disk and failure messages

    func testFirstRunNeedsAboutEightGigabytes() {
        XCTAssertGreaterThanOrEqual(AIServerManager.requiredSetupBytes(modelCached: false), 8_000_000_000)
        XCTAssertLessThan(AIServerManager.requiredSetupBytes(modelCached: true), 8_000_000_000)
        XCTAssertNil(LocalAIDiskSpace.shortfallMessage(requiredBytes: 10, availableBytes: 20, what: "x"))
        XCTAssertNil(LocalAIDiskSpace.shortfallMessage(requiredBytes: 10, availableBytes: nil, what: "x"))
        let message = LocalAIDiskSpace.shortfallMessage(
            requiredBytes: 8_000_000_000, availableBytes: 3_000_000_000, what: "the AI model")
        XCTAssertEqual(message?.contains("3.0 GB available"), true)
        XCTAssertEqual(message?.contains("8.0 GB needed"), true)
    }

    func testSetupFailureHintReadsTheLog() {
        XCTAssertTrue(AIServerManager.setupFailureHint(
            log: "ERROR: Could not install packages due to an OSError: [Errno 28] No space left on device")
            .contains("disk"))
        XCTAssertTrue(AIServerManager.setupFailureHint(
            log: "ProxyError('Cannot connect to proxy.')").contains("proxy"))
        XCTAssertTrue(AIServerManager.setupFailureHint(
            log: "WARNING: Retrying ... Max retries exceeded with url: /simple/mlx/").contains("internet"))
        // Not every failure is the network's fault.
        XCTAssertEqual(AIServerManager.setupFailureHint(log: "error: subprocess-exited-with-error"),
                       "See the log below for the cause.")
    }

    // MARK: - Download progress

    func testHealthDownloadProgressDecodes() throws {
        let json = """
            {"status":"loading","model":"m","revision":"r","pid":1,"phase":"downloading",
             "download_bytes":1300000000,"download_total_bytes":5200000000}
            """
        let health = try JSONDecoder().decode(AIHealthResponse.self, from: Data(json.utf8))
        let progress = try XCTUnwrap(AIModelLoadProgress(health: health))
        XCTAssertEqual(progress.phase, .downloading)
        XCTAssertEqual(try XCTUnwrap(progress.fraction), 0.25, accuracy: 1e-9)
        XCTAssertEqual(progress.bytesText, "1.3 of 5.2 GB")

        let older = try JSONDecoder().decode(AIHealthResponse.self, from: Data(
            #"{"status":"loading","model":"m","revision":"r","pid":1}"#.utf8))
        XCTAssertEqual(AIModelLoadProgress(health: older)?.phase, .starting)
        XCTAssertNil(AIModelLoadProgress(health: older)?.fraction)

        let ready = try JSONDecoder().decode(AIHealthResponse.self, from: Data(
            #"{"status":"ready","model":"m","revision":"r","pid":1}"#.utf8))
        XCTAssertNil(AIModelLoadProgress(health: ready))
    }

    func testSnapshotDetectionFollowsTheHubCache() throws {
        let environment = ["HF_HUB_CACHE": scratch.path]
        let repo = "org/model", revision = "abc"
        XCTAssertFalse(HuggingFaceCache.snapshotExists(repo: repo, revision: revision,
                                                       environment: environment))
        let snapshot = scratch.appendingPathComponent("models--org--model/snapshots/abc")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: snapshot.appendingPathComponent("config.json"))
        XCTAssertFalse(HuggingFaceCache.snapshotExists(repo: repo, revision: revision,
                                                       environment: environment),
                       "config alone, without weights, is an interrupted download")
        try Data("w".utf8).write(to: snapshot.appendingPathComponent("model.safetensors"))
        XCTAssertTrue(HuggingFaceCache.snapshotExists(repo: repo, revision: revision,
                                                      environment: environment))
        XCTAssertEqual(HuggingFaceCache.hubDirectory(environment: ["HF_HOME": "/x/hf"]).path, "/x/hf/hub")
    }

    // MARK: - Engine routing

    func testEngineResolution() {
        // No choice yet: the plugin only when it is installed and built-in is not set up.
        XCTAssertEqual(AIAnalysisEngine.resolve(preference: nil, pluginInstalled: false, builtInSetUp: false), .builtIn)
        XCTAssertEqual(AIAnalysisEngine.resolve(preference: nil, pluginInstalled: true, builtInSetUp: false), .gemmaPlugin)
        XCTAssertEqual(AIAnalysisEngine.resolve(preference: nil, pluginInstalled: true, builtInSetUp: true), .builtIn)
        // An explicit choice wins, unless it names a plugin that is not installed.
        XCTAssertEqual(AIAnalysisEngine.resolve(preference: .gemmaPlugin, pluginInstalled: true, builtInSetUp: true), .gemmaPlugin)
        XCTAssertEqual(AIAnalysisEngine.resolve(preference: .gemmaPlugin, pluginInstalled: false, builtInSetUp: true), .builtIn)
        XCTAssertEqual(AIAnalysisEngine.resolve(preference: .builtIn, pluginInstalled: true, builtInSetUp: false), .builtIn)
    }

    func testPluginResultsAreDroppedWhenTheStudyChanged() {
        XCTAssertTrue(DICOMModel.sameStudy(seriesIndex: 1, seriesID: "b", in: ["a", "b"]))
        XCTAssertFalse(DICOMModel.sameStudy(seriesIndex: 1, seriesID: "b", in: ["a", "c"]))
        XCTAssertFalse(DICOMModel.sameStudy(seriesIndex: 2, seriesID: "b", in: ["a", "b"]))
        XCTAssertFalse(DICOMModel.sameStudy(seriesIndex: 0, seriesID: nil, in: ["a"]))
    }

    @MainActor
    func testPluginBoxesAreSanitizedSliceBoundAndReplacePreviousResults() throws {
        let model = DICOMModel()
        let panel = PanelState()
        let task = try JSONDecoder().decode(PluginTask.self, from: Data("""
            {"id":"detect","label":"Detect","summary":"","inputs":["slice2d"],
             "outputs":["bbox","text"],"license":{"gate":"open","identifier":"MIT"},"weights":[]}
            """.utf8))
        let slice = AnnotationSlice(seriesIndex: 0, panelMode: .slice2D, index: 3, frame: 0, slab: 0)
        let first = PluginResult(text: "two findings", bboxes: [
            PluginBoundingBox(x: 0.1, y: 0.1, width: 0.2, height: 0.2, label: "a",
                              confidence: 0.9, severity: "Severe"),
            PluginBoundingBox(x: 0.5, y: 0.5, width: 0, height: 0.3, label: "degenerate",
                              confidence: 0.5, severity: nil),
            PluginBoundingBox(x: 0.9, y: 0.9, width: 0.5, height: 0.5, label: "clamped",
                              confidence: 7, severity: nil),
        ])
        model.apply(first, from: task, to: panel, slice: slice)

        XCTAssertEqual(panel.annotations.count, 2, "the degenerate box is dropped")
        XCTAssertTrue(panel.annotations.allSatisfy { $0.isAI && $0.slice == slice })
        XCTAssertEqual(panel.aiDescription, "two findings")
        XCTAssertEqual(panel.aiDescriptionSlice, slice)
        for annotation in panel.annotations {
            switch annotation.type {
            case .aiFinding(let rect, _, let severity):
                XCTAssertEqual(severity, "severe")
                XCTAssertEqual(rect.width, 0.2, accuracy: 1e-9)
            case .aiStructure(let rect, _, let confidence):
                XCTAssertLessThanOrEqual(rect.maxX, 1.0)
                XCTAssertEqual(confidence, 1.0)
            default:
                XCTFail("unexpected \(annotation.type)")
            }
        }

        // A measurement on the slice and a result on another slice survive.
        panel.annotations.append(Annotation(type: .aiStructure(rect: CGRect(x: 0, y: 0, width: 0.1, height: 0.1),
                                                               label: "other slice", confidence: 1),
                                            isAI: true,
                                            slice: AnnotationSlice(seriesIndex: 0, panelMode: .slice2D,
                                                                   index: 4, frame: 0, slab: 0)))
        let second = PluginResult(text: "one", bboxes: [
            PluginBoundingBox(x: 0.3, y: 0.3, width: 0.1, height: 0.1, label: "b",
                              confidence: 0.4, severity: nil),
        ])
        model.apply(second, from: task, to: panel, slice: slice)
        let onSlice = panel.annotations.filter { $0.slice == slice }
        XCTAssertEqual(onSlice.count, 1, "a new run replaces, not appends")
        XCTAssertEqual(panel.annotations.count, 2)
    }

    // MARK: - Request serialization

    func testRequestQueueRunsOneAtATime() async {
        let queue = AIRequestQueue()
        actor Log { var events: [String] = []; func add(_ e: String) { events.append(e) } }
        let log = Log()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<3 {
                group.addTask {
                    await queue.acquire()
                    await log.add("start\(index)")
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    await log.add("end\(index)")
                    await queue.release()
                }
            }
        }
        let events = await log.events
        XCTAssertEqual(events.count, 6)
        for pair in stride(from: 0, to: events.count, by: 2) {
            XCTAssertEqual(events[pair].dropFirst(5), events[pair + 1].dropFirst(3),
                           "requests overlapped: \(events)")
        }
    }

    // MARK: - Pins that must agree

    func testModelRevisionIsPinnedIdenticallyEverywhere() throws {
        let revision = AIServerManager.modelRevision
        XCTAssertEqual(revision.count, 40)
        let server = try String(contentsOf: repoRoot.appendingPathComponent("mlx-server/server.py"),
                                encoding: .utf8)
        XCTAssertTrue(server.contains("\"\(revision)\""))
        XCTAssertTrue(server.contains("MODEL_ID = \"\(AIServerManager.modelRepo)\""))
        let plugin = try String(contentsOf: repoRoot.appendingPathComponent("plugins/gemma/server.py"),
                                encoding: .utf8)
        XCTAssertTrue(plugin.contains("MODEL_REVISION = \"\(revision)\""))

        let manifest = try PluginManifest.load(contentsOf: repoRoot
            .appendingPathComponent("Sources/OpenDicomViewer/Resources/plugins.json"))
        let gemma = try XCTUnwrap(manifest.plugin(id: AIAnalysisEngine.pluginID))
        for task in gemma.tasks {
            for weight in task.weights where weight.repo == AIServerManager.modelRepo {
                XCTAssertEqual(weight.revision, revision, "\(task.id) does not pin the revision")
                XCTAssertTrue(PluginInstallHook.arguments(for: weight, destination: scratch)
                    .contains(revision))
            }
        }
    }

    func testGemmaPluginAndBuiltInServerPinTheSamePackages() throws {
        func pins(_ path: String) throws -> [String] {
            try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
                .split(separator: "\n")
                .map { String($0).components(separatedBy: "#")[0] }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        let server = try pins("mlx-server/requirements.txt")
        let plugin = try pins("plugins/gemma/requirements.txt")
        XCTAssertEqual(server, plugin)
        XCTAssertGreaterThan(server.count, 30, "the lock should include transitive packages")
        for line in server {
            XCTAssertTrue(line.contains("=="), "not pinned exactly: \(line)")
        }
        for package in ["mlx==0.32.0", "mlx-vlm==0.6.4", "transformers==5.12.1", "huggingface-hub==1.31.0"] {
            XCTAssertTrue(server.contains(package), "\(package) missing")
        }
    }
}
