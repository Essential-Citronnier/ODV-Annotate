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
            warnings.append(String(format: "Gantry tilt of %.1f° detected; reformats are sheared along the stacking direction.", tiltDegrees))
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
    /// 8/16-bit slices are stored as-is. When 32-bit slices hold values that
    /// don't fit Int16, the whole volume is stored with a linear encoding
    /// (stored = (value − intercept) / slope) instead of clamping.
    /// Missing slices (nil) are zero-filled.
    static func assemble(
        width: Int, height: Int, depth: Int,
        slice: (Int) throws -> SliceRaw?
    ) throws -> (voxels: UnsafeMutableBufferPointer<Int16>, slope: Double, intercept: Double) {
        let stride = width * height
        let buffer = UnsafeMutableBufferPointer<Int16>.allocate(capacity: stride * depth)
        buffer.initialize(repeating: 0)
        var success = false
        defer { if !success { buffer.deallocate() } }

        var wide: [(index: Int, values: [Int32])] = []
        var lo = Int64(Int16.max), hi = Int64(Int16.min)
        var any = false

        for z in 0..<depth {
            guard let s = try slice(z) else { continue }
            guard s.width == width, s.height == height else { throw VolumeBuilderError.inconsistentDimensions }
            let bps = PixelValues.bytesPerSample(bits: s.bits)
            guard s.data.count >= stride * bps else { continue }
            let offset = z * stride
            if bps == 4 {
                var values = [Int32](repeating: 0, count: stride)
                s.data.withUnsafeBytes { raw in
                    for i in 0..<stride {
                        let u = raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
                        let v = s.isSigned ? Int64(Int32(bitPattern: u)) : Int64(u)
                        let c = Int32(clamping: v)
                        values[i] = c
                        lo = min(lo, Int64(c)); hi = max(hi, Int64(c))
                    }
                }
                any = true
                wide.append((z, values))
            } else {
                s.data.withUnsafeBytes { raw in
                    for i in 0..<stride {
                        let v = Int64(PixelValues.value(in: raw, index: i, bits: s.bits, isSigned: s.isSigned) ?? 0)
                        let c = Int16(clamping: v)
                        buffer[offset + i] = c
                        lo = min(lo, Int64(c)); hi = max(hi, Int64(c))
                    }
                }
                any = true
            }
        }

        var slope = 1.0, intercept = 0.0
        if any && (lo < Int64(Int16.min) || hi > Int64(Int16.max)) {
            // Map [lo, hi] onto the full Int16 range
            slope = max(1.0, Double(hi - lo) / 65535.0)
            intercept = Double(lo) + 32768.0 * slope
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
            for i in 0..<stride {
                buffer[offset + i] = encode(Double(values[i]), slope: slope, intercept: intercept)
            }
        }
        success = true
        return (buffer, slope, intercept)
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

        let (buffer, slope, intercept) = try assemble(width: firstW, height: firstH, depth: depth) { z in
            progress?(Double(z) / Double(depth))
            guard let info = loadRawDataWithInfo(sorted[z], rawDataCache: rawDataCache, dcmtkCache: dcmtkCache),
                  info.samples == 1 else { return nil }
            return SliceRaw(data: info.data, width: info.width, height: info.height, bits: info.bits, isSigned: info.isSigned)
        }

        progress?(1.0)

        for w in geo.warnings { print("Volume build warning (\(series.seriesDescription)): \(w)") }

        return VolumeData(
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
            warnings: geo.warnings
        )
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
    /// directly, otherwise decoded to Int32.
    var modalityPixels: (data: Data, bits: Int, isSigned: Bool) {
        if rescaleSlope == 1 && rescaleIntercept == 0 { return (pixelData, 16, true) }
        return (PixelValues.int16ToModalityInt32(pixelData, slope: rescaleSlope, intercept: rescaleIntercept), 32, true)
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
    /// Generate an axial slab MIP/MinIP/Average by projecting consecutive axial slices.
    /// This is the clinical slab-MIP workflow used in CTA/MRA angiography:
    /// take N slices centered at `slabCenter`, max-project them into one 2D image.
    /// Output has the same width×height as a native axial slice.
    func axialSlabProjection(
        mode: ProjectionMode,
        slabCenter: Int,
        slabThickness: Int
    ) -> MPRSlice? {
        let halfSlab = slabThickness / 2
        let zStart = max(0, slabCenter - halfSlab)
        let zEnd = min(volume.depth - 1, slabCenter + halfSlab)
        guard zStart <= zEnd else { return nil }

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
