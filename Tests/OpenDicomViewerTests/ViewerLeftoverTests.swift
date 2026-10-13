// ViewerLeftoverTests.swift
// OpenDicomViewer Tests
//
// Units of the value readout and ROI stats per modality, and the slab
// definition shared by the CPU slab projection, the GPU projection and the
// cursor readout of GPU-rendered MIP panels.
// Licensed under the MIT License. See LICENSE for details.

import XCTest
import simd
@testable import OpenDicomViewer

final class ViewerLeftoverTests: XCTestCase {

    // MARK: - Value units

    private func element(_ g: UInt16, _ e: UInt16, _ vr: VR, _ s: String) -> DicomElement {
        let data = SyntheticDICOM.text(s)
        return DicomElement(tag: DicomTag(group: g, element: e), vr: vr, length: data.count, data: data)
    }

    private func tags(modality: String, rescaleType: String? = nil, petUnits: String? = nil) -> [DicomElement] {
        var out = [element(0x0008, 0x0060, .CS, modality)]
        if let r = rescaleType { out.append(element(0x0028, 0x1054, .LO, r)) }
        if let u = petUnits { out.append(element(0x0054, 0x1001, .CS, u)) }
        return out
    }

    func testCTIsHounsfield() {
        XCTAssertEqual(PixelValueUnit.label(for: tags(modality: "CT")), "HU")
        XCTAssertEqual(PixelValueUnit.label(for: tags(modality: "CT", rescaleType: "HU")), "HU")
    }

    func testPETUsesUnitsAttribute() {
        XCTAssertEqual(PixelValueUnit.label(for: tags(modality: "PT", petUnits: "BQML")), "Bq/mL")
        XCTAssertEqual(PixelValueUnit.label(for: tags(modality: "PT", petUnits: "CNTS")), "counts")
        // Values already in SUV (body weight) carry its unit; we don't compute SUV
        XCTAssertEqual(PixelValueUnit.label(for: tags(modality: "PT", petUnits: "GML")), "g/mL")
        // Unknown codes are shown as written
        XCTAssertEqual(PixelValueUnit.label(for: tags(modality: "PT", petUnits: "STDDEV")), "STDDEV")
        XCTAssertNil(PixelValueUnit.label(for: tags(modality: "PT")))
        XCTAssertNil(PixelValueUnit.label(for: tags(modality: "PT", petUnits: "NONE")))
        // RescaleType is not PET's unit
        XCTAssertNil(PixelValueUnit.label(for: tags(modality: "PT", rescaleType: "HU")))
    }

    func testOtherModalitiesHaveNoUnitUnlessRescaleTypeNamesOne() {
        for m in ["MR", "NM", "US", "CR", "DX", "MG", "XA", "OT"] {
            XCTAssertNil(PixelValueUnit.label(for: tags(modality: m)), m)
            // "US" = unspecified
            XCTAssertNil(PixelValueUnit.label(for: tags(modality: m, rescaleType: "US")), m)
        }
        XCTAssertEqual(PixelValueUnit.label(for: tags(modality: "XA", rescaleType: "OD")), "OD")
        XCTAssertNil(PixelValueUnit.label(for: []))
    }

    func testPaddingAndCaseAreIgnored() {
        XCTAssertEqual(PixelValueUnit.label(modality: "ct ", rescaleType: nil, petUnits: nil), "HU")
        XCTAssertEqual(PixelValueUnit.label(modality: "PT", rescaleType: nil, petUnits: "BQML\0"), "Bq/mL")
    }

    func testReadoutFormatting() {
        XCTAssertEqual(PixelValueUnit.format(40, unit: "HU"), "40 HU")
        XCTAssertEqual(PixelValueUnit.format(1250.5, unit: "Bq/mL"), "1250 Bq/mL")
        XCTAssertEqual(PixelValueUnit.format(812, unit: nil), "812")
        XCTAssertEqual(PixelValueUnit.format(12, unit: "%"), "12%")
    }

    func testPanelUnitFollowsItsTags() {
        let panel = PanelState()
        panel.tags = tags(modality: "MR")
        XCTAssertNil(panel.valueUnit)
        panel.tags = tags(modality: "CT")
        XCTAssertEqual(panel.valueUnit, "HU")
    }

    // MARK: - Slab definition

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
                          rescaleSlope: 1, rescaleIntercept: 0, seriesUID: "slab")
    }

    /// The GPU's slab, as the closed range of slices whose nearest-neighbour
    /// footprint [z − ½, z + ½) lies inside it.
    private func slicesInGPUSlab(_ slab: (thicknessMM: Float, centerVoxel: SIMD3<Float>),
                                 spacingZ: Double, depth: Int) -> ClosedRange<Int>? {
        let half = Double(slab.thicknessMM) / spacingZ / 2
        let lo = Double(slab.centerVoxel.z) - half, hi = Double(slab.centerVoxel.z) + half
        let inside = (0..<depth).filter { Double($0) - 0.5 >= lo - 1e-6 && Double($0) + 0.5 <= hi + 1e-6 }
        guard let first = inside.first, let last = inside.last else { return nil }
        // Footprints of the neighbours must be outside it
        XCTAssertFalse(Double(first) - 1.5 >= lo - 1e-6 && first > 0)
        return first...last
    }

    func testGPUSlabCoversExactlyTheSharedSliceRange() {
        let depth = 20
        for spacingZ in [1.0, 2.5, 0.625] {
            let engine = MPREngine(volume: makeVolume(width: 2, height: 2, depth: depth,
                                                      spacing: SIMD3(1, 1, spacingZ)) { _, _, _ in 0 })
            // Even and odd thicknesses, interior and clamped at both ends
            for (center, thickness) in [(10, 10), (10, 5), (10, 1), (0, 4), (1, 7), (19, 6), (18, 3), (10, 40)] {
                let range = engine.slabRange(center: center, thickness: thickness)
                let slab = engine.gpuSlab(center: center, thickness: thickness)
                XCTAssertNotNil(range)
                guard let range = range, let slab = slab else { continue }
                XCTAssertEqual(slicesInGPUSlab(slab, spacingZ: spacingZ, depth: depth), range,
                               "center \(center), thickness \(thickness), spacing \(spacingZ)")
                // Slab edges sit exactly half a voxel outside the first and last slice
                let half = Double(slab.thicknessMM) / spacingZ / 2
                XCTAssertEqual(Double(slab.centerVoxel.z) - half, Double(range.lowerBound) - 0.5, accuracy: 1e-4)
                XCTAssertEqual(Double(slab.centerVoxel.z) + half, Double(range.upperBound) + 0.5, accuracy: 1e-4)
            }
        }
        // Clamping: a slab at the first slice only reaches forward
        let engine = MPREngine(volume: makeVolume(width: 2, height: 2, depth: depth) { _, _, _ in 0 })
        XCTAssertEqual(engine.slabRange(center: 0, thickness: 4), 0...2)
        XCTAssertEqual(engine.slabRange(center: 19, thickness: 4), 17...19)
    }

    func testReadoutMatchesCPUProjectionPixels() {
        let w = 5, h = 4, d = 9
        let vol = makeVolume(width: w, height: h, depth: d) { x, y, z in Int16((z * 37 + x * 5 + y * 11) % 97 - 40) }
        let engine = MPREngine(volume: vol)
        for mode in [ProjectionMode.mip, .minip] {
            for (c, t) in [(0, 4), (4, 3), (8, 6), (4, 20)] {
                let slice = engine.axialSlabProjection(mode: mode, slabCenter: c, slabThickness: t)!
                let px = slice.pixelData.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
                for y in 0..<h { for x in 0..<w {
                    XCTAssertEqual(engine.slabProjectionValue(mode: mode, x: x, y: y, slabCenter: c, slabThickness: t),
                                   Double(px[y * w + x]), "\(mode) c\(c) t\(t) (\(x),\(y))")
                } }
            }
        }
    }

    /// Render on the GPU and check every pixel against the readout. Values
    /// span 0…255 and the window maps them 1:1 onto the 8-bit output.
    func testGPUProjectionMatchesReadoutPixelForPixel() throws {
        guard let renderer = MetalVolumeRenderer() else { throw XCTSkip("No Metal device") }
        let w = 7, h = 5, d = 11
        let vol = makeVolume(width: w, height: h, depth: d, spacing: SIMD3(0.8, 0.8, 2.5)) { x, y, z in
            Int16((z * 37 + x * 5 + y * 11 + (x * y * z) % 13) % 251)
        }
        let engine = MPREngine(volume: vol)
        for mode in ProjectionMode.allCases {
            for (c, t) in [(5, 4), (5, 3), (0, 4), (1, 1), (10, 5), (9, 6), (5, 30)] {
                let slab = try XCTUnwrap(engine.gpuSlab(center: c, thickness: t))
                let rgba = try XCTUnwrap(renderer.renderProjectionRGBA(
                    volume: vol, mode: mode, viewMatrix: matrix_identity_float4x4,
                    outputWidth: w, outputHeight: h, windowWidth: 255, windowCenter: 127.5,
                    slabThickness: slab.thicknessMM, slabCenterVoxel: slab.centerVoxel))
                for y in 0..<h { for x in 0..<w {
                    let shown = Double(rgba[(y * w + x) * 4])
                    let readout = try XCTUnwrap(engine.slabProjectionValue(
                        mode: mode, x: x, y: y, slabCenter: c, slabThickness: t))
                    // Average: the 8-bit output rounds the mean
                    let tolerance = mode == .average ? 0.5 + 1e-3 : 0
                    XCTAssertEqual(shown, readout, accuracy: tolerance, "\(mode) c\(c) t\(t) (\(x),\(y))")
                } }
            }
        }
    }
}
