// PluginProcessGroupTests.swift
// OpenDicomViewer
//
// Cancel and quit must reach a child's own children (pip's build
// subprocesses, a downloader's helpers), not just the child.
// Licensed under the MIT License. See LICENSE for details.

import XCTest
@testable import OpenDicomViewer

final class PluginProcessGroupTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("odv-pgroup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private func waitForPID(in file: URL, timeout: TimeInterval = 5) async throws -> pid_t {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? String(contentsOf: file, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw XCTSkip("the child never reported its own child")
    }

    /// The premise everything else rests on: Foundation spawns the child as
    /// the leader of a new process group, not in the app's.
    func testProcessSpawnsItsChildInANewGroup() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        let pid = process.processIdentifier
        XCTAssertEqual(getpgid(pid), pid)
        XCTAssertNotEqual(getpgid(pid), getpgrp())
        XCTAssertEqual(ProcessGroup.led(by: pid), pid)
        XCTAssertNil(ProcessGroup.led(by: getpid()), "the app's own group is never a target")
    }

    func testCancellingARunKillsTheGrandchild() async throws {
        let pidFile = root.appendingPathComponent("grandchild.pid")
        // The child ignores nothing; its background child would survive a
        // signal sent to the child's pid alone.
        let script = "sleep 60 & echo $! > '\(pidFile.path)'; wait"
        let task = Task {
            try await PluginProcessRunner.run(
                executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                onStdoutLine: { _ in }, onStderrLine: { _ in })
        }
        let grandchild = try await waitForPID(in: pidFile)
        XCTAssertTrue(isAlive(grandchild))

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled run must throw")
        } catch is CancellationError {}

        let deadline = Date().addingTimeInterval(8)
        while isAlive(grandchild) && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(isAlive(grandchild), "pip's own children must not outlive Cancel")
    }

    func testQuitKillsAnInstallInProgressAndItsChildren() async throws {
        let pidFile = root.appendingPathComponent("grandchild.pid")
        // The child traps TERM and keeps waiting, like a process mid-write.
        let script = "trap '' TERM; sleep 60 & echo $! > '\(pidFile.path)'; wait; wait"
        let task = Task {
            try await PluginProcessRunner.run(
                executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                onStdoutLine: { _ in }, onStderrLine: { _ in })
        }
        let grandchild = try await waitForPID(in: pidFile)

        PluginProcessRunner.ProcessControl.terminateAllForQuit(grace: 0.5)
        _ = try? await task.value

        let deadline = Date().addingTimeInterval(5)
        while isAlive(grandchild) && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(isAlive(grandchild))
    }
}
