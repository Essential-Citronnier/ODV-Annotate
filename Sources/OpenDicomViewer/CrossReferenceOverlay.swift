// CrossReferenceOverlay.swift
// OpenDicomViewer
//
// Draws cross-reference lines on a panel showing where other panels' slice
// planes intersect the current image plane. Uses DICOM spatial metadata
// (ImagePositionPatient, ImageOrientationPatient, PixelSpacing) to compute
// the geometric intersection of two image planes in 3D patient space, then
// projects the result into 2D pixel coordinates.
//
// The overlay respects the panel's current zoom, pan, rotation, and flip
// transforms so lines stay aligned with the displayed image.
//
// Each panel gets a distinct color (blue, green, yellow, red) for its
// cross-reference line, drawn as a dashed stroke.
// Licensed under the MIT License. See LICENSE for details.

import SwiftUI

/// Draws cross-reference lines showing where other panels' slices intersect this panel's image plane.
struct CrossReferenceOverlay: View {
    @ObservedObject var model: DICOMModel
    @ObservedObject var panel: PanelState

    /// Color per panel slot index
    static let panelColors: [Color] = [.blue, .green, .yellow, .red]

    var body: some View {
        GeometryReader { geo in
            ForEach(model.panels.filter { $0.id != panel.id }) { otherPanel in
                // Use a sub-view so SwiftUI observes otherPanel's @Published changes
                CrossRefLineView(
                    displayPanel: panel,
                    sourcePanel: otherPanel,
                    displayFrameOfReference: frameOfReference(for: panel),
                    sourceFrameOfReference: frameOfReference(for: otherPanel),
                    color: panelColor(for: otherPanel),
                    viewSize: geo.size
                )
            }
        }
        .allowsHitTesting(false)
    }

    /// FrameOfReferenceUID of the image a panel shows (series-level).
    private func frameOfReference(for p: PanelState) -> String? {
        guard p.seriesIndex >= 0, p.seriesIndex < model.allSeries.count else { return nil }
        let images = model.allSeries[p.seriesIndex].images
        let ctx = images.indices.contains(p.imageIndex) ? images[p.imageIndex] : images.first
        return ctx?.frameOfReferenceUID?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func panelColor(for targetPanel: PanelState) -> Color {
        guard let index = model.panels.firstIndex(where: { $0.id == targetPanel.id }) else {
            return .white
        }
        return Self.panelColors[index % Self.panelColors.count]
    }

}

/// Sub-view that observes BOTH display and source panels so the line updates
/// when either panel scrolls (changes imagePositionPatient).
private struct CrossRefLineView: View {
    @ObservedObject var displayPanel: PanelState
    @ObservedObject var sourcePanel: PanelState
    let displayFrameOfReference: String?
    let sourceFrameOfReference: String?
    let color: Color
    let viewSize: CGSize

    var body: some View {
        if let line = CrossReferenceOverlay.computeCrossReference(
            displayPanel: displayPanel, sourcePanel: sourcePanel,
            displayFrameOfReference: displayFrameOfReference,
            sourceFrameOfReference: sourceFrameOfReference
        ) {
            let p0 = pixelToScreen(line.startPixel)
            let p1 = pixelToScreen(line.endPixel)

            Path { path in
                path.move(to: p0)
                path.addLine(to: p1)
            }
            .stroke(
                color,
                style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
            )
            .opacity(0.7)
        }
    }

    private func pixelToScreen(_ pixel: CGPoint) -> CGPoint {
        let imgW = max(1, displayPanel.displayImageWidth)
        let imgH = max(1, displayPanel.displayImageHeight)
        let vw = viewSize.width
        let vh = viewSize.height

        // Aspect-ratio-preserving fit (matches .scaleProportionallyUpOrDown)
        let fitScale = min(vw / imgW, vh / imgH)
        let offsetX = (vw - imgW * fitScale) / 2
        let offsetY = (vh - imgH * fitScale) / 2

        var x = pixel.x * fitScale + offsetX
        var y = pixel.y * fitScale + offsetY

        // Center-relative (transforms applied around view center)
        let cx = vw / 2
        let cy = vh / 2
        x -= cx
        y -= cy

        // Flip
        if displayPanel.isFlippedH { x = -x }
        if displayPanel.isFlippedV { y = -y }

        // Rotation (90° steps)
        let steps = displayPanel.rotationSteps % 4
        if steps > 0 {
            let angle = -CGFloat(steps) * .pi / 2
            let cosA = cos(angle)
            let sinA = sin(angle)
            let rx = x * cosA - y * sinA
            let ry = x * sinA + y * cosA
            x = rx
            y = ry
        }

        // Zoom
        x *= displayPanel.scale
        y *= displayPanel.scale

        // Pan (translation is screen-space; Y is inverted between NSView Y-up and SwiftUI Y-down)
        x += displayPanel.translation.x
        y -= displayPanel.translation.y

        x += cx
        y += cy
        return CGPoint(x: x, y: y)
    }
}

extension CrossReferenceOverlay {

    // MARK: - Cross-Reference Geometry

    struct CrossReferenceLine {
        var startPixel: CGPoint
        var endPixel: CGPoint
    }

    /// Compute where `sourcePanel`'s slice plane intersects `displayPanel`'s image plane.
    /// Returns coordinates in the display panel's displayed-image space (the
    /// space `pixelToScreen` and annotations use), or nil if the planes are
    /// parallel, spatial metadata is missing, or the panels are in different
    /// frames of reference.
    static func computeCrossReference(
        displayPanel: PanelState,
        sourcePanel: PanelState,
        displayFrameOfReference: String? = nil,
        sourceFrameOfReference: String? = nil
    ) -> CrossReferenceLine? {
        // Positions in different frames of reference aren't comparable.
        if let a = displayFrameOfReference, let b = sourceFrameOfReference, !a.isEmpty, !b.isEmpty, a != b {
            return nil
        }
        guard let posA = displayPanel.imagePositionPatient,
              let oriA = displayPanel.imageOrientationPatient, oriA.count == 6,
              let spacingA = displayPanel.pixelSpacing,
              let posB = sourcePanel.imagePositionPatient,
              let oriB = sourcePanel.imageOrientationPatient, oriB.count == 6
        else { return nil }

        guard let raw = intersectionInPixels(
            originA: SIMD3(posA.0, posA.1, posA.2),
            rowA: SIMD3(oriA[0], oriA[1], oriA[2]),
            colA: SIMD3(oriA[3], oriA[4], oriA[5]),
            pixelSpacingA: spacingA,
            widthA: displayPanel.imageWidth,
            heightA: displayPanel.imageHeight,
            originB: SIMD3(posB.0, posB.1, posB.2),
            rowB: SIMD3(oriB[0], oriB[1], oriB[2]),
            colB: SIMD3(oriB[3], oriB[4], oriB[5])
        ) else { return nil }

        // Raw rows/columns → displayed image space (differs for aspect-corrected MPR/MIP)
        let mapping = displayPanel.pixelDisplayMapping
        return CrossReferenceLine(
            startPixel: mapping.rawToDisplay(raw.startPixel),
            endPixel: mapping.rawToDisplay(raw.endPixel)
        )
    }

    /// Intersection of plane B with image plane A, clipped to A's bounds, in
    /// A's raw pixel coordinates (x = column, y = row).
    ///
    /// A point on plane A is P = O_A + u·row_A + v·col_A (u, v in mm). It lies
    /// on plane B when n_B·(P − O_B) = 0, i.e. a·u + b·v = c with
    /// a = n_B·row_A, b = n_B·col_A, c = n_B·(O_B − O_A). This holds for any
    /// (oblique) orientation; with u = x·colSpacing, v = y·rowSpacing it is a
    /// line in pixel space that we clip to the image rectangle.
    static func intersectionInPixels(
        originA: SIMD3<Double>, rowA: SIMD3<Double>, colA: SIMD3<Double>,
        pixelSpacingA: (Double, Double), widthA: Int, heightA: Int,
        originB: SIMD3<Double>, rowB: SIMD3<Double>, colB: SIMD3<Double>
    ) -> CrossReferenceLine? {
        let rowSpacing = pixelSpacingA.0  // mm per row step (Y)
        let colSpacing = pixelSpacingA.1  // mm per column step (X)
        guard colSpacing > 0, rowSpacing > 0, widthA > 0, heightA > 0 else { return nil }

        let nB = cross(rowB, colB)
        let nBLen = length(nB)
        guard nBLen > 1e-9 else { return nil }
        let normalB = nB / nBLen

        // Line in pixel space: A·x + B·y = C
        let A = dot(normalB, rowA) * colSpacing
        let B = dot(normalB, colA) * rowSpacing
        let C = dot(normalB, originB - originA)

        // Parallel planes: plane B's normal is (anti)parallel to A's normal
        let nA = cross(rowA, colA)
        if length(cross(nA, normalB)) < 1e-6 * max(1, length(nA)) { return nil }
        guard abs(A) > 1e-12 || abs(B) > 1e-12 else { return nil }

        let w = Double(widthA), h = Double(heightA)
        var points: [CGPoint] = []
        func add(_ x: Double, _ y: Double) {
            let eps = 1e-9
            guard x >= -eps, x <= w + eps, y >= -eps, y <= h + eps, x.isFinite, y.isFinite else { return }
            let p = CGPoint(x: min(max(x, 0), w), y: min(max(y, 0), h))
            if !points.contains(where: { abs($0.x - p.x) < 1e-6 && abs($0.y - p.y) < 1e-6 }) {
                points.append(p)
            }
        }
        if abs(B) > 1e-12 {
            add(0, C / B)                 // left edge
            add(w, (C - A * w) / B)       // right edge
        }
        if abs(A) > 1e-12 {
            add(C / A, 0)                 // top edge
            add((C - B * h) / A, h)       // bottom edge
        }
        guard points.count >= 2 else { return nil }
        // Choose the two farthest-apart points (corner hits can add duplicates)
        var best = (points[0], points[1])
        var bestD = -1.0
        for i in 0..<points.count {
            for j in (i + 1)..<points.count {
                let dx = Double(points[i].x - points[j].x), dy = Double(points[i].y - points[j].y)
                let d = dx * dx + dy * dy
                if d > bestD { bestD = d; best = (points[i], points[j]) }
            }
        }
        guard bestD > 1e-12 else { return nil }
        return CrossReferenceLine(startPixel: best.0, endPixel: best.1)
    }

    private static func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3<Double>(
            a.y * b.z - a.z * b.y,
            a.z * b.x - a.x * b.z,
            a.x * b.y - a.y * b.x
        )
    }

    private static func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        a.x * b.x + a.y * b.y + a.z * b.z
    }

    private static func length(_ v: SIMD3<Double>) -> Double {
        sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
    }
}
