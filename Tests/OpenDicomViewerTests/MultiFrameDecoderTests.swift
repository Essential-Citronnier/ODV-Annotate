// MultiFrameDecoderTests.swift
// OpenDicomViewer Tests
//
// Basic Offset Table / fragment grouping, decode-path routing by transfer
// syntax, one window across raw frames (with rescale and MONOCHROME1), and
// the DCMTK path for RLE multi-frame data.
// Licensed under the MIT License. See LICENSE for details.

import XCTest
import CoreGraphics
@testable import OpenDicomViewer

final class MultiFrameDecoderTests: XCTestCase {
    typealias S = SyntheticDICOM

    // MARK: - Fragment grouping

    private func frag(_ item: Int, _ len: Int) -> EncapsulatedFragment {
        EncapsulatedFragment(itemOffset: item, dataOffset: item + 8, length: len)
    }

    func testBasicOffsetTableGroupsFragmentsIntoFrames() {
        // Frame 0 = two fragments (items at 100 and 118), frame 1 = one (item 140)
        let fragments = [frag(100, 10), frag(118, 14), frag(140, 20)]
        let frames = MultiFrameDecoder.groupFragments(fragments, basicOffsetTable: [0, 40], numberOfFrames: 2) { _ in false }
        XCTAssertEqual(frames, [[fragments[0], fragments[1]], [fragments[2]]])
    }

    func testWithoutOffsetTableOneFragmentPerFrame() {
        let fragments = [frag(0, 4), frag(12, 4), frag(24, 4)]
        let frames = MultiFrameDecoder.groupFragments(fragments, basicOffsetTable: [], numberOfFrames: 3) { _ in false }
        XCTAssertEqual(frames.count, 3)
    }

    func testWithoutOffsetTableGroupsByCodestreamStart() {
        // 4 fragments, 2 frames: fragments 0 and 2 start codestreams
        let fragments = [frag(0, 4), frag(12, 4), frag(24, 4), frag(36, 4)]
        let starts: Set<Int> = [0, 24]
        let frames = MultiFrameDecoder.groupFragments(fragments, basicOffsetTable: [], numberOfFrames: 2) { starts.contains($0.itemOffset) }
        XCTAssertEqual(frames, [[fragments[0], fragments[1]], [fragments[2], fragments[3]]])
        XCTAssertTrue(MultiFrameDecoder.startsCodestream([0xFF, 0xD8, 0xFF, 0xE0]))
        XCTAssertTrue(MultiFrameDecoder.startsCodestream([0xFF, 0x4F, 0xFF, 0x51]))
        XCTAssertFalse(MultiFrameDecoder.startsCodestream([0x12, 0x34, 0x56, 0x78]))
    }

    func testDecodePathRoutesUnsupportedSyntaxesToDCMTK() {
        XCTAssertEqual(MultiFrameDecoder.decodePath(transferSyntax: "1.2.840.10008.1.2.1", bitsStored: 16), .raw)
        XCTAssertEqual(MultiFrameDecoder.decodePath(transferSyntax: "1.2.840.10008.1.2.4.50", bitsStored: 8), .imageIO)
        XCTAssertEqual(MultiFrameDecoder.decodePath(transferSyntax: "1.2.840.10008.1.2.4.50", bitsStored: 12), .dcmtk)
        for ts in ["1.2.840.10008.1.2.4.57", "1.2.840.10008.1.2.4.70", "1.2.840.10008.1.2.4.80",
                   "1.2.840.10008.1.2.4.81", "1.2.840.10008.1.2.5", "1.2.840.10008.1.2.4.51"] {
            XCTAssertEqual(MultiFrameDecoder.decodePath(transferSyntax: ts, bitsStored: 12), .dcmtk, ts)
        }
    }

    // MARK: - Rendering

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

    func testRawFramesShareOneWindowWithRescale() throws {
        var spec = S.ImageSpec(rows: 1, columns: 2)
        spec.numberOfFrames = 2
        spec.rescaleIntercept = "-1000"
        // Frame 0 spans 0…100 (→ −1000…−900 HU); frame 1 is flat at 50 (→ −950)
        let file = S.image(spec, pixelBytes: S.le16([0, 100, 50, 50]))
        let url = try S.writeTemp(file, name: "cine-raw.dcm")
        let decoder = try XCTUnwrap(MultiFrameDecoder(url: url))
        XCTAssertEqual(decoder.decodePath, .raw)
        XCTAssertEqual(decoder.effectiveFrameCount, 2)
        XCTAssertEqual(decoder.window?.width ?? 0, 100, accuracy: 1e-9)
        XCTAssertEqual(decoder.window?.center ?? 0, -950, accuracy: 1e-9)
        // Frame 1 is mid-grey under the shared window (per-frame auto W/L made it black)
        let f1 = grayPixels(try XCTUnwrap(decoder.frameCGImage(at: 1)))
        XCTAssertEqual(Int(f1[0]), 127, accuracy: 1)
        XCTAssertEqual(f1[0], f1[1])
    }

    func testRawFramesUseStoredWindowAndMonochrome1() throws {
        var spec = S.ImageSpec(rows: 1, columns: 2)
        spec.numberOfFrames = 2
        spec.photometric = "MONOCHROME1"
        spec.windowCenter = "100"
        spec.windowWidth = "200"
        let file = S.image(spec, pixelBytes: S.le16([0, 200, 0, 200]))
        let decoder = try XCTUnwrap(MultiFrameDecoder(url: try S.writeTemp(file, name: "cine-m1.dcm")))
        XCTAssertEqual(decoder.window?.width, 200)
        let px = grayPixels(try XCTUnwrap(decoder.frameCGImage(at: 0)))
        // MONOCHROME1: lowest value is white
        XCTAssertEqual(px[0], 255)
        XCTAssertEqual(px[1], 0)
    }

    /// RLE Lossless: one segment, PackBits literal run per frame.
    private func rleFrame(_ bytes: [UInt8]) -> Data {
        var header = Data(S.u32(1))           // number of segments
        header.append(contentsOf: S.u32(64))   // offset of segment 1
        header.append(Data(count: 64 - 8))
        header.append(UInt8(bytes.count - 1))  // literal run of n bytes
        header.append(contentsOf: bytes)
        if header.count % 2 == 1 { header.append(0) }
        return header
    }

    func testRLEMultiFrameDecodesThroughDCMTK() throws {
        var ds = Data()
        ds.append(S.element(0x0008, 0x0016, "UI", S.text("1.2.840.10008.5.1.4.1.1.7.2", pad: 0)))
        ds.append(S.element(0x0008, 0x0060, "CS", S.text("OT")))
        ds.append(S.element(0x0028, 0x0002, "US", S.us(1)))
        ds.append(S.element(0x0028, 0x0004, "CS", S.text("MONOCHROME2")))
        ds.append(S.element(0x0028, 0x0008, "IS", S.text("2")))
        ds.append(S.element(0x0028, 0x0010, "US", S.us(2)))
        ds.append(S.element(0x0028, 0x0011, "US", S.us(2)))
        ds.append(S.element(0x0028, 0x0100, "US", S.us(8)))
        ds.append(S.element(0x0028, 0x0101, "US", S.us(8)))
        ds.append(S.element(0x0028, 0x0102, "US", S.us(7)))
        ds.append(S.element(0x0028, 0x0103, "US", S.us(0)))
        let items = [S.definedItem(Data()),                    // empty Basic Offset Table
                     S.definedItem(rleFrame([0, 200, 0, 200])),
                     S.definedItem(rleFrame([100, 100, 100, 100]))]
        ds.append(S.undefinedSequence(0x7FE0, 0x0010, items: items, vr: "OB"))
        let url = try S.writeTemp(S.part10(transferSyntax: "1.2.840.10008.1.2.5", dataset: ds), name: "cine-rle.dcm")

        let decoder = try XCTUnwrap(MultiFrameDecoder(url: url))
        XCTAssertEqual(decoder.decodePath, .dcmtk)
        XCTAssertEqual(decoder.effectiveFrameCount, 2)
        let f0 = grayPixels(try XCTUnwrap(decoder.frameCGImage(at: 0)))
        let f1 = grayPixels(try XCTUnwrap(decoder.frameCGImage(at: 1)))
        XCTAssertEqual(f0[0], 0)
        XCTAssertEqual(f0[1], 255)
        // Same window as frame 0, so 100 is mid-grey rather than auto-stretched
        XCTAssertEqual(Int(f1[0]), 127, accuracy: 2)
    }
}
