// PixelValues.swift
// OpenDicomViewer
//
// Shared helpers for decoded pixel buffers so every consumer (HU readout,
// ROI stats, histogram, W/L, volume building) interprets them the same way:
//
//   PixelValues        — read 8/16/32-bit signed/unsigned and RGB samples,
//                        min/max, and the default window for an image
//   PlainPixelDecoder  — normalizes uncompressed PixelData read by the pure
//                        Swift parser (BitsAllocated, endianness, planar
//                        configuration, Modality LUT) into the same layout
//                        and units the DCMTK path produces
//   PixelDisplayMapping — maps between raw pixel rows/columns and the
//                        displayed NSImage's coordinate space (which differs
//                        for aspect-corrected MPR/MIP images)
//
// Convention: decoded monochrome values are in modality units (RescaleSlope
// and RescaleIntercept applied, e.g. Hounsfield Units), matching DCMTK's
// getInterData(). Color is 8-bit interleaved RGB.
// Licensed under the MIT License. See LICENSE for details.

import Foundation
import CoreGraphics

enum PixelValues {
    /// Bytes per stored sample for a decoded buffer of the given bit depth.
    @inline(__always)
    static func bytesPerSample(bits: Int) -> Int {
        bits > 16 ? 4 : (bits > 8 ? 2 : 1)
    }

    /// Value of pixel `index` (row-major). For RGB, returns the mean of the
    /// three channels. Returns nil when out of bounds.
    static func value(in data: Data, index: Int, bits: Int, isSigned: Bool, samples: Int = 1) -> Double? {
        guard index >= 0 else { return nil }
        return data.withUnsafeBytes { raw in
            value(in: raw, index: index, bits: bits, isSigned: isSigned, samples: samples)
        }
    }

    @inline(__always)
    static func value(in raw: UnsafeRawBufferPointer, index: Int, bits: Int, isSigned: Bool, samples: Int = 1) -> Double? {
        let bps = bytesPerSample(bits: bits)
        let spp = max(1, samples)
        let start = index * spp * bps
        guard index >= 0, start + spp * bps <= raw.count else { return nil }
        if spp == 1 {
            return sample(raw, byteOffset: start, bps: bps, isSigned: isSigned)
        }
        var sum = 0.0
        for c in 0..<min(spp, 3) {
            sum += sample(raw, byteOffset: start + c * bps, bps: bps, isSigned: isSigned)
        }
        return sum / Double(min(spp, 3))
    }

    @inline(__always)
    private static func sample(_ raw: UnsafeRawBufferPointer, byteOffset: Int, bps: Int, isSigned: Bool) -> Double {
        switch bps {
        case 4:
            let v = raw.loadUnaligned(fromByteOffset: byteOffset, as: UInt32.self)
            return isSigned ? Double(Int32(bitPattern: v)) : Double(v)
        case 2:
            let v = raw.loadUnaligned(fromByteOffset: byteOffset, as: UInt16.self)
            return isSigned ? Double(Int16(bitPattern: v)) : Double(v)
        default:
            let v = raw[byteOffset]
            return isSigned ? Double(Int8(bitPattern: v)) : Double(v)
        }
    }

    /// Min/max over a decoded buffer (monochrome; RGB uses channel means).
    static func minMax(data: Data, bits: Int, isSigned: Bool, samples: Int = 1) -> (min: Double, max: Double) {
        let bps = bytesPerSample(bits: bits)
        let count = data.count / (bps * max(1, samples))
        var lo = Double.greatestFiniteMagnitude
        var hi = -Double.greatestFiniteMagnitude
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                guard let v = value(in: raw, index: i, bits: bits, isSigned: isSigned, samples: samples) else { break }
                if v < lo { lo = v }
                if v > hi { hi = v }
            }
        }
        if lo > hi { return (0, 1) }
        if hi == lo { hi = lo + 1 }
        return (lo, hi)
    }

    /// Initial window for an image: the file's stored WindowWidth/Center when
    /// present, otherwise the full data range.
    static func defaultWindow(storedWidth: Double?, storedCenter: Double?,
                              data: Data, bits: Int, isSigned: Bool, samples: Int = 1) -> (width: Double, center: Double) {
        if let w = storedWidth, w > 0, let c = storedCenter {
            return (w, c)
        }
        let (lo, hi) = minMax(data: data, bits: bits, isSigned: isSigned, samples: samples)
        let w = hi - lo
        return (w, lo + w / 2)
    }

    /// Convert a buffer to Int32 values (used to hand MPR/MIP slices with a
    /// non-identity volume encoding to consumers in modality units).
    static func int16ToModalityInt32(_ data: Data, slope: Double, intercept: Double) -> Data {
        let count = data.count / 2
        var out = Data(count: count * 4)
        data.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                let s = src.bindMemory(to: Int16.self)
                let d = dst.bindMemory(to: Int32.self)
                for i in 0..<count {
                    let v = (Double(s[i]) * slope + intercept).rounded()
                    d[i] = Int32(clamping: Int64(max(-2_147_483_648, min(2_147_483_647, v))))
                }
            }
        }
        return out
    }
}

// MARK: - Header-derived pixel attributes

/// Pixel-related attributes read from a parsed header.
struct DicomPixelAttributes {
    var rows: Int?
    var columns: Int?
    var bitsAllocated: Int = 16
    var bitsStored: Int = 16
    var highBit: Int = 15
    var pixelRepresentation: Int = 0
    var samplesPerPixel: Int = 1
    var planarConfiguration: Int = 0
    var photometric: String = "MONOCHROME2"
    var rescaleSlope: Double = 1
    var rescaleIntercept: Double = 0
    var windowCenter: Double?
    var windowWidth: Double?

    var isMonochrome1: Bool { photometric.uppercased().contains("MONOCHROME1") }

    init() {}

    init(elements: [DicomElement], bigEndian: Bool = false) {
        func el(_ g: UInt16, _ e: UInt16) -> DicomElement? {
            elements.first(where: { $0.tag == DicomTag(group: g, element: e) })
        }
        func str(_ g: UInt16, _ e: UInt16) -> String? {
            el(g, e)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        /// US values are binary; IS/DS are text. Handles both and big endian.
        func int(_ g: UInt16, _ e: UInt16) -> Int? {
            guard let element = el(g, e) else { return nil }
            if element.vr == .IS || element.vr == .DS, let s = element.stringValue, let v = Int(s) { return v }
            if element.data.count == 2 {
                let b = [UInt8](element.data)
                return bigEndian ? Int(UInt16(b[0]) << 8 | UInt16(b[1])) : Int(UInt16(b[1]) << 8 | UInt16(b[0]))
            }
            if element.data.count == 4 && element.vr != .IS {
                let b = [UInt8](element.data)
                let v = bigEndian
                    ? UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
                    : UInt32(b[3]) << 24 | UInt32(b[2]) << 16 | UInt32(b[1]) << 8 | UInt32(b[0])
                return Int(v)
            }
            if let s = element.stringValue, let v = Int(s) { return v }
            return nil
        }
        /// First value of a (possibly multi-valued) DS.
        func ds(_ g: UInt16, _ e: UInt16) -> Double? {
            guard let s = str(g, e) else { return nil }
            let first = s.components(separatedBy: "\\").first?.trimmingCharacters(in: .whitespaces) ?? ""
            return Double(first)
        }
        rows = int(0x0028, 0x0010)
        columns = int(0x0028, 0x0011)
        bitsAllocated = int(0x0028, 0x0100) ?? 16
        bitsStored = int(0x0028, 0x0101) ?? bitsAllocated
        highBit = int(0x0028, 0x0102) ?? (bitsStored - 1)
        pixelRepresentation = int(0x0028, 0x0103) ?? 0
        samplesPerPixel = int(0x0028, 0x0002) ?? 1
        planarConfiguration = int(0x0028, 0x0006) ?? 0
        photometric = str(0x0028, 0x0004) ?? "MONOCHROME2"
        if let s = ds(0x0028, 0x1053), s != 0 { rescaleSlope = s }
        rescaleIntercept = ds(0x0028, 0x1052) ?? 0
        windowCenter = ds(0x0028, 0x1050)
        windowWidth = ds(0x0028, 0x1051)
    }

    /// Parse the header of a file (first 64 KB is enough for pixel attributes).
    static func read(url: URL) -> DicomPixelAttributes? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let data = (try? fh.read(upToCount: 65_536)) ?? Data()
        let parser = SimpleDicomParser(data: data)
        guard let (elements, _, ts) = try? parser.parse(stopAtPixelData: true) else { return nil }
        let be = ts?.trimmingCharacters(in: .controlCharacters.union(.whitespaces)) == "1.2.840.10008.1.2.2"
        return DicomPixelAttributes(elements: elements, bigEndian: be)
    }
}

// MARK: - Plain-parser decode

/// A decoded buffer in the app's common layout.
struct DecodedPixelBuffer {
    let data: Data
    let width: Int
    let height: Int
    /// 8, 16 or 32 (bytes per sample = 1, 2, 4)
    let bitDepth: Int
    let samples: Int
    let isSigned: Bool
}

enum PlainPixelDecoder {
    /// Normalize uncompressed PixelData to the common layout: monochrome
    /// values with the Modality LUT applied (8/16/32-bit chosen to fit),
    /// or 8-bit interleaved RGB. Handles BitsAllocated 8/16/32, BitsStored
    /// masking with sign extension, big-endian data and PlanarConfiguration=1.
    static func decode(pixelData: Data, attributes a: DicomPixelAttributes, bigEndian: Bool) -> DecodedPixelBuffer? {
        guard let width = a.columns, let height = a.rows,
              width > 0, height > 0 else { return nil }
        let bitsAllocated = a.bitsAllocated
        guard [8, 16, 32].contains(bitsAllocated) else { return nil }
        let bps = bitsAllocated / 8
        let spp = max(1, a.samplesPerPixel)
        let pixelCount = width * height
        guard pixelData.count >= pixelCount * spp * bps else { return nil }

        let bitsStored = min(max(1, a.bitsStored), bitsAllocated)
        let highBit = min(max(bitsStored - 1, a.highBit), bitsAllocated - 1)
        let shift = highBit + 1 - bitsStored
        let mask: UInt64 = bitsStored >= 64 ? .max : (UInt64(1) << UInt64(bitsStored)) - 1
        let signed = a.pixelRepresentation == 1

        func stored(_ raw: UnsafeRawBufferPointer, _ sampleIndex: Int) -> Int64 {
            let off = sampleIndex * bps
            var u: UInt64
            switch bps {
            case 4:
                let v = raw.loadUnaligned(fromByteOffset: off, as: UInt32.self)
                u = UInt64(bigEndian ? UInt32(bigEndian: v) : UInt32(littleEndian: v))
            case 2:
                let v = raw.loadUnaligned(fromByteOffset: off, as: UInt16.self)
                u = UInt64(bigEndian ? UInt16(bigEndian: v) : UInt16(littleEndian: v))
            default:
                u = UInt64(raw[off])
            }
            u = (u >> UInt64(shift)) & mask
            if signed && bitsStored < 64 && (u & (UInt64(1) << UInt64(bitsStored - 1))) != 0 {
                return Int64(u) - Int64(1) << Int64(bitsStored)
            }
            return Int64(u)
        }

        if spp >= 3 {
            // Color → 8-bit interleaved RGB. Planar config 1 stores R plane, G plane, B plane.
            var rgb = Data(count: pixelCount * 3)
            let downShift = max(0, bitsStored - 8)
            pixelData.withUnsafeBytes { raw in
                rgb.withUnsafeMutableBytes { dst in
                    let out = dst.bindMemory(to: UInt8.self)
                    for i in 0..<pixelCount {
                        for c in 0..<3 {
                            let si = a.planarConfiguration == 1 ? c * pixelCount + i : i * spp + c
                            let v = stored(raw, si) >> Int64(downShift)
                            out[i * 3 + c] = UInt8(clamping: v)
                        }
                    }
                }
            }
            return DecodedPixelBuffer(data: rgb, width: width, height: height, bitDepth: 8, samples: 3, isSigned: false)
        }

        // Monochrome → modality values
        var values = [Double](repeating: 0, count: pixelCount)
        var lo = Double.greatestFiniteMagnitude
        var hi = -Double.greatestFiniteMagnitude
        pixelData.withUnsafeBytes { raw in
            for i in 0..<pixelCount {
                let v = Double(stored(raw, i)) * a.rescaleSlope + a.rescaleIntercept
                values[i] = v
                if v < lo { lo = v }
                if v > hi { hi = v }
            }
        }
        return pack(values, lo: lo, hi: hi, width: width, height: height)
    }

    /// Pack values into the narrowest of UInt8 / Int16 / UInt16 / Int32
    /// (same choice as the DCMTK wrapper's JPEG 2000 path).
    static func pack(_ values: [Double], lo: Double, hi: Double, width: Int, height: Int) -> DecodedPixelBuffer {
        let n = values.count
        if lo >= 0 && hi <= 255 {
            let d = Data(values.map { UInt8(clamping: Int($0.rounded())) })
            return DecodedPixelBuffer(data: d, width: width, height: height, bitDepth: 8, samples: 1, isSigned: false)
        }
        if lo >= -32768 && hi <= 32767 {
            var d = Data(count: n * 2)
            d.withUnsafeMutableBytes { p in
                let o = p.bindMemory(to: Int16.self)
                for i in 0..<n { o[i] = Int16(clamping: Int(values[i].rounded())) }
            }
            return DecodedPixelBuffer(data: d, width: width, height: height, bitDepth: 16, samples: 1, isSigned: true)
        }
        if lo >= 0 && hi <= 65535 {
            var d = Data(count: n * 2)
            d.withUnsafeMutableBytes { p in
                let o = p.bindMemory(to: UInt16.self)
                for i in 0..<n { o[i] = UInt16(clamping: Int(values[i].rounded())) }
            }
            return DecodedPixelBuffer(data: d, width: width, height: height, bitDepth: 16, samples: 1, isSigned: false)
        }
        var d = Data(count: n * 4)
        d.withUnsafeMutableBytes { p in
            let o = p.bindMemory(to: Int32.self)
            for i in 0..<n {
                let v = max(-2_147_483_648, min(2_147_483_647, values[i].rounded()))
                o[i] = Int32(v)
            }
        }
        return DecodedPixelBuffer(data: d, width: width, height: height, bitDepth: 32, samples: 1, isSigned: true)
    }
}

// MARK: - Raw pixel ↔ display mapping

/// Maps between raw pixel coordinates (columns × rows of the decoded buffer)
/// and the displayed NSImage's coordinate space. They differ for MPR/MIP
/// images whose NSImage size is aspect-corrected for non-isotropic spacing.
/// Annotations and ROIs are stored in display space; measurements, HU lookups
/// and patient-coordinate math need raw pixels.
struct PixelDisplayMapping: Equatable {
    let rawWidth: Double
    let rawHeight: Double
    let displayWidth: Double
    let displayHeight: Double

    init(rawWidth: Int, rawHeight: Int, displayWidth: CGFloat, displayHeight: CGFloat) {
        self.rawWidth = Double(rawWidth)
        self.rawHeight = Double(rawHeight)
        // Unknown display size → identity
        self.displayWidth = displayWidth > 0 ? Double(displayWidth) : Double(rawWidth)
        self.displayHeight = displayHeight > 0 ? Double(displayHeight) : Double(rawHeight)
    }

    var scaleX: Double { rawWidth > 0 && displayWidth > 0 ? rawWidth / displayWidth : 1 }
    var scaleY: Double { rawHeight > 0 && displayHeight > 0 ? rawHeight / displayHeight : 1 }

    func displayToRaw(_ p: CGPoint) -> CGPoint {
        CGPoint(x: Double(p.x) * scaleX, y: Double(p.y) * scaleY)
    }

    func rawToDisplay(_ p: CGPoint) -> CGPoint {
        CGPoint(x: Double(p.x) / scaleX, y: Double(p.y) / scaleY)
    }

    func displayRectToRaw(_ r: CGRect) -> CGRect {
        CGRect(x: Double(r.minX) * scaleX, y: Double(r.minY) * scaleY,
               width: Double(r.width) * scaleX, height: Double(r.height) * scaleY)
    }

    /// Integer raw pixel (column, row) under a display-space point, or nil if outside.
    func rawPixelIndex(_ p: CGPoint) -> (x: Int, y: Int)? {
        let r = displayToRaw(p)
        guard r.x.isFinite, r.y.isFinite, r.x >= 0, r.y >= 0 else { return nil }
        let x = Int(r.x), y = Int(r.y)
        guard Double(x) < rawWidth, Double(y) < rawHeight else { return nil }
        return (x, y)
    }

    /// Physical offset (mm) of a display-space vector. `pixelSpacing` is DICOM
    /// order: (row spacing = mm per raw row, column spacing = mm per raw column).
    /// Without spacing, the result is in raw pixels.
    func physicalVector(from a: CGPoint, to b: CGPoint, pixelSpacing: (Double, Double)?) -> (dx: Double, dy: Double) {
        let ra = displayToRaw(a), rb = displayToRaw(b)
        let dx = Double(rb.x - ra.x), dy = Double(rb.y - ra.y)
        guard let ps = pixelSpacing else { return (dx, dy) }
        return (dx * ps.1, dy * ps.0)
    }

    func distance(from a: CGPoint, to b: CGPoint, pixelSpacing: (Double, Double)?) -> Double {
        let v = physicalVector(from: a, to: b, pixelSpacing: pixelSpacing)
        return (v.dx * v.dx + v.dy * v.dy).squareRoot()
    }

    /// Angle (degrees) at `vertex` between the arms, measured in physical space.
    func angle(vertex: CGPoint, arm1: CGPoint, arm2: CGPoint, pixelSpacing: (Double, Double)?) -> Double {
        let v1 = physicalVector(from: vertex, to: arm1, pixelSpacing: pixelSpacing)
        let v2 = physicalVector(from: vertex, to: arm2, pixelSpacing: pixelSpacing)
        let m1 = (v1.dx * v1.dx + v1.dy * v1.dy).squareRoot()
        let m2 = (v2.dx * v2.dx + v2.dy * v2.dy).squareRoot()
        guard m1 > 0, m2 > 0 else { return 0 }
        let c = max(-1, min(1, (v1.dx * v2.dx + v1.dy * v2.dy) / (m1 * m2)))
        return acos(c) * 180 / .pi
    }
}

extension PanelState {
    /// Raw pixel ↔ displayed-image mapping for this panel's current image.
    var pixelDisplayMapping: PixelDisplayMapping {
        PixelDisplayMapping(rawWidth: imageWidth, rawHeight: imageHeight,
                            displayWidth: displayImageWidth, displayHeight: displayImageHeight)
    }
}
