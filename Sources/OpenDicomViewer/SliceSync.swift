// SliceSync.swift
// OpenDicomViewer
//
// Orientation-independent slice geometry used for volumetric detection and
// synchronized scrolling. Positions are compared by projecting
// ImagePositionPatient onto the slice normal (row × column), so sagittal,
// coronal and oblique stacks work the same as axial ones (IPP.z alone is
// constant for a sagittal stack).
// Licensed under the MIT License. See LICENSE for details.

import Foundation
import simd

enum SliceSync {
    /// Unit normal of an image plane from its ImageOrientationPatient.
    static func normal(of orientation: [Double]?) -> SIMD3<Double>? {
        guard let o = orientation, o.count == 6 else { return nil }
        let n = simd_cross(SIMD3(o[0], o[1], o[2]), SIMD3(o[3], o[4], o[5]))
        let len = simd_length(n)
        return len > 1e-9 ? n / len : nil
    }

    /// True when the images form a stack: at least `minimumSlices` images,
    /// consistent orientation, and at least `minimumSlices` distinct positions
    /// along the slice normal.
    static func isVolumetric(_ images: [DicomImageContext], minimumSlices: Int = 10) -> Bool {
        guard images.count >= minimumSlices,
              let refOrientation = images.first?.imageOrientation, refOrientation.count == 6,
              let n = normal(of: refOrientation) else { return false }
        var positions = Set<Double>()
        for img in images {
            guard let orient = img.imageOrientation, orient.count == 6,
                  zip(refOrientation, orient).allSatisfy({ abs($0 - $1) < 0.01 }) else { return false }
            if let pos = img.imagePosition {
                // Round to 0.1 mm to merge floating-point duplicates
                positions.insert((simd_dot(pos, n) * 10).rounded() / 10)
            }
        }
        return positions.count >= minimumSlices
    }

    /// Index of the image whose plane is closest to `point` (distance measured
    /// along each image's own normal). Nil if any image lacks geometry.
    static func closestImageIndex(to point: SIMD3<Double>, in images: [DicomImageContext]) -> Int? {
        var best: (index: Int, distance: Double)?
        for (i, img) in images.enumerated() {
            guard let pos = img.imagePosition, let n = normal(of: img.imageOrientation) else { return nil }
            let d = abs(simd_dot(point - pos, n))
            if best == nil || d < best!.distance { best = (i, d) }
        }
        return best?.index
    }

    /// World point at the centre of an image plane (falls back to IPP).
    static func planeCenter(position: SIMD3<Double>, orientation: [Double]?,
                            pixelSpacing: (Double, Double)?, columns: Int, rows: Int) -> SIMD3<Double> {
        guard let o = orientation, o.count == 6, let ps = pixelSpacing, columns > 0, rows > 0 else { return position }
        let row = SIMD3(o[0], o[1], o[2]), col = SIMD3(o[3], o[4], o[5])
        return position + Double(columns - 1) / 2 * ps.1 * row + Double(rows - 1) / 2 * ps.0 * col
    }
}
