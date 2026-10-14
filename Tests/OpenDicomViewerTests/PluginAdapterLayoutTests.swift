// PluginAdapterLayoutTests.swift
// The manifest names adapter directories, entry points, and requirements files
// by string. Nothing else checks that those strings correspond to files that
// exist, so a renamed adapter would fail at install time on a user's machine
// rather than here.

import XCTest
@testable import OpenDicomViewer

final class PluginAdapterLayoutTests: XCTestCase {

    private func repositoryRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            dir = dir.deletingLastPathComponent()
            if FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir
            }
        }
        throw XCTSkip("repository root not found relative to test source")
    }

    private func manifest() throws -> PluginManifest {
        try PluginManifest.load(contentsOf: try repositoryRoot()
            .appendingPathComponent("Sources/OpenDicomViewer/Resources/plugins.json"))
    }

    func testEveryDeclaredAdapterExistsOnDisk() throws {
        let root = try repositoryRoot()
        let locator = PluginEnvironmentLocator(
            adaptersRoot: root.appendingPathComponent("plugins", isDirectory: true),
            paths: .standard)

        for plugin in try manifest().plugins {
            let directory = locator.adapterDirectory(for: plugin)
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path),
                          "\(plugin.id): no adapter directory at \(directory.path)")

            let entry = locator.entryScript(for: plugin)
            XCTAssertTrue(FileManager.default.fileExists(atPath: entry.path),
                          "\(plugin.id): entry point missing at \(entry.path)")

            let requirements = locator.requirementsFile(for: plugin)
            XCTAssertTrue(FileManager.default.fileExists(atPath: requirements.path),
                          "\(plugin.id): requirements missing at \(requirements.path)")
        }
    }

    /// Invoke an adapter and return its combined output plus exit status.
    ///
    /// Behavior, not documentation: an adapter dispatches `--install-weights` to
    /// a separate parser before its main one, so that mode's flags never appear
    /// in `--help` even though they work. What matters to the host is whether a
    /// flag is accepted, which only running it establishes. Heavy imports are
    /// lazy, so nothing here loads a model.
    private func runAdapter(_ plugin: PluginDescriptor,
                            arguments: [String],
                            root: URL) throws -> (output: String, status: Int32) {
        let python = "/usr/bin/python3"
        guard FileManager.default.fileExists(atPath: python) else {
            throw XCTSkip("no system python to probe adapters with")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [plugin.entry] + arguments
        process.currentDirectoryURL = root
            .appendingPathComponent("plugins")
            .appendingPathComponent(plugin.adapterDir)
        var environment = ProcessInfo.processInfo.environment
        // The adapters import `_shared` as a package rooted at plugins/.
        environment["PYTHONPATH"] = root.appendingPathComponent("plugins").path
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus)
    }

    /// argparse reports an unrecognized flag with this phrasing and exit 2. Any
    /// other failure means the flag was accepted and the adapter got further.
    private func rejectedAsUnknown(_ result: (output: String, status: Int32)) -> Bool {
        result.status == 2 &&
            (result.output.contains("unrecognized arguments") ||
             result.output.contains("invalid choice"))
    }

    /// Resident and session adapters are launched with `--port`; one that did
    /// not accept it would start and then never be reachable.
    func testResidentAdaptersRequireAPortArgument() throws {
        let root = try repositoryRoot()
        for plugin in try manifest().plugins where plugin.execution.isResident {
            let help = try runAdapter(plugin, arguments: ["--help"], root: root)
            XCTAssertTrue(help.output.contains("--port"),
                          "\(plugin.id) is resident but does not offer --port:\n\(help.output)")

            // Required, not merely accepted: starting without one would leave
            // the host with no address to poll.
            let missing = try runAdapter(plugin, arguments: [], root: root)
            XCTAssertNotEqual(missing.status, 0,
                              "\(plugin.id) started without --port")
        }
    }

    /// Section 4b requires the weight-acquisition hook on every adapter,
    /// whatever its execution model.
    func testEveryAdapterAcceptsTheWeightHook() throws {
        let root = try repositoryRoot()
        for plugin in try manifest().plugins {
            let result = try runAdapter(
                plugin,
                arguments: ["--install-weights",
                            "--weight-id", "definitely-not-a-real-weight",
                            "--source", "huggingface",
                            "--dest", NSTemporaryDirectory()],
                root: root)
            // It must reject the unknown weight id on its merits, not reject the
            // flags as unparseable.
            XCTAssertFalse(rejectedAsUnknown(result),
                           "\(plugin.id) does not accept the section 4b hook:\n\(result.output)")
            XCTAssertNotEqual(result.status, 0,
                              "\(plugin.id) claimed success for an unknown weight id")
        }
    }

    /// One-shot adapters take the section 4 CLI, and must reject a missing
    /// series rather than treating the flag as unknown.
    func testOneShotAdaptersAcceptTheSectionFourCLI() throws {
        let root = try repositoryRoot()
        let absent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("odv-no-such-series-\(UUID().uuidString)")

        for plugin in try manifest().plugins where plugin.execution == .oneShot {
            let task = try XCTUnwrap(plugin.tasks.first).id
            let result = try runAdapter(
                plugin,
                arguments: ["--task", task,
                            "--out", NSTemporaryDirectory(),
                            "--input-series3d", absent.path],
                root: root)
            XCTAssertFalse(rejectedAsUnknown(result),
                           "\(plugin.id) does not accept the section 4 CLI:\n\(result.output)")
            XCTAssertNotEqual(result.status, 0,
                              "\(plugin.id) claimed success for a missing series")
        }
    }

    /// Every adapter's requirements file is a full lock: each non-comment line
    /// pins one package exactly, transitive ones included, so an install made
    /// months from now resolves to the set that was tested. A range (`>=`)
    /// slipping back in would let an upstream release change a plugin silently.
    func testEveryAdapterRequirementsFileIsAFullLock() throws {
        let root = try repositoryRoot()
        let locator = PluginEnvironmentLocator(
            adaptersRoot: root.appendingPathComponent("plugins", isDirectory: true),
            paths: .standard)

        for plugin in try manifest().plugins {
            let lines = try String(contentsOf: locator.requirementsFile(for: plugin), encoding: .utf8)
                .split(separator: "\n")
                .map { String($0).components(separatedBy: "#")[0] }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            XCTAssertGreaterThan(lines.count, 20,
                                 "\(plugin.id): the lock should include transitive packages")
            for line in lines {
                XCTAssertTrue(line.contains("==") && !line.contains(">") && !line.contains("<"),
                              "\(plugin.id): not pinned exactly: \(line)")
            }
        }
    }

    /// Hugging Face weights name a commit, so a re-upload to the repository
    /// cannot change what a fresh install downloads.
    func testEveryHuggingFaceWeightPinsARevision() throws {
        for plugin in try manifest().plugins {
            for task in plugin.tasks {
                for weight in task.weights where weight.repo != nil {
                    let revision = try XCTUnwrap(weight.revision,
                                                 "\(plugin.id)/\(weight.id) has no revision")
                    XCTAssertEqual(revision.count, 40,
                                   "\(plugin.id)/\(weight.id): revision is not a full commit SHA")
                }
            }
        }
    }
}
