// ResourceArbiterOverrideTests.swift
// OpenDicomViewer
//
// The split between refusals the user may overrule ("Start anyway") and those
// they may not, and the live-memory estimate that feeds the headroom term.
// Licensed under the MIT License. See LICENSE for details.

import XCTest
@testable import OpenDicomViewer

final class ResourceArbiterOverrideTests: XCTestCase {

    private let gemma = PluginResidency(pluginID: "gemma-4-e4b", declaredRamGB: 5.0)

    func testLiveHeadroomRefusalIsOverridable() {
        let starved = ResourceArbiter(probe: MemoryProbe.fixed(physicalGB: 64, availableGB: 3))
        let decision = starved.admit(gemma, residents: [])
        XCTAssertFalse(decision.isAdmitted)
        XCTAssertTrue(decision.isOverridable)
        XCTAssertEqual(decision.overridden, .admit)
        guard case .insufficientLiveMemory(let required, _)? = decision.refusalError else {
            return XCTFail("expected an overridable error, got \(String(describing: decision.refusalError))")
        }
        XCTAssertEqual(required, 5.0)
    }

    func testRequestOverThePhysicalBudgetIsNeverOverridable() {
        // 12 GB against an 8 GiB budget: no amount of free memory makes it fit.
        let idle = ResourceArbiter(probe: MemoryProbe.fixed(physicalGB: 16, availableGB: 15))
        let huge = PluginResidency(pluginID: "enormous", declaredRamGB: 12)
        let decision = idle.admit(huge, residents: [])
        XCTAssertFalse(decision.isOverridable)
        XCTAssertEqual(decision.overridden, decision, "a budget refusal survives an override")
        guard case .insufficientMemory? = decision.refusalError else {
            return XCTFail("expected a final refusal")
        }

        // Also when the machine is starved: the budget term wins.
        let starved = ResourceArbiter(probe: MemoryProbe.fixed(physicalGB: 16, availableGB: 1))
        XCTAssertFalse(starved.admit(huge, residents: []).isOverridable)
        // A one-shot is budgeted against the larger one-shot share (12 GiB of
        // 16), so it is overridable up to that and final beyond it.
        XCTAssertTrue(starved.admitOneShot(huge, residents: []).isOverridable)
        let hugerJob = PluginResidency(pluginID: "enormous", declaredRamGB: 13)
        XCTAssertFalse(starved.admitOneShot(hugerJob, residents: []).isOverridable)
    }

    func testBusyResidentHoldingTheBudgetIsNotOverridable() {
        let busy = PluginResidency(pluginID: "gemma-4-e4b", declaredRamGB: 5.0, isEvictable: false)
        let request = PluginResidency(pluginID: "sam3", declaredRamGB: 6.0)
        let decision = ResourceArbiter(probe: MemoryProbe.fixed(physicalGB: 16, availableGB: 1))
            .admit(request, residents: [busy])
        XCTAssertFalse(decision.isOverridable, "5 + 6 GB cannot share an 8 GiB budget")
    }

    func testOverrideKeepsOnlyTheEvictionsTheBudgetNeeds() {
        let old = PluginResidency(pluginID: "sam2", declaredRamGB: 3.0,
                                  lastUsed: Date().addingTimeInterval(-600))
        let new = PluginResidency(pluginID: "medsam", declaredRamGB: 3.0, lastUsed: Date())

        // 32 GiB, 16 GiB budget: 3 + 3 + 8 fits, so nothing needs to go for
        // the budget; only the live reading is short.
        let request = PluginResidency(pluginID: "big", declaredRamGB: 8.0)
        let roomy = ResourceArbiter(probe: MemoryProbe.fixed(physicalGB: 32, availableGB: 2))
            .admit(request, residents: [new, old])
        XCTAssertTrue(roomy.isOverridable)
        XCTAssertEqual(roomy.overridden, .admit)

        // 16 GiB, 8 GiB budget: 3 + 3 + 5 does not fit; the older one goes.
        let sam3 = PluginResidency(pluginID: "sam3", declaredRamGB: 5.0)
        let tight = ResourceArbiter(probe: MemoryProbe.fixed(physicalGB: 16, availableGB: 0))
            .admit(sam3, residents: [new, old])
        XCTAssertTrue(tight.isOverridable)
        XCTAssertEqual(tight.overridden, .evictThenAdmit(["sam2"]))
    }

    func testAdmittedDecisionsAreUnchangedByOverride() {
        let idle = ResourceArbiter(probe: MemoryProbe.fixed(physicalGB: 32, availableGB: 28))
        let decision = idle.admit(gemma, residents: [])
        XCTAssertEqual(decision, .admit)
        XCTAssertEqual(decision.overridden, .admit)
        XCTAssertFalse(decision.isOverridable)
    }

    // MARK: - Live estimate

    private let page: Double = 16_384
    private func pages(_ gb: Double) -> UInt64 { UInt64(gb * MemoryStatus.bytesPerGB / 16_384) }

    func testInactiveAnonymousMemoryCountsAsAvailable() {
        // 16 GiB: 2 wired, 1 compressor, 10 anonymous of which 4 inactive,
        // 3 file-backed of which 1 inactive -> inactive queue = 5.
        let counters = MemoryProbe.VMCounters(
            inactive: pages(5), wired: pages(2), purgeable: 0,
            internalPages: pages(10), externalPages: pages(3), compressor: pages(1))
        let available = MemoryProbe.availableGB(counters, pageSize: page, physicalGB: 16)
        // Lower bound on inactive anonymous is 5 - 3 = 2, so used = (10 - 2) + 2 + 1.
        XCTAssertEqual(available, 5, accuracy: 0.01)

        // The previous estimate, which treated all anonymous memory as used.
        XCTAssertGreaterThan(available, 16 - (10 + 2 + 1))
    }

    func testPurgeableMemoryCountsAsAvailable() {
        let base = MemoryProbe.VMCounters(
            inactive: 0, wired: pages(2), purgeable: 0,
            internalPages: pages(8), externalPages: pages(2), compressor: 0)
        var withPurgeable = base
        withPurgeable.purgeable = pages(3)
        let before = MemoryProbe.availableGB(base, pageSize: page, physicalGB: 16)
        let after = MemoryProbe.availableGB(withPurgeable, pageSize: page, physicalGB: 16)
        XCTAssertEqual(after - before, 3, accuracy: 0.01)
    }

    func testEstimateStaysWithinThePhysicalRange() {
        // Reclaimable pages can never exceed the anonymous pages they come from.
        let odd = MemoryProbe.VMCounters(
            inactive: pages(30), wired: 0, purgeable: pages(30),
            internalPages: pages(4), externalPages: 0, compressor: 0)
        XCTAssertEqual(MemoryProbe.availableGB(odd, pageSize: page, physicalGB: 16), 16, accuracy: 0.01)

        let overcommitted = MemoryProbe.VMCounters(
            inactive: 0, wired: pages(10), purgeable: 0,
            internalPages: pages(10), externalPages: 0, compressor: pages(4))
        XCTAssertEqual(MemoryProbe.availableGB(overcommitted, pageSize: page, physicalGB: 16), 0)
    }
}
