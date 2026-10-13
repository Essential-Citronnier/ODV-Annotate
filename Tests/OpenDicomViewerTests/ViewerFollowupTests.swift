// ViewerFollowupTests.swift
// OpenDicomViewer Tests
//
// Gantry-tilt shear correction, full-precision decoding of fractional
// rescale data (PET), the readout of GPU-rendered projections, and
// slice-bound manual measurements.
// Licensed under the MIT License. See LICENSE for details.

import XCTest
import simd
import DCMTKWrapper
@testable import OpenDicomViewer

final class ViewerFollowupTests: XCTestCase {

    // MARK: - Helpers

    private func makeVolume(width: Int, height: Int, depth: Int,
                            spacing: SIMD3<Double> = SIMD3(1, 1, 1),
                            sliceDirection: SIMD3<Double>? = nil,
                            slope: Double = 1, intercept: Double = 0,
                            fill: (Int, Int, Int) -> Int16) -> VolumeData {
        let buffer = UnsafeMutableBufferPointer<Int16>.allocate(capacity: width * height * depth)
        for z in 0..<depth { for y in 0..<height { for x in 0..<width {
            buffer[z * width * height + y * width + x] = fill(x, y, z)
        } } }
        return VolumeData(voxels: buffer, width: width, height: height, depth: depth,
                          spacingX: spacing.x, spacingY: spacing.y, spacingZ: spacing.z,
                          origin: .zero, rowDirection: SIMD3(1, 0, 0), colDirection: SIMD3(0, 1, 0),
                          sliceDirection: sliceDirection,
                          rescaleSlope: slope, rescaleIntercept: intercept, seriesUID: "t")
    }

    private func context(_ i: Int, url: URL, position: SIMD3<Double>, seriesUID: String) -> DicomImageContext {
        DicomImageContext(
            url: url, sopInstanceUID: "1.2.\(i)", seriesUID: seriesUID, seriesDescription: "t",
            instanceNumber: i, seriesNumber: 1,
            zLocation: position.z, imagePosition: position, imageOrientation: [1, 0, 0, 0, 1, 0],
            pixelSpacing: SIMD2(1, 1), sliceThickness: 1, spacingBetweenSlices: nil,
            frameOfReferenceUID: "1.2.840.1", studyInstanceUID: "1.2", numberOfFrames: 1)
    }

    /// Write a series of 16-bit synthetic slices and return it with contexts
    /// at the given positions.
    private func writeSeries(positions: [SIMD3<Double>], rows: Int = 4, columns: Int = 4,
                             spec: SyntheticDICOM.ImageSpec = .init(),
                             pixels: (Int) -> [Int]) throws -> DicomSeries {
        let uid = "1.2.3.\(UUID().uuidString.prefix(8).unicodeScalars.map { String($0.value % 10) }.joined())"
        var images: [DicomImageContext] = []
        for (i, p) in positions.enumerated() {
            var s = spec
            s.rows = rows; s.columns = columns
            let data = SyntheticDICOM.image(s, pixelBytes: SyntheticDICOM.le16(pixels(i)))
            let url = try SyntheticDICOM.writeTemp(data, name: "slice\(i).dcm")
            images.append(context(i, url: url, position: p, seriesUID: uid))
        }
        return DicomSeries(id: uid, seriesNumber: 1, seriesDescription: "t", images: images)
    }

    private func buildVolume(_ series: DicomSeries) throws -> VolumeData {
        try VolumeBuilder.build(series: series, rawDataCache: NSCache(), dcmtkCache: NSCache())
    }

    // MARK: - Gantry tilt (item 2)

    func testGantryTiltIsResampledOntoOrthogonalGrid() {
        // Each slice is 2 mm further along z and shifted 0.5 mm along y
        // (~14° tilt). Voxels hold 10 × world y, a field that is linear in
        // patient space, so a correct resampling reproduces it exactly.
        let step = SIMD3<Double>(0, 0.5, 2)
        let w = 6, h = 8, d = 5
        let sheared = makeVolume(width: w, height: h, depth: d,
                                 spacing: SIMD3(1, 1, simd_length(step)),
                                 sliceDirection: simd_normalize(step)) { _, y, z in
            Int16((Double(y) + Double(z) * step.y) * 10)
        }
        let worldOfSourceVoxel = sheared.voxelToWorld(SIMD3(3, 4, 2))
        let corrected = VolumeBuilder.correctGantryTilt(sheared)

        // Orthonormal affine stacked along the slice normal, 2 mm apart
        XCTAssertEqual(corrected.sliceDirection.z, 1, accuracy: 1e-9)
        XCTAssertEqual(corrected.spacingZ, 2, accuracy: 1e-9)
        XCTAssertEqual(corrected.depth, d)
        // The grid grows to hold every shifted slice: 4 × 0.5 mm = 2 extra rows
        XCTAssertEqual(corrected.width, w)
        XCTAssertEqual(corrected.height, h + 2)

        // Same patient space: a source voxel maps to the same world point
        let v = corrected.worldToVoxel(worldOfSourceVoxel)
        XCTAssertEqual(v.z, 2, accuracy: 1e-9)
        XCTAssertEqual(corrected.calibratedValue(x: Int(v.x.rounded()), y: Int(v.y.rounded()), z: 2),
                       sheared.calibratedValue(x: 3, y: 4, z: 2), accuracy: 1)

        var covered = 0
        for z in 0..<corrected.depth { for y in 0..<corrected.height { for x in 0..<corrected.width {
            let world = corrected.voxelToWorld(SIMD3(Double(x), Double(y), Double(z)))
            let src = sheared.worldToVoxel(world)
            let inside = src.y >= -1e-6 && src.y <= Double(h - 1) + 1e-6
            if inside {
                covered += 1
                XCTAssertEqual(corrected.calibratedValue(x: x, y: y, z: z), (world.y * 10).rounded(), accuracy: 1,
                               "voxel (\(x), \(y), \(z))")
            } else {
                // Uncovered corners are padded with the volume minimum
                XCTAssertEqual(corrected.voxelAt(x: x, y: y, z: z), 0)
            }
        } } }
        // Half-pixel shifts on odd slices leave one fewer fully covered row
        XCTAssertEqual(covered, w * (h * 3 + (h - 1) * 2))

        // Sagittal reformat now follows the normal: IOP is orthonormal
        let g = MPREngine(volume: corrected).sagittalGeometry(at: 2)
        XCTAssertEqual(simd_dot(g.rowDir, g.colDir), 0, accuracy: 1e-9)
    }

    func testVolumeBuildCorrectsGantryTiltAndReportsIt() throws {
        let step = SIMD3<Double>(0, 0.5, 2)
        let series = try writeSeries(positions: (0..<5).map { Double($0) * step }) { _ in
            Array(repeating: 100, count: 16)
        }
        let volume = try buildVolume(series)
        XCTAssertEqual(volume.sliceDirection.z, 1, accuracy: 1e-9)
        XCTAssertEqual(volume.spacingZ, 2, accuracy: 1e-9)
        XCTAssertEqual(volume.height, 6)
        XCTAssertTrue(volume.warnings.contains { $0.contains("tilt") && $0.contains("resampled") }, "\(volume.warnings)")
    }

    func testUntiltedVolumeIsNotResampled() throws {
        let series = try writeSeries(positions: (0..<4).map { SIMD3(0, 0, Double($0) * 3) }) { i in
            Array(repeating: i * 10, count: 16)
        }
        let volume = try buildVolume(series)
        XCTAssertEqual(volume.width, 4); XCTAssertEqual(volume.height, 4)
        XCTAssertTrue(volume.warnings.isEmpty, "\(volume.warnings)")
        XCTAssertEqual(volume.calibratedValue(x: 1, y: 1, z: 3), 30)
    }

    // MARK: - Fractional rescale precision (item 3)

    private var petSpec: SyntheticDICOM.ImageSpec {
        var spec = SyntheticDICOM.ImageSpec()
        spec.rows = 2; spec.columns = 2
        spec.rescaleSlope = "0.001"
        spec.rescaleIntercept = "0"
        return spec
    }

    func testPlainDecoderKeepsFractionalValuesAsFloat() {
        var a = DicomPixelAttributes()
        a.rows = 1; a.columns = 3
        a.rescaleSlope = 0.001
        let decoded = PlainPixelDecoder.decode(pixelData: SyntheticDICOM.le16([1234, 5678, 0]), attributes: a, bigEndian: false)!
        XCTAssertEqual(decoded.bitDepth, PixelValues.floatBits)
        XCTAssertEqual(PixelValues.value(in: decoded.data, index: 0, bits: decoded.bitDepth, isSigned: decoded.isSigned)!, 1.234, accuracy: 1e-6)
        XCTAssertEqual(PixelValues.value(in: decoded.data, index: 1, bits: decoded.bitDepth, isSigned: decoded.isSigned)!, 5.678, accuracy: 1e-6)
    }

    func testDCMTKDecodeKeepsFractionalRescale() throws {
        let data = SyntheticDICOM.image(petSpec, pixelBytes: SyntheticDICOM.le16([1234, 5678, 0, 65535]))
        let url = try SyntheticDICOM.writeTemp(data, name: "pet.dcm")
        let obj = try XCTUnwrap(DCMTKImageObject(path: url.path))
        var w = 0, h = 0, bits = 0, spp = 0
        var signed: ObjCBool = false
        let raw = try XCTUnwrap(obj.getRawDataWidth(&w, height: &h, bitDepth: &bits, samples: &spp, isSigned: &signed))
        XCTAssertEqual(bits, PixelValues.floatBits)
        let values = (0..<4).map { PixelValues.value(in: raw, index: $0, bits: bits, isSigned: signed.boolValue)! }
        XCTAssertEqual(values[0], 1.234, accuracy: 1e-5)
        XCTAssertEqual(values[1], 5.678, accuracy: 1e-5)
        XCTAssertEqual(values[3], 65.535, accuracy: 1e-4)
        // Display still renders with a modality-unit window
        XCTAssertNotNil(obj.renderImage(withWidth: 0, height: 0, ww: 10, wc: 5))
    }

    func testIntegerRescaleStaysInteger() throws {
        // CT: slope 1, intercept −1024 must keep the 16-bit integer path (memory)
        var spec = SyntheticDICOM.ImageSpec()
        spec.rows = 2; spec.columns = 2
        spec.rescaleSlope = "1"; spec.rescaleIntercept = "-1024"
        let url = try SyntheticDICOM.writeTemp(SyntheticDICOM.image(spec, pixelBytes: SyntheticDICOM.le16([0, 1024, 2048, 100])), name: "ct.dcm")
        let obj = try XCTUnwrap(DCMTKImageObject(path: url.path))
        var w = 0, h = 0, bits = 0, spp = 0
        var signed: ObjCBool = false
        let raw = try XCTUnwrap(obj.getRawDataWidth(&w, height: &h, bitDepth: &bits, samples: &spp, isSigned: &signed))
        XCTAssertEqual(bits, 16)
        XCTAssertEqual(PixelValues.value(in: raw, index: 0, bits: bits, isSigned: signed.boolValue), -1024)
        XCTAssertEqual(PixelValues.value(in: raw, index: 2, bits: bits, isSigned: signed.boolValue), 1024)
    }

    func testAssembleEncodesFractionalSlicesWithFineSlope() throws {
        func floats(_ v: [Float]) -> Data { v.withUnsafeBufferPointer { Data(buffer: $0) } }
        let slices: [VolumeBuilder.SliceRaw] = [
            .init(data: floats([0, 1.234]), width: 2, height: 1, bits: PixelValues.floatBits, isSigned: true),
            .init(data: floats([5.678, 20]), width: 2, height: 1, bits: PixelValues.floatBits, isSigned: true),
        ]
        let (voxels, slope, intercept, mismatched) = try VolumeBuilder.assemble(width: 2, height: 1, depth: 2) { slices[$0] }
        defer { voxels.deallocate() }
        XCTAssertTrue(mismatched.isEmpty)
        XCTAssertLessThan(slope, 0.001)
        func value(_ i: Int) -> Double { Double(voxels[i]) * slope + intercept }
        XCTAssertEqual(value(1), 1.234, accuracy: slope)
        XCTAssertEqual(value(2), 5.678, accuracy: slope)
        XCTAssertEqual(value(3), 20, accuracy: slope)
    }

    func testPETVolumeAndReformatsKeepPrecision() throws {
        let series = try writeSeries(positions: (0..<3).map { SIMD3(0, 0, Double($0) * 2) },
                                     rows: 2, columns: 2, spec: petSpec) { i in
            [1234 + i, 5678, 0, 250]
        }
        let volume = try buildVolume(series)
        XCTAssertEqual(volume.calibratedValue(x: 0, y: 0, z: 1), 1.235, accuracy: volume.rescaleSlope)
        XCTAssertEqual(volume.calibratedValue(x: 1, y: 1, z: 2), 0.25, accuracy: volume.rescaleSlope)
        // Reformat consumers (readout, ROI stats) get Float32 modality values
        let slice = try XCTUnwrap(MPREngine(volume: volume).coronalSlice(at: 0))
        let px = slice.modalityPixels
        XCTAssertEqual(px.bits, PixelValues.floatBits)
        let v = PixelValues.value(in: px.data, index: 0, bits: px.bits, isSigned: px.isSigned)!
        XCTAssertNotEqual(v, v.rounded())
    }

    func testROIStatsUseFloatPixels() {
        let model = DICOMModel()
        let panel = PanelState()
        let values: [Float] = [1.5, 2.5, 3.5, 4.5]
        panel.rawPixelData = values.withUnsafeBufferPointer { Data(buffer: $0) }
        panel.bitDepth = PixelValues.floatBits
        panel.isSigned = true
        panel.imageWidth = 2; panel.imageHeight = 2
        let stats = model.computeROIStats(panel: panel, rect: CGRect(x: 0, y: 0, width: 2, height: 2))
        XCTAssertEqual(stats?.mean ?? 0, 3, accuracy: 1e-9)
        XCTAssertEqual(stats?.min ?? 0, 1.5, accuracy: 1e-9)
        XCTAssertEqual(stats?.max ?? 0, 4.5, accuracy: 1e-9)
        XCTAssertEqual(PixelValues.format(1.2345), "1.234")
        XCTAssertEqual(PixelValues.format(-1024), "-1024")
    }

    // MARK: - Projection readout (item 5)

    func testSlabProjectionValueMatchesProjectionForEveryMode() {
        // Encoded volume (slope 2, intercept −10) so readouts must decode
        let vol = makeVolume(width: 3, height: 2, depth: 7, slope: 2, intercept: -10) { x, y, z in
            Int16((z * 7 + x * 3 + y * 5) % 11)
        }
        let engine = MPREngine(volume: vol)
        for mode in ProjectionMode.allCases {
            let proj = engine.axialSlabProjection(mode: mode, slabCenter: 3, slabThickness: 4)!
            let px = proj.modalityPixels
            for y in 0..<2 { for x in 0..<3 {
                let readout = engine.slabProjectionValue(mode: mode, x: x, y: y, slabCenter: 3, slabThickness: 4)!
                let shown = PixelValues.value(in: px.data, index: y * 3 + x, bits: px.bits, isSigned: px.isSigned)!
                // Average is rounded to stored units in the projection image
                XCTAssertEqual(readout, shown, accuracy: mode == .average ? vol.rescaleSlope : 1e-9, "\(mode) (\(x), \(y))")
            } }
        }
        // MIP picks the brightest voxel on the ray: slices 1...5 at (0, 0)
        let expected = (1...5).map { Double(($0 * 7) % 11) }.max()! * 2 - 10
        XCTAssertEqual(engine.slabProjectionValue(mode: .mip, x: 0, y: 0, slabCenter: 3, slabThickness: 4), expected)
        XCTAssertNil(engine.slabProjectionValue(mode: .mip, x: 3, y: 0, slabCenter: 3, slabThickness: 4))
    }

    func testGPUProjectionReadoutAndModeAreKept() throws {
        let series = try writeSeries(positions: (0..<5).map { SIMD3(0, 0, Double($0)) }) { z in
            (0..<16).map { $0 == 5 ? 100 * (z + 1) : z }
        }
        let model = DICOMModel()
        model.allSeries = [series]
        let built = expectation(description: "volume")
        model.getVolume(for: 0) { volume, _ in
            XCTAssertNotNil(volume)
            built.fulfill()
        }
        wait(for: [built], timeout: 30)

        let panel = PanelState()
        panel.seriesIndex = 0
        panel.panelMode = .mip
        panel.mipSlabPosition = 2
        panel.mipSlabThickness = 5
        model.loadMIPForPanel(panel, mode: .minip)
        XCTAssertEqual(panel.projectionMode, .minip)
        // Scrolling / W/L re-renders call without a mode and must keep it
        model.loadMIPForPanel(panel)
        XCTAssertEqual(panel.projectionMode, .minip)

        // Readout as on a GPU-rendered panel (no CPU pixel buffer)
        panel.rawPixelData = nil
        XCTAssertEqual(model.projectionReadout(for: panel, x: 1, y: 1), 100) // MinIP over slices 0...4
        panel.projectionMode = .mip
        XCTAssertEqual(model.projectionReadout(for: panel, x: 1, y: 1), 500) // brightest voxel on the ray
        XCTAssertEqual(model.projectionReadout(for: panel, x: 0, y: 0), 4)
        // ROI stats fall back to the projection computed from the volume
        let stats = model.computeROIStats(panel: panel, rect: CGRect(x: 0, y: 0, width: 3, height: 3))
        XCTAssertEqual(stats?.max, 500)
        // Geometry notices reach the panel (none for this clean series)
        XCTAssertTrue(panel.volumeWarnings.isEmpty)
    }

    // MARK: - Slice-bound measurements (item 6)

    func testManualMeasurementsAreBoundToTheirSlice() {
        let model = DICOMModel()
        let panel = PanelState()
        panel.seriesIndex = 0
        panel.imageIndex = 3
        panel.addMeasurement(.ruler(start: .zero, end: CGPoint(x: 5, y: 0), distanceMM: 5))
        panel.addMeasurement(.roiStats(rect: CGRect(x: 1, y: 1, width: 4, height: 4),
                                       mean: 0, max: 0, min: 0, stdDev: 0, count: 16))
        XCTAssertEqual(panel.annotations.first?.slice, panel.currentSlice)
        XCTAssertEqual(panel.visibleAnnotations.count, 2)
        XCTAssertEqual(model.latestROIForAIDescription(in: panel), CGRect(x: 1, y: 1, width: 4, height: 4))

        // Another slice: nothing from slice 3 shows, Describe ROI has no target
        panel.imageIndex = 4
        XCTAssertTrue(panel.visibleAnnotations.isEmpty)
        XCTAssertNil(model.latestROIForAIDescription(in: panel))
        panel.addMeasurement(.angle(vertex: .zero, arm1: CGPoint(x: 1, y: 0), arm2: CGPoint(x: 0, y: 1), degrees: 90))
        XCTAssertEqual(panel.visibleAnnotations.count, 1)

        // Back on slice 3, its measurements return; the latest ROI there wins
        panel.imageIndex = 3
        panel.addMeasurement(.roiStats(rect: CGRect(x: 2, y: 2, width: 3, height: 3),
                                       mean: 0, max: 0, min: 0, stdDev: 0, count: 9))
        XCTAssertEqual(panel.visibleAnnotations.count, 3)
        XCTAssertEqual(model.latestROIForAIDescription(in: panel), CGRect(x: 2, y: 2, width: 3, height: 3))

        // MPR slices are distinct from the 2D image with the same index
        panel.panelMode = .mprCoronal
        panel.mprSliceIndex = 3
        XCTAssertTrue(panel.visibleAnnotations.isEmpty)
    }

    func testAssembleBlanksAMinorityOfMismatchedSlices() throws {
        let slices: [VolumeBuilder.SliceRaw] = [
            .init(data: SyntheticDICOM.le16([1, 2]), width: 2, height: 1, bits: 16, isSigned: true),
            .init(data: SyntheticDICOM.le16([1, 2, 3]), width: 3, height: 1, bits: 16, isSigned: true),
            .init(data: SyntheticDICOM.le16([5, 6]), width: 2, height: 1, bits: 16, isSigned: true),
        ]
        let (voxels, _, _, mismatched) = try VolumeBuilder.assemble(width: 2, height: 1, depth: 3) { slices[$0] }
        defer { voxels.deallocate() }
        XCTAssertEqual(mismatched, [1])
        XCTAssertEqual(Array(voxels), [1, 2, 0, 0, 5, 6])
    }
}
