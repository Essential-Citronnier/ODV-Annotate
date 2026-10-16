//
//  ReviewFixesTests.swift
//  Viewer-core fixes from the pre-release review: unsigned 16-bit volumes,
//  ROI bounds, cache-hit validity, UID-keyed annotation slices and the
//  multi-frame panel reset.
//

import XCTest
@testable import OpenDicomViewer

final class ReviewFixesTests: XCTestCase {
    private typealias S = SyntheticDICOM

    // MARK: - Unsigned 16-bit above 32767 in a volume

    private func u16Data(_ values: [UInt16]) -> Data {
        var d = Data()
        for v in values { d.append(contentsOf: S.u16(v)) }
        return d
    }

    func testAssembleKeepsUnsigned16BitAboveInt16Max() throws {
        let slices: [VolumeBuilder.SliceRaw] = [
            .init(data: u16Data([0, 65_535]), width: 2, height: 1, bits: 16, isSigned: false),
            .init(data: u16Data([40_000, 100]), width: 2, height: 1, bits: 16, isSigned: false),
        ]
        let (voxels, slope, intercept, _) = try VolumeBuilder.assemble(width: 2, height: 1, depth: 2) { slices[$0] }
        defer { voxels.deallocate() }
        func value(_ i: Int) -> Double { Double(voxels[i]) * slope + intercept }
        XCTAssertEqual(value(0), 0, accuracy: slope)
        XCTAssertEqual(value(1), 65_535, accuracy: slope)
        XCTAssertEqual(value(2), 40_000, accuracy: slope)
        XCTAssertEqual(value(3), 100, accuracy: slope)
    }

    func testAssembleUnsigned16BitWithinInt16StaysIdentity() throws {
        let slices: [VolumeBuilder.SliceRaw] = [
            .init(data: u16Data([0, 32_767]), width: 2, height: 1, bits: 16, isSigned: false),
        ]
        let (voxels, slope, intercept, _) = try VolumeBuilder.assemble(width: 2, height: 1, depth: 1) { slices[$0] }
        defer { voxels.deallocate() }
        XCTAssertEqual(slope, 1); XCTAssertEqual(intercept, 0)
        XCTAssertEqual(Array(voxels), [0, 32_767])
    }

    // MARK: - ROI bounds are half-open

    func testROIBoundsDoNotCountAnExtraRowAndColumn() throws {
        let b = try XCTUnwrap(DICOMModel.roiPixelBounds(rawRect: CGRect(x: 0, y: 0, width: 10, height: 4),
                                                       width: 64, height: 64))
        XCTAssertEqual(b.x, 0..<10)
        XCTAssertEqual(b.y, 0..<4)
    }

    func testROIBoundsClipAtTheImageEdge() throws {
        let b = try XCTUnwrap(DICOMModel.roiPixelBounds(rawRect: CGRect(x: 60, y: 62, width: 10, height: 10),
                                                       width: 64, height: 64))
        XCTAssertEqual(b.x, 60..<64)
        XCTAssertEqual(b.y, 62..<64)
        XCTAssertNil(DICOMModel.roiPixelBounds(rawRect: CGRect(x: 64, y: 0, width: 5, height: 5),
                                               width: 64, height: 64))
        // A whole-image ROI covers exactly width × height pixels
        let all = try XCTUnwrap(DICOMModel.roiPixelBounds(rawRect: CGRect(x: 0, y: 0, width: 64, height: 64),
                                                         width: 64, height: 64))
        XCTAssertEqual(all.x.count * all.y.count, 64 * 64)
    }

    // MARK: - Cache hits need meta and a pixel source

    func testDisplayOnlyCacheHitIsAMiss() {
        XCTAssertFalse(DICOMModel.isUsableCacheHit(hasMeta: false, hasRaw: false, hasDCMTK: false))
        XCTAssertFalse(DICOMModel.isUsableCacheHit(hasMeta: true, hasRaw: false, hasDCMTK: false))
        XCTAssertFalse(DICOMModel.isUsableCacheHit(hasMeta: false, hasRaw: true, hasDCMTK: true))
        XCTAssertTrue(DICOMModel.isUsableCacheHit(hasMeta: true, hasRaw: true, hasDCMTK: false))
        XCTAssertTrue(DICOMModel.isUsableCacheHit(hasMeta: true, hasRaw: false, hasDCMTK: true))
    }

    // MARK: - Annotation slices key on UIDs

    func testSliceIdentityFollowsUIDsNotIndices() {
        let a = AnnotationSlice(seriesIndex: 0, panelMode: .slice2D, index: 3, frame: 0, slab: 0,
                                seriesUID: "1.2.3", instanceUID: "1.2.3.7")
        let moved = AnnotationSlice(seriesIndex: 2, panelMode: .slice2D, index: 5, frame: 0, slab: 0,
                                    seriesUID: "1.2.3", instanceUID: "1.2.3.7")
        let other = AnnotationSlice(seriesIndex: 0, panelMode: .slice2D, index: 3, frame: 0, slab: 0,
                                    seriesUID: "1.2.3", instanceUID: "1.2.3.8")
        XCTAssertEqual(a, moved, "the same image after the series list re-sorted")
        XCTAssertEqual(a.hashValue, moved.hashValue)
        XCTAssertNotEqual(a, other, "another image now at the same index")
    }

    func testMIPSliceIdentityIncludesProjectionMode() {
        let mip = AnnotationSlice(seriesIndex: 0, panelMode: .mip, index: 40, frame: 0, slab: 10,
                                  seriesUID: "1.2.3", projectionMode: .mip)
        let minip = AnnotationSlice(seriesIndex: 0, panelMode: .mip, index: 40, frame: 0, slab: 10,
                                    seriesUID: "1.2.3", projectionMode: .minip)
        XCTAssertNotEqual(mip, minip)
    }

    private func context(_ i: Int) -> DicomImageContext {
        DicomImageContext(
            url: URL(fileURLWithPath: "/tmp/img\(i).dcm"),
            sopInstanceUID: "1.2.\(i)", seriesUID: "1.2.3", seriesDescription: "t",
            instanceNumber: i, seriesNumber: 1,
            zLocation: Double(i), imagePosition: SIMD3(0, 0, Double(i)), imageOrientation: [1, 0, 0, 0, 1, 0],
            pixelSpacing: SIMD2(1, 1), sliceThickness: 1, spacingBetweenSlices: nil,
            frameOfReferenceUID: "1.2.840.1", studyInstanceUID: "1.2", numberOfFrames: 1)
    }

    @MainActor
    func testPanelSliceSurvivesASeriesListReorder() {
        let model = DICOMModel()
        let panel = model.panels[0]
        let other = DicomSeries(id: "9.9", seriesNumber: 0, seriesDescription: "o", images: [context(9)])
        let target = DicomSeries(id: "1.2.3", seriesNumber: 1, seriesDescription: "t",
                                 images: [context(0), context(1)])
        model.allSeries = [target]
        panel.seriesIndex = 0
        panel.imageIndex = 1
        let bound = panel.currentSlice
        XCTAssertEqual(bound.instanceUID, "1.2.1")

        // A scan update inserts a series in front; the panel follows its image
        model.allSeries = [other, target]
        panel.seriesIndex = 1
        XCTAssertEqual(panel.currentSlice, bound)
        // ...while whatever now sits at the old indices is a different slice
        panel.seriesIndex = 0
        panel.imageIndex = 0
        XCTAssertNotEqual(panel.currentSlice, bound)
    }

    // MARK: - Multi-frame panels drop the previous image's pixel state

    @MainActor
    func testApplyingAMultiFrameDecoderResetsStalePixelState() throws {
        var spec = S.ImageSpec(rows: 3, columns: 2)
        spec.numberOfFrames = 2
        let url = try S.writeTemp(S.image(spec, pixelBytes: S.le16([1, 2, 3, 4, 5, 6, 1, 2, 3, 4, 5, 6])),
                                  name: "review-cine.dcm")
        let decoder = try XCTUnwrap(MultiFrameDecoder(url: url))
        let model = DICOMModel()
        let panel = PanelState()
        // Leftovers from a CT shown before
        panel.rawPixelData = Data(count: 512 * 512 * 2)
        panel.imageWidth = 512
        panel.imageHeight = 512
        panel.bitDepth = 16
        panel.isSigned = true
        panel.tags = try SimpleDicomParser(data: S.image(S.ImageSpec(), pixelBytes: S.le16(Array(repeating: 0, count: 16))))
            .parse(stopAtPixelData: true).0
        XCTAssertFalse(panel.tags.isEmpty)

        model.applyMultiFrameDecoder(decoder, to: panel)

        XCTAssertNil(panel.rawPixelData)
        XCTAssertNil(panel.dcmtkImage)
        XCTAssertEqual(panel.imageWidth, 2)
        XCTAssertEqual(panel.imageHeight, 3)
        XCTAssertEqual(panel.bitDepth, 16)
        XCTAssertFalse(panel.isSigned)
        XCTAssertTrue(panel.tags.isEmpty, "stale CT tags are dropped until the cine's header is read")
        XCTAssertTrue(panel.isMultiFrame)
    }
}
