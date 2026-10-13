// ViewerCoreGeometryTests.swift
// OpenDicomViewer Tests
//
// Pixel ↔ display mapping for aspect-corrected MPR images, cross-reference
// plane intersection, average slab accumulation, normal-based slice sync,
// and volume geometry validation / caching.
// Licensed under the MIT License. See LICENSE for details.

import XCTest
import simd
@testable import OpenDicomViewer

final class ViewerCoreGeometryTests: XCTestCase {

    // MARK: - Helpers

    private func makeVolume(width: Int, height: Int, depth: Int,
                            spacing: SIMD3<Double> = SIMD3(1, 1, 1),
                            fill: (Int, Int, Int) -> Int16) -> VolumeData {
        let buffer = UnsafeMutableBufferPointer<Int16>.allocate(capacity: width * height * depth)
        for z in 0..<depth { for y in 0..<height { for x in 0..<width {
            buffer[z * width * height + y * width + x] = fill(x, y, z)
        } } }
        return VolumeData(voxels: buffer, width: width, height: height, depth: depth,
                          spacingX: spacing.x, spacingY: spacing.y, spacingZ: spacing.z,
                          origin: .zero, rowDirection: SIMD3(1, 0, 0), colDirection: SIMD3(0, 1, 0),
                          rescaleSlope: 1, rescaleIntercept: 0, seriesUID: "t")
    }

    private func context(_ i: Int, position: SIMD3<Double>, orientation: [Double] = [1, 0, 0, 0, 1, 0],
                         instance: Int? = nil, path: String? = nil) -> DicomImageContext {
        DicomImageContext(
            url: URL(fileURLWithPath: path ?? "/tmp/img\(i).dcm"),
            sopInstanceUID: "1.2.\(i)", seriesUID: "1.2.3", seriesDescription: "t",
            instanceNumber: instance ?? i, seriesNumber: 1,
            zLocation: position.z, imagePosition: position, imageOrientation: orientation,
            pixelSpacing: SIMD2(1, 1), sliceThickness: 1, spacingBetweenSlices: nil,
            frameOfReferenceUID: "1.2.840.1", studyInstanceUID: "1.2", numberOfFrames: 1)
    }

    // MARK: - Item 3: one pixel ↔ display mapping

    func testMappingConvertsAspectCorrectedDisplayToRawRows() {
        // Sagittal reformat: 4 columns (1 mm) × 10 rows (3 mm slices).
        let vol = makeVolume(width: 2, height: 4, depth: 10, spacing: SIMD3(1, 1, 3)) { _, _, z in Int16(z * 100) }
        let slice = MPREngine(volume: vol).sagittalSlice(at: 0)!
        let image = MPREngine.renderSlice(slice, ww: 2000, wc: 500)!
        // NSImage height is aspect corrected (4 px wide → 30 mm / 4 mm × 4 = 30 display rows)
        XCTAssertEqual(image.size.width, 4, accuracy: 1e-9)
        XCTAssertEqual(image.size.height, 30, accuracy: 1e-9)

        let mapping = PixelDisplayMapping(rawWidth: slice.width, rawHeight: slice.height,
                                          displayWidth: image.size.width, displayHeight: image.size.height)
        // A display point 15 rows down is raw row 5
        XCTAssertEqual(mapping.rawPixelIndex(CGPoint(x: 1.5, y: 15.2))?.y, 5)
        XCTAssertEqual(mapping.rawPixelIndex(CGPoint(x: 1.5, y: 15.2))?.x, 1)
        // Ruler from top to bottom of the image: 10 rows × 3 mm, not 30 display px × 3 mm
        let length = mapping.distance(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: 30),
                                      pixelSpacing: slice.dicomPixelSpacing)
        XCTAssertEqual(length, 30, accuracy: 1e-9)
        // Horizontal ruler is unaffected
        XCTAssertEqual(mapping.distance(from: .zero, to: CGPoint(x: 4, y: 0), pixelSpacing: slice.dicomPixelSpacing), 4, accuracy: 1e-9)
        // 45° in physical space
        let deg = mapping.angle(vertex: .zero, arm1: CGPoint(x: 3, y: 0), arm2: CGPoint(x: 3, y: 3),
                                pixelSpacing: slice.dicomPixelSpacing)
        XCTAssertEqual(deg, 45, accuracy: 1e-9)
        // Round trip
        let p = CGPoint(x: 2, y: 7)
        XCTAssertEqual(mapping.displayToRaw(mapping.rawToDisplay(p)).y, 7, accuracy: 1e-9)
    }

    func testCrossReferenceIsReturnedInDisplaySpace() {
        // Display panel: sagittal reformat with 3 mm rows shown aspect-corrected
        let vol = makeVolume(width: 4, height: 8, depth: 10, spacing: SIMD3(1, 1, 3)) { _, _, _ in 0 }
        let engine = MPREngine(volume: vol)
        let slice = engine.sagittalSlice(at: 2)!
        let image = MPREngine.renderSlice(slice, ww: 100, wc: 0)!

        let display = PanelState()
        display.setDisplayImage(image)
        display.imageWidth = slice.width
        display.imageHeight = slice.height
        let o = slice.planeOrigin
        display.imagePositionPatient = (o.x, o.y, o.z)
        display.imageOrientationPatient = slice.imageOrientationPatient
        display.pixelSpacing = slice.dicomPixelSpacing

        // Source panel: axial plane at slice index 3 (z = 9 mm)
        let source = PanelState()
        let axial = engine.axialGeometry(at: 3)
        source.imagePositionPatient = (axial.origin.x, axial.origin.y, axial.origin.z)
        source.imageOrientationPatient = [1, 0, 0, 0, 1, 0]
        source.pixelSpacing = (1, 1)

        let line = CrossReferenceOverlay.computeCrossReference(displayPanel: display, sourcePanel: source)
        XCTAssertNotNil(line)
        // Z flipped: slice 3 of 10 is raw row 6 → display row 6 × (30/10)... display height = 8 × 30/8 = 30
        let expectedDisplayY = 6.0 * Double(image.size.height) / Double(slice.height)
        XCTAssertEqual(Double(line!.startPixel.y), expectedDisplayY, accuracy: 1e-6)
        XCTAssertEqual(Double(line!.endPixel.y), expectedDisplayY, accuracy: 1e-6)
    }

    // MARK: - Item 11: oblique planes and frame of reference

    func testObliqueCrossReferenceUsesTruePlaneIntersection() {
        // A: axial at z = 0, 100×100, 1 mm. B: tilted 45° about x, through (0, 50, 10).
        // Intersection with z = 0: y = 40 (projecting B's origin would wrongly give y = 50).
        let s = 0.5.squareRoot()
        let line = CrossReferenceOverlay.intersectionInPixels(
            originA: .zero, rowA: SIMD3(1, 0, 0), colA: SIMD3(0, 1, 0),
            pixelSpacingA: (1, 1), widthA: 100, heightA: 100,
            originB: SIMD3(0, 50, 10), rowB: SIMD3(1, 0, 0), colB: SIMD3(0, s, s))
        XCTAssertNotNil(line)
        XCTAssertEqual(Double(line!.startPixel.y), 40, accuracy: 1e-6)
        XCTAssertEqual(Double(line!.endPixel.y), 40, accuracy: 1e-6)
        XCTAssertEqual(abs(Double(line!.endPixel.x - line!.startPixel.x)), 100, accuracy: 1e-6)
    }

    func testDiagonalCrossReferenceClipsToImage() {
        // B: vertical plane x = y. Intersection is the image diagonal.
        let s = 0.5.squareRoot()
        let line = CrossReferenceOverlay.intersectionInPixels(
            originA: .zero, rowA: SIMD3(1, 0, 0), colA: SIMD3(0, 1, 0),
            pixelSpacingA: (0.5, 0.5), widthA: 200, heightA: 200,
            originB: SIMD3(20, 20, -5), rowB: SIMD3(s, s, 0), colB: SIMD3(0, 0, 1))!
        let pts = [line.startPixel, line.endPixel].sorted { $0.x < $1.x }
        XCTAssertEqual(Double(pts[0].x), 0, accuracy: 1e-6); XCTAssertEqual(Double(pts[0].y), 0, accuracy: 1e-6)
        XCTAssertEqual(Double(pts[1].x), 200, accuracy: 1e-6); XCTAssertEqual(Double(pts[1].y), 200, accuracy: 1e-6)
    }

    func testCrossReferenceParallelAndDifferentFrameOfReferenceReturnNil() {
        XCTAssertNil(CrossReferenceOverlay.intersectionInPixels(
            originA: .zero, rowA: SIMD3(1, 0, 0), colA: SIMD3(0, 1, 0), pixelSpacingA: (1, 1), widthA: 10, heightA: 10,
            originB: SIMD3(0, 0, 5), rowB: SIMD3(1, 0, 0), colB: SIMD3(0, 1, 0)))

        let a = PanelState(), b = PanelState()
        for p in [a, b] { p.imageWidth = 10; p.imageHeight = 10; p.pixelSpacing = (1, 1) }
        a.imagePositionPatient = (0, 0, 0); a.imageOrientationPatient = [1, 0, 0, 0, 1, 0]
        b.imagePositionPatient = (5, 0, 0); b.imageOrientationPatient = [0, 1, 0, 0, 0, -1]
        XCTAssertNotNil(CrossReferenceOverlay.computeCrossReference(displayPanel: a, sourcePanel: b,
                                                                    displayFrameOfReference: "1.2.3", sourceFrameOfReference: "1.2.3"))
        XCTAssertNil(CrossReferenceOverlay.computeCrossReference(displayPanel: a, sourcePanel: b,
                                                                 displayFrameOfReference: "1.2.3", sourceFrameOfReference: "9.9.9"))
    }

    // MARK: - MPR plane geometry follows the Z flip

    func testSagittalPlaneOriginMatchesFlippedRows() {
        let vol = makeVolume(width: 3, height: 4, depth: 5, spacing: SIMD3(1, 1, 2)) { x, y, z in Int16(z) }
        let engine = MPREngine(volume: vol)
        let slice = engine.sagittalSlice(at: 1)!
        // Row 0 shows the last slice (z = 4 → 8 mm) and rows advance toward -z
        XCTAssertEqual(slice.planeOrigin.z, 8, accuracy: 1e-9)
        XCTAssertEqual(slice.planeColDir.z, -1, accuracy: 1e-9)
        let top = slice.pixelData.withUnsafeBytes { $0.load(as: Int16.self) }
        XCTAssertEqual(top, 4)
    }

    // MARK: - Item 7: average slab

    func testAverageSlabDoesNotOverflowInt16() {
        let vol = makeVolume(width: 2, height: 2, depth: 5) { _, _, _ in 30000 }
        let slab = MPREngine(volume: vol).axialSlabProjection(mode: .average, slabCenter: 2, slabThickness: 4)!
        let values = slab.pixelData.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        XCTAssertEqual(values, [30000, 30000, 30000, 30000])
    }

    func testAverageSlabOfMixedSignsRounds() {
        let vol = makeVolume(width: 1, height: 1, depth: 3) { _, _, z in [-1000, 20000, 20001][z] }
        let slab = MPREngine(volume: vol).axialSlabProjection(mode: .average, slabCenter: 1, slabThickness: 2)!
        let v = slab.pixelData.withUnsafeBytes { $0.load(as: Int16.self) }
        XCTAssertEqual(v, 13000)
    }

    // MARK: - Item 10: normal-based volumetric detection and sync

    func testSagittalStackIsVolumetric() {
        // Sagittal stack: IPP.z constant, x varies; orientation row = y, col = -z
        let images = (0..<12).map { context($0, position: SIMD3(Double($0) * 1.5, 0, 100), orientation: [0, 1, 0, 0, 0, -1]) }
        XCTAssertTrue(SliceSync.isVolumetric(images))
        // A single position repeated isn't
        let flat = (0..<12).map { context($0, position: SIMD3(5, 0, 100), orientation: [0, 1, 0, 0, 0, -1]) }
        XCTAssertFalse(SliceSync.isVolumetric(flat))
    }

    func testClosestImageUsesSliceNormal() {
        let images = (0..<12).map { context($0, position: SIMD3(Double($0) * 2, 0, 100), orientation: [0, 1, 0, 0, 0, -1]) }
        // A point at x = 9.1 is nearest the image at x = 10 (index 5); z is irrelevant
        XCTAssertEqual(SliceSync.closestImageIndex(to: SIMD3(9.1, 37, -50), in: images), 5)
        XCTAssertEqual(SliceSync.closestImageIndex(to: SIMD3(-3, 0, 0), in: images), 0)
    }

    // MARK: - Item 6: 32-bit values in the volume

    func testAssembleKeepsWideRangeValuesViaEncoding() throws {
        let w = 2, h = 1
        let slices: [VolumeBuilder.SliceRaw] = [
            .init(data: SyntheticDICOM.le32([0, 100_000]), width: w, height: h, bits: 32, isSigned: true),
            .init(data: SyntheticDICOM.le16([-1000, 500]), width: w, height: h, bits: 16, isSigned: true),
        ]
        let (voxels, slope, intercept) = try VolumeBuilder.assemble(width: w, height: h, depth: 2) { slices[$0] }
        defer { voxels.deallocate() }
        func value(_ i: Int) -> Double { Double(voxels[i]) * slope + intercept }
        XCTAssertGreaterThan(slope, 1)
        XCTAssertEqual(value(1), 100_000, accuracy: slope)
        XCTAssertEqual(value(0), 0, accuracy: slope)
        XCTAssertEqual(value(2), -1000, accuracy: slope)
        XCTAssertEqual(value(3), 500, accuracy: slope)
    }

    func testAssembleIsIdentityWhenValuesFitInt16() throws {
        let slices: [VolumeBuilder.SliceRaw] = [
            .init(data: SyntheticDICOM.le32([-1024, 3071]), width: 2, height: 1, bits: 32, isSigned: true),
            .init(data: Data([7, 200]), width: 2, height: 1, bits: 8, isSigned: false),
        ]
        let (voxels, slope, intercept) = try VolumeBuilder.assemble(width: 2, height: 1, depth: 2) { slices[$0] }
        defer { voxels.deallocate() }
        XCTAssertEqual(slope, 1); XCTAssertEqual(intercept, 0)
        XCTAssertEqual(Array(voxels), [-1024, 3071, 7, 200])
    }

    func testAssembleRejectsMismatchedDimensions() {
        let slices: [VolumeBuilder.SliceRaw] = [
            .init(data: SyntheticDICOM.le16([1, 2]), width: 2, height: 1, bits: 16, isSigned: true),
            .init(data: SyntheticDICOM.le16([1, 2, 3]), width: 3, height: 1, bits: 16, isSigned: true),
        ]
        XCTAssertThrowsError(try VolumeBuilder.assemble(width: 2, height: 1, depth: 2) { slices[$0] })
    }

    // MARK: - Item 8: volume geometry validation

    private func series(_ images: [DicomImageContext]) -> DicomSeries {
        DicomSeries(id: "1.2.3", seriesNumber: 1, seriesDescription: "t", images: images)
    }

    func testGeometrySplitsEvenMultiPhaseSeries() throws {
        // 2 phases × 5 positions; phase 2 has higher instance numbers
        var imgs: [DicomImageContext] = []
        for phase in 0..<2 { for z in 0..<5 {
            imgs.append(context(phase * 5 + z, position: SIMD3(0, 0, Double(z) * 2), instance: phase * 100 + z))
        } }
        let geo = try VolumeBuilder.geometry(for: series(imgs.shuffled()))
        XCTAssertEqual(geo.images.count, 5)
        XCTAssertTrue(geo.images.allSatisfy { $0.instanceNumber < 100 })
        XCTAssertEqual(geo.sliceSpacing, 2, accuracy: 1e-9)
        XCTAssertFalse(geo.warnings.isEmpty)
    }

    func testGeometryRefusesUnevenDuplicates() {
        var imgs = (0..<5).map { context($0, position: SIMD3(0, 0, Double($0))) }
        imgs.append(context(9, position: SIMD3(0, 0, 2)))
        XCTAssertThrowsError(try VolumeBuilder.geometry(for: series(imgs))) { error in
            guard case VolumeBuilderError.duplicateSlicePositions = error else { return XCTFail("\(error)") }
        }
    }

    func testGeometryRejectsLargeSpacingGaps() {
        let zs: [Double] = [0, 1, 2, 3, 10, 11, 12]
        let imgs = zs.enumerated().map { context($0.offset, position: SIMD3(0, 0, $0.element)) }
        XCTAssertThrowsError(try VolumeBuilder.geometry(for: series(imgs))) { error in
            guard case VolumeBuilderError.nonUniformSpacing = error else { return XCTFail("\(error)") }
        }
    }

    func testGeometryRejectsMixedOrientation() {
        var imgs = (0..<5).map { context($0, position: SIMD3(0, 0, Double($0))) }
        imgs.append(context(7, position: SIMD3(0, 0, 6), orientation: [0, 1, 0, 0, 0, -1]))
        XCTAssertThrowsError(try VolumeBuilder.geometry(for: series(imgs)))
    }

    func testGeometryFollowsGantryTilt() throws {
        // Positions advance 2 mm in z and 0.35 mm in y per slice (~10° tilt)
        let imgs = (0..<6).map { context($0, position: SIMD3(0, Double($0) * 0.35, Double($0) * 2)) }
        let geo = try VolumeBuilder.geometry(for: series(imgs))
        XCTAssertGreaterThan(geo.stackDirection.y, 0.1)
        XCTAssertEqual(geo.sliceSpacing, simd_length(SIMD3(0, 0.35, 2.0)), accuracy: 1e-6)
        XCTAssertTrue(geo.warnings.contains { $0.contains("tilt") })
    }

    // MARK: - Item 9: volume cache keys and LRU

    func testVolumeCacheKeyDependsOnFileSet() {
        let a = VolumeCacheKey.make(seriesID: "1.2", paths: ["/a/1", "/a/2"])
        XCTAssertEqual(a, VolumeCacheKey.make(seriesID: "1.2", paths: ["/a/2", "/a/1"]))
        XCTAssertNotEqual(a, VolumeCacheKey.make(seriesID: "1.2", paths: ["/a/1", "/a/2", "/a/3"]))
        XCTAssertNotEqual(a, VolumeCacheKey.make(seriesID: "1.2", paths: ["/b/1", "/b/2"]))
    }

    func testVolumeLRUEvictsLeastRecentlyUsed() {
        var cache = VolumeLRUCache(maxEntries: 2, maxBytes: .max)
        let v = { self.makeVolume(width: 2, height: 2, depth: 2) { _, _, _ in 0 } }
        cache.set("a", v()); cache.set("b", v())
        _ = cache.get("a")            // a is now most recent
        cache.set("c", v())
        XCTAssertNotNil(cache.get("a"))
        XCTAssertNil(cache.get("b"))
        XCTAssertNotNil(cache.get("c"))

        var bytes = VolumeLRUCache(maxEntries: 10, maxBytes: 20)  // each volume is 16 bytes
        bytes.set("x", v()); bytes.set("y", v())
        XCTAssertEqual(bytes.count, 1)
        XCTAssertNotNil(bytes.get("y"))
    }
}
