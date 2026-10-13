// DerivedOverlayMatchingTests.swift
// OpenDicomViewer Tests
//
// RTSTRUCT contours honour the ROI's Referenced Frame of Reference, and SEG
// frames without derivation references draw only on the image they lie on.
// Licensed under the MIT License. See LICENSE for details.

import XCTest
import simd
@testable import OpenDicomViewer

final class DerivedOverlayMatchingTests: XCTestCase {
    typealias S = SyntheticDICOM

    private func sq(_ g: UInt16, _ e: UInt16, _ items: [Data]) -> Data {
        S.element(g, e, "SQ", items.reduce(Data()) { $0 + S.definedItem($1) })
    }

    private func image(sop: String = "1.2.3.9", z: Double = 0, frame: String? = "FOR.A") -> DicomImageContext {
        DicomImageContext(
            url: URL(fileURLWithPath: "/tmp/src.dcm"), sopInstanceUID: sop, seriesUID: "s", seriesDescription: "s",
            instanceNumber: 1, seriesNumber: 1, zLocation: z, imagePosition: SIMD3(0, 0, z),
            imageOrientation: [1, 0, 0, 0, 1, 0], pixelSpacing: SIMD2(1, 1), sliceThickness: 1,
            spacingBetweenSlices: nil, frameOfReferenceUID: frame, studyInstanceUID: nil, numberOfFrames: 1)
    }

    private func write(_ ds: Data, _ name: String) throws -> URL {
        try S.writeTemp(S.part10(dataset: ds), name: name)
    }

    // MARK: - RTSTRUCT

    /// RTSTRUCT with one unreferenced contour on z = 0 whose ROI references `roiFrame`.
    private func rtstruct(roiFrame: String) throws -> DICOMAnnotationObject {
        let roi = S.element(0x3006, 0x0022, "IS", S.text("1"))
            + S.element(0x3006, 0x0024, "UI", S.text(roiFrame, pad: 0))
            + S.element(0x3006, 0x0026, "LO", S.text("LIVER"))
        let contour = S.element(0x3006, 0x0042, "CS", S.text("CLOSED_PLANAR"))
            + S.element(0x3006, 0x0050, "DS", S.text("0\\0\\0\\10\\0\\0\\10\\10\\0"))
        let roiContour = S.element(0x3006, 0x0084, "IS", S.text("1")) + sq(0x3006, 0x0040, [contour])
        var ds = Data()
        ds.append(S.element(0x0008, 0x0016, "UI", S.text("1.2.840.10008.5.1.4.1.1.481.3", pad: 0)))
        ds.append(S.element(0x0008, 0x0060, "CS", S.text("RTSTRUCT")))
        ds.append(sq(0x3006, 0x0010, [S.element(0x0020, 0x0052, "UI", S.text(roiFrame, pad: 0))]))
        ds.append(sq(0x3006, 0x0020, [roi]))
        ds.append(sq(0x3006, 0x0039, [roiContour]))
        let url = try write(ds, "rt.dcm")
        return try XCTUnwrap(DICOMAnnotationObjectParser.parse(url: url, kind: .rtStructureSet))
    }

    func testRTStructReadsReferencedFrameOfReference() throws {
        let object = try rtstruct(roiFrame: "FOR.A")
        XCTAssertEqual(object.frameOfReferenceUID, "FOR.A")
        XCTAssertEqual(object.contours.first?.frameOfReferenceUID, "FOR.A")
        XCTAssertEqual(object.resolvedOverlays(for: image(frame: "FOR.A")).count, 1)
    }

    func testRTStructContourSkippedForOtherFrameOfReference() throws {
        let object = try rtstruct(roiFrame: "FOR.A")
        // Same plane geometry, different patient/frame: must not draw
        XCTAssertTrue(object.resolvedOverlays(for: image(frame: "FOR.B")).isEmpty)
    }

    // MARK: - SEG

    private func seg(frameOfReference: String, framePosition: [Double]?, referencedSOP: String? = nil) throws -> DICOMAnnotationObject {
        var frameItem = Data()
        if let ref = referencedSOP {
            let source = S.element(0x0008, 0x1155, "UI", S.text(ref, pad: 0))
            frameItem.append(sq(0x0008, 0x9124, [sq(0x0008, 0x2112, [source])]))
        }
        if let p = framePosition {
            frameItem.append(sq(0x0020, 0x9113, [S.element(0x0020, 0x0032, "DS", S.text(p.map { String($0) }.joined(separator: "\\")))]))
        }
        frameItem.append(sq(0x0062, 0x000A, [S.element(0x0062, 0x000B, "US", S.us(1))]))
        let shared = sq(0x0020, 0x9116, [S.element(0x0020, 0x0037, "DS", S.text("1\\0\\0\\0\\1\\0"))])
        var ds = Data()
        ds.append(S.element(0x0008, 0x0016, "UI", S.text("1.2.840.10008.5.1.4.1.1.66.4", pad: 0)))
        ds.append(S.element(0x0008, 0x0060, "CS", S.text("SEG")))
        ds.append(S.element(0x0020, 0x0052, "UI", S.text(frameOfReference, pad: 0)))
        ds.append(S.element(0x0028, 0x0002, "US", S.us(1)))
        ds.append(S.element(0x0028, 0x0008, "IS", S.text("1")))
        ds.append(S.element(0x0028, 0x0010, "US", S.us(2)))
        ds.append(S.element(0x0028, 0x0011, "US", S.us(2)))
        ds.append(S.element(0x0028, 0x0100, "US", S.us(1)))
        ds.append(S.element(0x0028, 0x0101, "US", S.us(1)))
        ds.append(S.element(0x0062, 0x0001, "CS", S.text("BINARY")))
        ds.append(sq(0x0062, 0x0002, [S.element(0x0062, 0x0004, "US", S.us(1)) + S.element(0x0062, 0x0005, "LO", S.text("LESION"))]))
        ds.append(sq(0x5200, 0x9229, [shared]))
        ds.append(sq(0x5200, 0x9230, [frameItem]))
        ds.append(S.element(0x7FE0, 0x0010, "OB", Data([0b0000_1001, 0])))
        return try XCTUnwrap(DICOMAnnotationObjectParser.parse(url: try write(ds, "seg.dcm"), kind: .dicomSegmentation))
    }

    func testSegFrameWithoutReferencesDrawsOnlyOnItsPlane() throws {
        let object = try seg(frameOfReference: "FOR.A", framePosition: [0, 0, 5])
        XCTAssertEqual(object.segmentFrames.first?.imagePosition, SIMD3(0, 0, 5))
        XCTAssertEqual(object.resolvedOverlays(for: image(z: 5)).count, 1)
        XCTAssertTrue(object.resolvedOverlays(for: image(z: 20)).isEmpty)
        XCTAssertTrue(object.resolvedOverlays(for: image(z: 5, frame: "FOR.B")).isEmpty)
    }

    func testSegFrameWithoutAnyPlacementIsNotDrawnEverywhere() throws {
        let object = try seg(frameOfReference: "FOR.A", framePosition: nil)
        XCTAssertTrue(object.resolvedOverlays(for: image(z: 0)).isEmpty)
    }

    func testSegFrameWithReferenceStillMatchesBySOP() throws {
        let object = try seg(frameOfReference: "FOR.A", framePosition: nil, referencedSOP: "1.2.3.9")
        XCTAssertEqual(object.resolvedOverlays(for: image(sop: "1.2.3.9", z: 100)).count, 1)
        XCTAssertTrue(object.resolvedOverlays(for: image(sop: "1.2.3.10", z: 100)).isEmpty)
    }
}
