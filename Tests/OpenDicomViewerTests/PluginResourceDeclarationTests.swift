// PluginResourceDeclarationTests.swift
// The arbiter admits work by comparing DECLARED memory against a budget, so a
// wrong or invisible declaration defeats the policy without the policy being
// wrong. Both failure modes were found by measurement rather than by reasoning:
//
//   - TotalSegmentator declared 3.5 GB and peaked at 20.9-23.2 GB across four
//     runs on two series. On a 16 GB machine the declaration admitted a job
//     needing more than the whole machine.
//   - A one-shot invocation never enters the runtime-state table, so residency
//     accounting could not see the heaviest process on the machine, and a
//     resident engine could start alongside it.

import XCTest
@testable import OpenDicomViewer

final class PluginResourceDeclarationTests: XCTestCase {

    private func manifest() throws -> PluginManifest {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(
                "Sources/OpenDicomViewer/Resources/plugins.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try PluginManifest.load(contentsOf: candidate)
            }
        }
        throw XCTSkip("plugins.json not found relative to test source")
    }

    // MARK: - Per-task declarations

    func testTaskRAMFallsBackToThePluginFigure() throws {
        let manifest = try manifest()
        let sam2 = try XCTUnwrap(manifest.plugin(id: "sam2"))
        // sam2 declares no per-task figure, so the plugin's applies.
        XCTAssertEqual(sam2.declaredRAMGB(forTask: "prompt-mask"), sam2.ramGB)
        // An unknown task also resolves to the plugin figure rather than trapping.
        XCTAssertEqual(sam2.declaredRAMGB(forTask: "no-such-task"), sam2.ramGB)
    }

    func testHeavyTaskCarriesItsOwnMeasuredDeclaration() throws {
        let manifest = try manifest()
        let totalseg = try XCTUnwrap(manifest.plugin(id: "totalsegmentator"))
        let total = totalseg.declaredRAMGB(forTask: "total")

        // The measured peak was 20.9-23.2 GB. The declaration must cover it:
        // under-declaring is the direction that admits an impossible job.
        XCTAssertGreaterThanOrEqual(
            total, 20.9,
            "the `total` task declares \(total) GB but was measured at up to 23.2 GB")
    }

    /// Every declaration must be positive and plausible; a zero or negative
    /// figure would make the arbiter admit anything.
    func testAllDeclarationsArePositive() throws {
        for plugin in try manifest().plugins {
            XCTAssertGreaterThan(plugin.ramGB, 0, "\(plugin.id) declares no RAM")
            for task in plugin.tasks {
                let declared = plugin.declaredRAMGB(forTask: task.id)
                XCTAssertGreaterThan(
                    declared, 0,
                    "\(plugin.id)/\(task.id) resolves to a non-positive declaration")
            }
        }
    }

    // MARK: - Arbitration against the corrected declaration

    /// The scenario the correction exists for: on a 16 GB machine the measured
    /// footprint must be refused, where the old 3.5 GB declaration was admitted.
    func testHeavySegmentationIsRefusedOnA16GBMachine() throws {
        let manifest = try manifest()
        let totalseg = try XCTUnwrap(manifest.plugin(id: "totalsegmentator"))
        let arbiter = ResourceArbiter(probe: { MemoryStatus(physicalGB: 16.0, availableGB: 12.0) })

        let decision = arbiter.admitOneShot(
            PluginResidency(pluginID: totalseg.id,
                            declaredRamGB: totalseg.declaredRAMGB(forTask: "total")),
            residents: [])
        XCTAssertNotNil(decision.refusalError,
                        "a 23 GB task must not be admitted on a 16 GB machine")
    }

    /// The same task on a machine that can hold it must be admitted, so the
    /// corrected declaration is not simply blocking everything.
    func testHeavySegmentationIsAdmittedOnALargeMachine() throws {
        let manifest = try manifest()
        let totalseg = try XCTUnwrap(manifest.plugin(id: "totalsegmentator"))
        let arbiter = ResourceArbiter(probe: { MemoryStatus(physicalGB: 128.0, availableGB: 100.0) })

        let decision = arbiter.admitOneShot(
            PluginResidency(pluginID: totalseg.id,
                            declaredRamGB: totalseg.declaredRAMGB(forTask: "total")),
            residents: [])
        XCTAssertNil(decision.refusalError,
                     "128 GB with 100 GB free must accommodate a 23 GB task")
    }

    /// A resident engine must not be admitted alongside a running one-shot when
    /// their combined declarations exceed the budget. Before the fix the
    /// one-shot was invisible and this admitted.
    func testResidentIsRefusedWhileAOneShotHoldsMemory() throws {
        let arbiter = ResourceArbiter(probe: { MemoryStatus(physicalGB: 16.0, availableGB: 12.0) })
        let runningOneShot = PluginResidency(pluginID: "totalsegmentator",
                                            declaredRamGB: 23.5,
                                            lastUsed: Date(),
                                            isEvictable: false)
        let decision = arbiter.admit(
            PluginResidency(pluginID: "gemma-4-e4b", declaredRamGB: 5.0),
            residents: [runningOneShot])

        XCTAssertNotNil(decision.refusalError,
                        "a one-shot holding 23.5 GB must block a 5 GB resident")
        XCTAssertTrue(decision.evictions.isEmpty,
                      "an in-flight one-shot must never be chosen for eviction")
    }
}
