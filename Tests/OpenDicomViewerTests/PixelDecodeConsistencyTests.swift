// PixelDecodeConsistencyTests.swift
// OpenDicomViewer Tests
//
// Decode paths must agree on pixel units and layout: DCMTK (modality LUT
// applied), the pure-Swift plain parser fallback, color handling, the file's
// stored window, and MONOCHROME1 propagation. Uses synthetic DICOM files.
// Licensed under the MIT License. See LICENSE for details.

import XCTest
import DCMTKWrapper
@testable import OpenDicomViewer

final class PixelDecodeConsistencyTests: XCTestCase {
    typealias S = SyntheticDICOM

    private struct Decoded {
        let data: Data, width: Int, height: Int, bits: Int, samples: Int, signed: Bool
        func values() -> [Double] {
            (0..<(width * height)).map { PixelValues.value(in: data, index: $0, bits: bits, isSigned: signed, samples: samples)! }
        }
    }

    private func decodeDCMTK(_ url: URL) -> (Decoded, DCMTKImageObject)? {
        guard let obj = DCMTKImageObject(path: url.path) else { return nil }
        var w = 0, h = 0, d = 0, s = 0
        var signed: ObjCBool = false
        guard let raw = obj.getRawDataWidth(&w, height: &h, bitDepth: &d, samples: &s, isSigned: &signed) else { return nil }
        return (Decoded(data: raw, width: w, height: h, bits: d, samples: s, signed: signed.boolValue), obj)
    }

    private func decodePlain(_ file: Data) -> (Decoded, DicomPixelAttributes)? {
        let parser = SimpleDicomParser(data: file)
        guard let (elements, pixels, ts) = try? parser.parse(), let pixels = pixels else { return nil }
        let be = ts == S.explicitBE
        let attrs = DicomPixelAttributes(elements: elements, bigEndian: be)
        guard let d = PlainPixelDecoder.decode(pixelData: pixels, attributes: attrs, bigEndian: be) else { return nil }
        return (Decoded(data: d.data, width: d.width, height: d.height, bits: d.bitDepth, samples: d.samples, signed: d.isSigned), attrs)
    }

    // MARK: - Item 5: same units on DCMTK and plain-parser paths

    func testCTRescaleGivesSameHUOnBothPaths() throws {
        var spec = S.ImageSpec(rows: 2, columns: 3)
        spec.bitsStored = 12
        spec.rescaleSlope = "1"
        spec.rescaleIntercept = "-1024"
        let stored = [0, 1024, 2048, 24, 3000, 4095]
        let file = S.image(spec, pixelBytes: S.le16(stored))
        let expected = stored.map { Double($0) - 1024 }

        let (plain, _) = try XCTUnwrap(decodePlain(file))
        XCTAssertEqual(plain.values(), expected)

        let url = try S.writeTemp(file, name: "ct.dcm")
        let (dcmtk, _) = try XCTUnwrap(decodeDCMTK(url))
        XCTAssertEqual(dcmtk.values(), expected)
    }

    func testFractionalSlopeAndSignedDataMatchAcrossPaths() throws {
        var spec = S.ImageSpec(rows: 1, columns: 4)
        spec.pixelRepresentation = 1
        spec.rescaleSlope = "2"
        spec.rescaleIntercept = "10"
        let stored = [-100, 0, 7, 1000]
        let file = S.image(spec, pixelBytes: S.le16(stored))
        let expected = stored.map { Double($0) * 2 + 10 }

        let (plain, _) = try XCTUnwrap(decodePlain(file))
        XCTAssertEqual(plain.values(), expected)
        let (dcmtk, _) = try XCTUnwrap(decodeDCMTK(try S.writeTemp(file, name: "signed.dcm")))
        XCTAssertEqual(dcmtk.values(), expected)
    }

    func testWideRescaleProduces32BitOnPlainPath() throws {
        var spec = S.ImageSpec(rows: 1, columns: 2)
        spec.rescaleSlope = "10"
        let file = S.image(spec, pixelBytes: S.le16([0, 60000]))
        let (plain, _) = try XCTUnwrap(decodePlain(file))
        XCTAssertEqual(plain.bits, 32)
        XCTAssertEqual(plain.values(), [0, 600_000])
    }

    // MARK: - Item 16: BitsAllocated, big endian, planar configuration

    func testPlainPathUsesBitsAllocatedNotBitsStored() throws {
        // BitsStored 8 in a 16-bit container: old code read it as 8-bit bytes
        var spec = S.ImageSpec(rows: 1, columns: 3)
        spec.bitsStored = 8
        let file = S.image(spec, pixelBytes: S.le16([10, 200, 255]))
        let (plain, _) = try XCTUnwrap(decodePlain(file))
        XCTAssertEqual(plain.values(), [10, 200, 255])
    }

    func testPlainPathByteSwapsBigEndian() throws {
        var spec = S.ImageSpec(rows: 1, columns: 3)
        spec.transferSyntax = S.explicitBE
        let file = S.image(spec, pixelBytes: S.be16([1, 300, 65535]))
        let (plain, attrs) = try XCTUnwrap(decodePlain(file))
        XCTAssertEqual(attrs.columns, 3)
        XCTAssertEqual(plain.values(), [1, 300, 65535])
    }

    func testPlainPathInterleavesPlanarRGB() throws {
        var spec = S.ImageSpec(rows: 1, columns: 2)
        spec.bitsAllocated = 8; spec.bitsStored = 8
        spec.samplesPerPixel = 3; spec.photometric = "RGB"; spec.planarConfiguration = 1
        // R plane, G plane, B plane
        let file = S.image(spec, pixelBytes: Data([10, 11, 20, 21, 30, 31]))
        let (plain, _) = try XCTUnwrap(decodePlain(file))
        XCTAssertEqual(plain.samples, 3)
        XCTAssertEqual([UInt8](plain.data), [10, 20, 30, 11, 21, 31])
    }

    // MARK: - Item 2: DCMTK color data is interleaved RGB, not plane pointers

    func testDCMTKColorReturnsInterleavedRGB() throws {
        var spec = S.ImageSpec(rows: 2, columns: 2)
        spec.bitsAllocated = 8; spec.bitsStored = 8
        spec.samplesPerPixel = 3; spec.photometric = "RGB"; spec.planarConfiguration = 0
        let rgb: [UInt8] = [255, 0, 0,  0, 255, 0,  0, 0, 255,  10, 20, 30]
        let url = try S.writeTemp(S.image(spec, pixelBytes: Data(rgb)), name: "rgb.dcm")
        let (decoded, _) = try XCTUnwrap(decodeDCMTK(url))
        XCTAssertEqual(decoded.samples, 3)
        XCTAssertEqual(decoded.bits, 8)
        XCTAssertEqual([UInt8](decoded.data), rgb)

        // Planar configuration 1 is interleaved on output too
        spec.planarConfiguration = 1
        let planar: [UInt8] = [255, 0, 0, 10,  0, 255, 0, 20,  0, 0, 255, 30]
        let url2 = try S.writeTemp(S.image(spec, pixelBytes: Data(planar)), name: "rgb-planar.dcm")
        let (decoded2, _) = try XCTUnwrap(decodeDCMTK(url2))
        XCTAssertEqual([UInt8](decoded2.data), rgb)
    }

    // MARK: - Item 4: stored window; Item 5: MONOCHROME1

    func testDCMTKReportsStoredWindow() throws {
        var spec = S.ImageSpec(rows: 1, columns: 2)
        spec.windowCenter = "40\\300"
        spec.windowWidth = "400\\1500"
        let url = try S.writeTemp(S.image(spec, pixelBytes: S.le16([0, 100])), name: "win.dcm")
        let (decoded, obj) = try XCTUnwrap(decodeDCMTK(url))
        XCTAssertEqual(obj.getWindowWidth(), 400)
        XCTAssertEqual(obj.getWindowCenter(), 40)
        let win = PixelValues.defaultWindow(storedWidth: obj.getWindowWidth(), storedCenter: obj.getWindowCenter(),
                                            data: decoded.data, bits: decoded.bits, isSigned: decoded.signed)
        XCTAssertEqual(win.width, 400); XCTAssertEqual(win.center, 40)

        // No stored window → full data range
        let url2 = try S.writeTemp(S.image(S.ImageSpec(rows: 1, columns: 2), pixelBytes: S.le16([0, 100])), name: "nowin.dcm")
        let (d2, obj2) = try XCTUnwrap(decodeDCMTK(url2))
        XCTAssertEqual(obj2.getWindowWidth(), 0)
        let auto = PixelValues.defaultWindow(storedWidth: obj2.getWindowWidth(), storedCenter: obj2.getWindowCenter(),
                                             data: d2.data, bits: d2.bits, isSigned: d2.signed)
        XCTAssertEqual(auto.width, 100); XCTAssertEqual(auto.center, 50)
    }

    func testMonochrome1IsReportedByBothPaths() throws {
        var spec = S.ImageSpec(rows: 1, columns: 2)
        spec.photometric = "MONOCHROME1"
        let file = S.image(spec, pixelBytes: S.le16([0, 4095]))
        let (_, obj) = try XCTUnwrap(decodeDCMTK(try S.writeTemp(file, name: "m1.dcm")))
        XCTAssertTrue(obj.isMonochrome1())
        XCTAssertTrue(try XCTUnwrap(decodePlain(file)).1.isMonochrome1)

        let (_, obj2) = try XCTUnwrap(decodeDCMTK(try S.writeTemp(S.image(S.ImageSpec(rows: 1, columns: 2), pixelBytes: S.le16([0, 1])), name: "m2.dcm")))
        XCTAssertFalse(obj2.isMonochrome1())
    }

    // MARK: - Item 6: 32-bit values are read as 32-bit everywhere

    func testPixelValuesReads32BitAndRGB() {
        let d32 = S.le32([-70000, 123456])
        XCTAssertEqual(PixelValues.value(in: d32, index: 0, bits: 32, isSigned: true), -70000)
        XCTAssertEqual(PixelValues.value(in: d32, index: 1, bits: 32, isSigned: true), 123456)
        XCTAssertNil(PixelValues.value(in: d32, index: 2, bits: 32, isSigned: true))
        XCTAssertEqual(PixelValues.minMax(data: d32, bits: 32, isSigned: true).max, 123456)
        let rgb = Data([30, 60, 90, 0, 0, 3])
        XCTAssertEqual(PixelValues.value(in: rgb, index: 0, bits: 8, isSigned: false, samples: 3), 60)
        XCTAssertEqual(PixelValues.value(in: rgb, index: 1, bits: 8, isSigned: false, samples: 3), 1)
    }
}
