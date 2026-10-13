// SyntheticDICOM.swift
// OpenDicomViewer Tests
//
// Builds small synthetic DICOM byte streams (Part 10 or preamble-less,
// explicit/implicit VR, little/big endian) for parser and decoder tests.
// Licensed under the MIT License. See LICENSE for details.

import Foundation

enum SyntheticDICOM {
    static let implicitLE = "1.2.840.10008.1.2"
    static let explicitLE = "1.2.840.10008.1.2.1"
    static let explicitBE = "1.2.840.10008.1.2.2"

    private static let longVRs: Set<String> = ["OB", "OD", "OF", "OL", "OV", "OW", "SQ", "SV", "UC", "UN", "UR", "UT", "UV"]

    static func u16(_ v: UInt16, bigEndian: Bool = false) -> [UInt8] {
        bigEndian ? [UInt8(v >> 8), UInt8(v & 0xFF)] : [UInt8(v & 0xFF), UInt8(v >> 8)]
    }

    static func u32(_ v: UInt32, bigEndian: Bool = false) -> [UInt8] {
        let le = [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
        return bigEndian ? le.reversed() : le
    }

    /// Text value padded to even length.
    static func text(_ s: String, pad: UInt8 = 0x20) -> Data {
        var d = Data(s.utf8)
        if d.count % 2 == 1 { d.append(pad) }
        return d
    }

    static func us(_ v: UInt16, bigEndian: Bool = false) -> Data { Data(u16(v, bigEndian: bigEndian)) }

    /// Encode one element. `length` overrides the value length (e.g. 0xFFFFFFFF).
    static func element(_ g: UInt16, _ e: UInt16, _ vr: String, _ value: Data,
                        explicit: Bool = true, bigEndian: Bool = false, length: UInt32? = nil) -> Data {
        var d = Data(u16(g, bigEndian: bigEndian) + u16(e, bigEndian: bigEndian))
        let len = length ?? UInt32(value.count)
        if explicit {
            d.append(contentsOf: Array(vr.utf8))
            if longVRs.contains(vr) {
                d.append(contentsOf: [0, 0])
                d.append(contentsOf: u32(len, bigEndian: bigEndian))
            } else {
                d.append(contentsOf: u16(UInt16(len), bigEndian: bigEndian))
            }
        } else {
            d.append(contentsOf: u32(len, bigEndian: bigEndian))
        }
        d.append(value)
        return d
    }

    /// Item with undefined length followed by an Item Delimitation Item.
    static func undefinedItem(_ content: Data, bigEndian: Bool = false) -> Data {
        var d = Data(u16(0xFFFE, bigEndian: bigEndian) + u16(0xE000, bigEndian: bigEndian) + u32(0xFFFFFFFF, bigEndian: bigEndian))
        d.append(content)
        d.append(contentsOf: u16(0xFFFE, bigEndian: bigEndian) + u16(0xE00D, bigEndian: bigEndian) + u32(0, bigEndian: bigEndian))
        return d
    }

    static func definedItem(_ content: Data, bigEndian: Bool = false) -> Data {
        var d = Data(u16(0xFFFE, bigEndian: bigEndian) + u16(0xE000, bigEndian: bigEndian) + u32(UInt32(content.count), bigEndian: bigEndian))
        d.append(content)
        return d
    }

    static func sequenceDelimiter(bigEndian: Bool = false) -> Data {
        Data(u16(0xFFFE, bigEndian: bigEndian) + u16(0xE0DD, bigEndian: bigEndian) + u32(0, bigEndian: bigEndian))
    }

    /// Undefined-length sequence element containing the given items.
    static func undefinedSequence(_ g: UInt16, _ e: UInt16, items: [Data], vr: String = "SQ",
                                  explicit: Bool = true, bigEndian: Bool = false) -> Data {
        var content = Data()
        for item in items { content.append(item) }
        content.append(sequenceDelimiter(bigEndian: bigEndian))
        return element(g, e, vr, content, explicit: explicit, bigEndian: bigEndian, length: 0xFFFFFFFF)
    }

    /// Part 10 file: 128-byte preamble, DICM, meta group, then the dataset.
    static func part10(transferSyntax: String = explicitLE, dataset: Data) -> Data {
        var meta = Data()
        meta.append(element(0x0002, 0x0001, "OB", Data([0, 1])))
        meta.append(element(0x0002, 0x0010, "UI", text(transferSyntax, pad: 0)))
        var d = Data(count: 128)
        d.append(contentsOf: Array("DICM".utf8))
        d.append(element(0x0002, 0x0000, "UL", Data(u32(UInt32(meta.count)))))
        d.append(meta)
        d.append(dataset)
        return d
    }

    struct ImageSpec {
        var rows: Int = 4
        var columns: Int = 4
        var bitsAllocated: Int = 16
        var bitsStored: Int = 16
        var pixelRepresentation: Int = 0
        var samplesPerPixel: Int = 1
        var planarConfiguration: Int? = nil
        var photometric: String = "MONOCHROME2"
        var rescaleSlope: String? = nil
        var rescaleIntercept: String? = nil
        var windowCenter: String? = nil
        var windowWidth: String? = nil
        var numberOfFrames: Int? = nil
        var transferSyntax: String = explicitLE
        var includePreamble: Bool = true
        var sopClassUID: String = "1.2.840.10008.5.1.4.1.1.7"
        var seriesUID: String = "1.2.3.4.5"
    }

    /// Build a complete uncompressed image. `pixelBytes` must already be in the
    /// transfer syntax's byte order.
    static func image(_ spec: ImageSpec, pixelBytes: Data) -> Data {
        let explicit = spec.transferSyntax != implicitLE
        let be = spec.transferSyntax == explicitBE
        func el(_ g: UInt16, _ e: UInt16, _ vr: String, _ v: Data) -> Data {
            element(g, e, vr, v, explicit: explicit, bigEndian: be)
        }
        var ds = Data()
        ds.append(el(0x0008, 0x0016, "UI", text(spec.sopClassUID, pad: 0)))
        ds.append(el(0x0008, 0x0018, "UI", text("1.2.3.4.5.6.7", pad: 0)))
        ds.append(el(0x0008, 0x0060, "CS", text("OT")))
        ds.append(el(0x0010, 0x0010, "PN", text("TEST^SYNTHETIC")))
        ds.append(el(0x0020, 0x000D, "UI", text("1.2.3.4", pad: 0)))
        ds.append(el(0x0020, 0x000E, "UI", text(spec.seriesUID, pad: 0)))
        ds.append(el(0x0020, 0x0013, "IS", text("1")))
        ds.append(el(0x0028, 0x0002, "US", us(UInt16(spec.samplesPerPixel), bigEndian: be)))
        ds.append(el(0x0028, 0x0004, "CS", text(spec.photometric)))
        if let pc = spec.planarConfiguration {
            ds.append(el(0x0028, 0x0006, "US", us(UInt16(pc), bigEndian: be)))
        }
        if let nf = spec.numberOfFrames {
            ds.append(el(0x0028, 0x0008, "IS", text(String(nf))))
        }
        ds.append(el(0x0028, 0x0010, "US", us(UInt16(spec.rows), bigEndian: be)))
        ds.append(el(0x0028, 0x0011, "US", us(UInt16(spec.columns), bigEndian: be)))
        ds.append(el(0x0028, 0x0030, "DS", text("0.5\\0.5")))
        ds.append(el(0x0028, 0x0100, "US", us(UInt16(spec.bitsAllocated), bigEndian: be)))
        ds.append(el(0x0028, 0x0101, "US", us(UInt16(spec.bitsStored), bigEndian: be)))
        ds.append(el(0x0028, 0x0102, "US", us(UInt16(spec.bitsStored - 1), bigEndian: be)))
        ds.append(el(0x0028, 0x0103, "US", us(UInt16(spec.pixelRepresentation), bigEndian: be)))
        if let wc = spec.windowCenter { ds.append(el(0x0028, 0x1050, "DS", text(wc))) }
        if let ww = spec.windowWidth { ds.append(el(0x0028, 0x1051, "DS", text(ww))) }
        if let ri = spec.rescaleIntercept { ds.append(el(0x0028, 0x1052, "DS", text(ri))) }
        if let rs = spec.rescaleSlope { ds.append(el(0x0028, 0x1053, "DS", text(rs))) }
        var px = pixelBytes
        if px.count % 2 == 1 { px.append(0) }
        ds.append(el(0x7FE0, 0x0010, spec.bitsAllocated > 8 ? "OW" : "OB", px))
        return spec.includePreamble ? part10(transferSyntax: spec.transferSyntax, dataset: ds) : ds
    }

    static func le16(_ values: [Int]) -> Data {
        var d = Data()
        for v in values { d.append(contentsOf: u16(UInt16(truncatingIfNeeded: v))) }
        return d
    }

    static func be16(_ values: [Int]) -> Data {
        var d = Data()
        for v in values { d.append(contentsOf: u16(UInt16(truncatingIfNeeded: v), bigEndian: true)) }
        return d
    }

    static func le32(_ values: [Int]) -> Data {
        var d = Data()
        for v in values { d.append(contentsOf: u32(UInt32(truncatingIfNeeded: v))) }
        return d
    }

    /// Write data to a fresh temporary file with the given name.
    static func writeTemp(_ data: Data, name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("odv-synthetic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}
