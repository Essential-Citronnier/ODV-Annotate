// MPREngine.swift
// OpenDicomViewer
//
// CPU-based Multi-Planar Reconstruction (MPR) engine. Extracts oblique 2D
// slices from a 3D VolumeData by sampling along orthogonal planes (sagittal,
// coronal) using trilinear interpolation. Converts the sampled voxel values
// to grayscale NSImage via window/level tone mapping.
//
// This is the fallback rendering path; GPU-accelerated rendering is handled
// by MetalVolumeRenderer for MIP projections.
// Licensed under the MIT License. See LICENSE for details.

import Foundation
import AppKit
import simd
import DCMTKWrapper

// MARK: - Volume Builder

enum VolumeBuilderError: Error, CustomStringConvertible {
    case noImages
    case inconsistentDimensions
    case missingPixelData(url: URL)
    case missingSpatialMetadata
    case inconsistentOrientation
    case nonUniformSpacing(maxDeviation: Double)
    case memoryLimitExceeded(requiredMB: Int)
    case duplicateSlicePositions(positions: Int, images: Int)

    var description: String {
        switch self {
        case .noImages: return "Series has no images"
        case .inconsistentDimensions: return "Images have different dimensions"
        case .missingPixelData(let url): return "Missing pixel data: \(url.lastPathComponent)"
        case .missingSpatialMetadata: return "Missing spatial metadata (position/orientation/spacing)"
        case .inconsistentOrientation: return "Images have different orientations"
        case .nonUniformSpacing(let dev): return "Non-uniform slice spacing (max deviation: \(String(format: "%.1f", dev))%)"
        case .memoryLimitExceeded(let mb): return "Volume exceeds memory limit (\(mb) MB)"
        case .duplicateSlicePositions(let positions, let images):
            return "\(images) images share \(positions) slice positions unevenly (mixed phases/acquisitions); cannot form one volume"
        }
    }
}

/// Slice geometry derived from a series before any pixel data is read.
struct VolumeGeometry {
    /// Images in stacking order (one per position; first phase when the
    /// series repeats positions)
    let images: [DicomImageContext]
    let rowDirection: SIMD3<Double>
    let colDirection: SIMD3<Double>
    /// Actual stacking direction (first → last position), unit length.
    /// Differs from row × col when the acquisition has gantry tilt.
    let stackDirection: SIMD3<Double>
    /// Distance between voxel planes along `stackDirection` (mm)
    let sliceSpacing: Double
    let pixelSpacing: SIMD2<Double>
    let origin: SIMD3<Double>
    /// Angle between the stacking direction and the slice normal (degrees)
    var tiltDegrees: Double = 0
    let warnings: [String]
}

struct VolumeBuilder {
    /// Maximum volume memory in bytes (default 1 GB)
    static let maxMemoryBytes = 1_073_741_824
    /// Two positions closer than this (mm, along the normal) are the same slice
    static let duplicatePositionTolerance = 0.01
    /// Spacing deviation (percent of median) above which we warn / refuse
    static let spacingWarnPercent = 5.0
    static let spacingFailPercent = 50.0
    /// Gantry tilt (degrees) above which we warn
    static let tiltWarnDegrees = 0.5

    /// Validate and order a series' slices: consistent orientation, duplicate
    /// positions (multi-phase CT, DWI → first phase, or refuse when uneven),
    /// spacing uniformity, and gantry tilt.
    static func geometry(for series: DicomSeries) throws -> VolumeGeometry {
        let images = series.images
        guard !images.isEmpty else { throw VolumeBuilderError.noImages }

        var firstOrient: [Double]?
        var firstSpacing: SIMD2<Double>?
        for img in images {
            if firstOrient == nil, let o = img.imageOrientation, o.count == 6 { firstOrient = o }
            if firstSpacing == nil, let s = img.pixelSpacing { firstSpacing = s }
            if firstOrient != nil && firstSpacing != nil { break }
        }
        guard let orient = firstOrient, let spacing = firstSpacing, spacing.x > 0, spacing.y > 0
        else { throw VolumeBuilderError.missingSpatialMetadata }

        for img in images {
            if let o = img.imageOrientation, o.count == 6,
               zip(o, orient).contains(where: { abs($0 - $1) > 0.01 }) {
                throw VolumeBuilderError.inconsistentOrientation
            }
        }

        let rowDir = simd_normalize(SIMD3<Double>(orient[0], orient[1], orient[2]))
        let colDir = simd_normalize(SIMD3<Double>(orient[3], orient[4], orient[5]))
        let normal = simd_normalize(simd_cross(rowDir, colDir))

        // Sort by projection onto the slice normal
        let projected = images.compactMap { img -> (DicomImageContext, Double)? in
            guard let pos = img.imagePosition else { return nil }
            return (img, simd_dot(pos, normal))
        }.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.instanceNumber < $1.0.instanceNumber }

        // Group images that share a position
        var groups: [[(DicomImageContext, Double)]] = []
        for entry in projected {
            if let last = groups.last?.first, abs(entry.1 - last.1) < duplicatePositionTolerance {
                groups[groups.count - 1].append(entry)
            } else {
                groups.append([entry])
            }
        }
        var warnings: [String] = []
        let maxGroup = groups.map(\.count).max() ?? 0
        if maxGroup > 1 {
            let counts = Set(groups.map(\.count))
            guard counts.count == 1 else {
                throw VolumeBuilderError.duplicateSlicePositions(positions: groups.count, images: projected.count)
            }
            warnings.append("Series repeats each slice position \(maxGroup)× (multi-phase or diffusion); using the first of each.")
        }
        let sorted = groups.map { group in
            group.min(by: { $0.0.instanceNumber < $1.0.instanceNumber })!
        }

        guard sorted.count >= 2 else { throw VolumeBuilderError.missingSpatialMetadata }

        // Slice spacing (median gap along the normal) and uniformity
        var gaps: [Double] = []
        for i in 1..<sorted.count { gaps.append(sorted[i].1 - sorted[i - 1].1) }
        let medianGap = gaps.sorted()[gaps.count / 2]
        guard medianGap > 1e-6 else { throw VolumeBuilderError.missingSpatialMetadata }
        let maxDeviation = gaps.map { abs($0 - medianGap) / medianGap * 100 }.max() ?? 0
        if maxDeviation > spacingFailPercent {
            throw VolumeBuilderError.nonUniformSpacing(maxDeviation: maxDeviation)
        } else if maxDeviation > spacingWarnPercent {
            warnings.append(String(format: "Slice spacing varies by up to %.1f%%; volume uses the median spacing.", maxDeviation))
        }

        // Gantry tilt: stacking direction vs. slice normal. Geometry follows
        // the real stacking vector so world coordinates stay correct.
        guard let firstPos = sorted.first?.0.imagePosition, let lastPos = sorted.last?.0.imagePosition
        else { throw VolumeBuilderError.missingSpatialMetadata }
        var stackDir = normal
        let span = lastPos - firstPos
        if simd_length(span) > 1e-6 {
            stackDir = simd_normalize(span)
            if simd_dot(stackDir, normal) < 0 { stackDir = -stackDir }
        }
        let cosTilt = min(1, max(-1, simd_dot(stackDir, normal)))
        let tiltDegrees = acos(cosTilt) * 180 / .pi
        if tiltDegrees > tiltWarnDegrees {
            warnings.append(String(format: "Gantry tilt of %.1f° detected.", tiltDegrees))
        }
        let sliceSpacing = medianGap / max(cosTilt, 1e-3)

        return VolumeGeometry(
            images: sorted.map(\.0),
            rowDirection: rowDir,
            colDirection: colDir,
            stackDirection: stackDir,
            sliceSpacing: sliceSpacing,
            pixelSpacing: spacing,
            origin: firstPos,
            tiltDegrees: tiltDegrees,
            warnings: warnings
        )
    }

    /// Decoded slice handed to `assemble`.
    struct SliceRaw {
        let data: Data
        let width: Int
        let height: Int
        let bits: Int
        let isSigned: Bool
    }

    /// Fill an Int16 voxel buffer from decoded slices (modality units).
    /// 8/16-bit slices are stored as-is. When slices hold values that Int16
    /// can't represent — unsigned 16-bit or 32-bit values outside its range, or fractional
    /// Float32 values (PET SUV-scaled, Philips MR) — the whole volume is
    /// stored with a linear encoding (stored = (value − intercept) / slope)
    /// spanning the data range, instead of clamping or rounding to integers.
    /// Missing slices (nil) are zero-filled. Slices whose dimensions differ
    /// from the volume's are left blank and reported in `mismatched`; when
    /// more than half differ the series is rejected.
    static func assemble(
        width: Int, height: Int, depth: Int,
        slice: (Int) throws -> SliceRaw?
    ) throws -> (voxels: UnsafeMutableBufferPointer<Int16>, slope: Double, intercept: Double, mismatched: [Int]) {
        let stride = width * height
        let buffer = UnsafeMutableBufferPointer<Int16>.allocate(capacity: stride * depth)
        buffer.initialize(repeating: 0)
        var success = false
        defer { if !success { buffer.deallocate() } }

        enum WideSlice {
            case int([Int32])
            case float([Float])
        }
        var wide: [(index: Int, values: WideSlice)] = []
        var lo = Double(Int16.max), hi = Double(Int16.min)
        var any = false
        var anyFractional = false
        var mismatched: [Int] = []

        for z in 0..<depth {
            guard let s = try slice(z) else { continue }
            guard s.width == width, s.height == height else {
                mismatched.append(z)
                continue
            }
            let bps = PixelValues.bytesPerSample(bits: s.bits)
            guard s.data.count >= stride * bps else { continue }
            let offset = z * stride
            if PixelValues.isFloat(bits: s.bits) {
                var values = [Float](repeating: 0, count: stride)
                s.data.withUnsafeBytes { raw in
                    for i in 0..<stride {
                        var v = raw.loadUnaligned(fromByteOffset: i * 4, as: Float32.self)
                        if !v.isFinite { v = 0 }
                        values[i] = v
                        let d = Double(v)
                        lo = min(lo, d); hi = max(hi, d)
                        if !anyFractional && !PixelValues.isIntegral(d) { anyFractional = true }
                    }
                }
                any = true
                wide.append((z, .float(values)))
            } else if bps == 2 && !s.isSigned && s.data.withUnsafeBytes({ raw in
                // Unsigned 16-bit above 32767 (MR, NM, integer PET) doesn't
                // fit Int16 as identity: take the wide path so it's rescaled
                // instead of clamped.
                (0..<stride).contains { (PixelValues.value(in: raw, index: $0, bits: s.bits, isSigned: false) ?? 0) > Double(Int16.max) }
            }) {
                var values = [Int32](repeating: 0, count: stride)
                s.data.withUnsafeBytes { raw in
                    for i in 0..<stride {
                        let v = Int32(PixelValues.value(in: raw, index: i, bits: s.bits, isSigned: false) ?? 0)
                        values[i] = v
                        lo = min(lo, Double(v)); hi = max(hi, Double(v))
                    }
                }
                any = true
                wide.append((z, .int(values)))
            } else if bps == 4 {
                var values = [Int32](repeating: 0, count: stride)
                s.data.withUnsafeBytes { raw in
                    for i in 0..<stride {
                        let u = raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
                        let v = s.isSigned ? Int64(Int32(bitPattern: u)) : Int64(u)
                        let c = Int32(clamping: v)
                        values[i] = c
                        lo = min(lo, Double(c)); hi = max(hi, Double(c))
                    }
                }
                any = true
                wide.append((z, .int(values)))
            } else {
                s.data.withUnsafeBytes { raw in
                    for i in 0..<stride {
                        let v = Int64(PixelValues.value(in: raw, index: i, bits: s.bits, isSigned: s.isSigned) ?? 0)
                        let c = Int16(clamping: v)
                        buffer[offset + i] = c
                        lo = min(lo, Double(c)); hi = max(hi, Double(c))
                    }
                }
                any = true
            }
        }
        if mismatched.count * 2 > depth { throw VolumeBuilderError.inconsistentDimensions }

        var slope = 1.0, intercept = 0.0
        if any && (anyFractional || lo < Double(Int16.min) || hi > Double(Int16.max)) {
            // Map [lo, hi] onto the full Int16 range. Integer data keeps a
            // slope of at least 1; fractional data uses whatever step the
            // range needs (e.g. 0.0003 SUV for a 0–20 SUV range).
            let span = (hi - lo) / 65535.0
            slope = anyFractional ? (span > 0 ? span : 1) : max(1.0, span)
            intercept = lo + 32768.0 * slope
            // Re-encode slices already stored as identity
            let wideIndices = Set(wide.map(\.index))
            for z in 0..<depth where !wideIndices.contains(z) {
                for i in (z * stride)..<((z + 1) * stride) {
                    buffer[i] = encode(Double(buffer[i]), slope: slope, intercept: intercept)
                }
            }
        }
        for (z, values) in wide {
            let offset = z * stride
            switch values {
            case .int(let v):
                for i in 0..<stride { buffer[offset + i] = encode(Double(v[i]), slope: slope, intercept: intercept) }
            case .float(let v):
                for i in 0..<stride { buffer[offset + i] = encode(Double(v[i]), slope: slope, intercept: intercept) }
            }
        }
        success = true
        return (buffer, slope, intercept, mismatched)
    }

    @inline(__always)
    private static func encode(_ v: Double, slope: Double, intercept: Double) -> Int16 {
        Int16(clamping: Int(((v - intercept) / slope).rounded()))
    }

    /// Build a VolumeData from a DICOM series.
    /// Reads modality-unit pixel data via DCMTK (or the JPEG 2000 fallback).
    /// `volumeID` identifies this build (series + file set) for GPU texture caching.
    static func build(
        series: DicomSeries,
        volumeID: String? = nil,
        rawDataCache: NSCache<NSURL, NSData>,
        dcmtkCache: NSCache<NSURL, DCMTKImageObject>,
        progress: ((Double) -> Void)? = nil
    ) throws -> VolumeData {
        let geo = try geometry(for: series)
        let sorted = geo.images
        let depth = sorted.count

        // Determine consistent dimensions — try multiple images if the first fails
        var firstW = 0, firstH = 0
        for img in sorted {
            if let (w, h, _, _) = try? loadImageDimensions(img, rawDataCache: rawDataCache, dcmtkCache: dcmtkCache) {
                firstW = w; firstH = h; break
            }
        }
        guard firstW > 0, firstH > 0 else {
            throw VolumeBuilderError.missingPixelData(url: sorted[0].url)
        }

        // Memory check
        let requiredBytes = firstW * firstH * depth * MemoryLayout<Int16>.stride
        if requiredBytes > maxMemoryBytes {
            throw VolumeBuilderError.memoryLimitExceeded(requiredMB: requiredBytes / (1024 * 1024))
        }

        // Clear caches for this series so every slice is decoded the same way
        // (all paths now yield modality units; this keeps stale entries from
        // older decodes out of the volume).
        for img in sorted {
            rawDataCache.removeObject(forKey: img.url as NSURL)
            dcmtkCache.removeObject(forKey: img.url as NSURL)
        }

        var missing = 0
        let (buffer, slope, intercept, mismatched) = try assemble(width: firstW, height: firstH, depth: depth) { z in
            progress?(Double(z) / Double(depth))
            guard let info = loadRawDataWithInfo(sorted[z], rawDataCache: rawDataCache, dcmtkCache: dcmtkCache),
                  info.samples == 1 else { missing += 1; return nil }
            return SliceRaw(data: info.data, width: info.width, height: info.height, bits: info.bits, isSigned: info.isSigned)
        }

        progress?(1.0)

        var warnings = geo.warnings
        if !mismatched.isEmpty {
            warnings.append("\(mismatched.count) of \(depth) slices have different dimensions from the rest and are left blank.")
        }
        if missing > 0 {
            warnings.append("\(missing) of \(depth) slices could not be decoded and are left blank.")
        }

        let volume = VolumeData(
            voxels: buffer,
            width: firstW,
            height: firstH,
            depth: depth,
            spacingX: geo.pixelSpacing.y,   // column spacing: mm between columns (along row direction)
            spacingY: geo.pixelSpacing.x,   // row spacing: mm between rows (along column direction)
            spacingZ: geo.sliceSpacing,
            origin: geo.origin,
            rowDirection: geo.rowDirection,
            colDirection: geo.colDirection,
            sliceDirection: geo.stackDirection,
            rescaleSlope: slope,
            rescaleIntercept: intercept,
            seriesUID: volumeID ?? series.id,
            warnings: warnings
        )
        guard geo.tiltDegrees > tiltWarnDegrees else { return volume }
        return correctGantryTilt(volume)
    }

    /// Resample a gantry-tilted stack onto an orthogonal grid.
    ///
    /// With gantry tilt every slice is an ordinary row × column plane, but
    /// successive slices are offset in-plane (the stacking direction is not
    /// the slice normal), so the voxel grid is sheared. The output grid keeps
    /// the row and column directions and stacks along the true normal, so its
    /// affine is orthonormal. Each output voxel is mapped back into the
    /// sheared grid through the exact patient-space affine and sampled
    /// trilinearly; the in-plane extent grows to hold every shifted slice and
    /// uncovered voxels are filled with the volume minimum (air for CT).
    /// Returns the input unchanged if the corrected grid would exceed the
    /// memory limit.
    static func correctGantryTilt(_ src: VolumeData) -> VolumeData {
        let normal = simd_normalize(simd_cross(src.rowDirection, src.colDirection))
        let s = src.sliceDirection
        let cosTilt = simd_dot(s, normal)
        guard cosTilt > 1e-3, src.depth > 1 else { return src }

        let W = src.width, H = src.height, D = src.depth
        // Distance between slice planes along the normal
        let dz = src.spacingZ * cosTilt
        // In-plane shift per slice, in source pixels
        let a = src.spacingZ * simd_dot(s, src.rowDirection) / src.spacingX
        let b = src.spacingZ * simd_dot(s, src.colDirection) / src.spacingY
        let lastK = Double(D - 1)
        let minA = min(0, a * lastK), maxA = max(0, a * lastK)
        let minB = min(0, b * lastK), maxB = max(0, b * lastK)
        let outW = W + Int(ceil(maxA - minA - 1e-9))
        let outH = H + Int(ceil(maxB - minB - 1e-9))

        if outW * outH * D * MemoryLayout<Int16>.stride > maxMemoryBytes {
            src.warnings.append("Shear correction skipped (resampled volume would exceed the memory limit); reformats are sheared.")
            return src
        }

        let outOrigin = src.origin
            + minA * src.spacingX * src.rowDirection
            + minB * src.spacingY * src.colDirection

        var pad = Int16.max
        for v in src.voxels where v < pad { pad = v }
        if src.voxels.isEmpty { pad = 0 }

        let out = UnsafeMutableBufferPointer<Int16>.allocate(capacity: outW * outH * D)
        // Source voxel coordinates of output voxel (i, j, k) via the affines.
        // Both affines are linear, so step per output index instead of
        // multiplying a matrix per voxel.
        let worldToSrc = src.worldToVoxelMatrix
        func srcCoord(_ world: SIMD3<Double>) -> SIMD3<Double> {
            let v = worldToSrc * SIMD4<Double>(world.x, world.y, world.z, 1)
            return SIMD3(v.x, v.y, v.z)
        }
        let o = srcCoord(outOrigin)
        let di = srcCoord(outOrigin + src.spacingX * src.rowDirection) - o
        let dj = srcCoord(outOrigin + src.spacingY * src.colDirection) - o
        let dk = srcCoord(outOrigin + dz * normal) - o
        let eps = 1e-6
        let maxX = Double(W - 1) + eps, maxY = Double(H - 1) + eps, maxZ = Double(D - 1) + eps

        DispatchQueue.concurrentPerform(iterations: D) { k in
            let sliceBase = k * outW * outH
            for j in 0..<outH {
                var p = o + Double(k) * dk + Double(j) * dj
                let rowBase = sliceBase + j * outW
                for i in 0..<outW {
                    if p.x < -eps || p.y < -eps || p.z < -eps || p.x > maxX || p.y > maxY || p.z > maxZ {
                        out[rowBase + i] = pad
                    } else {
                        out[rowBase + i] = Int16(clamping: Int(trilinear(src, p).rounded()))
                    }
                    p += di
                }
            }
        }

        let warnings = src.warnings.map {
            $0.hasPrefix("Gantry tilt") ? $0 + " Slices were resampled onto an orthogonal grid to remove the shear." : $0
        }
        return VolumeData(
            voxels: out,
            width: outW, height: outH, depth: D,
            spacingX: src.spacingX, spacingY: src.spacingY, spacingZ: dz,
            origin: outOrigin,
            rowDirection: src.rowDirection,
            colDirection: src.colDirection,
            sliceDirection: normal,
            rescaleSlope: src.rescaleSlope,
            rescaleIntercept: src.rescaleIntercept,
            seriesUID: src.seriesUID,
            warnings: warnings
        )
    }

    /// Trilinear sample of stored voxels at continuous coordinates already
    /// known to lie inside [0, dim − 1] (edges clamp instead of reading 0).
    @inline(__always)
    private static func trilinear(_ v: VolumeData, _ p: SIMD3<Double>) -> Double {
        let x = min(max(p.x, 0), Double(v.width - 1))
        let y = min(max(p.y, 0), Double(v.height - 1))
        let z = min(max(p.z, 0), Double(v.depth - 1))
        let x0 = Int(x), y0 = Int(y), z0 = Int(z)
        let x1 = min(x0 + 1, v.width - 1), y1 = min(y0 + 1, v.height - 1), z1 = min(z0 + 1, v.depth - 1)
        let fx = x - Double(x0), fy = y - Double(y0), fz = z - Double(z0)
        let w = v.width, plane = v.width * v.height
        @inline(__always) func at(_ xi: Int, _ yi: Int, _ zi: Int) -> Double {
            Double(v.voxels[zi * plane + yi * w + xi])
        }
        let c00 = at(x0, y0, z0) * (1 - fx) + at(x1, y0, z0) * fx
        let c10 = at(x0, y1, z0) * (1 - fx) + at(x1, y1, z0) * fx
        let c01 = at(x0, y0, z1) * (1 - fx) + at(x1, y0, z1) * fx
        let c11 = at(x0, y1, z1) * (1 - fx) + at(x1, y1, z1) * fx
        let c0 = c00 * (1 - fy) + c10 * fy
        let c1 = c01 * (1 - fy) + c11 * fy
        return c0 * (1 - fz) + c1 * fz
    }

    // MARK: - Private Helpers

    private static func loadImageDimensions(
        _ img: DicomImageContext,
        rawDataCache: NSCache<NSURL, NSData>,
        dcmtkCache: NSCache<NSURL, DCMTKImageObject>
    ) throws -> (width: Int, height: Int, bits: Int, isSigned: Bool) {
        // Try DCMTK object first
        if let dcmObj = dcmtkCache.object(forKey: img.url as NSURL) ?? DCMTKImageObject(path: img.url.path) {
            var w: Int = 0, h: Int = 0, d: Int = 0, s: Int = 0
            var signed: ObjCBool = false
            if dcmObj.getRawDataWidth(&w, height: &h, bitDepth: &d, samples: &s, isSigned: &signed) != nil {
                return (w, h, d, signed.boolValue)
            }
        }
        // JPEG 2000 fallback via OpenJPEG
        var w: Int = 0, h: Int = 0, d: Int = 0, s: Int = 0
        var signed: ObjCBool = false
        if DCMTKHelper.decodeJPEG2000DICOM(img.url.path, width: &w, height: &h, bitDepth: &d, samples: &s, isSigned: &signed) != nil {
            return (w, h, d, signed.boolValue)
        }
        throw VolumeBuilderError.missingPixelData(url: img.url)
    }

    /// Load modality-unit pixel data along with per-slice representation info
    private static func loadRawDataWithInfo(
        _ img: DicomImageContext,
        rawDataCache: NSCache<NSURL, NSData>,
        dcmtkCache: NSCache<NSURL, DCMTKImageObject>
    ) -> (data: Data, width: Int, height: Int, bits: Int, samples: Int, isSigned: Bool)? {
        // Try DCMTK
        if let dcmObj = dcmtkCache.object(forKey: img.url as NSURL) ?? DCMTKImageObject(path: img.url.path) {
            var w: Int = 0, h: Int = 0, d: Int = 0, s: Int = 0
            var signed: ObjCBool = false
            if let raw = dcmObj.getRawDataWidth(&w, height: &h, bitDepth: &d, samples: &s, isSigned: &signed) {
                rawDataCache.setObject(raw as NSData, forKey: img.url as NSURL)
                dcmtkCache.setObject(dcmObj, forKey: img.url as NSURL)
                return (raw as Data, w, h, d, s, signed.boolValue)
            }
        }
        // JPEG 2000 fallback via OpenJPEG (rescale applied in the wrapper)
        var w: Int = 0, h: Int = 0, d: Int = 0, s: Int = 0
        var signed: ObjCBool = false
        if let raw = DCMTKHelper.decodeJPEG2000DICOM(img.url.path, width: &w, height: &h, bitDepth: &d, samples: &s, isSigned: &signed) {
            rawDataCache.setObject(raw as NSData, forKey: img.url as NSURL)
            return (raw as Data, w, h, d, s, signed.boolValue)
        }
        return nil
    }
}

// MARK: - MPR Engine

/// Result of an MPR slice generation
struct MPRSlice {
    let pixelData: Data     // Stored Int16 values (see rescaleSlope/Intercept)
    let width: Int
    let height: Int
    /// World position of the centre of pixel (0, 0) — DICOM ImagePositionPatient
    let planeOrigin: SIMD3<Double>
    /// Direction of increasing column index (DICOM IOP row cosines)
    let planeRowDir: SIMD3<Double>
    /// Direction of increasing row index (DICOM IOP column cosines)
    let planeColDir: SIMD3<Double>
    /// mm between columns
    let pixelSpacingX: Double
    /// mm between rows
    let pixelSpacingY: Double
    /// value = stored × slope + intercept (from the volume's encoding)
    var rescaleSlope: Double = 1
    var rescaleIntercept: Double = 0

    /// DICOM-order PixelSpacing: (row spacing, column spacing)
    var dicomPixelSpacing: (Double, Double) { (pixelSpacingY, pixelSpacingX) }

    /// DICOM ImageOrientationPatient for this plane
    var imageOrientationPatient: [Double] {
        [planeRowDir.x, planeRowDir.y, planeRowDir.z, planeColDir.x, planeColDir.y, planeColDir.z]
    }

    /// Pixel data in modality units for consumers that read raw values
    /// (HU readout, ROI stats): Int16 when the volume stores modality values
    /// directly, Int32 for wide integer encodings, Float32 when the encoding
    /// has a fractional slope or intercept (e.g. PET).
    var modalityPixels: (data: Data, bits: Int, isSigned: Bool) {
        if rescaleSlope == 1 && rescaleIntercept == 0 { return (pixelData, 16, true) }
        if PixelValues.isIntegralRescale(slope: rescaleSlope, intercept: rescaleIntercept) {
            return (PixelValues.int16ToModalityInt32(pixelData, slope: rescaleSlope, intercept: rescaleIntercept), 32, true)
        }
        return (PixelValues.int16ToModalityFloat(pixelData, slope: rescaleSlope, intercept: rescaleIntercept), PixelValues.floatBits, true)
    }
}

/// Geometry of an orthogonal MPR plane, independent of pixel extraction so
/// panels can update spatial metadata before rendering.
struct MPRPlaneGeometry {
    let origin: SIMD3<Double>
    let rowDir: SIMD3<Double>
    let colDir: SIMD3<Double>
    let spacingX: Double
    let spacingY: Double
    let width: Int
    let height: Int
}

class MPREngine {
    let volume: VolumeData

    init(volume: VolumeData) {
        self.volume = volume
    }

    // MARK: - Orthogonal Slices

    /// Generate an axial slice at a given Z voxel index (fast path, no interpolation needed)
    func axialSlice(at zIndex: Int) -> MPRSlice? {
        guard zIndex >= 0, zIndex < volume.depth else { return nil }
        let w = volume.width
        let h = volume.height
        let sliceStride = w * h

        var data = Data(count: sliceStride * MemoryLayout<Int16>.stride)
        data.withUnsafeMutableBytes { buf in
            guard let dst = buf.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            let offset = zIndex * sliceStride
            for i in 0..<sliceStride {
                dst[i] = volume.voxels[offset + i]
            }
        }

        return makeSlice(data, axialGeometry(at: zIndex))
    }

    /// Whether sagittal/coronal reformats put the last slice on the top row
    /// (so superior is up when slices advance toward superior).
    var flipsZ: Bool { volume.sliceDirection.z >= 0 }

    /// Plane geometry of the sagittal reformat at X index `xIndex`.
    /// Row 0 is the last slice when `flipsZ`, so the origin and column
    /// direction follow the flip.
    func sagittalGeometry(at xIndex: Int) -> MPRPlaneGeometry {
        let zTop = flipsZ ? Double(volume.depth - 1) : 0
        return MPRPlaneGeometry(
            origin: volume.voxelToWorld(SIMD3<Double>(Double(xIndex), 0, zTop)),
            rowDir: volume.colDirection,
            colDir: flipsZ ? -volume.sliceDirection : volume.sliceDirection,
            spacingX: volume.spacingY,
            spacingY: volume.spacingZ,
            width: volume.height,
            height: volume.depth
        )
    }

    /// Plane geometry of the coronal reformat at Y index `yIndex`.
    func coronalGeometry(at yIndex: Int) -> MPRPlaneGeometry {
        let zTop = flipsZ ? Double(volume.depth - 1) : 0
        return MPRPlaneGeometry(
            origin: volume.voxelToWorld(SIMD3<Double>(0, Double(yIndex), zTop)),
            rowDir: volume.rowDirection,
            colDir: flipsZ ? -volume.sliceDirection : volume.sliceDirection,
            spacingX: volume.spacingX,
            spacingY: volume.spacingZ,
            width: volume.width,
            height: volume.depth
        )
    }

    /// Plane geometry of the axial slice (or slab centre) at Z index `zIndex`.
    func axialGeometry(at zIndex: Int) -> MPRPlaneGeometry {
        MPRPlaneGeometry(
            origin: volume.voxelToWorld(SIMD3<Double>(0, 0, Double(zIndex))),
            rowDir: volume.rowDirection,
            colDir: volume.colDirection,
            spacingX: volume.spacingX,
            spacingY: volume.spacingY,
            width: volume.width,
            height: volume.height
        )
    }

    private func makeSlice(_ data: Data, _ g: MPRPlaneGeometry) -> MPRSlice {
        MPRSlice(
            pixelData: data, width: g.width, height: g.height,
            planeOrigin: g.origin, planeRowDir: g.rowDir, planeColDir: g.colDir,
            pixelSpacingX: g.spacingX, pixelSpacingY: g.spacingY,
            rescaleSlope: volume.rescaleSlope, rescaleIntercept: volume.rescaleIntercept
        )
    }

    /// Generate a sagittal slice at a given X voxel index
    func sagittalSlice(at xIndex: Int) -> MPRSlice? {
        guard xIndex >= 0, xIndex < volume.width else { return nil }
        // Sagittal: rows = Z (depth), cols = Y (height)
        // Flip Z so superior is at top: only when sliceDirection.z >= 0 (z increases toward superior)
        let w = volume.height   // output width = Y dimension
        let h = volume.depth    // output height = Z dimension
        let flipZ = flipsZ

        var data = Data(count: w * h * MemoryLayout<Int16>.stride)
        data.withUnsafeMutableBytes { buf in
            guard let dst = buf.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for z in 0..<volume.depth {
                let outRow = flipZ ? (volume.depth - 1 - z) : z
                for y in 0..<volume.height {
                    dst[outRow * w + y] = volume.voxelAt(x: xIndex, y: y, z: z)
                }
            }
        }

        return makeSlice(data, sagittalGeometry(at: xIndex))
    }

    /// Generate a coronal slice at a given Y voxel index
    func coronalSlice(at yIndex: Int) -> MPRSlice? {
        guard yIndex >= 0, yIndex < volume.height else { return nil }
        // Coronal: rows = Z (depth), cols = X (width)
        // Flip Z so superior is at top: only when sliceDirection.z >= 0 (z increases toward superior)
        let w = volume.width    // output width = X dimension
        let h = volume.depth    // output height = Z dimension
        let flipZ = flipsZ

        var data = Data(count: w * h * MemoryLayout<Int16>.stride)
        data.withUnsafeMutableBytes { buf in
            guard let dst = buf.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for z in 0..<volume.depth {
                let outRow = flipZ ? (volume.depth - 1 - z) : z
                for x in 0..<volume.width {
                    dst[outRow * w + x] = volume.voxelAt(x: x, y: yIndex, z: z)
                }
            }
        }

        return makeSlice(data, coronalGeometry(at: yIndex))
    }

    // MARK: - Arbitrary Oblique Slice

    /// Generate an oblique slice through the volume defined by origin, row/col direction, and dimensions
    func obliqueSlice(
        origin: SIMD3<Double>,   // World coordinates of top-left corner
        rowDir: SIMD3<Double>,   // Normalized row direction
        colDir: SIMD3<Double>,   // Normalized column direction
        width: Int,
        height: Int,
        spacing: Double          // Output pixel spacing in mm
    ) -> MPRSlice {
        var data = Data(count: width * height * MemoryLayout<Int16>.stride)
        data.withUnsafeMutableBytes { buf in
            guard let dst = buf.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }

            for row in 0..<height {
                for col in 0..<width {
                    let worldPt = origin
                        + Double(col) * spacing * rowDir
                        + Double(row) * spacing * colDir

                    let voxel = volume.worldToVoxel(worldPt)
                    let val = volume.sampleTrilinear(vx: voxel.x, vy: voxel.y, vz: voxel.z)
                    dst[row * width + col] = Int16(clamping: Int(val.rounded()))
                }
            }
        }

        return MPRSlice(
            pixelData: data,
            width: width,
            height: height,
            planeOrigin: origin,
            planeRowDir: rowDir,
            planeColDir: colDir,
            pixelSpacingX: spacing,
            pixelSpacingY: spacing,
            rescaleSlope: volume.rescaleSlope,
            rescaleIntercept: volume.rescaleIntercept
        )
    }

    // MARK: - Rendering MPR to NSImage

    /// Render an MPR slice to a displayable image with Window/Level
    /// The NSImage size reflects physical dimensions (mm) so non-isotropic pixels display correctly
    static func renderSlice(_ slice: MPRSlice, ww: Double, wc: Double, invert: Bool = false) -> NSImage? {
        let totalPixels = slice.width * slice.height
        guard totalPixels > 0, ww > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil,
            width: slice.width,
            height: slice.height,
            bitsPerComponent: 8,
            bytesPerRow: slice.width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        guard let destData = context.data else { return nil }
        let destBuffer = destData.bindMemory(to: UInt8.self, capacity: totalPixels)

        // W/L is in modality units; voxels may be stored with an encoding
        let slope = slice.rescaleSlope == 0 ? 1 : slice.rescaleSlope
        let storedWW = ww / slope
        let windowBottom = (wc - slice.rescaleIntercept) / slope - (storedWW / 2.0)

        slice.pixelData.withUnsafeBytes { rawBuf in
            guard let src = rawBuf.baseAddress?.assumingMemoryBound(to: Int16.self),
                  slice.pixelData.count >= totalPixels * 2 else { return }

            for i in 0..<totalPixels {
                let val = Double(src[i])
                var norm = (val - windowBottom) / storedWW * 255.0
                if invert { norm = 255.0 - norm }
                destBuffer[i] = UInt8(max(0, min(255, norm)))
            }
        }

        guard let cgImage = context.makeImage() else { return nil }

        // Scale NSImage size to reflect physical dimensions so non-isotropic
        // pixels (e.g., sagittal/coronal with thick slices) display correctly.
        // Use the ratio of spacingY/spacingX to determine the aspect correction.
        let physicalWidth = Double(slice.width) * slice.pixelSpacingX
        let physicalHeight = Double(slice.height) * slice.pixelSpacingY
        let aspectRatio = physicalHeight / physicalWidth

        // Set display size: keep width as pixel width, scale height by aspect ratio
        let displayWidth = CGFloat(slice.width)
        let displayHeight = CGFloat(Double(slice.width) * aspectRatio)

        return NSImage(cgImage: cgImage, size: NSSize(width: displayWidth, height: displayHeight))
    }
}

// MARK: - Axial Slab Projection (Clinical MIP)

enum ProjectionMode: String, CaseIterable, Identifiable {
    case mip = "MIP"
    case minip = "MinIP"
    case average = "Average"

    var id: String { rawValue }
}

extension MPREngine {

    /// Modality value an axial slab projection shows at voxel column `x`,
    /// row `y`: the maximum (MIP), minimum (MinIP) or mean (Average) voxel
    /// along the projection ray through the slab. Used for the cursor
    /// readout of GPU-rendered projections, which have no CPU pixel buffer.
    func slabProjectionValue(mode: ProjectionMode, x: Int, y: Int,
                             slabCenter: Int, slabThickness: Int) -> Double? {
        guard x >= 0, x < volume.width, y >= 0, y < volume.height,
              let range = slabRange(center: slabCenter, thickness: slabThickness) else { return nil }
        var result: Double
        switch mode {
        case .mip: result = -Double.greatestFiniteMagnitude
        case .minip: result = Double.greatestFiniteMagnitude
        case .average: result = 0
        }
        for z in range {
            let v = Double(volume.voxelAt(x: x, y: y, z: z))
            switch mode {
            case .mip: result = max(result, v)
            case .minip: result = min(result, v)
            case .average: result += v
            }
        }
        if mode == .average { result /= Double(range.count) }
        return result * volume.rescaleSlope + volume.rescaleIntercept
    }

    /// Axial slice range a slab covers (clamped to the volume), or nil.
    /// The one slab definition shared by the CPU projection, the GPU
    /// projection (through `gpuSlab`) and the cursor readout.
    /// `thickness` is a slice count, so an unclamped slab spans exactly that
    /// many slices; an even count puts the extra slice after the centre.
    func slabRange(center: Int, thickness: Int) -> ClosedRange<Int>? {
        let count = max(1, thickness)
        let first = center - (count - 1) / 2
        let zStart = max(0, first)
        let zEnd = min(volume.depth - 1, first + count - 1)
        return zStart <= zEnd ? zStart...zEnd : nil
    }

    /// Slab parameters for `MetalVolumeRenderer.renderProjection` that make
    /// the GPU sample exactly the slices of `slabRange(center:thickness:)`:
    /// the slab spans [first − ½, last + ½] voxels along z (each slice's
    /// nearest-neighbour footprint), centred between the first and last
    /// slice, with its thickness in mm.
    func gpuSlab(center: Int, thickness: Int) -> (thicknessMM: Float, centerVoxel: SIMD3<Float>)? {
        guard let range = slabRange(center: center, thickness: thickness) else { return nil }
        let slices = Float(range.count)
        let midZ = Float(range.lowerBound + range.upperBound) / 2
        return (slices * Float(volume.spacingZ),
                SIMD3<Float>(Float(volume.width) / 2, Float(volume.height) / 2, midZ))
    }

    /// Generate an axial slab MIP/MinIP/Average by projecting consecutive axial slices.
    /// This is the clinical slab-MIP workflow used in CTA/MRA angiography:
    /// take N slices centered at `slabCenter`, max-project them into one 2D image.
    /// Output has the same width×height as a native axial slice.
    func axialSlabProjection(
        mode: ProjectionMode,
        slabCenter: Int,
        slabThickness: Int
    ) -> MPRSlice? {
        guard let range = slabRange(center: slabCenter, thickness: slabThickness) else { return nil }
        let zStart = range.lowerBound, zEnd = range.upperBound

        let w = volume.width
        let h = volume.height
        let pixelCount = w * h
        var data = Data(count: pixelCount * MemoryLayout<Int16>.stride)

        data.withUnsafeMutableBytes { buf in
            guard let dst = buf.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }

            switch mode {
            case .mip, .minip:
                for i in 0..<pixelCount { dst[i] = mode == .mip ? Int16.min : Int16.max }
                for z in zStart...zEnd {
                    let sliceOffset = z * pixelCount
                    for i in 0..<pixelCount {
                        let val = volume.voxels[sliceOffset + i]
                        if mode == .mip { if val > dst[i] { dst[i] = val } }
                        else if val < dst[i] { dst[i] = val }
                    }
                }
            case .average:
                // Accumulate in Int32: summing even a few Int16 slices overflows Int16
                var sum = [Int32](repeating: 0, count: pixelCount)
                for z in zStart...zEnd {
                    let sliceOffset = z * pixelCount
                    for i in 0..<pixelCount {
                        sum[i] &+= Int32(volume.voxels[sliceOffset + i])
                    }
                }
                let count = Double(zEnd - zStart + 1)
                for i in 0..<pixelCount {
                    dst[i] = Int16(clamping: Int((Double(sum[i]) / count).rounded()))
                }
            }
        }

        return makeSlice(data, axialGeometry(at: slabCenter))
    }
}

// MARK: - 3D Ray-March Projection (Legacy)

extension MPREngine {
    /// Generate a projection (MIP/MinIP/Average) through the volume along a given view direction
    func generateProjection(
        mode: ProjectionMode,
        viewDirection: SIMD3<Double>,
        upDirection: SIMD3<Double>,
        slabThickness: Double?,      // nil = full volume
        outputWidth: Int,
        outputHeight: Int,
        spacing: Double
    ) -> MPRSlice {
        let viewDir = simd_normalize(viewDirection)
        let right = simd_normalize(simd_cross(viewDir, upDirection))
        let up = simd_normalize(simd_cross(right, viewDir))

        let center = volume.worldCenter
        let bounds = volume.worldBounds

        // Compute ray length through volume (diagonal)
        let diagonal = simd_length(bounds.max - bounds.min)
        let halfLen = (slabThickness != nil) ? slabThickness! / 2.0 : diagonal / 2.0

        // Step size: half the minimum voxel spacing for quality
        let minSpacing = min(volume.spacingX, min(volume.spacingY, volume.spacingZ))
        let stepSize = minSpacing * 0.5
        let numSteps = Int(2.0 * halfLen / stepSize) + 1

        let halfW = Double(outputWidth) / 2.0
        let halfH = Double(outputHeight) / 2.0

        var data = Data(count: outputWidth * outputHeight * MemoryLayout<Int16>.stride)
        data.withUnsafeMutableBytes { buf in
            guard let dst = buf.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }

            for row in 0..<outputHeight {
                for col in 0..<outputWidth {
                    let u = (Double(col) - halfW) * spacing
                    let v = (Double(row) - halfH) * spacing

                    let rayOrigin = center + u * right + v * up - halfLen * viewDir

                    var result: Double
                    switch mode {
                    case .mip:   result = -Double.greatestFiniteMagnitude
                    case .minip: result = Double.greatestFiniteMagnitude
                    case .average: result = 0
                    }

                    var sampleCount = 0

                    for step in 0..<numSteps {
                        let t = Double(step) * stepSize
                        let worldPt = rayOrigin + t * viewDir
                        let voxel = volume.worldToVoxel(worldPt)

                        // Bounds check (with small margin)
                        guard voxel.x >= -0.5, voxel.x < Double(volume.width) - 0.5,
                              voxel.y >= -0.5, voxel.y < Double(volume.height) - 0.5,
                              voxel.z >= -0.5, voxel.z < Double(volume.depth) - 0.5 else { continue }

                        let val = volume.sampleTrilinear(vx: voxel.x, vy: voxel.y, vz: voxel.z)
                        sampleCount += 1

                        switch mode {
                        case .mip:     result = max(result, val)
                        case .minip:   result = min(result, val)
                        case .average: result += val
                        }
                    }

                    if mode == .average && sampleCount > 0 {
                        result /= Double(sampleCount)
                    }
                    if sampleCount == 0 { result = 0 }

                    dst[row * outputWidth + col] = Int16(clamping: Int(result.rounded()))
                }
            }
        }

        return MPRSlice(
            pixelData: data,
            width: outputWidth,
            height: outputHeight,
            planeOrigin: center - halfW * spacing * right - halfH * spacing * up,
            planeRowDir: right,
            planeColDir: up,
            pixelSpacingX: spacing,
            pixelSpacingY: spacing,
            rescaleSlope: volume.rescaleSlope,
            rescaleIntercept: volume.rescaleIntercept
        )
    }
}
