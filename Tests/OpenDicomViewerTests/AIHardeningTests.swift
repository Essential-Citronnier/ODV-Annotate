// AIHardeningTests.swift
// OpenDicomViewer Tests
//
// Tests for the built-in AI path's defensive logic: box sanitizing, severity
// parsing, slice-bound annotation filtering, the setup marker and the PID
// record used to recognize an orphaned server.
// Licensed under the MIT License. See LICENSE for details.

import XCTest
@testable import OpenDicomViewer

final class AIHardeningTests: XCTestCase {

    // MARK: - Box sanitizing

    func testNormalizedBoxPassesThrough() throws {
        let rect = try XCTUnwrap(AIBoxSanitizer.normalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        XCTAssertEqual(rect.minX, 0.1, accuracy: 1e-9)
        XCTAssertEqual(rect.minY, 0.2, accuracy: 1e-9)
        XCTAssertEqual(rect.width, 0.3, accuracy: 1e-9)
        XCTAssertEqual(rect.height, 0.4, accuracy: 1e-9)
    }

    func testBoxIsClampedToImage() throws {
        let rect = try XCTUnwrap(AIBoxSanitizer.normalizedRect(x: 0.8, y: -0.2, width: 0.5, height: 0.5))
        XCTAssertEqual(rect.minX, 0.8, accuracy: 1e-9)
        XCTAssertEqual(rect.maxX, 1.0, accuracy: 1e-9)
        XCTAssertEqual(rect.minY, 0.0, accuracy: 1e-9)
        XCTAssertEqual(rect.maxY, 0.3, accuracy: 1e-9)
    }

    func testNegativeSizeIsReordered() throws {
        let rect = try XCTUnwrap(AIBoxSanitizer.normalizedRect(x: 0.5, y: 0.5, width: -0.2, height: -0.1))
        XCTAssertEqual(rect.minX, 0.3, accuracy: 1e-9)
        XCTAssertEqual(rect.width, 0.2, accuracy: 1e-9)
        XCTAssertEqual(rect.minY, 0.4, accuracy: 1e-9)
        XCTAssertEqual(rect.height, 0.1, accuracy: 1e-9)
    }

    func testDegenerateAndNonFiniteBoxesAreDropped() {
        XCTAssertNil(AIBoxSanitizer.normalizedRect(x: 0.1, y: 0.1, width: 0, height: 0.2))
        XCTAssertNil(AIBoxSanitizer.normalizedRect(x: 2, y: 2, width: 0.5, height: 0.5))
        XCTAssertNil(AIBoxSanitizer.normalizedRect(x: .nan, y: 0.1, width: 0.1, height: 0.1))
        XCTAssertNil(AIBoxSanitizer.normalizedRect(x: 0.1, y: 0.1, width: .infinity, height: 0.1))
    }

    func testConfidenceIsClamped() {
        XCTAssertEqual(AIBoxSanitizer.confidence(1.7), 1)
        XCTAssertEqual(AIBoxSanitizer.confidence(-0.3), 0)
        XCTAssertEqual(AIBoxSanitizer.confidence(.nan), 0)
        XCTAssertEqual(AIBoxSanitizer.confidence(0.42), 0.42)
    }

    // MARK: - Severity

    func testSeverityParsingIsCaseInsensitive() {
        XCTAssertEqual(AISeverity(parsing: "Severe"), .severe)
        XCTAssertEqual(AISeverity(parsing: " MODERATE "), .moderate)
        XCTAssertEqual(AISeverity(parsing: "critical"), .critical)
    }

    func testUnknownAndCriticalSeveritiesAreNeverGreen() {
        for raw in ["", "urgent", "N/A", "critical", "Critical", "SEVERE"] {
            XCTAssertNotEqual(AISeverity(parsing: raw).color, .green, raw)
        }
        XCTAssertEqual(AISeverity(parsing: "urgent"), .unknown)
        XCTAssertEqual(AISeverity(parsing: "normal").color, .green)
    }

    // MARK: - Slice binding

    private func makePanel(series: Int = 0, image: Int = 3) -> PanelState {
        let panel = PanelState()
        panel.seriesIndex = series
        panel.imageIndex = image
        return panel
    }

    private func aiBox(on slice: AnnotationSlice?) -> Annotation {
        Annotation(type: .aiStructure(rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
                                      label: "x", confidence: 0.5),
                   isAI: true, slice: slice)
    }

    func testAIAnnotationOnlyVisibleOnItsSlice() {
        let panel = makePanel()
        let slice = panel.currentSlice
        panel.annotations = [aiBox(on: slice)]
        XCTAssertEqual(panel.visibleAnnotations.count, 1)

        panel.imageIndex = 4
        XCTAssertTrue(panel.visibleAnnotations.isEmpty)

        panel.imageIndex = 3
        panel.seriesIndex = 1
        XCTAssertTrue(panel.visibleAnnotations.isEmpty)

        panel.seriesIndex = 0
        XCTAssertEqual(panel.visibleAnnotations.count, 1)
    }

    func testUnboundAnnotationsStayVisible() {
        let panel = makePanel()
        let ruler = Annotation(type: .ruler(start: .zero, end: CGPoint(x: 1, y: 1), distanceMM: 1))
        panel.annotations = [ruler, aiBox(on: nil)]
        panel.imageIndex = 9
        XCTAssertEqual(panel.visibleAnnotations.count, 2)
    }

    func testSliceDistinguishesModesFramesAndSlabs() {
        let panel = makePanel()
        let axial = panel.currentSlice

        panel.panelMode = .mprSagittal
        panel.mprSliceIndex = 3
        XCTAssertNotEqual(panel.currentSlice, axial)
        let sagittal = panel.currentSlice
        panel.panelMode = .mprCoronal
        XCTAssertNotEqual(panel.currentSlice, sagittal)

        panel.panelMode = .mip
        panel.mipSlabPosition = 3
        let mip = panel.currentSlice
        panel.mipSlabThickness += 2
        XCTAssertNotEqual(panel.currentSlice, mip)

        panel.panelMode = .slice2D
        panel.isMultiFrame = true
        panel.currentFrameIndex = 0
        let frame0 = panel.currentSlice
        panel.currentFrameIndex = 1
        XCTAssertNotEqual(panel.currentSlice, frame0)
    }

    func testSliceBoundAnnotationsHiddenDuringPlayback() {
        let panel = makePanel()
        panel.annotations = [aiBox(on: panel.currentSlice)]
        panel.isPlaying = true
        XCTAssertTrue(panel.visibleAnnotations.isEmpty)
    }

    func testDescriptionIsBoundToSlice() {
        let panel = makePanel()
        panel.aiDescription = "finding"
        panel.aiDescriptionSlice = panel.currentSlice
        XCTAssertEqual(panel.visibleAIDescription, "finding")
        panel.imageIndex = 7
        XCTAssertNil(panel.visibleAIDescription)
        panel.clearAIAnnotations()
        XCTAssertNil(panel.aiDescriptionSlice)
    }

    // MARK: - Setup marker

    func testSetupMarkerRequiresMatchingHash() {
        let hash = AIServerManager.requirementsHash(of: Data("mlx==1\n".utf8))
        XCTAssertEqual(hash.count, 64)
        XCTAssertTrue(AIServerManager.setupMarkerIsValid(markerContents: hash + "\n", requirementsHash: hash))
        XCTAssertFalse(AIServerManager.setupMarkerIsValid(markerContents: nil, requirementsHash: hash))
        XCTAssertFalse(AIServerManager.setupMarkerIsValid(markerContents: "", requirementsHash: hash))
        let other = AIServerManager.requirementsHash(of: Data("mlx==2\n".utf8))
        XCTAssertFalse(AIServerManager.setupMarkerIsValid(markerContents: other, requirementsHash: hash))
    }

    func testReadinessBackoffGrowsAndCaps() {
        XCTAssertEqual(AIServerManager.readinessBackoff(attempt: 0), 5)
        XCTAssertEqual(AIServerManager.readinessBackoff(attempt: 1), 10)
        XCTAssertEqual(AIServerManager.readinessBackoff(attempt: 50), 60)
    }

    // MARK: - PID record

    func testPIDRecordRoundTripsAndMatchesLiveProcess() throws {
        let own = try XCTUnwrap(AIServerManager.PIDRecord.current(pid: getpid()))
        XCTAssertEqual(AIServerManager.PIDRecord(serialized: own.serialized), own)
        XCTAssertEqual(AIServerManager.PIDRecord.current(pid: getpid()), own)

        let reused = AIServerManager.PIDRecord(pid: own.pid, startSeconds: own.startSeconds - 1,
                                               startMicroseconds: own.startMicroseconds)
        XCTAssertNotEqual(AIServerManager.PIDRecord.current(pid: getpid()), reused)
    }

    func testPIDRecordRejectsGarbage() {
        XCTAssertNil(AIServerManager.PIDRecord(serialized: ""))
        XCTAssertNil(AIServerManager.PIDRecord(serialized: "1 2 3"))  // pid 1 is launchd
        XCTAssertNil(AIServerManager.PIDRecord(serialized: "abc 1 2"))
        XCTAssertNil(AIServerManager.PIDRecord.current(pid: 999_999))
    }
}
