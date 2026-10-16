// JPEG2000MultiFrameTests.swift
// OpenDicomViewer Tests
//
// Monochrome 16-bit JPEG 2000 multi-frame decoding through the wrapper's
// OpenJPEG path (decodeJPEG2000Frame): stored values at full precision,
// sign handling, the Modality LUT, MONOCHROME1 and the one window shared by
// all frames. Codestreams come from OpenJPEG's encoder (J2KTestSupport).
// Licensed under the MIT License. See LICENSE for details.

import XCTest
import CoreGraphics
import DCMTKWrapper
import J2KTestSupport
@testable import OpenDicomViewer

final class JPEG2000MultiFrameTests: XCTestCase {
    typealias S = SyntheticDICOM

    static let j2kLossless = "1.2.840.10008.1.2.4.90"
    let rows = 3, columns = 4

    // MARK: - Helpers

    /// Lossless J2K codestream of one frame of stored values.
    private func encode(_ values: [Int], precision: Int = 16, signed: Bool = false) throws -> Data {
        XCTAssertEqual(values.count, rows * columns)
        let pixels = values.map { Int32($0) }
        var bytes: UnsafeMutablePointer<UInt8>?
        var length = 0
        let ok = pixels.withUnsafeBufferPointer {
            j2k_test_encode_gray($0.baseAddress, Int32(columns), Int32(rows), Int32(precision),
                                 signed ? 1 : 0, &bytes, &length)
        }
        guard ok == 1, let bytes = bytes else {
            XCTFail("OpenJPEG encode failed")
            throw XCTSkip("encoder unavailable")
        }
        defer { j2k_test_free(bytes) }
        let data = Data(bytes: bytes, count: length)
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0x4F], "J2K codestream starts with SOC")
        return data
    }

    struct Spec {
        var photometric = "MONOCHROME2"
        var pixelRepresentation = 0
        var rescaleSlope: String? = nil
        var rescaleIntercept: String? = nil
        var windowCenter: String? = nil
        var windowWidth: String? = nil
    }

    /// Multi-frame JPEG 2000 file, one fragment per frame, empty Basic Offset Table.
    private func file(frames: [Data], spec: Spec = Spec()) -> Data {
        var ds = Data()
        ds.append(S.element(0x0008, 0x0016, "UI", S.text("1.2.840.10008.5.1.4.1.1.7.3", pad: 0)))
        ds.append(S.element(0x0008, 0x0018, "UI", S.text("1.2.3.4.5.6.9", pad: 0)))
        ds.append(S.element(0x0008, 0x0060, "CS", S.text("OT")))
        ds.append(S.element(0x0020, 0x000E, "UI", S.text("1.2.3.4.9", pad: 0)))
        ds.append(S.element(0x0028, 0x0002, "US", S.us(1)))
        ds.append(S.element(0x0028, 0x0004, "CS", S.text(spec.photometric)))
        ds.append(S.element(0x0028, 0x0008, "IS", S.text(String(frames.count))))
        ds.append(S.element(0x0028, 0x0010, "US", S.us(UInt16(rows))))
        ds.append(S.element(0x0028, 0x0011, "US", S.us(UInt16(columns))))
        ds.append(S.element(0x0028, 0x0100, "US", S.us(16)))
        ds.append(S.element(0x0028, 0x0101, "US", S.us(16)))
        ds.append(S.element(0x0028, 0x0102, "US", S.us(15)))
        ds.append(S.element(0x0028, 0x0103, "US", S.us(UInt16(spec.pixelRepresentation))))
        if let wc = spec.windowCenter { ds.append(S.element(0x0028, 0x1050, "DS", S.text(wc))) }
        if let ww = spec.windowWidth { ds.append(S.element(0x0028, 0x1051, "DS", S.text(ww))) }
        if let ri = spec.rescaleIntercept { ds.append(S.element(0x0028, 0x1052, "DS", S.text(ri))) }
        if let rs = spec.rescaleSlope { ds.append(S.element(0x0028, 0x1053, "DS", S.text(rs))) }
        var items = [S.definedItem(Data())]
        for frame in frames {
            var f = frame
            if f.count % 2 == 1 { f.append(0) }   // items are even length
            items.append(S.definedItem(f))
        }
        ds.append(S.undefinedSequence(0x7FE0, 0x0010, items: items, vr: "OB"))
        return S.part10(transferSyntax: Self.j2kLossless, dataset: ds)
    }

    private func decoder(frames: [Data], spec: Spec = Spec(), name: String) throws -> MultiFrameDecoder {
        let url = try S.writeTemp(file(frames: frames, spec: spec), name: name)
        let decoder = try XCTUnwrap(MultiFrameDecoder(url: url))
        XCTAssertEqual(decoder.decodePath, .openJPEG)
        XCTAssertEqual(decoder.effectiveFrameCount, frames.count)
        return decoder
    }

    private func values(_ buffer: DecodedPixelBuffer) -> [Double] {
        (0..<(buffer.width * buffer.height)).map {
            PixelValues.value(in: buffer.data, index: $0, bits: buffer.bitDepth, isSigned: buffer.isSigned) ?? .nan
        }
    }

    private func grayPixels(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var out = [UInt8](repeating: 0, count: w * h)
        out.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return out
    }

    /// Frame 0 spans the full unsigned 16-bit range; frame 1 is flat.
    private let frame0: [Int] = [0, 1, 255, 256, 4095, 4096, 32767, 32768, 40000, 51234, 65534, 65535]
    private let frame1: [Int] = Array(repeating: 32768, count: 12)

    // MARK: - decodeJPEG2000Frame

    func testUnsigned16BitFrameKeepsFullPrecision() throws {
        let attrs = DicomPixelAttributes(elements: [], bigEndian: false)
        let decoded = try XCTUnwrap(MultiFrameDecoder.decodeJPEG2000(try encode(frame0), attributes: attrs))
        XCTAssertEqual(decoded.width, columns)
        XCTAssertEqual(decoded.height, rows)
        XCTAssertEqual(decoded.samples, 1)
        XCTAssertEqual(values(decoded), frame0.map(Double.init))
    }

    func testRescaleIsAppliedToEveryFrame() throws {
        // Slope 2, intercept −1000: modality values exceed 16 bits
        let decoder = try decoder(frames: [try encode(frame0), try encode(frame1)],
                                  spec: Spec(rescaleSlope: "2", rescaleIntercept: "-1000"), name: "j2k-rescale.dcm")
        let url = decoder.url
        let attrs = try attributes(of: url)
        XCTAssertEqual(attrs.rescaleSlope, 2)
        let d0 = try XCTUnwrap(MultiFrameDecoder.decodeJPEG2000(try encode(frame0), attributes: attrs))
        XCTAssertEqual(values(d0), frame0.map { Double($0 * 2 - 1000) })
        XCTAssertFalse(PixelValues.isFloat(bits: d0.bitDepth))

        // File-wide window = frame 0's modality range
        XCTAssertEqual(decoder.window?.width ?? 0, 131_070, accuracy: 1e-9)
        XCTAssertEqual(decoder.window?.center ?? 0, -1000 + 65_535, accuracy: 1e-9)
        // Frame 1 (flat, mid-range) is mid-grey under that window, not auto-stretched
        let f1 = grayPixels(try XCTUnwrap(decoder.frameCGImage(at: 1)))
        XCTAssertEqual(Int(f1[0]), 127, accuracy: 1)
        XCTAssertEqual(Set(f1).count, 1)
        // Frame 0 spans black to white
        let f0 = grayPixels(try XCTUnwrap(decoder.frameCGImage(at: 0)))
        XCTAssertEqual(f0.first, 0)
        XCTAssertEqual(f0.last, 255)
    }

    func testFractionalRescaleDecodesToFloat() throws {
        let attrs = try attributes(of: try S.writeTemp(
            file(frames: [try encode(frame0)], spec: Spec(rescaleSlope: "0.25", rescaleIntercept: "0.5")),
            name: "j2k-float.dcm"))
        let decoded = try XCTUnwrap(MultiFrameDecoder.decodeJPEG2000(try encode(frame0), attributes: attrs))
        XCTAssertTrue(PixelValues.isFloat(bits: decoded.bitDepth))
        for (v, stored) in zip(values(decoded), frame0) {
            XCTAssertEqual(v, Double(stored) * 0.25 + 0.5, accuracy: 1e-3)
        }
    }

    func testSignedFrames() throws {
        let signed = [-32768, -32767, -2000, -1, 0, 1, 1000, 2000, 3071, 30000, 32766, 32767]
        var attrs = DicomPixelAttributes(elements: [], bigEndian: false)
        attrs.pixelRepresentation = 1
        // Component marked signed in the codestream
        let a = try XCTUnwrap(MultiFrameDecoder.decodeJPEG2000(try encode(signed, signed: true), attributes: attrs))
        XCTAssertEqual(values(a), signed.map(Double.init))
        XCTAssertTrue(a.isSigned)
        // Component marked unsigned but PixelRepresentation 1: sign-extended
        let twos = signed.map { $0 & 0xFFFF }
        let b = try XCTUnwrap(MultiFrameDecoder.decodeJPEG2000(try encode(twos, signed: false), attributes: attrs))
        XCTAssertEqual(values(b), signed.map(Double.init))
        // PixelRepresentation 0 leaves the same codestream unsigned
        attrs.pixelRepresentation = 0
        let c = try XCTUnwrap(MultiFrameDecoder.decodeJPEG2000(try encode(twos, signed: false), attributes: attrs))
        XCTAssertEqual(values(c), twos.map(Double.init))
    }

    // MARK: - MultiFrameDecoder end to end

    func testMonochrome1InvertsUnderFileWideWindow() throws {
        let decoder = try decoder(frames: [try encode(frame0), try encode(frame1)],
                                  spec: Spec(photometric: "MONOCHROME1"), name: "j2k-m1.dcm")
        XCTAssertEqual(decoder.window?.width ?? 0, 65_535, accuracy: 1e-9)
        let f0 = grayPixels(try XCTUnwrap(decoder.frameCGImage(at: 0)))
        // MONOCHROME1: lowest value is white
        XCTAssertEqual(f0.first, 255)
        XCTAssertEqual(f0.last, 0)
        let f1 = grayPixels(try XCTUnwrap(decoder.frameCGImage(at: 1)))
        XCTAssertEqual(Int(f1[0]), 127, accuracy: 1)
    }

    func testStoredWindowIsUsedForAllFrames() throws {
        let decoder = try decoder(frames: [try encode(frame0), try encode(frame1)],
                                  spec: Spec(rescaleIntercept: "-32768", windowCenter: "0", windowWidth: "1000"),
                                  name: "j2k-window.dcm")
        XCTAssertEqual(decoder.window?.width, 1000)
        XCTAssertEqual(decoder.window?.center, 0)
        // Frame 1 is 32768 − 32768 = 0: the window centre
        let f1 = grayPixels(try XCTUnwrap(decoder.frameCGImage(at: 1)))
        XCTAssertEqual(Int(f1[0]), 127, accuracy: 1)
        // Frame 0: −32768 → black, 32767 → white, 0 (stored 32768) → mid-grey
        let f0 = grayPixels(try XCTUnwrap(decoder.frameCGImage(at: 0)))
        XCTAssertEqual(f0[0], 0)
        XCTAssertEqual(f0[11], 255)
        XCTAssertEqual(Int(f0[7]), 127, accuracy: 1)
        // Out-of-range frame index
        XCTAssertNil(decoder.frameCGImage(at: 2))
    }

    private func attributes(of url: URL) throws -> DicomPixelAttributes {
        let data = try Data(contentsOf: url)
        let (elements, _, _) = try SimpleDicomParser(data: data).parse(stopAtPixelData: true)
        return DicomPixelAttributes(elements: elements, bigEndian: false)
    }
}
