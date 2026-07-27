// PluginStoreTests.swift
// OpenDicomViewer
//
// Exercises PluginStore against the shipped manifest and a mock runtime:
// row construction, deterministic ordering, filtering, the gate-driven action
// for each of the three license gates, key validation, hardware gating, and
// state propagation.
// Licensed under the MIT License. See LICENSE for details.

import XCTest
import Combine
@testable import OpenDicomViewer

// MARK: - Will-change facade

/// Facade that emits its change signal *before* applying the mutation, the way
/// an `ObservableObject`'s `objectWillChange` does. Used to prove the store
/// does not latch a stale row under that ordering.
@MainActor
private final class WillChangeFacade: PluginRuntimeFacade {
    let manifest: PluginManifest
    private var states: [PluginTaskRef: PluginInstallState] = [:]
    private let subject = PassthroughSubject<Void, Never>()

    init(manifest: PluginManifest) { self.manifest = manifest }

    var stateDidChange: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }

    func signalThenSet(_ state: PluginInstallState, for ref: PluginTaskRef) {
        subject.send()
        states[ref] = state
    }

    func installState(for ref: PluginTaskRef) -> PluginInstallState {
        states[ref] ?? .notInstalled
    }
    func runtimeState(for pluginID: String) -> PluginRuntimeState { .stopped }
    func checkpointLocation(for ref: PluginTaskRef) -> PluginCheckpointLocation? { nil }
    func installLog(for ref: PluginTaskRef) -> String { "" }
    func install(_ ref: PluginTaskRef, licenseKey: String?) async {}
    func cancelInstall(_ ref: PluginTaskRef) async {}
    func remove(_ ref: PluginTaskRef) async {}
    @discardableResult
    func verifyCheckpoint(for ref: PluginTaskRef) async -> Bool { false }
    func start(_ pluginID: String) async {}
    func stop(_ pluginID: String) async {}
}

@MainActor
final class PluginStoreTests: XCTestCase {

    // MARK: - Fixtures

    /// The real shipped manifest, located relative to the test source so the
    /// suite does not depend on bundle resources being staged.
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

    private func makeStore(
        appleSilicon: Bool = true,
        memoryGB: Double = 32
    ) throws -> (PluginStore, MockPluginRuntimeFacade) {
        let manifest = try PluginManifest.load(contentsOf: try manifestURL())
        let facade = MockPluginRuntimeFacade(
            manifest: manifest,
            checkpointRoot: URL(fileURLWithPath: "/tmp/odv-test-plugins"))
        let machine = PluginMachineProfile(
            isAppleSilicon: appleSilicon,
            architectureName: appleSilicon ? "Apple Silicon" : "Intel",
            physicalMemoryGB: memoryGB)
        return (PluginStore(facade: facade, machine: machine), facade)
    }

    private let gemmaAnalyze = PluginTaskRef(pluginID: "gemma-4-e4b", taskID: "analyze")
    private let sam3Prompt = PluginTaskRef(pluginID: "sam3", taskID: "prompt-mask")
    private let heartChambers = PluginTaskRef(pluginID: "totalsegmentator",
                                              taskID: "heartchambers_highres")

    // MARK: - Row construction and grouping

    func testRowsAreBuiltForEveryManifestTask() throws {
        let (store, _) = try makeStore()
        let manifest = try PluginManifest.load(contentsOf: try manifestURL())

        let expected = manifest.plugins.reduce(0) { $0 + $1.tasks.count }
        XCTAssertEqual(store.rows.count, expected)
        XCTAssertEqual(store.groups.count, manifest.plugins.count)

        for group in store.groups {
            let descriptor = manifest.plugin(id: group.id)
            XCTAssertNotNil(descriptor)
            XCTAssertEqual(group.rows.count, descriptor?.tasks.count)
            XCTAssertTrue(group.rows.allSatisfy { $0.pluginID == group.id })
        }
    }

    func testRowCarriesSizeMemoryAndLicenseFromManifest() throws {
        let (store, _) = try makeStore()
        let row = try XCTUnwrap(store.row(for: gemmaAnalyze))

        XCTAssertEqual(row.pluginName, "Gemma 4 E4B (MLX)")
        XCTAssertEqual(row.taskLabel, "Analyze Image")
        XCTAssertEqual(row.sizeGB, 4.5, accuracy: 0.0001)
        XCTAssertEqual(row.ramGB, 5.0, accuracy: 0.0001)
        XCTAssertEqual(row.license.identifier, "Apache-2.0")
        XCTAssertEqual(row.license.gate, .open)
        XCTAssertEqual(row.installState, .notInstalled)
        XCTAssertTrue(row.requiresAppleSilicon)
        XCTAssertTrue(row.isSupported)
        XCTAssertNil(row.disabledReason)
    }

    /// Sub-gigabyte weights are the common case for SAM 2; showing "0.2 GB"
    /// would understate a difference the user is choosing on.
    func testSizeTextSwitchesToMegabytesBelowOneGigabyte() throws {
        let (store, _) = try makeStore()
        let sam2 = try XCTUnwrap(store.row(for: PluginTaskRef(pluginID: "sam2",
                                                              taskID: "prompt-mask")))
        XCTAssertEqual(sam2.sizeText, "184 MB")

        let gemma = try XCTUnwrap(store.row(for: gemmaAnalyze))
        XCTAssertEqual(gemma.sizeText, "4.5 GB")
    }

    // MARK: - Deterministic ordering

    func testOrderingIsStableAcrossRefreshAndStateChange() throws {
        let (store, facade) = try makeStore()
        let before = store.rows.map(\.id)

        store.refresh()
        XCTAssertEqual(store.rows.map(\.id), before)

        facade.set(.ready, for: gemmaAnalyze)
        facade.set(.downloading(progress: 0.5), for: sam3Prompt)
        XCTAssertEqual(store.rows.map(\.id), before,
                       "install state must not reorder rows under the pointer")
    }

    func testGroupsAndTasksSortByDisplayName() throws {
        let (store, _) = try makeStore()
        XCTAssertEqual(store.groups.map(\.name),
                       store.groups.map(\.name).sorted())
        for group in store.groups {
            XCTAssertEqual(group.rows.map(\.taskLabel),
                           group.rows.map(\.taskLabel).sorted(),
                           "tasks in \(group.id) are not in stable label order")
        }
    }

    // MARK: - Filtering

    func testSearchMatchesPluginTaskAndVendorText() throws {
        let (store, _) = try makeStore()

        store.searchText = "heart"
        XCTAssertEqual(store.rows.map(\.ref), [heartChambers])

        store.searchText = "Meta"
        XCTAssertEqual(Set(store.groups.map(\.id)), ["sam2", "sam3"])

        store.searchText = "SEGMENT ANYTHING"
        XCTAssertFalse(store.rows.isEmpty, "search must be case-insensitive")

        store.searchText = "no such plugin"
        XCTAssertTrue(store.groups.isEmpty)

        store.searchText = ""
        XCTAssertFalse(store.groups.isEmpty)
    }

    func testInstalledOnlyFilterHidesEverythingUntilSomethingIsReady() throws {
        let (store, facade) = try makeStore()

        store.showInstalledOnly = true
        XCTAssertTrue(store.rows.isEmpty)

        facade.set(.ready, for: gemmaAnalyze)
        XCTAssertEqual(store.rows.map(\.ref), [gemmaAnalyze])

        // A download in flight is not an installation.
        facade.set(.downloading(progress: 0.9), for: sam3Prompt)
        XCTAssertEqual(store.rows.map(\.ref), [gemmaAnalyze])
    }

    // MARK: - Gate-driven actions

    func testOpenGateInstallsDirectly() throws {
        let (store, facade) = try makeStore()
        let row = try XCTUnwrap(store.row(for: gemmaAnalyze))
        XCTAssertEqual(row.action, .install)
        XCTAssertFalse(row.action.opensGateSheet)

        let waited = expectation(description: "install")
        Task { await store.perform(row.action, on: row.ref); waited.fulfill() }
        wait(for: [waited], timeout: 2)

        XCTAssertEqual(facade.installCalls.count, 1)
        XCTAssertEqual(facade.installCalls.first?.ref, gemmaAnalyze)
        XCTAssertNil(facade.installCalls.first?.licenseKey)
    }

    func testLicenseKeyGateAsksBeforeInstalling() throws {
        let (store, facade) = try makeStore()
        let row = try XCTUnwrap(store.row(for: heartChambers))
        XCTAssertEqual(row.license.gate, .licenseKey)
        XCTAssertEqual(row.action, .resolveLicenseKey)
        XCTAssertTrue(row.action.opensGateSheet)

        // The row action alone must not reach the installer.
        let waited = expectation(description: "no-op")
        Task { await store.perform(row.action, on: row.ref); waited.fulfill() }
        wait(for: [waited], timeout: 2)
        XCTAssertTrue(facade.installCalls.isEmpty)
    }

    func testGatedDownloadOffersCheckpointPathAndVerification() throws {
        let (store, facade) = try makeStore()
        let row = try XCTUnwrap(store.row(for: sam3Prompt))
        XCTAssertEqual(row.license.gate, .gatedDownload)
        XCTAssertEqual(row.action, .acquireCheckpoint)
        XCTAssertEqual(row.checkpointLocation?.filename, "sam3.pt")
        XCTAssertEqual(row.checkpointLocation?.path,
                       "/tmp/odv-test-plugins/sam3/sam3.pt")

        let missing = expectation(description: "verify missing")
        Task {
            let found = await store.verifyCheckpoint(for: self.sam3Prompt)
            XCTAssertFalse(found)
            missing.fulfill()
        }
        wait(for: [missing], timeout: 2)
        XCTAssertEqual(store.row(for: sam3Prompt)?.installState, .resolvingLicense)

        facade.setCheckpointPresent(true, for: sam3Prompt)
        let present = expectation(description: "verify present")
        Task {
            let found = await store.verifyCheckpoint(for: self.sam3Prompt)
            XCTAssertTrue(found)
            present.fulfill()
        }
        wait(for: [present], timeout: 2)
        XCTAssertEqual(store.row(for: sam3Prompt)?.installState, .ready)
        XCTAssertEqual(store.row(for: sam3Prompt)?.action, .remove)
        XCTAssertTrue(facade.installCalls.isEmpty,
                      "a gated download is never fetched by the app")
    }

    func testActionMappingCoversEveryStateAndGate() {
        XCTAssertEqual(PluginStore.action(for: .ready, gate: .open), .remove)
        XCTAssertEqual(PluginStore.action(for: .ready, gate: .licenseKey), .remove)
        XCTAssertEqual(PluginStore.action(for: .downloading(progress: 0.1), gate: .open),
                       .cancel)
        XCTAssertEqual(PluginStore.action(for: .installing(progress: 0.1), gate: .open),
                       .cancel)
        XCTAssertEqual(PluginStore.action(for: .failed("boom"), gate: .open), .retryInstall)
        XCTAssertEqual(PluginStore.action(for: .failed("boom"), gate: .licenseKey),
                       .resolveLicenseKey)
        XCTAssertEqual(PluginStore.action(for: .resolvingLicense, gate: .gatedDownload),
                       .acquireCheckpoint)
        XCTAssertEqual(PluginStore.action(for: .notInstalled, gate: .gatedDownload),
                       .acquireCheckpoint)
    }

    // MARK: - License key validation

    func testWellFormedKeyIsAcceptedAndReachesTheInstaller() throws {
        let (store, facade) = try makeStore()
        XCTAssertEqual(store.validate(licenseKey: "aca_9f2c1b", for: heartChambers), .valid)
        XCTAssertEqual(store.validate(licenseKey: "  aca_9f2c1b  ", for: heartChambers),
                       .valid, "surrounding whitespace is the user's, not the key's")

        let waited = expectation(description: "submit")
        Task {
            let accepted = await store.submitLicenseKey(" aca_9f2c1b ",
                                                        for: self.heartChambers)
            XCTAssertTrue(accepted)
            waited.fulfill()
        }
        wait(for: [waited], timeout: 2)

        XCTAssertEqual(facade.installCalls.count, 1)
        XCTAssertEqual(facade.installCalls.first?.licenseKey, "aca_9f2c1b")
    }

    func testMalformedKeyIsRejectedAndNeverReachesTheInstaller() throws {
        let (store, facade) = try makeStore()

        XCTAssertEqual(store.validate(licenseKey: "", for: heartChambers), .empty)
        XCTAssertEqual(store.validate(licenseKey: "   ", for: heartChambers), .empty)
        XCTAssertEqual(store.validate(licenseKey: "abc_123", for: heartChambers),
                       .wrongPrefix(expected: "aca_"))
        XCTAssertEqual(store.validate(licenseKey: "aca_", for: heartChambers),
                       .wrongPrefix(expected: "aca_"),
                       "a bare prefix carries no license number")

        let waited = expectation(description: "reject")
        Task {
            let accepted = await store.submitLicenseKey("abc_123", for: self.heartChambers)
            XCTAssertFalse(accepted)
            waited.fulfill()
        }
        wait(for: [waited], timeout: 2)
        XCTAssertTrue(facade.installCalls.isEmpty)
    }

    /// The store never becomes a place a key can leak from: it is a call
    /// argument only, so nothing observable on the store or the log holds it.
    func testSubmittedKeyIsNotRetainedInStoreStateOrLog() throws {
        let (store, facade) = try makeStore()
        let secret = "aca_do_not_leak"

        let waited = expectation(description: "submit")
        Task { await store.submitLicenseKey(secret, for: self.heartChambers)
               waited.fulfill() }
        wait(for: [waited], timeout: 2)

        XCTAssertFalse(store.installLog(for: heartChambers).contains(secret))
        XCTAssertFalse(store.searchText.contains(secret))
        XCTAssertFalse(facade.installLog(for: heartChambers).contains(secret))
        for row in store.rows {
            XCTAssertFalse(row.taskSummary.contains(secret))
            XCTAssertFalse(row.installState.displayText.contains(secret))
        }
    }

    func testValidationPassesWhenTheManifestDeclaresNoKeyFormat() throws {
        let (store, _) = try makeStore()
        // The open-gate tasks declare no key format; validation must not
        // invent a constraint the manifest does not state.
        XCTAssertEqual(store.validate(licenseKey: "anything", for: gemmaAnalyze), .valid)
    }

    // MARK: - Hardware gating

    func testAppleSiliconOnlyPluginIsDisabledOnIntelWithAReason() throws {
        let (store, facade) = try makeStore(appleSilicon: false)
        let row = try XCTUnwrap(store.row(for: gemmaAnalyze))

        XCTAssertFalse(row.isSupported)
        XCTAssertEqual(row.action, .unavailable)
        let reason = try XCTUnwrap(row.disabledReason)
        XCTAssertTrue(reason.contains("Apple Silicon"))
        XCTAssertTrue(reason.contains("Intel"))

        // Plugins that do not require Apple Silicon stay installable.
        let sam2 = try XCTUnwrap(store.row(for: PluginTaskRef(pluginID: "sam2",
                                                              taskID: "prompt-mask")))
        XCTAssertTrue(sam2.isSupported)
        XCTAssertEqual(sam2.action, .install)

        let waited = expectation(description: "no install")
        Task { await store.perform(row.action, on: row.ref); waited.fulfill() }
        wait(for: [waited], timeout: 2)
        XCTAssertTrue(facade.installCalls.isEmpty)
    }

    func testPluginDeclaringMoreMemoryThanTheMachineHasIsDisabled() throws {
        let (store, _) = try makeStore(memoryGB: 4)
        let row = try XCTUnwrap(store.row(for: gemmaAnalyze))
        XCTAssertFalse(row.isSupported)
        XCTAssertEqual(row.action, .unavailable)
        XCTAssertTrue(try XCTUnwrap(row.disabledReason).contains("peak memory"))
    }

    // MARK: - Propagation

    func testFacadeStateChangePropagatesToTheRow() throws {
        let (store, facade) = try makeStore()
        XCTAssertEqual(store.row(for: gemmaAnalyze)?.installState, .notInstalled)

        facade.set(.downloading(progress: 0.25), for: gemmaAnalyze)
        XCTAssertEqual(store.row(for: gemmaAnalyze)?.installState,
                       .downloading(progress: 0.25))
        XCTAssertEqual(store.row(for: gemmaAnalyze)?.action, .cancel)

        facade.set(.installing(progress: 0.8), for: gemmaAnalyze)
        XCTAssertEqual(store.row(for: gemmaAnalyze)?.installState.progress, 0.8)

        facade.set(.ready, for: gemmaAnalyze)
        XCTAssertEqual(store.row(for: gemmaAnalyze)?.action, .remove)

        facade.set(.failed("pip resolution failed"), for: gemmaAnalyze)
        XCTAssertEqual(store.row(for: gemmaAnalyze)?.action, .retryInstall)
        XCTAssertEqual(store.row(for: gemmaAnalyze)?.installState.displayText,
                       "Failed: pip resolution failed")
    }

    func testRuntimeStateChangePropagatesToTheGroup() throws {
        let (store, facade) = try makeStore()
        facade.set(.ready, for: gemmaAnalyze)

        let group = try XCTUnwrap(store.groups.first { $0.id == "gemma-4-e4b" })
        XCTAssertTrue(group.canStart)
        XCTAssertFalse(group.isRunning)

        facade.setRuntime(.ready, for: "gemma-4-e4b")
        let running = try XCTUnwrap(store.groups.first { $0.id == "gemma-4-e4b" })
        XCTAssertTrue(running.isRunning)
        XCTAssertEqual(running.rows.first(where: { $0.ref == self.gemmaAnalyze })?
                        .runtimeState, .ready)
    }

    /// A one-shot plugin has no resident process, so the store must not offer
    /// to start one even after its tasks install.
    func testOneShotPluginNeverOffersStart() throws {
        let (store, facade) = try makeStore()
        facade.set(.ready, for: PluginTaskRef(pluginID: "totalsegmentator", taskID: "total"))
        let group = try XCTUnwrap(store.groups.first { $0.id == "totalsegmentator" })
        XCTAssertEqual(group.execution, .oneShot)
        XCTAssertFalse(group.canStart)
    }

    func testRemoveClearsInstalledStateAndLog() throws {
        let (store, facade) = try makeStore()
        facade.set(.ready, for: gemmaAnalyze)
        facade.appendLog("Downloaded 4.5 GB", for: gemmaAnalyze)
        XCTAssertFalse(store.installLog(for: gemmaAnalyze).isEmpty)

        let waited = expectation(description: "remove")
        Task { await store.perform(.remove, on: self.gemmaAnalyze); waited.fulfill() }
        wait(for: [waited], timeout: 2)

        XCTAssertEqual(facade.removeCalls, [gemmaAnalyze])
        XCTAssertEqual(store.row(for: gemmaAnalyze)?.installState, .notInstalled)
        XCTAssertTrue(store.installLog(for: gemmaAnalyze).isEmpty)
    }

    func testCancelDuringInstallReturnsTheRowToNotInstalled() throws {
        let (store, facade) = try makeStore()
        facade.set(.downloading(progress: 0.3), for: gemmaAnalyze)
        XCTAssertEqual(store.row(for: gemmaAnalyze)?.action, .cancel)

        let waited = expectation(description: "cancel")
        Task { await store.perform(.cancel, on: self.gemmaAnalyze); waited.fulfill() }
        wait(for: [waited], timeout: 2)

        XCTAssertEqual(facade.cancelCalls, [gemmaAnalyze])
        XCTAssertEqual(store.row(for: gemmaAnalyze)?.action, .install)
    }

    // MARK: - Menu availability

    /// The menu lists every task in the manifest. An uninstalled task must be
    /// visible but disabled, carrying the reason, so the user learns the
    /// capability exists rather than that it does not.
    func testMenuDisablesUninstalledTasksWithAReason() throws {
        let (store, facade) = try makeStore()

        let notInstalled = store.menuAvailability(
            for: try XCTUnwrap(store.row(for: gemmaAnalyze)))
        XCTAssertFalse(notInstalled.isRunnable)
        XCTAssertEqual(notInstalled.reason, "not installed")

        facade.set(.resolvingLicense, for: heartChambers)
        XCTAssertEqual(store.menuAvailability(
            for: try XCTUnwrap(store.row(for: heartChambers))).reason,
                       "license required")

        facade.set(.downloading(progress: 0.1), for: gemmaAnalyze)
        XCTAssertEqual(store.menuAvailability(
            for: try XCTUnwrap(store.row(for: gemmaAnalyze))).reason, "installing")

        facade.set(.failed("pip"), for: gemmaAnalyze)
        XCTAssertEqual(store.menuAvailability(
            for: try XCTUnwrap(store.row(for: gemmaAnalyze))).reason, "install failed")
    }

    func testMenuRequiresAResidentPluginToBeRunningButNotAOneShotOne() throws {
        let (store, facade) = try makeStore()
        let total = PluginTaskRef(pluginID: "totalsegmentator", taskID: "total")

        facade.set(.ready, for: gemmaAnalyze)
        let stopped = store.menuAvailability(
            for: try XCTUnwrap(store.row(for: gemmaAnalyze)))
        XCTAssertFalse(stopped.isRunnable)
        XCTAssertEqual(stopped.reason, "plugin not running")

        facade.setRuntime(.ready, for: "gemma-4-e4b")
        let running = store.menuAvailability(
            for: try XCTUnwrap(store.row(for: gemmaAnalyze)))
        XCTAssertTrue(running.isRunnable)
        XCTAssertNil(running.reason)

        // TotalSegmentator is spawned per invocation, so an installed task is
        // runnable with nothing resident.
        facade.set(.ready, for: total)
        let oneShot = store.menuAvailability(for: try XCTUnwrap(store.row(for: total)))
        XCTAssertTrue(oneShot.isRunnable)
    }

    func testMenuReportsHardwareBlockAheadOfInstallState() throws {
        let (store, facade) = try makeStore(appleSilicon: false)
        facade.set(.ready, for: gemmaAnalyze)
        facade.setRuntime(.ready, for: "gemma-4-e4b")

        let availability = store.menuAvailability(
            for: try XCTUnwrap(store.row(for: gemmaAnalyze)))
        XCTAssertFalse(availability.isRunnable)
        XCTAssertEqual(availability.reason, "unavailable on this Mac")
    }

    /// The store's action column and the menu must agree: anything the menu
    /// calls runnable is a row the store shows as installed and supported.
    func testMenuAvailabilityAgreesWithRowState() throws {
        let (store, facade) = try makeStore()
        facade.set(.ready, for: gemmaAnalyze)
        facade.setRuntime(.ready, for: "gemma-4-e4b")

        for row in store.rows where store.menuAvailability(for: row).isRunnable {
            XCTAssertTrue(row.isInstalled)
            XCTAssertTrue(row.isSupported)
            XCTAssertEqual(row.action, .remove)
        }
    }

    /// `PluginRuntime` is an ObservableObject, so the natural conformance
    /// forwards `objectWillChange` — which fires before the value changes. The
    /// store must still converge, or every row would render one transition
    /// behind.
    func testStoreConvergesWhenTheFacadeSignalsBeforeMutating() throws {
        let manifest = try PluginManifest.load(contentsOf: try manifestURL())
        let facade = WillChangeFacade(manifest: manifest)
        let store = PluginStore(facade: facade,
                                machine: PluginMachineProfile(
                                    isAppleSilicon: true,
                                    architectureName: "Apple Silicon",
                                    physicalMemoryGB: 32))

        facade.signalThenSet(.ready, for: gemmaAnalyze)

        let converged = expectation(description: "row catches up")
        RunLoop.main.perform { converged.fulfill() }
        wait(for: [converged], timeout: 2)

        XCTAssertEqual(store.row(for: gemmaAnalyze)?.installState, .ready)
        XCTAssertEqual(store.row(for: gemmaAnalyze)?.action, .remove)
    }

    // MARK: - Standing claims

    /// These strings are quoted in the paper and are the user-facing form of
    /// PLUGIN_PROTOCOL.md invariants 1, 3 and 5. Pin them so a well-meaning
    /// edit cannot quietly weaken the claim.
    func testPrivacyAndResearchStatementsMakeTheRequiredClaims() {
        let privacy = PluginStore.privacyStatement
        XCTAssertTrue(privacy.contains("model weights"))
        XCTAssertTrue(privacy.contains("never transmitted"))
        XCTAssertTrue(privacy.lowercased().contains("on this mac"))

        let research = PluginStore.researchUseStatement
        XCTAssertTrue(research.contains("research use only"))
        XCTAssertTrue(research.contains("not a diagnosis"))
    }
}
