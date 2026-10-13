// MultiPanelContainer.swift
// OpenDicomViewer
//
// The main viewer area that arranges panels in a grid (1x1 to 2x2).
// Each panel is a self-contained DICOM image viewer with:
//   - Image display with aspect-ratio-preserving fit
//   - Mouse gesture handling: right-drag for W/L, scroll for navigation,
//     pinch-to-zoom, two-finger pan, click to activate
//   - Drag-and-drop series assignment from the sidebar
//   - Overlay layers: info strings, orientation labels, cross-reference
//     lines, ROI rectangle, cursor readout, cache progress bar
//   - Bottom toolbar: histogram, Auto W/L, ROI mode buttons
//
// Key types:
//   MultiPanelContainer      — Grid layout that creates PanelView per slot
//   PanelView                — Single panel: image + all overlays + gestures
//   InteractiveDICOMView     — NSViewRepresentable wrapping NSImageView with
//                              gesture recognizers for W/L, zoom, pan, scroll
//   PanelAdjustmentToolbar   — Bottom bar with histogram + Auto/ROI buttons
//   PanelHistogramView       — Miniature histogram with W/L window indicator
// Licensed under the MIT License. See LICENSE for details.

import SwiftUI
import QuartzCore

// MARK: - Multi-Panel Container

/// Arranges panels in a grid based on the current ViewerLayout.
struct MultiPanelContainer: View {
    @ObservedObject var model: DICOMModel
    @FocusState.Binding var isFocused: Bool

    var body: some View {
        let layout = model.layout

        // Fullscreen mode: show only the fullscreen panel
        if let fsID = model.fullscreenPanelID,
           let fsPanel = model.panels.first(where: { $0.id == fsID }) {
            PanelView(
                model: model,
                panel: fsPanel,
                isActive: true,
                isFocused: $isFocused
            )
            .id(fsPanel.id)
            .onTapGesture(count: 2) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    model.toggleFullscreen(for: fsPanel)
                }
            }
            .onTapGesture(count: 1) {
                isFocused = true
            }
        } else {
            // Grid mode — equal sizing via flexible frames
            let rows = layout.rows
            let cols = layout.columns

            VStack(spacing: 1) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: 1) {
                        ForEach(0..<cols, id: \.self) { col in
                            let index = row * cols + col
                            if index < model.panels.count {
                                let panel = model.panels[index]
                                PanelView(
                                    model: model,
                                    panel: panel,
                                    isActive: panel.id == model.activePanelID,
                                    isFocused: $isFocused
                                )
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .id(panel.id)
                                .onTapGesture(count: 2) {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        model.toggleFullscreen(for: panel)
                                    }
                                }
                                .onTapGesture(count: 1) {
                                    model.activePanelID = panel.id
                                    isFocused = true
                                }
                            } else {
                                EmptyPanelView()
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                    }
                }
            }
            .background(Color(white: 0.15))
        }
    }
}

// MARK: - Empty Panel View

struct EmptyPanelView: View {
    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 8) {
                Image(systemName: "rectangle.dashed")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("Drag a series here, or drop a DICOM folder")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

// MARK: - Panel View

/// Individual panel — refactored from the original DetailView.
/// Each panel has its own image, histogram, scrollbar, W/L, zoom/pan state.
struct PanelView: View {
    @ObservedObject var model: DICOMModel
    @ObservedObject var panel: PanelState
    let isActive: Bool
    @FocusState.Binding var isFocused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Image View
            if let image = panel.image {
                PanelInteractiveDICOMView(model: model, panel: panel, image: image)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .zIndex(0)
            } else if panel.errorMessage == nil && !panel.isLoading {
                if panel.seriesIndex >= 0 {
                    // Series assigned but no image yet
                    ProgressView()
                        .controlSize(.large)
                } else {
                    EmptyPanelView()
                }
            }

            // Top toolbar (Volume or Cine)
            if panel.seriesIndex >= 0 && panel.image != nil {
                VStack {
                    HStack {
                        if panel.isMultiFrame && panel.numberOfFrames > 1 {
                            CineToolbar(model: model, panel: panel)
                                .padding(6)
                        } else {
                            VolumeToolbar(model: model, panel: panel)
                                .padding(6)
                        }
                        Spacer()
                    }
                    // Non-blocking notice about the volume behind MPR/MIP
                    if panel.panelMode != .slice2D && !panel.volumeWarnings.isEmpty {
                        HStack {
                            VolumeWarningBadge(warnings: panel.volumeWarnings)
                                .padding(.horizontal, 6)
                            Spacer()
                        }
                    }
                    Spacer()
                }
                .zIndex(5)
            }

            // Shift-overlay for group selection (multi-panel only)
            if model.isShiftHeld && model.panels.count > 1 {
                ZStack {
                    if panel.isGroupSelected {
                        Color.orange.opacity(0.25)
                        VStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 36))
                                .foregroundStyle(.orange)
                            Text("Selected")
                                .font(.headline)
                                .foregroundStyle(.orange)
                        }
                    } else {
                        Color.black.opacity(0.5)
                        VStack(spacing: 8) {
                            Image(systemName: "hand.tap")
                                .font(.system(size: 36))
                                .foregroundStyle(.white.opacity(0.7))
                            Text("Click to select for\nsimultaneous scrolling")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.7))
                                .multilineTextAlignment(.center)
                        }
                    }
                }
                .allowsHitTesting(false)
                .zIndex(500)
            }

            // Cross-reference lines overlay
            if panel.image != nil && model.panels.count > 1 && model.showCrossReference {
                CrossReferenceOverlay(model: model, panel: panel)
                    .zIndex(10)
            }

            // ROI rectangle overlay
            if panel.image != nil, let roiRect = panel.roiRect {
                ROIOverlay(panel: panel, roiRect: roiRect)
                    .zIndex(12)
            }

            // Selected DICOM-derived annotation overlay (GSPS, RTSTRUCT, SEG)
            if panel.image != nil && !panel.importedOverlays.isEmpty {
                ImportedDICOMOverlay(panel: panel)
                    .zIndex(12.5)
            }

            // Annotation overlay (rulers, angles, ROI stats, AI annotations)
            if panel.image != nil {
                AnnotationOverlay(panel: panel)
                    .zIndex(13)
            }

            // AI analysis in-progress indicator (compact, top-right)
            if panel.aiAnalysisInProgress {
                VStack {
                    HStack {
                        Spacer()
                        HStack(spacing: 6) {
                            ProgressView()
                                .scaleEffect(0.6)
                                .tint(.yellow)
                            Text("AI Analyzing...")
                                .font(.system(.caption2, design: .rounded))
                                .foregroundStyle(.yellow)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(6)
                        .padding(.top, 8)
                        .padding(.trailing, 52)
                    }
                    Spacer()
                }
                .allowsHitTesting(false)
                .zIndex(14)
            }

            // Orientation labels (A/P/R/L/S/I)
            if panel.image != nil {
                OrientationLabelsOverlay(orientation: panel.imageOrientationPatient,
                                         rotationSteps: panel.rotationSteps,
                                         isFlippedH: panel.isFlippedH,
                                         isFlippedV: panel.isFlippedV)
                    .zIndex(15)
            }

            // Cursor info (HU readout)
            if panel.showCursorInfo {
                CursorInfoOverlay(panel: panel)
                    .zIndex(55)
            }

            // Error Overlay
            if let error = panel.errorMessage {
                ContentUnavailableView {
                    Label("Error", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error).font(.caption)
                }
                .background(Color.black.opacity(0.8))
                .zIndex(200)
            }

            // Info Overlay (bottom)
            if panel.image != nil {
                VStack {
                    Spacer()
                    HStack {
                        VStack(alignment: .leading) {
                            if !panel.currentSeriesInfo.isEmpty {
                                Text(panel.currentSeriesInfo).padding(4)
                            }
                            if panel.windowWidth != 0 {
                                Text(String(format: "WL: %.0f WW: %.0f", panel.windowCenter, panel.windowWidth))
                                    .padding(4)
                                    .font(.system(.caption, design: .monospaced))
                            }
                        }
                        .background(.thinMaterial)
                        .cornerRadius(8)

                        Spacer()

                        if !panel.currentImageInfo.isEmpty {
                            HStack {
                                if panel.cacheProgress < 1.0 && panel.cacheProgress > 0 {
                                    Text(String(format: "Loading: %.0f%%", panel.cacheProgress * 100))
                                        .font(.caption)
                                        .padding(6)
                                        .background(.thinMaterial)
                                        .cornerRadius(8)
                                        .transition(.opacity)
                                }
                                Text(panel.currentImageInfo)
                                    .padding(8)
                                    .background(.thinMaterial)
                                    .cornerRadius(8)
                            }
                            .animation(.easeInOut, value: panel.cacheProgress < 1.0)
                        }
                    }
                    .padding()
                }
                .zIndex(50)
            }

            // Adjustment Toolbar (bottom center)
            if panel.image != nil {
                VStack {
                    Spacer()
                    PanelAdjustmentToolbar(model: model, panel: panel)
                        .padding(.bottom, 20)
                }
                .zIndex(60)
            }

            // Right Side Scroller (always visible when series assigned)
            if panel.seriesIndex >= 0 {
                HStack {
                    Spacer()
                    PanelDICOMScroller(model: model, panel: panel)
                        .frame(width: 40)
                        .padding(.trailing, 4)
                        .padding(.vertical, 8)
                }
                .frame(maxHeight: .infinity)
                .zIndex(70)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Active panel border + group selection border
        .overlay(
            ZStack {
                // Group selection border (outer, orange)
                if panel.isGroupSelected {
                    Rectangle()
                        .stroke(Color.orange, lineWidth: 2.5)
                }
                // Active panel border (inner, accent color)
                Rectangle()
                    .stroke(isActive ? Color.accentColor : Color.clear, lineWidth: 1.5)
                    .padding(panel.isGroupSelected ? 2.5 : 0)
            }
        )
        .clipped()
    }
}

// MARK: - Volume Warning Badge

/// Compact, non-blocking notice on MPR/MIP panels when the volume was built
/// from imperfect geometry. Collapsed it shows a count; clicking expands the
/// explanations.
struct VolumeWarningBadge: View {
    let warnings: [String]
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { isExpanded.toggle() }) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(warnings.count == 1 ? "Volume geometry notice" : "\(warnings.count) volume geometry notices")
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                }
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(.yellow)
            }
            .buttonStyle(.plain)
            .help(warnings.joined(separator: "\n"))

            if isExpanded {
                ForEach(warnings, id: \.self) { warning in
                    Text("• " + warning)
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Reformats and projections may not match the acquired slices exactly.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: 360, alignment: .leading)
        .background(Color.black.opacity(0.7))
        .cornerRadius(6)
    }
}

// MARK: - Panel Interactive DICOM View (NSViewRepresentable)

struct PanelInteractiveDICOMView: NSViewRepresentable {
    @ObservedObject var model: DICOMModel
    @ObservedObject var panel: PanelState
    var image: NSImage

    func makeNSView(context: Context) -> PanelDICOMInteractView {
        let view = PanelDICOMInteractView()
        view.model = model
        view.panel = panel
        panel.cineDisplayView = view
        return view
    }

    func updateNSView(_ nsView: PanelDICOMInteractView, context: Context) {
        nsView.model = model
        nsView.panel = panel
        // During cine playback, frames are rendered directly via setCineFrame
        // on the CALayer. Skip the expensive SwiftUI image pipeline but still
        // apply the CALayer transform (zoom/pan) so W/L and navigation work.
        if !panel.isPlaying {
            nsView.setImage(image)
            nsView.applyFilters()
        }
        nsView.updateTransform()
        nsView.updateROICursor()
    }

    class PanelDICOMInteractView: NSView {
        weak var model: DICOMModel?
        var panel: PanelState?
        private var imageView = NSImageView()
        private var lastDragLocation: NSPoint?
        private var scrollAccumulator: CGFloat = 0.0
        private var roiStartPixel: CGPoint?  // ROI drag start in pixel coords
        private var isCrosshairCursorActive: Bool = false
        private var wlPendingDeltaWidth: Double = 0
        private var wlPendingDeltaCenter: Double = 0
        private var wlLastRenderTime: CFTimeInterval = 0
        private let wlRenderInterval: CFTimeInterval = 1.0 / 60.0

        // In-progress annotation state
        private var rulerStartPixel: CGPoint?
        private var anglePoints: [CGPoint] = []

        // Prevent image dimensions from influencing SwiftUI layout
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            setup()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setup()
        }

        override func layout() {
            super.layout()
            if let layer = imageView.layer {
                layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                let midX = self.bounds.width / 2.0
                let midY = self.bounds.height / 2.0
                layer.position = CGPoint(x: midX, y: midY)
            }
        }

        private func setup() {
            self.wantsLayer = true
            self.layer?.backgroundColor = NSColor.black.cgColor
            self.layer?.masksToBounds = true

            imageView.imageScaling = .scaleProportionallyUpOrDown
            // Prevent NSImageView from wanting to grow to its image's natural size
            imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
            imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
            imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            self.addSubview(imageView)

            imageView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                imageView.centerXAnchor.constraint(equalTo: self.centerXAnchor),
                imageView.centerYAnchor.constraint(equalTo: self.centerYAnchor),
                imageView.widthAnchor.constraint(equalTo: self.widthAnchor),
                imageView.heightAnchor.constraint(equalTo: self.heightAnchor)
            ])

            imageView.wantsLayer = true
            imageView.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)

            // Register for drag & drop: series from sidebar (.string) + files/folders from Finder (.fileURL)
            registerForDraggedTypes([.string, .fileURL])
        }

        // MARK: - Drag & Drop (NSDraggingDestination)

        private func hasDraggableContent(_ sender: NSDraggingInfo) -> Bool {
            let pb = sender.draggingPasteboard
            // Check for series index string (from sidebar)
            if let strs = pb.readObjects(forClasses: [NSString.self]) as? [String],
               let first = strs.first, Int(first) != nil {
                return true
            }
            // Check for file URLs (from Finder)
            if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]),
               !urls.isEmpty {
                return true
            }
            return false
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            hasDraggableContent(sender) ? .copy : []
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            hasDraggableContent(sender) ? .copy : []
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let pb = sender.draggingPasteboard

            // 1. Series index from sidebar
            if let strs = pb.readObjects(forClasses: [NSString.self]) as? [String],
               let first = strs.first,
               let seriesIndex = Int(first),
               let model = model, let panel = panel {
                DispatchQueue.main.async {
                    model.assignSeriesToPanel(panel, seriesIndex: seriesIndex)
                }
                return true
            }

            // 2. File/folder URL from Finder
            if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
               let url = urls.first,
               let model = model {
                DispatchQueue.main.async {
                    model.load(url: url)
                }
                return true
            }

            return false
        }

        func setImage(_ img: NSImage) {
            if imageView.image != img {
                imageView.image = img
                DispatchQueue.main.async {
                    self.restoreState()
                }
            }
        }

        /// Set a CGImage directly on the layer for high-performance cine playback.
        /// Bypasses NSImageView.image and SwiftUI update cycle entirely.
        func setCineFrame(_ cgImage: CGImage) {
            imageView.layer?.contents = cgImage
        }

        func updateTransform() { restoreState() }

        private func restoreState() {
            guard let panel = panel, let layer = imageView.layer else { return }

            // Build transform: flip → rotate → scale → translate
            var t = CATransform3DIdentity

            // Apply flip
            let flipX: CGFloat = panel.isFlippedH ? -1.0 : 1.0
            let flipY: CGFloat = panel.isFlippedV ? -1.0 : 1.0
            t = CATransform3DScale(t, flipX, flipY, 1.0)

            // Apply rotation (90° steps around Z axis)
            let angle = CGFloat(panel.rotationSteps) * .pi / 2.0
            t = CATransform3DRotate(t, angle, 0, 0, 1)

            // Apply zoom
            t = CATransform3DScale(t, panel.scale, panel.scale, 1.0)

            // Apply pan
            t = CATransform3DTranslate(t, panel.translation.x / panel.scale, panel.translation.y / panel.scale, 0)

            layer.transform = t
        }

        func applyFilters() {
            guard let panel = panel else { return }

            var filters: [CIFilter] = []

            if !panel.isRawDataAvailable {
                let currentWW = panel.windowWidth
                let currentWC = panel.windowCenter
                let initialWW = panel.initialWindowWidth
                let initialWC = panel.initialWindowCenter

                if initialWW != 0 {
                    let safeWW = currentWW == 0 ? 1 : currentWW
                    let contrast = CGFloat(initialWW / safeWW)
                    let brightness = CGFloat((initialWC - currentWC) / 255.0)

                    if let filter = CIFilter(name: "CIColorControls") {
                        filter.setDefaults()
                        filter.setValue(contrast, forKey: "inputContrast")
                        filter.setValue(brightness, forKey: "inputBrightness")
                        filters.append(filter)
                    }
                }
            }

            // Invert filter
            if panel.isInverted {
                if let invertFilter = CIFilter(name: "CIColorInvert") {
                    invertFilter.setDefaults()
                    filters.append(invertFilter)
                }
            }

            imageView.contentFilters = filters
        }

        private func saveState() {
            guard let panel = panel, let model = model, let layer = imageView.layer else { return }
            // Don't extract scale from m11 — after rotation, m11 ≠ scale.
            // panel.scale is maintained directly by zoom handlers.
            let tx = layer.transform.m41
            let ty = layer.transform.m42

            panel.translation = CGPoint(x: tx, y: ty)
            model.saveViewStateForPanel(panel, scale: panel.scale, translation: CGPoint(x: tx, y: ty))
            model.syncZoomFromPanel(panel)
        }

        override var acceptsFirstResponder: Bool { true }

        // performKeyEquivalent fires BEFORE the Input Method (Korean/Japanese/Chinese IME)
        // processes the event. This is the only reliable way to handle single-letter shortcuts
        // when a CJK input method is active. Returns true to consume the event.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard let model = model, let panel = panel else { return super.performKeyEquivalent(with: event) }
            // Only handle if this is the active panel (avoid duplicate handling across panels)
            guard panel.id == model.activePanelID else { return super.performKeyEquivalent(with: event) }
            // Only handle unmodified keys
            let flags = event.modifierFlags.intersection([.command, .control, .option])
            guard flags.isEmpty else { return super.performKeyEquivalent(with: event) }
            guard let key = event.charactersIgnoringModifiers?.lowercased() else { return super.performKeyEquivalent(with: event) }

            switch key {
            case "1":
                DispatchQueue.main.async { withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.single) } }
                return true
            case "2":
                DispatchQueue.main.async { withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.twoHorizontal) } }
                return true
            case "3":
                DispatchQueue.main.async { withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.twoVertical) } }
                return true
            case "4":
                DispatchQueue.main.async { withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.quad) } }
                return true
            case "r":
                model.resetViewForPanel(model.activePanel)
                return true
            case "l":
                model.synchronizedScrolling.toggle()
                return true
            case "x":
                model.showCrossReference.toggle()
                return true
            case "t":
                model.showTags.toggle()
                return true
            case "i":
                model.invertForPanel(model.activePanel)
                return true
            case "f":
                model.fitToWindowForPanel(model.activePanel)
                return true
            case "a":
                if let p = model.activePanel {
                    model.autoWindowLevelForPanel(p)
                }
                return true
            case "o":
                model.activeTool = .roiWL
                return true
            case "s":
                model.activeTool = .roiStats
                return true
            case "d":
                model.activeTool = .ruler
                return true
            case "n":
                model.activeTool = .angle
                return true
            case "e":
                model.activeTool = .eraser
                return true
            case "]", ".":
                model.rotateClockwiseForPanel(model.activePanel)
                return true
            case "[", ",":
                model.rotateCounterClockwiseForPanel(model.activePanel)
                return true
            case "w":
                model.activeTool = .windowLevel
                return true
            case "v":
                model.activeTool = .select
                return true
            case "p":
                model.activeTool = .pan
                return true
            case "z":
                model.activeTool = .zoom
                return true
            case "h":
                model.flipHorizontalForPanel(model.activePanel)
                return true
            case " ":
                if panel.isMultiFrame && panel.numberOfFrames > 1 {
                    model.toggleCinePlayback(panel)
                    return true
                }
                return false
            default:
                return super.performKeyEquivalent(with: event)
            }
        }

        func updateROICursor() {
            let tool = model?.activeTool ?? .select

            let desiredCursor: NSCursor
            switch tool {
            case .select:
                desiredCursor = .arrow
            case .pan:
                desiredCursor = .openHand
            case .windowLevel:
                desiredCursor = .resizeUpDown
            case .zoom:
                desiredCursor = .crosshair
            case .roiWL, .roiStats, .ruler, .angle:
                desiredCursor = .crosshair
            case .eraser:
                desiredCursor = .disappearingItem
            case .aiAnalyze, .aiPoint, .aiBox:
                desiredCursor = .crosshair
            }

            if tool == .select {
                // Default arrow cursor — pop any custom cursor
                if isCrosshairCursorActive {
                    NSCursor.pop()
                    isCrosshairCursorActive = false
                }
                return
            }

            if !isCrosshairCursorActive {
                desiredCursor.push()
                isCrosshairCursorActive = true
            } else {
                // Pop previous and push new
                NSCursor.pop()
                desiredCursor.push()
            }
        }

        /// Convert a window-space NSEvent location to image pixel coordinates.
        /// Returns nil if the position is outside the image bounds.
        private func screenToPixel(_ event: NSEvent) -> CGPoint? {
            guard let panel = panel, let image = imageView.image else { return nil }

            let loc = convert(event.locationInWindow, from: nil)

            let viewW = bounds.width
            let viewH = bounds.height
            let imgW = image.size.width
            let imgH = image.size.height

            let fitScale = min(viewW / imgW, viewH / imgH)
            let displayW = imgW * fitScale
            let displayH = imgH * fitScale
            let offsetX = (viewW - displayW) / 2
            let offsetY = (viewH - displayH) / 2

            let cx = viewW / 2
            let cy = viewH / 2

            // Convert NSView Y-up to image Y-down
            var x = loc.x
            var y = viewH - loc.y

            // Undo pan (translation is screen-space; Y was inverted in pixelToScreen)
            x -= panel.translation.x
            y += panel.translation.y

            // Undo zoom (center-relative)
            x = (x - cx) / panel.scale + cx
            y = (y - cy) / panel.scale + cy

            // Undo rotation (center-relative, negative angle to reverse)
            let angle = -CGFloat(panel.rotationSteps) * .pi / 2.0
            let dx = x - cx
            let dy = y - cy
            let cosA = cos(angle)
            let sinA = sin(angle)
            x = dx * cosA - dy * sinA + cx
            y = dx * sinA + dy * cosA + cy

            // Undo flip (center-relative)
            if panel.isFlippedH { x = 2 * cx - x }
            if panel.isFlippedV { y = 2 * cy - y }

            // Convert from view space to pixel space
            let pixelX = (x - offsetX) / fitScale
            let pixelY = (y - offsetY) / fitScale

            guard pixelX.isFinite, pixelY.isFinite else { return nil }
            return CGPoint(x: pixelX, y: pixelY)
        }

        override func mouseDown(with event: NSEvent) {
            // Shift+click: toggle group selection via overlay
            if event.modifierFlags.contains(.shift), let panel = panel, let model = model, model.panels.count > 1 {
                DispatchQueue.main.async {
                    panel.isGroupSelected.toggle()
                }
                return
            }

            // Activate this panel on click and become first responder
            // (first responder is needed so keyDown: reaches this view, not the SwiftUI host)
            if let panel = panel, let model = model {
                window?.makeFirstResponder(self)
                DispatchQueue.main.async {
                    model.activePanelID = panel.id
                }
            }

            guard let model = model, let panel = panel else { return }

            // Modifier overrides: Option/Control + left-click starts pan
            let mods = event.modifierFlags.intersection([.option, .control])
            if !mods.isEmpty {
                lastDragLocation = event.locationInWindow
                return
            }

            switch model.activeTool {
            case .select:
                break

            case .pan:
                // Just activate (handled above)
                break

            case .windowLevel:
                lastDragLocation = event.locationInWindow
                wlPendingDeltaWidth = 0
                wlPendingDeltaCenter = 0

            case .zoom:
                lastDragLocation = event.locationInWindow

            case .roiWL, .roiStats, .aiBox:
                if let px = screenToPixel(event) {
                    roiStartPixel = px
                    panel.roiRect = CGRect(x: px.x, y: px.y, width: 0, height: 0)
                }

            case .ruler:
                if let px = screenToPixel(event) {
                    if rulerStartPixel == nil {
                        // First click: record start
                        rulerStartPixel = px
                        panel.rulerPreviewStart = px
                        panel.rulerPreviewEnd = px
                    } else {
                        // Second click: finalize ruler
                        // Points are in display-image space; measure in raw pixels × spacing
                        // (they differ for aspect-corrected MPR/MIP images).
                        let start = rulerStartPixel!
                        let distance = panel.pixelDisplayMapping.distance(from: start, to: px, pixelSpacing: panel.pixelSpacing)
                        panel.addMeasurement(.ruler(start: start, end: px, distanceMM: distance))
                        // Clear preview
                        rulerStartPixel = nil
                        panel.rulerPreviewStart = nil
                        panel.rulerPreviewEnd = nil
                    }
                }

            case .angle:
                if let px = screenToPixel(event) {
                    anglePoints.append(px)
                    panel.anglePreviewPoints = anglePoints
                    if anglePoints.count == 3 {
                        // Compute angle using dot product
                        let vertex = anglePoints[1]
                        let arm1 = anglePoints[0]
                        let arm2 = anglePoints[2]
                        let degrees = panel.pixelDisplayMapping.angle(vertex: vertex, arm1: arm1, arm2: arm2,
                                                                      pixelSpacing: panel.pixelSpacing)
                        panel.addMeasurement(.angle(vertex: vertex, arm1: arm1, arm2: arm2, degrees: degrees))
                        // Clear preview
                        anglePoints = []
                        panel.anglePreviewPoints = []
                    }
                }

            case .eraser:
                if let px = screenToPixel(event) {
                    // Find the nearest annotation drawn on this slice and remove it
                    let threshold: CGFloat = 15.0
                    var bestID: UUID? = nil
                    var bestDist: CGFloat = .infinity
                    for ann in panel.visibleAnnotations {
                        let dist = distanceToAnnotation(ann, from: px)
                        if dist < bestDist {
                            bestDist = dist
                            bestID = ann.id
                        }
                    }
                    if let id = bestID, bestDist < threshold {
                        panel.annotations.removeAll { $0.id == id }
                    }
                }

            case .aiAnalyze:
                // AI analyze triggered by clicking on image
                model.triggerPreferredAIAnalysis(for: panel)

            case .aiPoint:
                // Option-click subtracts: SAM-family prompting refines a mask by
                // adding background points, so the modifier carries the polarity
                // rather than requiring a separate tool.
                if let px = screenToPixel(event) {
                    let isForeground = !event.modifierFlags.contains(.option)
                    model.addPromptPoint(px, isForeground: isForeground, for: panel)
                }
            }
            // `.aiBox` needs nothing here: it is grouped with the ROI tools
            // above, which start the rect on mouseDown; the prompt is submitted
            // on mouseUp once the rect is complete.
        }

        /// Compute minimum distance from a point to an annotation
        private func distanceToAnnotation(_ annotation: Annotation, from point: CGPoint) -> CGFloat {
            switch annotation.type {
            case .ruler(let start, let end, _):
                return pointToSegmentDistance(point, start, end)
            case .angle(let vertex, let arm1, let arm2, _):
                let d1 = pointToSegmentDistance(point, arm1, vertex)
                let d2 = pointToSegmentDistance(point, vertex, arm2)
                return min(d1, d2)
            case .roiStats(let rect, _, _, _, _, _):
                // Distance to rectangle edges
                let closest = CGPoint(
                    x: max(rect.minX, min(point.x, rect.maxX)),
                    y: max(rect.minY, min(point.y, rect.maxY))
                )
                return hypot(point.x - closest.x, point.y - closest.y)
            case .aiMask(_, _, _, let bounds, _, _):
                // Mask bounds are already in pixel space, unlike the normalized
                // rects the bbox-producing tasks emit.
                let closest = CGPoint(
                    x: max(bounds.minX, min(point.x, bounds.maxX)),
                    y: max(bounds.minY, min(point.y, bounds.maxY))
                )
                return hypot(point.x - closest.x, point.y - closest.y)
            case .aiStructure(let rect, _, _), .aiFinding(let rect, _, _), .aiROILabel(let rect, _, _, _):
                let imgW = max(1, panel?.displayImageWidth ?? 1)
                let imgH = max(1, panel?.displayImageHeight ?? 1)
                let pixelRect = CGRect(x: rect.origin.x * imgW, y: rect.origin.y * imgH,
                                       width: rect.width * imgW, height: rect.height * imgH)
                let closest = CGPoint(
                    x: max(pixelRect.minX, min(point.x, pixelRect.maxX)),
                    y: max(pixelRect.minY, min(point.y, pixelRect.maxY))
                )
                return hypot(point.x - closest.x, point.y - closest.y)
            }
        }

        /// Distance from a point to a line segment
        private func pointToSegmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = b.x - a.x
            let dy = b.y - a.y
            let lenSq = dx * dx + dy * dy
            if lenSq == 0 { return hypot(p.x - a.x, p.y - a.y) }
            var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq
            t = max(0, min(1, t))
            let projX = a.x + t * dx
            let projY = a.y + t * dy
            return hypot(p.x - projX, p.y - projY)
        }

        override func keyDown(with event: NSEvent) {
            guard let model = model, let panel = panel else {
                super.keyDown(with: event)
                return
            }

            // Arrow keys by keyCode (not affected by IME)
            let code = event.keyCode
            switch code {
            case 123: model.navigatePanel(panel, direction: .prevSeries); return
            case 124: model.navigatePanel(panel, direction: .nextSeries); return
            case 126: model.navigatePanelWithGroup(panel, direction: .prevImage); return
            case 125: model.navigatePanelWithGroup(panel, direction: .nextImage); return
            case 49: // Space
                if panel.isMultiFrame && panel.numberOfFrames > 1 {
                    model.toggleCinePlayback(panel); return
                }
            case 53: // Escape
                if !model.groupSelectedPanels.isEmpty {
                    model.clearGroupSelection(); return
                }
            default: break
            }

            // Handle letter/symbol shortcuts using charactersIgnoringModifiers
            // This returns the physical key regardless of IME (Korean, Japanese, Chinese)
            let flags = event.modifierFlags.intersection([.command, .control, .option])
            if flags.isEmpty, let key = event.charactersIgnoringModifiers?.lowercased() {
                switch key {
                case "1":
                    DispatchQueue.main.async { withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.single) } }
                    return
                case "2":
                    DispatchQueue.main.async { withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.twoHorizontal) } }
                    return
                case "3":
                    DispatchQueue.main.async { withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.twoVertical) } }
                    return
                case "4":
                    DispatchQueue.main.async { withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.quad) } }
                    return
                case "r": model.resetViewForPanel(model.activePanel); return
                case "l": model.synchronizedScrolling.toggle(); return
                case "x": model.showCrossReference.toggle(); return
                case "t": model.showTags.toggle(); return
                case "i": model.invertForPanel(model.activePanel); return
                case "f": model.fitToWindowForPanel(model.activePanel); return
                case "a":
                    if let p = model.activePanel { model.autoWindowLevelForPanel(p) }
                    return
                case "o": model.activeTool = .roiWL; return
                case "s": model.activeTool = .roiStats; return
                case "d": model.activeTool = .ruler; return
                case "n": model.activeTool = .angle; return
                case "e": model.activeTool = .eraser; return
                case "]", ".": model.rotateClockwiseForPanel(model.activePanel); return
                case "[", ",": model.rotateCounterClockwiseForPanel(model.activePanel); return
                case "w": model.activeTool = .windowLevel; return
                case "v": model.activeTool = .select; return
                case "p": model.activeTool = .pan; return
                case "z": model.activeTool = .zoom; return
                case "h": model.flipHorizontalForPanel(model.activePanel); return
                default: break
                }
            }

            // Not handled — pass to default (including IME)
            super.keyDown(with: event)
        }

        override func scrollWheel(with event: NSEvent) {
            // Option/Control+Scroll or Zoom tool active = Zoom
            if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.control) || model?.activeTool == .zoom {
                guard let panel = panel else { return }
                let dy = event.deltaY
                if dy == 0 { return }
                let zoomSpeed: CGFloat = 0.05
                let delta = dy * zoomSpeed
                var newScale = panel.scale + CGFloat(delta)
                newScale = max(0.1, min(10.0, newScale))
                panel.scale = newScale
                restoreState()
                return
            }

            // Ignore momentum (inertial) scroll events — they fight direction changes
            if event.momentumPhase.rawValue != 0 {
                return
            }

            // Reset accumulator when gesture ends
            if event.phase == .ended || event.phase == .cancelled {
                scrollAccumulator = 0
                return
            }

            guard let model = model, let panel = panel else { return }

            if event.hasPreciseScrollingDeltas {
                // Trackpad: accumulate pixel-level deltas
                let delta = event.scrollingDeltaY
                if delta == 0 { return }

                // Reset accumulator on direction change for immediate responsiveness
                if scrollAccumulator != 0 && ((scrollAccumulator > 0) != (delta > 0)) {
                    scrollAccumulator = 0
                }
                scrollAccumulator += delta

                let threshold: CGFloat = 25.0
                if abs(scrollAccumulator) >= threshold {
                    if scrollAccumulator > 0 {
                        model.navigatePanelWithGroup(panel, direction: .prevImage)
                    } else {
                        model.navigatePanelWithGroup(panel, direction: .nextImage)
                    }
                    scrollAccumulator = 0
                }
            } else {
                // Mouse wheel: navigate immediately per click
                let dy = event.deltaY
                if dy == 0 { return }
                if dy > 0 {
                    model.navigatePanelWithGroup(panel, direction: .prevImage)
                } else {
                    model.navigatePanelWithGroup(panel, direction: .nextImage)
                }
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            // Activate panel on right-click too
            if let panel = panel, let model = model {
                DispatchQueue.main.async {
                    model.activePanelID = panel.id
                }
            }
            wlPendingDeltaWidth = 0
            wlPendingDeltaCenter = 0
            lastDragLocation = event.locationInWindow
        }

        override func rightMouseDragged(with event: NSEvent) {
            guard let start = lastDragLocation, let panel = panel else { return }
            let current = event.locationInWindow

            let dx = Double(current.x - start.x)
            let dy = Double(current.y - start.y)

            let currentWW = panel.windowWidth
            let dynamicFactor = max(0.1, currentWW / 500.0)
            let sensitivity: Double = 1.0 * dynamicFactor

            wlPendingDeltaWidth += dx * sensitivity
            wlPendingDeltaCenter += dy * sensitivity
            flushPendingWindowLevelIfNeeded(force: false)
            lastDragLocation = current
        }

        override func rightMouseUp(with event: NSEvent) {
            flushPendingWindowLevelIfNeeded(force: true)
            lastDragLocation = nil
        }

        override func mouseDragged(with event: NSEvent) {
            guard let panel = panel, let model = model else { return }

            // Modifier overrides: Option/Control + left-drag = pan
            let mods = event.modifierFlags.intersection([.option, .control])
            if !mods.isEmpty {
                guard let layer = imageView.layer else { return }
                let dx = event.deltaX
                let dy = -event.deltaY
                layer.transform.m41 += CGFloat(dx)
                layer.transform.m42 += CGFloat(dy)
                saveState()
                return
            }

            switch model.activeTool {
            case .select:
                break

            case .pan:
                // Left-click drag = pan
                guard let layer = imageView.layer else { return }
                let dx = event.deltaX
                let dy = -event.deltaY
                layer.transform.m41 += CGFloat(dx)
                layer.transform.m42 += CGFloat(dy)
                saveState()

            case .windowLevel:
                // W/L adjustment (same as right-drag)
                guard let start = lastDragLocation else { return }
                let current = event.locationInWindow
                let dx = Double(current.x - start.x)
                let dy = Double(current.y - start.y)
                let currentWW = panel.windowWidth
                let dynamicFactor = max(0.1, currentWW / 500.0)
                let sensitivity: Double = 1.0 * dynamicFactor
                wlPendingDeltaWidth += dx * sensitivity
                wlPendingDeltaCenter += dy * sensitivity
                flushPendingWindowLevelIfNeeded(force: false)
                lastDragLocation = current

            case .zoom:
                // Drag up = zoom in, drag down = zoom out
                guard let start = lastDragLocation else { return }
                let current = event.locationInWindow
                let dy = current.y - start.y
                let zoomSpeed: CGFloat = 0.005
                var newScale = panel.scale + dy * zoomSpeed
                newScale = max(0.1, min(10.0, newScale))
                panel.scale = newScale
                restoreState()
                lastDragLocation = current

            case .roiWL, .roiStats, .aiBox:
                // Update ROI rectangle
                if let start = roiStartPixel, let current = screenToPixel(event) {
                    let x = min(start.x, current.x)
                    let y = min(start.y, current.y)
                    let w = abs(current.x - start.x)
                    let h = abs(current.y - start.y)
                    panel.roiRect = CGRect(x: x, y: y, width: w, height: h)
                }

            case .ruler:
                // Update preview line endpoint
                if rulerStartPixel != nil, let current = screenToPixel(event) {
                    panel.rulerPreviewEnd = current
                }

            case .angle:
                // Update preview line endpoint
                if !anglePoints.isEmpty, let current = screenToPixel(event) {
                    var preview = anglePoints
                    preview.append(current)
                    panel.anglePreviewPoints = preview
                }

            case .eraser:
                break

            case .aiAnalyze, .aiPoint:
                break
            }
        }

        override func mouseUp(with event: NSEvent) {
            guard let panel = panel, let model = model else { return }

            switch model.activeTool {
            case .select:
                break

            case .roiWL:
                if let rect = panel.roiRect, rect.width > 1 && rect.height > 1 {
                    model.autoWindowLevelForPanelROI(panel, rect: rect)
                }
                roiStartPixel = nil
                panel.roiRect = nil

            case .aiBox:
                if let rect = panel.roiRect, rect.width > 1 && rect.height > 1 {
                    model.addPromptBox(rect, for: panel)
                }
                roiStartPixel = nil
                panel.roiRect = nil

            case .roiStats:
                if let rect = panel.roiRect, rect.width > 1 && rect.height > 1 {
                    if let stats = model.computeROIStats(panel: panel, rect: rect) {
                        panel.addMeasurement(.roiStats(
                            rect: rect,
                            mean: stats.mean, max: stats.max, min: stats.min,
                            stdDev: stats.stdDev, count: stats.count
                        ))
                    }
                }
                roiStartPixel = nil
                panel.roiRect = nil

            case .windowLevel:
                flushPendingWindowLevelIfNeeded(force: true)
                lastDragLocation = nil

            default:
                break
            }
        }

        private func flushPendingWindowLevelIfNeeded(force: Bool) {
            guard let model = model, let panel = panel else { return }
            guard wlPendingDeltaWidth != 0 || wlPendingDeltaCenter != 0 else { return }

            let now = CACurrentMediaTime()
            if !force && (now - wlLastRenderTime) < wlRenderInterval {
                return
            }

            model.adjustWindowLevelForPanel(panel, deltaWidth: wlPendingDeltaWidth, deltaCenter: wlPendingDeltaCenter)
            applyFilters()
            wlPendingDeltaWidth = 0
            wlPendingDeltaCenter = 0
            wlLastRenderTime = now
        }

        // MARK: - Mouse Tracking for HU Readout

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas {
                removeTrackingArea(area)
            }
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                owner: self,
                userInfo: nil
            ))
        }

        override func mouseEntered(with event: NSEvent) {
            updateROICursor()
        }

        override func mouseExited(with event: NSEvent) {
            panel?.showCursorInfo = false
            if isCrosshairCursorActive {
                NSCursor.pop()
                isCrosshairCursorActive = false
            }
        }

        override func mouseMoved(with event: NSEvent) {
            guard let panel = panel, imageView.image != nil else {
                panel?.showCursorInfo = false
                return
            }

            // Update ruler/angle preview line to follow mouse
            if let model = model, let currentPixel = screenToPixel(event) {
                switch model.activeTool {
                case .ruler:
                    if rulerStartPixel != nil {
                        panel.rulerPreviewEnd = currentPixel
                    }
                case .angle:
                    if !anglePoints.isEmpty, anglePoints.count < 3 {
                        panel.anglePreviewPoints = anglePoints + [currentPixel]
                    }
                default:
                    break
                }
            }

            // Use screenToPixel for HU readout coordinate mapping
            guard let pixelPoint = screenToPixel(event) else {
                panel.showCursorInfo = false
                return
            }
            // screenToPixel yields display-image coordinates; convert to raw
            // rows/columns (they differ for aspect-corrected MPR/MIP images).
            guard let rawIndex = panel.pixelDisplayMapping.rawPixelIndex(pixelPoint),
                  rawIndex.x < panel.imageWidth, rawIndex.y < panel.imageHeight else {
                panel.showCursorInfo = false
                return
            }
            let px = rawIndex.x
            let py = rawIndex.y

            // Only update if position changed (throttle view updates)
            guard px != panel.cursorPixelX || py != panel.cursorPixelY else { return }

            // Look up the pixel value (modality units; 8/16/32-bit, RGB mean)
            var huValue: Double = 0
            if let data = panel.rawPixelData,
               let v = PixelValues.value(in: data, index: py * panel.imageWidth + px,
                                         bits: panel.bitDepth, isSigned: panel.isSigned, samples: panel.samples) {
                huValue = v
            } else if let v = model?.projectionReadout(for: panel, x: px, y: py) {
                // GPU projection: no pixel buffer, read the voxel along the ray
                huValue = v
            }

            panel.cursorPixelX = px
            panel.cursorPixelY = py
            panel.cursorHU = huValue
            panel.showCursorInfo = true

            // Compute patient coordinates if spatial metadata available
            if let ipp = panel.imagePositionPatient,
               let iop = panel.imageOrientationPatient, iop.count == 6,
               let ps = panel.pixelSpacing {
                let row = SIMD3<Double>(iop[0], iop[1], iop[2])
                let col = SIMD3<Double>(iop[3], iop[4], iop[5])
                let origin = SIMD3<Double>(ipp.0, ipp.1, ipp.2)
                // DICOM PixelSpacing = (row_spacing, col_spacing) where row_spacing is
                // the distance between rows (i.e. spacing in the column/Y direction)
                // and col_spacing is the distance between columns (row/X direction).
                // So: px (column index) * col_spacing (ps.1) * row_dir,
                //     py (row index) * row_spacing (ps.0) * col_dir.
                let patPos = origin + Double(px) * ps.1 * row + Double(py) * ps.0 * col
                panel.cursorPatientX = patPos.x
                panel.cursorPatientY = patPos.y
                panel.cursorPatientZ = patPos.z
                panel.hasCursorPatientPosition = true
            } else {
                panel.hasCursorPatientPosition = false
            }
        }
    }
}

// MARK: - ROI Overlay

/// Draws the ROI selection rectangle during drag.
struct ROIOverlay: View {
    @ObservedObject var panel: PanelState
    let roiRect: CGRect

    var body: some View {
        GeometryReader { geo in
            let screenRect = pixelRectToScreen(roiRect, viewSize: geo.size)
            Rectangle()
                .stroke(Color.yellow, lineWidth: 2)
                .background(Color.yellow.opacity(0.1))
                .frame(width: screenRect.width, height: screenRect.height)
                .position(x: screenRect.midX, y: screenRect.midY)
        }
        .allowsHitTesting(false)
    }

    /// Convert a pixel-space rectangle to SwiftUI overlay screen coordinates.
    /// Uses the same transform logic as CrossReferenceOverlay's pixelToScreen.
    private func pixelRectToScreen(_ rect: CGRect, viewSize: CGSize) -> CGRect {
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
        ].map { pixelToScreen($0, viewSize: viewSize) }

        guard let first = corners.first else { return .zero }
        let minX = corners.dropFirst().reduce(first.x) { min($0, $1.x) }
        let minY = corners.dropFirst().reduce(first.y) { min($0, $1.y) }
        let maxX = corners.dropFirst().reduce(first.x) { max($0, $1.x) }
        let maxY = corners.dropFirst().reduce(first.y) { max($0, $1.y) }

        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }

    private func pixelToScreen(_ pixel: CGPoint, viewSize: CGSize) -> CGPoint {
        let imgW = max(1, panel.displayImageWidth)
        let imgH = max(1, panel.displayImageHeight)
        let vw = viewSize.width
        let vh = viewSize.height

        let fitScale = min(vw / imgW, vh / imgH)
        let offsetX = (vw - imgW * fitScale) / 2
        let offsetY = (vh - imgH * fitScale) / 2

        var x = pixel.x * fitScale + offsetX
        var y = pixel.y * fitScale + offsetY

        let cx = vw / 2
        let cy = vh / 2
        x -= cx
        y -= cy

        if panel.isFlippedH { x = -x }
        if panel.isFlippedV { y = -y }

        let steps = panel.rotationSteps % 4
        if steps > 0 {
            let angle = -CGFloat(steps) * .pi / 2
            let cosA = cos(angle)
            let sinA = sin(angle)
            let rx = x * cosA - y * sinA
            let ry = x * sinA + y * cosA
            x = rx
            y = ry
        }

        x *= panel.scale
        y *= panel.scale

        // Pan (same as fixed CrossReferenceOverlay)
        x += panel.translation.x
        y -= panel.translation.y

        x += cx
        y += cy
        return CGPoint(x: x, y: y)
    }
}

// MARK: - Panel Adjustment Toolbar

struct PanelAdjustmentToolbar: View {
    @ObservedObject var model: DICOMModel
    @ObservedObject var panel: PanelState

    var body: some View {
        HStack(spacing: 8) {
            if !panel.histogramData.isEmpty {
                PanelHistogramView(
                    data: panel.histogramData,
                    minVal: panel.minPixelValue,
                    maxVal: panel.maxPixelValue,
                    windowWidth: panel.windowWidth,
                    windowCenter: panel.windowCenter
                )
                .frame(width: 100, height: 40)
                .background(Color.black.opacity(0.5))
                .border(Color.white.opacity(0.2), width: 1)
            }

            Button(action: { model.autoWindowLevelForPanel(panel) }) {
                HStack(spacing: 4) {
                    Text("Auto")
                    Text("A")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.white.opacity(0.15))
                        .cornerRadius(3)
                }
            }
            .frame(height: 40)
            .help("Auto W/L (A)")

        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .foregroundStyle(.white)
        .fixedSize(horizontal: false, vertical: true)
        .padding(6)
        .background(.thinMaterial)
        .cornerRadius(12)
    }
}

// MARK: - Panel Histogram View

struct PanelHistogramView: View {
    let data: [Double]
    let minVal: Double
    let maxVal: Double
    let windowWidth: Double
    let windowCenter: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Path { path in
                    let width = geo.size.width
                    let height = geo.size.height
                    let step = width / CGFloat(data.count)

                    path.move(to: CGPoint(x: 0, y: height))
                    for (i, val) in data.enumerated() {
                        let x = CGFloat(i) * step
                        let y = height - (CGFloat(val) * height)
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                    path.addLine(to: CGPoint(x: width, y: height))
                    path.closeSubpath()
                }
                .fill(LinearGradient(colors: [.blue.opacity(0.6), .purple.opacity(0.6)], startPoint: .top, endPoint: .bottom))

                let totalRange = maxVal - minVal
                if totalRange > 0 {
                    let windowStart = (windowCenter - (windowWidth / 2.0))
                    let windowEnd = (windowCenter + (windowWidth / 2.0))

                    let startRatio = max(0.0, min(1.0, (windowStart - minVal) / totalRange))
                    let endRatio = max(0.0, min(1.0, (windowEnd - minVal) / totalRange))

                    let startX = CGFloat(startRatio) * geo.size.width
                    let widthPx = CGFloat(endRatio - startRatio) * geo.size.width

                    Rectangle()
                        .fill(Color.yellow.opacity(0.2))
                        .frame(width: max(2, widthPx), height: geo.size.height)
                        .position(x: startX + (widthPx / 2.0), y: geo.size.height / 2.0)

                    let centerRatio = max(0.0, min(1.0, (windowCenter - minVal) / totalRange))
                    let centerX = CGFloat(centerRatio) * geo.size.width
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 1, height: geo.size.height)
                        .position(x: centerX, y: geo.size.height / 2.0)
                }
            }
        }
    }
}

// MARK: - Panel DICOM Scroller

struct PanelDICOMScroller: View {
    @ObservedObject var model: DICOMModel
    @ObservedObject var panel: PanelState
    @State private var isHovering = false
    @State private var hoverLocation: CGPoint = .zero
    @State private var dragLocation: CGPoint? = nil

    var body: some View {
        GeometryReader { geo in
            let total = model.totalSliceCount(for: panel)
            let currentIdx = model.currentSliceIndex(for: panel)

            ZStack(alignment: .top) {
                // Track
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 8, height: geo.size.height)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                // Handle
                if total > 0 {
                    let thumbHeight = max(20.0, geo.size.height / CGFloat(total) * 4.0)
                    let progress = Double(currentIdx) / Double(max(1, total - 1))
                    let availHeight = geo.size.height - thumbHeight
                    let offset = CGFloat(progress) * availHeight

                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.8))
                        .frame(width: 8, height: thumbHeight)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .offset(y: offset)
                }
            }
            .contentShape(Rectangle())
            .overlay {
                PanelScrollerInteractionView(
                    onDrag: { loc in
                        dragLocation = loc
                        calculateIndex(y: loc.y, height: geo.size.height, total: total, commit: true)
                    },
                    onHover: { loc in
                        hoverLocation = loc
                    },
                    onEnter: { isHovering = true },
                    onExit: {
                        isHovering = false
                        dragLocation = nil
                    }
                )
            }
            .overlay(alignment: .topTrailing) {
                if total > 0, let pY = activeY() {
                    let idx = getIndex(y: pY, height: geo.size.height, total: total)
                    if panel.panelMode == .slice2D {
                        PanelThumbnailPopup(model: model, panel: panel, index: idx, total: total)
                            .offset(x: -20, y: min(max(0, pY - 45), geo.size.height - 90))
                            .allowsHitTesting(false)
                    } else {
                        // MPR mode: show slice number instead of thumbnail
                        Text("\(idx + 1)/\(total)")
                            .font(.system(.caption2, design: .monospaced))
                            .padding(4)
                            .background(.ultraThinMaterial)
                            .cornerRadius(4)
                            .offset(x: -20, y: min(max(0, pY - 12), geo.size.height - 24))
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    private func activeY() -> CGFloat? {
        if let d = dragLocation { return d.y }
        if isHovering { return hoverLocation.y }
        return nil
    }

    func calculateIndex(y: CGFloat, height: CGFloat, total: Int, commit: Bool) {
        if total <= 1 { return }
        let idx = getIndex(y: y, height: height, total: total)
        if commit {
            model.navigatePanelToSlice(panel, index: idx)
        }
    }

    func getIndex(y: CGFloat, height: CGFloat, total: Int) -> Int {
        let pct = max(0, min(1, y / height))
        return Int(pct * Double(total - 1))
    }
}

// MARK: - Panel Thumbnail Popup

struct PanelThumbnailPopup: View {
    @ObservedObject var model: DICOMModel
    @ObservedObject var panel: PanelState
    let index: Int
    let total: Int

    var body: some View {
        HStack {
            Text("\(index + 1)")
                .font(.caption)
                .padding(4)
                .background(.black.opacity(0.7))
                .cornerRadius(4)

            if let img = model.getCachedImageForPanel(panel, at: index) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 80, height: 80)
                    .background(Color.black)
                    .cornerRadius(4)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 80, height: 80)
            }
        }
        .padding(4)
        .background(.ultraThinMaterial)
        .cornerRadius(8)
        .shadow(radius: 4)
    }
}

// MARK: - Panel Scroller Interaction View

struct PanelScrollerInteractionView: NSViewRepresentable {
    var onDrag: (CGPoint) -> Void
    var onHover: (CGPoint) -> Void
    var onEnter: () -> Void
    var onExit: () -> Void

    func makeNSView(context: Context) -> NSView {
        let v = InteractionView()
        v.onDrag = onDrag
        v.onHover = onHover
        v.onEnter = onEnter
        v.onExit = onExit
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let v = nsView as? InteractionView {
            v.onDrag = onDrag
            v.onHover = onHover
            v.onEnter = onEnter
            v.onExit = onExit
        }
    }

    class InteractionView: NSView {
        var onDrag: ((CGPoint) -> Void)?
        var onHover: ((CGPoint) -> Void)?
        var onEnter: (() -> Void)?
        var onExit: (() -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach { removeTrackingArea($0) }
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .activeAlways], owner: self, userInfo: nil))
        }

        override func mouseDown(with event: NSEvent) { handleDrag(event) }
        override func mouseDragged(with event: NSEvent) { handleDrag(event) }

        private func handleDrag(_ event: NSEvent) {
            let loc = convert(event.locationInWindow, from: nil)
            let flippedY = bounds.height - loc.y
            onDrag?(CGPoint(x: loc.x, y: flippedY))
        }

        override func mouseEntered(with event: NSEvent) { onEnter?() }
        override func mouseExited(with event: NSEvent) { onExit?() }
        override func mouseMoved(with event: NSEvent) {
            let loc = convert(event.locationInWindow, from: nil)
            let flippedY = bounds.height - loc.y
            onHover?(CGPoint(x: loc.x, y: flippedY))
        }
    }
}

// MARK: - Orientation Labels Overlay

struct OrientationLabelsOverlay: View {
    let orientation: [Double]?
    var rotationSteps: Int = 0
    var isFlippedH: Bool = false
    var isFlippedV: Bool = false

    var body: some View {
        if let ori = orientation, ori.count == 6 {
            let row = SIMD3<Double>(ori[0], ori[1], ori[2])
            let col = SIMD3<Double>(ori[3], ori[4], ori[5])

            // Base labels: right, left, bottom, top
            let baseRight = dirLabel(row)
            let baseLeft = oppositeLabel(baseRight)
            let baseBottom = dirLabel(col)
            let baseTop = oppositeLabel(baseBottom)

            // Apply flip and rotation transforms to the 4 label slots.
            // Start with logical positions: right=0, top=1, left=2, bottom=3
            // then rotate and flip to get the final label for each screen position.
            let labels = transformedLabels(
                right: baseRight, top: baseTop, left: baseLeft, bottom: baseBottom,
                rotationSteps: rotationSteps, flipH: isFlippedH, flipV: isFlippedV)

            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height

                Text(labels.right)
                    .position(x: w - 16, y: h / 2)
                Text(labels.left)
                    .position(x: 16, y: h / 2)
                Text(labels.bottom)
                    .position(x: w / 2, y: h - 16)
                Text(labels.top)
                    .position(x: w / 2, y: 16)
            }
            .font(.system(size: 14, weight: .bold, design: .monospaced))
            .foregroundStyle(.yellow.opacity(0.8))
            .allowsHitTesting(false)
        }
    }

    /// Apply flip and rotation to the four orientation labels.
    /// Rotation is CW in 90-degree steps; flips are applied before rotation
    /// (matching the image transform order in restoreState).
    private func transformedLabels(
        right: String, top: String, left: String, bottom: String,
        rotationSteps: Int, flipH: Bool, flipV: Bool
    ) -> (right: String, top: String, left: String, bottom: String) {
        // Put labels in array: [right, top, left, bottom] indexed 0-3
        var labels = [right, top, left, bottom]

        // Horizontal flip swaps left ↔ right
        if flipH { labels.swapAt(0, 2) }
        // Vertical flip swaps top ↔ bottom
        if flipV { labels.swapAt(1, 3) }

        // CW rotation by N steps: each 90° CW step moves
        // right→bottom, bottom→left, left→top, top→right
        // That's equivalent to rotating the array backward by N positions.
        let steps = ((rotationSteps % 4) + 4) % 4
        if steps > 0 {
            let rotated = (0..<4).map { labels[($0 + steps) % 4] }
            labels = rotated
        }

        return (right: labels[0], top: labels[1], left: labels[2], bottom: labels[3])
    }

    /// Map a direction vector to its dominant anatomical label.
    /// DICOM patient coordinate system: +x=L, -x=R, +y=P, -y=A, +z=S, -z=I
    private func dirLabel(_ v: SIMD3<Double>) -> String {
        let ax = abs(v.x), ay = abs(v.y), az = abs(v.z)
        if ax >= ay && ax >= az { return v.x > 0 ? "L" : "R" }
        if ay >= ax && ay >= az { return v.y > 0 ? "P" : "A" }
        return v.z > 0 ? "S" : "I"
    }

    private func oppositeLabel(_ l: String) -> String {
        switch l {
        case "L": return "R"; case "R": return "L"
        case "A": return "P"; case "P": return "A"
        case "S": return "I"; case "I": return "S"
        default: return ""
        }
    }
}

// MARK: - Imported DICOM Overlay

struct ImportedDICOMOverlay: View {
    @ObservedObject var panel: PanelState

    var body: some View {
        GeometryReader { geo in
            ForEach(panel.importedOverlays) { overlay in
                overlayView(overlay, viewSize: geo.size)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func overlayView(_ overlay: DICOMImportedOverlay, viewSize: CGSize) -> some View {
        switch overlay.geometry {
        case .polyline(let points, let closed):
            let screenPoints = points.map { pixelToScreen(resolve($0, in: overlay.coordinateSpace), viewSize: viewSize) }
            if screenPoints.count >= 2 {
                Path { path in
                    path.move(to: screenPoints[0])
                    for point in screenPoints.dropFirst() {
                        path.addLine(to: point)
                    }
                    if closed {
                        path.closeSubpath()
                    }
                }
                .stroke(overlayColor(for: overlay.sourceKind), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            }

        case .point(let point):
            let screenPoint = pixelToScreen(resolve(point, in: overlay.coordinateSpace), viewSize: viewSize)
            Circle()
                .stroke(overlayColor(for: overlay.sourceKind), lineWidth: 2)
                .frame(width: 9, height: 9)
                .position(screenPoint)

        case .ellipse(let points):
            let resolved = points.map { resolve($0, in: overlay.coordinateSpace) }
            if let rect = boundingRect(for: resolved) {
                let topLeft = pixelToScreen(CGPoint(x: rect.minX, y: rect.minY), viewSize: viewSize)
                let bottomRight = pixelToScreen(CGPoint(x: rect.maxX, y: rect.maxY), viewSize: viewSize)
                let screenRect = CGRect(
                    x: min(topLeft.x, bottomRight.x),
                    y: min(topLeft.y, bottomRight.y),
                    width: abs(bottomRight.x - topLeft.x),
                    height: abs(bottomRight.y - topLeft.y)
                )
                Ellipse()
                    .stroke(overlayColor(for: overlay.sourceKind), lineWidth: 2)
                    .frame(width: screenRect.width, height: screenRect.height)
                    .position(x: screenRect.midX, y: screenRect.midY)
            }

        case .text(let value, let anchor):
            let screenPoint = pixelToScreen(resolve(anchor, in: overlay.coordinateSpace), viewSize: viewSize)
            Text(value)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(overlayColor(for: overlay.sourceKind))
                .padding(3)
                .background(Color.black.opacity(0.7))
                .cornerRadius(3)
                .position(screenPoint)

        case .mask(let width, let height, let bitmap):
            maskOverlay(width: width, height: height, bitmap: bitmap, color: overlayColor(for: overlay.sourceKind), viewSize: viewSize)
        }
    }

    private func maskOverlay(width: Int, height: Int, bitmap: Data, color: Color, viewSize: CGSize) -> some View {
        Canvas { context, _ in
            var path = Path()
            guard width > 0, height > 0, bitmap.count == width * height else { return }

            for y in 0..<height {
                var x = 0
                while x < width {
                    let start = x
                    while x < width && bitmap[y * width + x] != 0 {
                        x += 1
                    }

                    if x > start {
                        let rect = pixelRectToScreen(
                            CGRect(x: start, y: y, width: x - start, height: 1),
                            viewSize: viewSize
                        )
                        path.addRect(rect)
                    }
                    x += 1
                }
            }

            context.fill(path, with: .color(color.opacity(0.32)))
            context.stroke(path, with: .color(color.opacity(0.75)), lineWidth: 0.4)
        }
    }

    private func overlayColor(for kind: DICOMDerivedObjectKind) -> Color {
        switch kind {
        case .rtStructureSet:
            return .mint
        case .dicomSegmentation:
            return .cyan
        case .grayscaleSoftcopyPresentationState, .colorSoftcopyPresentationState, .blendingSoftcopyPresentationState:
            return .yellow
        default:
            return .orange
        }
    }

    private func resolve(_ point: CGPoint, in coordinateSpace: DICOMOverlayCoordinateSpace) -> CGPoint {
        switch coordinateSpace {
        case .pixel:
            return point
        case .display:
            return CGPoint(
                x: point.x * max(1, panel.displayImageWidth),
                y: point.y * max(1, panel.displayImageHeight)
            )
        }
    }

    private func pixelRectToScreen(_ rect: CGRect, viewSize: CGSize) -> CGRect {
        let topLeft = pixelToScreen(CGPoint(x: rect.minX, y: rect.minY), viewSize: viewSize)
        let bottomRight = pixelToScreen(CGPoint(x: rect.maxX, y: rect.maxY), viewSize: viewSize)
        return CGRect(
            x: min(topLeft.x, bottomRight.x),
            y: min(topLeft.y, bottomRight.y),
            width: abs(bottomRight.x - topLeft.x),
            height: abs(bottomRight.y - topLeft.y)
        )
    }

    private func boundingRect(for points: [CGPoint]) -> CGRect? {
        guard let first = points.first else { return nil }
        var minX = first.x
        var minY = first.y
        var maxX = first.x
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }
        if minX == maxX { maxX += 1 }
        if minY == maxY { maxY += 1 }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func pixelToScreen(_ pixel: CGPoint, viewSize: CGSize) -> CGPoint {
        let imgW = max(1, panel.displayImageWidth)
        let imgH = max(1, panel.displayImageHeight)
        let vw = viewSize.width
        let vh = viewSize.height

        let fitScale = min(vw / imgW, vh / imgH)
        let offsetX = (vw - imgW * fitScale) / 2
        let offsetY = (vh - imgH * fitScale) / 2

        var x = pixel.x * fitScale + offsetX
        var y = pixel.y * fitScale + offsetY

        let cx = vw / 2
        let cy = vh / 2
        x -= cx
        y -= cy

        if panel.isFlippedH { x = -x }
        if panel.isFlippedV { y = -y }

        let steps = panel.rotationSteps % 4
        if steps > 0 {
            let angle = -CGFloat(steps) * .pi / 2
            let cosA = cos(angle)
            let sinA = sin(angle)
            let rx = x * cosA - y * sinA
            let ry = x * sinA + y * cosA
            x = rx
            y = ry
        }

        x *= panel.scale
        y *= panel.scale

        x += panel.translation.x
        y -= panel.translation.y

        x += cx
        y += cy
        return CGPoint(x: x, y: y)
    }
}

// MARK: - AI Inspector View

struct AIInspectorView: View {
    @ObservedObject var model: DICOMModel
    @ObservedObject private var aiService = AIService.shared
    @ObservedObject private var aiServerManager = AIServerManager.shared
    @ObservedObject private var pluginRuntime = PluginRuntime.shared
    @State private var dotCount: Int = 0
    /// Mirrors AIAnalysisEngine.preference so the picker redraws.
    @State private var enginePreference: AIAnalysisEngine? = AIAnalysisEngine.preference

    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    private var panel: PanelState? { model.activePanel }

    private var engine: AIAnalysisEngine {
        AIAnalysisEngine.resolve(preference: enginePreference,
                                 pluginInstalled: pluginInstalled,
                                 builtInSetUp: aiServerManager.setupState == .ready)
    }

    private var pluginInstalled: Bool {
        pluginRuntime.installState(AIAnalysisEngine.pluginAnalyze).isReady
    }

    /// AI annotations computed on the slice currently on screen.
    private var aiAnnotations: [Annotation] {
        panel?.visibleAnnotations.filter { $0.isAI } ?? []
    }

    /// AI annotations bound to other slices of this panel.
    private var offSliceAIAnnotationCount: Int {
        guard let panel else { return 0 }
        return panel.annotations.filter { $0.isAI }.count - aiAnnotations.count
    }

    /// Whether the panel has anything AI to show, from either engine. Such
    /// content is shown whatever state the built-in server is in: a plugin
    /// result or error must not hide behind "Setup required".
    private var panelHasAIContent: Bool {
        guard let panel else { return false }
        return panel.aiAnalysisInProgress || panel.aiError != nil
            || panel.visibleAIDescription != nil || !aiAnnotations.isEmpty
    }

    /// The built-in server is installing, downloading or loading.
    private var builtInBusy: Bool {
        aiServerManager.setupState == .installingDeps
            || (aiServerManager.isServerRunning && !aiService.serverStatus.isReady)
    }

    private var statusText: String {
        if panel?.aiAnalysisInProgress == true { return "Analyzing…" }
        if engine == .gemmaPlugin {
            return pluginRuntime.runtimeState(AIAnalysisEngine.pluginID).isReady
                ? "Plugin ready" : "Plugin starts on first use"
        }
        switch aiServerManager.setupState {
        case .notSetup, .unknown where !aiServerManager.isServerRunning:
            return aiServerManager.aiEnabled == true ? "Setup required" : "Not enabled"
        case .installingDeps: return "Setting up…"
        case .failed:         return "Failed"
        default: break
        }
        if let progress = aiService.loadProgress, !aiService.serverStatus.isReady {
            switch progress.phase {
            case .downloading: return "Downloading model…"
            case .loading: return "Loading model…"
            case .starting: return "Starting…"
            }
        }
        return aiService.serverStatus.displayText
    }

    private var statusColor: Color {
        if engine == .gemmaPlugin {
            return pluginRuntime.runtimeState(AIAnalysisEngine.pluginID).isReady ? .green : .gray
        }
        switch aiServerManager.setupState {
        case .notSetup:       return .orange
        case .installingDeps: return .yellow
        case .failed:         return .red
        default: break
        }
        return aiService.serverStatus.color
    }

    /// Modes from the built-in server once it has answered, else the plugin
    /// task's declared values.
    private var modes: [AIAnalyzeMode] {
        if !aiService.availableModes.isEmpty { return aiService.availableModes }
        guard engine == .gemmaPlugin,
              let task = pluginRuntime.manifest.plugin(id: AIAnalysisEngine.pluginID)?
                .task(id: AIAnalysisEngine.pluginAnalyze.taskID),
              let values = task.options?["mode"]?.values else { return [] }
        return values.map { AIAnalyzeMode(key: $0, label: $0.capitalized, description: "") }
    }

    private var canRun: Bool {
        guard let panel, panel.image != nil, !panel.aiAnalysisInProgress else { return false }
        if engine == .builtIn, case .failed = aiServerManager.setupState { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — always visible
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: "brain")
                        .foregroundStyle(.yellow)
                    Text("AI Analysis")
                        .font(.headline)
                }
                Spacer()
                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(statusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            if pluginInstalled {
                Picker("Engine", selection: Binding(
                    get: { engine },
                    set: { newValue in
                        AIAnalysisEngine.preference = newValue
                        enginePreference = newValue
                    })) {
                    ForEach(AIAnalysisEngine.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .padding(.horizontal)
                .padding(.bottom, 6)
                .help("Run Gemma through the built-in AI server or the Gemma plugin from the store. Only one holds the model in memory at a time.")
            }

            if !modes.isEmpty && (engine == .gemmaPlugin || aiService.serverStatus.isReady) {
                Picker("Mode", selection: $aiService.selectedMode) {
                    ForEach(modes) { mode in
                        Text(mode.label).tag(mode.key)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .padding(.horizontal)
                .padding(.bottom, 6)
            }

            Divider()

            // Main content: the panel's results whenever it has any (from
            // either engine); otherwise, for the built-in engine, its setup
            // or server state.
            Group {
                if panelHasAIContent || engine == .gemmaPlugin {
                    VStack(spacing: 0) {
                        if engine == .builtIn && builtInBusy {
                            AIBusyBanner()
                        }
                        panelContent
                    }
                } else {
                    builtInStatusContent
                }
            }

            Divider()

            // Bottom action bar
            HStack {
                Button(action: {
                    if let panel = panel {
                        panel.clearAIAnnotations()
                        model.triggerPreferredAIAnalysis(for: panel)
                    }
                }) {
                    Label("Analyze", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canRun)
                .help("Analyze this slice (G / ⌘G)")

                Button(action: {
                    if let panel = panel {
                        model.triggerPreferredAIDescribeROI(for: panel)
                    }
                }) {
                    Label("Describe ROI", systemImage: "text.viewfinder")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canRun)
                .help("Describe the most recent ROI Stats rectangle (S) on this slice")

                Spacer()

                // Clears this slice; the menu half clears every slice.
                Menu {
                    Button("Clear This Slice") {
                        panel?.clearAIAnnotations()
                        model.objectWillChange.send()
                    }
                    .disabled(panel?.hasAIResultsOnCurrentSlice != true)
                    Button("Clear All Slices") {
                        panel?.clearAIAnnotations(allSlices: true)
                        model.objectWillChange.send()
                    }
                    .disabled(panel?.hasAnyAIResults != true)
                } label: {
                    Label("Clear", systemImage: "trash")
                        .font(.caption)
                } primaryAction: {
                    panel?.clearAIAnnotations()
                    model.objectWillChange.send()
                }
                .menuStyle(.borderedButton)
                .fixedSize()
                .controlSize(.small)
                .disabled(panel?.hasAnyAIResults != true)
                .help("Clear AI results on this slice; use the arrow to clear every slice")
            }
            .padding(.horizontal)
            .padding(.top, 8)

            Text("Research use only — not for diagnosis. Findings and confidence values are model-generated and unvalidated.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
    }

    // MARK: - Built-in engine state (when the panel has no results)

    @ViewBuilder
    private var builtInStatusContent: some View {
        switch aiServerManager.setupState {
        case .installingDeps:
            AIInstallingView(log: aiServerManager.setupLog)
        case .failed(let msg):
            AISetupFailedView(message: msg)
        case .notSetup where !aiServerManager.isServerRunning,
             .unknown where !aiServerManager.isServerRunning:
            AISetupRequiredView()
        default:
            if aiService.serverStatus.isReady {
                panelContent
            } else if aiServerManager.isServerRunning || aiService.serverStatus == .starting {
                AIModelLoadingView()
            } else {
                AIServerStoppedView()
            }
        }
    }

    // MARK: - Panel Content

    @ViewBuilder
    private var panelContent: some View {
        if let panel = panel {
            if panel.aiAnalysisInProgress {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(.yellow)
                    Text("Analyzing" + String(repeating: ".", count: dotCount))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .onReceive(timer) { _ in dotCount = (dotCount % 3) + 1 }
                    if engine == .gemmaPlugin
                        && !pluginRuntime.runtimeState(AIAnalysisEngine.pluginID).isReady {
                        Text("Starting the Gemma plugin — loading the model takes a little while the first time.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = panel.aiError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                    Button(panel.lastAIAction.retryTitle) {
                        let action = panel.lastAIAction
                        // Describe ROI only replaces the description, so keep
                        // the slice's boxes when retrying it.
                        if action != .describeROI { panel.clearAIAnnotations() }
                        model.triggerPreferredAI(action, for: panel)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if aiAnnotations.isEmpty && panel.visibleAIDescription == nil {
                ContentUnavailableView {
                    Label("No Analysis", systemImage: "brain")
                } description: {
                    if offSliceAIAnnotationCount > 0 {
                        Text("AI results on this panel belong to other slices. Press G or ⌘G to analyze this one.")
                    } else {
                        Text("Press G or ⌘G to analyze the current image")
                    }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if let desc = panel.visibleAIDescription, !desc.isEmpty {
                            Text(desc)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.white)
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.white.opacity(0.05))
                                .cornerRadius(6)
                        }
                        if !aiAnnotations.isEmpty {
                            Text("Findings")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                            ForEach(aiAnnotations) { annotation in
                                AIAnnotationRow(
                                    annotation: annotation,
                                    isSelected: panel.selectedAnnotationID == annotation.id,
                                    onTap: {
                                        if panel.selectedAnnotationID == annotation.id {
                                            panel.selectedAnnotationID = nil
                                        } else {
                                            panel.selectedAnnotationID = annotation.id
                                        }
                                        model.objectWillChange.send()
                                    }
                                )
                            }
                        }
                    }
                    .padding()
                }
            }
        } else {
            ContentUnavailableView("No Panel", systemImage: "rectangle.slash")
        }
    }
}

// MARK: - Setup State Sub-Views

/// Shown when local AI has not been enabled or set up. Nothing starts until
/// the user asks: the setup is a 6–7 GB download.
private struct AISetupRequiredView: View {
    @ObservedObject private var manager = AIServerManager.shared

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "brain")
                .font(.system(size: 30))
                .foregroundStyle(.yellow)

            VStack(spacing: 6) {
                Text("Local AI Is Not Set Up")
                    .font(.headline)
                Text("Gemma 4 runs entirely on this Mac. Setting it up downloads about 6–7 GB once and takes roughly 10–30 minutes; you can keep working meanwhile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 4) {
                Label("~1.5 GB Python packages (mlx, mlx-vlm…)", systemImage: "arrow.down.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Label(manager.isModelCached
                      ? "Model already downloaded"
                      : "~5.2 GB model download (Hugging Face)", systemImage: "arrow.down.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Label("Needs about 8 GB of free disk space", systemImage: "internaldrive")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)

            Button(action: { manager.enableAndStart() }) {
                Label("Enable Local AI", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(.yellow)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shown while pip install is running
private struct AIInstallingView: View {
    let log: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.yellow)
                Text("Installing AI dependencies…")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal)
            .padding(.top, 12)

            Text("This runs once and takes several minutes. The model downloads next. Keep the app open.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal)

            AILogView(log: log)
                .padding(.horizontal)
                .frame(maxHeight: .infinity)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Scrolling monospaced log that follows its tail.
private struct AILogView: View {
    let log: String
    var maxLines: Int = 200

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(tail.isEmpty ? " " : tail)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.green.opacity(0.85))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .id("logBottom")
            }
            .background(Color.black.opacity(0.4))
            .cornerRadius(6)
            .onAppear { proxy.scrollTo("logBottom", anchor: .bottom) }
            .onChange(of: log) {
                withAnimation { proxy.scrollTo("logBottom", anchor: .bottom) }
            }
        }
    }

    private var tail: String {
        log.split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(maxLines).joined(separator: "\n")
    }
}

/// Shown when setup failed or the server could not start: the reason, and
/// the end of the log it came from.
private struct AISetupFailedView: View {
    let message: String
    @ObservedObject private var manager = AIServerManager.shared

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.red)

            Text(manager.isSetupComplete ? "AI Server Failed" : "Setup Failed")
                .font(.headline)

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)

            let log = manager.isSetupComplete ? manager.serverLog : manager.setupLog
            if !log.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last log lines")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    AILogView(log: log, maxLines: 25)
                        .frame(maxHeight: 180)
                }
            }

            HStack {
                Button(action: { manager.retrySetup() }) {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if manager.isSetupComplete {
                    Button(action: { manager.reinstallEnvironment() }) {
                        Label("Reinstall", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Recreate the Python environment and reinstall dependencies")
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shown when the environment is ready but the server is not running. The
/// server starts on the first analysis; this offers to start it now.
/// Deliberately does not auto-start: restarting from here would loop on a
/// server that keeps dying.
private struct AIServerStoppedView: View {
    @ObservedObject private var manager = AIServerManager.shared
    @ObservedObject private var aiService = AIService.shared

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "pause.circle")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)

            Text("Local AI Not Running")
                .font(.headline)

            if case .error(let message) = aiService.serverStatus {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            } else if !manager.isModelCached {
                Text("The first start downloads Gemma 4 (~5.2 GB) from Hugging Face. Keep the app open — this takes 10–30 minutes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            } else {
                Text("It starts by itself when you analyze an image (G). Loading the model takes a few seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }

            Button(action: { manager.startServer() }) {
                Label("Start AI Now", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(.yellow)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One line of download / load progress, for both the full loading view and
/// the banner above existing results.
private struct AILoadProgressLine: View {
    @ObservedObject private var manager = AIServerManager.shared
    @ObservedObject private var aiService = AIService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if manager.setupState == .installingDeps {
                Text("Installing Python packages…")
                    .font(.caption)
            } else if let progress = aiService.loadProgress, progress.phase == .downloading {
                Text("Downloading Gemma 4 E4B" + (progress.bytesText.map { " — \($0)" } ?? ""))
                    .font(.caption)
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                        .tint(.yellow)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(.yellow)
                }
            } else if aiService.loadProgress?.phase == .loading {
                Text("Loading the model into memory…")
                    .font(.caption)
            } else {
                Text("Starting the AI server…")
                    .font(.caption)
            }
        }
    }
}

/// Compact status shown above existing results while the built-in engine
/// installs or loads.
private struct AIBusyBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(.yellow)
            AILoadProgressLine()
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.yellow.opacity(0.08))
    }
}

/// Shown while the server process is starting, downloading or loading the model
private struct AIModelLoadingView: View {
    @ObservedObject private var manager = AIServerManager.shared
    @ObservedObject private var aiService = AIService.shared
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .tint(.yellow)
                .scaleEffect(1.2)

            AILoadProgressLine()
                .frame(maxWidth: .infinity, alignment: .leading)

            if aiService.loadProgress?.phase == .downloading || !manager.isModelCached {
                Text("First run: Gemma 4 E4B (~5.2 GB) downloads once to ~/.cache/huggingface. This may take 10–30 minutes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if manager.hasPendingRun {
                Text("Your analysis will run as soon as the model is ready.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            DisclosureGroup("Server log", isExpanded: $showLog) {
                AILogView(log: manager.serverLog, maxLines: 80)
                    .frame(height: 160)
            }
            .font(.caption)

            Button("Cancel") { manager.stopServer() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - AI Annotation Row

struct AIAnnotationRow: View {
    let annotation: Annotation
    let isSelected: Bool
    let onTap: () -> Void

    private var bgColor: Color {
        isSelected ? Color.yellow.opacity(0.15) : Color.white.opacity(0.05)
    }

    private var borderColor: Color {
        isSelected ? Color.yellow.opacity(0.5) : Color.clear
    }

    var body: some View {
        Button(action: onTap) {
            rowContent
        }
        .buttonStyle(.plain)
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(annotationColor)
                .frame(width: 4, height: 32)

            labelSection

            Spacer()

            confidenceBadge
        }
        .padding(6)
        .background(bgColor)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    private var labelSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(annotationLabel)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(.white)

            if !annotationDetail.isEmpty {
                Text(annotationDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var confidenceBadge: some View {
        if !confidenceText.isEmpty {
            Text(confidenceText)
                .font(.caption2)
                .foregroundStyle(annotationColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(annotationColor.opacity(0.15))
                .cornerRadius(4)
                .help("Model-generated confidence — not a calibrated probability")
        }
    }

    private var annotationColor: Color {
        switch annotation.type {
        case .aiStructure: return .yellow
        case .aiFinding(_, _, let severity): return AISeverity(parsing: severity).color
        case .aiROILabel: return .blue
        default: return .gray
        }
    }

    private var annotationLabel: String {
        switch annotation.type {
        case .aiStructure(_, let label, _): return label
        case .aiFinding(_, _, let severity): return AISeverity(parsing: severity).displayName
        case .aiROILabel(_, let label, _, _): return label
        default: return ""
        }
    }

    private var annotationDetail: String {
        switch annotation.type {
        case .aiStructure: return ""
        case .aiFinding(_, let description, _): return description
        case .aiROILabel(_, _, let description, _): return description
        default: return ""
        }
    }

    private var confidenceText: String {
        switch annotation.type {
        case .aiStructure(_, _, let confidence): return "model \(Int(confidence * 100))%"
        case .aiROILabel(_, _, _, let confidence): return "model \(Int(confidence * 100))%"
        default: return ""
        }
    }
}

// MARK: - Annotation Overlay

struct AnnotationOverlay: View {
    @ObservedObject var panel: PanelState

    var body: some View {
        GeometryReader { geo in
            // Finalized annotations (AI results only on the slice they were computed on)
            ForEach(panel.visibleAnnotations) { annotation in
                annotationView(for: annotation, viewSize: geo.size)
            }

            // Ruler preview (dashed line)
            if let start = panel.rulerPreviewStart, let end = panel.rulerPreviewEnd {
                let s = pixelToScreen(start, viewSize: geo.size)
                let e = pixelToScreen(end, viewSize: geo.size)
                Path { path in
                    path.move(to: s)
                    path.addLine(to: e)
                }
                .stroke(Color.cyan, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            }

            // Angle preview (dashed lines)
            if panel.anglePreviewPoints.count >= 2 {
                let pts = panel.anglePreviewPoints.map { pixelToScreen($0, viewSize: geo.size) }
                Path { path in
                    path.move(to: pts[0])
                    for i in 1..<pts.count {
                        path.addLine(to: pts[i])
                    }
                }
                .stroke(Color.green, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func annotationView(for annotation: Annotation, viewSize: CGSize) -> some View {
        switch annotation.type {
        case .ruler(let start, let end, let distanceMM):
            let s = pixelToScreen(start, viewSize: viewSize)
            let e = pixelToScreen(end, viewSize: viewSize)
            ZStack {
                Path { path in
                    path.move(to: s)
                    path.addLine(to: e)
                }
                .stroke(Color.cyan, lineWidth: 1.5)

                // Distance label at midpoint
                let mid = CGPoint(x: (s.x + e.x) / 2, y: (s.y + e.y) / 2)
                let label = panel.pixelSpacing != nil
                    ? String(format: "%.1f mm", distanceMM)
                    : String(format: "%.1f px", distanceMM)
                Text(label)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.cyan)
                    .padding(2)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(2)
                    .position(x: mid.x, y: mid.y - 12)

                // Endpoint markers
                Circle()
                    .fill(Color.cyan)
                    .frame(width: 6, height: 6)
                    .position(s)
                Circle()
                    .fill(Color.cyan)
                    .frame(width: 6, height: 6)
                    .position(e)
            }

        case .angle(let vertex, let arm1, let arm2, let degrees):
            let v = pixelToScreen(vertex, viewSize: viewSize)
            let a1 = pixelToScreen(arm1, viewSize: viewSize)
            let a2 = pixelToScreen(arm2, viewSize: viewSize)
            ZStack {
                Path { path in
                    path.move(to: a1)
                    path.addLine(to: v)
                    path.addLine(to: a2)
                }
                .stroke(Color.green, lineWidth: 1.5)

                // Angle label near vertex
                Text(String(format: "%.1f°", degrees))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.green)
                    .padding(2)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(2)
                    .position(x: v.x + 16, y: v.y - 12)

                // Endpoint markers
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                    .position(a1)
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                    .position(v)
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                    .position(a2)
            }

        case .roiStats(let rect, let mean, let maxV, let minV, let stdDev, let count):
            let topLeft = pixelToScreen(CGPoint(x: rect.minX, y: rect.minY), viewSize: viewSize)
            let bottomRight = pixelToScreen(CGPoint(x: rect.maxX, y: rect.maxY), viewSize: viewSize)
            let screenRect = CGRect(
                x: min(topLeft.x, bottomRight.x),
                y: min(topLeft.y, bottomRight.y),
                width: abs(bottomRight.x - topLeft.x),
                height: abs(bottomRight.y - topLeft.y)
            )
            ZStack {
                Rectangle()
                    .stroke(Color.orange, lineWidth: 1.5)
                    .frame(width: screenRect.width, height: screenRect.height)
                    .position(x: screenRect.midX, y: screenRect.midY)

                // Stats label below the rectangle
                let unit = panel.valueUnit
                VStack(alignment: .leading, spacing: 1) {
                    Text("Mean: \(PixelValueUnit.format(mean, unit: unit))")
                    Text("SD: \(PixelValueUnit.format(stdDev, unit: unit))")
                    Text("Min: \(PixelValues.format(minV))  Max: \(PixelValueUnit.format(maxV, unit: unit))")
                    Text("N: \(count)")
                }
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.orange)
                .padding(3)
                .background(Color.black.opacity(0.7))
                .cornerRadius(3)
                .position(x: screenRect.midX, y: screenRect.maxY + 30)
            }

        // MARK: AI Annotation Types

        case .aiMask(let mask, let maskWidth, let maskHeight, let bounds,
                     let label, let confidence):
            if panel.showAIAnnotations,
               let image = AnnotationMaskImage.cgImage(mask: mask,
                                                       width: maskWidth,
                                                       height: maskHeight) {
                // Bounds are in pixel space; map the corners through the same
                // transform the image itself uses so the mask stays registered
                // under zoom, pan, and rotation.
                let topLeft = pixelToScreen(CGPoint(x: bounds.minX, y: bounds.minY),
                                            viewSize: viewSize)
                let bottomRight = pixelToScreen(CGPoint(x: bounds.maxX, y: bounds.maxY),
                                                viewSize: viewSize)
                let screenRect = CGRect(x: min(topLeft.x, bottomRight.x),
                                        y: min(topLeft.y, bottomRight.y),
                                        width: abs(bottomRight.x - topLeft.x),
                                        height: abs(bottomRight.y - topLeft.y))
                let isSelected = panel.selectedAnnotationID == annotation.id

                ZStack {
                    Image(decorative: image, scale: 1.0)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: screenRect.width, height: screenRect.height)
                        .position(x: screenRect.midX, y: screenRect.midY)
                        .opacity(isSelected ? 0.65 : 0.45)

                    Rectangle()
                        .stroke(Color.mint,
                                style: StrokeStyle(lineWidth: isSelected ? 2.0 : 1.0,
                                                   dash: [4, 3]))
                        .frame(width: screenRect.width, height: screenRect.height)
                        .position(x: screenRect.midX, y: screenRect.midY)

                    HStack(spacing: 3) {
                        Text("AI")
                            .font(.system(.caption2, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Color.mint)
                            .cornerRadius(2)
                        Text(confidence > 0
                             ? "\(label) (\(Int(confidence * 100))%)"
                             : label)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.mint)
                    }
                    .padding(2)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(3)
                    .position(x: screenRect.midX, y: screenRect.minY - 12)
                }
            }

        case .aiStructure(let rect, let label, let confidence):
            if panel.showAIAnnotations {
                let sr = aiScreenRect(rect, viewSize: viewSize)
                let isSelected = panel.selectedAnnotationID == annotation.id
                ZStack {
                    if isSelected {
                        Rectangle()
                            .fill(Color.yellow.opacity(0.15))
                            .frame(width: sr.width, height: sr.height)
                            .position(x: sr.midX, y: sr.midY)
                    }
                    Rectangle()
                        .stroke(Color.yellow, style: StrokeStyle(lineWidth: isSelected ? 2.5 : 1.5, dash: [6, 3]))
                        .frame(width: sr.width, height: sr.height)
                        .position(x: sr.midX, y: sr.midY)

                    HStack(spacing: 3) {
                        Text("AI")
                            .font(.system(.caption2, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Color.yellow)
                            .cornerRadius(2)
                        Text("\(label) (model \(Int(confidence * 100))%)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.yellow)
                    }
                    .padding(2)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(3)
                    .position(x: sr.midX, y: sr.minY - 12)
                }
            }

        case .aiFinding(let rect, let description, let severity):
            if panel.showAIAnnotations {
                let sr = aiScreenRect(rect, viewSize: viewSize)
                let parsedSeverity = AISeverity(parsing: severity)
                let severityColor = parsedSeverity.color
                let isSelected = panel.selectedAnnotationID == annotation.id
                ZStack {
                    Rectangle()
                        .fill(severityColor.opacity(isSelected ? 0.3 : 0.15))
                        .frame(width: sr.width, height: sr.height)
                        .position(x: sr.midX, y: sr.midY)
                    Rectangle()
                        .stroke(severityColor, lineWidth: isSelected ? 3 : 2)
                        .frame(width: sr.width, height: sr.height)
                        .position(x: sr.midX, y: sr.midY)

                    HStack(spacing: 3) {
                        Text("AI")
                            .font(.system(.caption2, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(severityColor)
                            .cornerRadius(2)
                        Text(parsedSeverity.rawValue.uppercased())
                            .font(.system(.caption2, weight: .bold))
                            .foregroundStyle(severityColor)
                        Text(description)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    .padding(3)
                    .background(Color.black.opacity(0.8))
                    .cornerRadius(3)
                    .position(x: sr.midX, y: sr.maxY + 14)
                }
            }

        case .aiROILabel(let rect, let label, let description, let confidence):
            if panel.showAIAnnotations {
                let sr = aiScreenRect(rect, viewSize: viewSize)
                let isSelected = panel.selectedAnnotationID == annotation.id
                ZStack {
                    if isSelected {
                        Rectangle()
                            .fill(Color.blue.opacity(0.15))
                            .frame(width: sr.width, height: sr.height)
                            .position(x: sr.midX, y: sr.midY)
                    }
                    Rectangle()
                        .stroke(Color.blue, style: StrokeStyle(lineWidth: isSelected ? 2.5 : 1.5, dash: [4, 3]))
                        .frame(width: sr.width, height: sr.height)
                        .position(x: sr.midX, y: sr.midY)

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 3) {
                            Text("AI")
                                .font(.system(.caption2, weight: .bold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(Color.blue)
                                .cornerRadius(2)
                            Text("\(label) (model \(Int(confidence * 100))%)")
                                .font(.system(.caption2, weight: .semibold))
                                .foregroundStyle(.blue)
                        }
                        Text(description)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                    }
                    .padding(3)
                    .background(Color.black.opacity(0.8))
                    .cornerRadius(3)
                    .position(x: sr.midX, y: sr.maxY + 22)
                }
            }
        }
    }

    /// Convert a normalized (0-1) AI bounding box rect to screen coordinates
    private func aiScreenRect(_ rect: CGRect, viewSize: CGSize) -> CGRect {
        let imgW = max(1, panel.displayImageWidth)
        let imgH = max(1, panel.displayImageHeight)
        let topLeft = pixelToScreen(
            CGPoint(x: rect.origin.x * imgW, y: rect.origin.y * imgH),
            viewSize: viewSize
        )
        let bottomRight = pixelToScreen(
            CGPoint(x: (rect.origin.x + rect.width) * imgW,
                    y: (rect.origin.y + rect.height) * imgH),
            viewSize: viewSize
        )
        return CGRect(
            x: min(topLeft.x, bottomRight.x),
            y: min(topLeft.y, bottomRight.y),
            width: abs(bottomRight.x - topLeft.x),
            height: abs(bottomRight.y - topLeft.y)
        )
    }

    private func pixelToScreen(_ pixel: CGPoint, viewSize: CGSize) -> CGPoint {
        let imgW = max(1, panel.displayImageWidth)
        let imgH = max(1, panel.displayImageHeight)
        let vw = viewSize.width
        let vh = viewSize.height

        let fitScale = min(vw / imgW, vh / imgH)
        let offsetX = (vw - imgW * fitScale) / 2
        let offsetY = (vh - imgH * fitScale) / 2

        var x = pixel.x * fitScale + offsetX
        var y = pixel.y * fitScale + offsetY

        let cx = vw / 2
        let cy = vh / 2
        x -= cx
        y -= cy

        if panel.isFlippedH { x = -x }
        if panel.isFlippedV { y = -y }

        let steps = panel.rotationSteps % 4
        if steps > 0 {
            let angle = -CGFloat(steps) * .pi / 2
            let cosA = cos(angle)
            let sinA = sin(angle)
            let rx = x * cosA - y * sinA
            let ry = x * sinA + y * cosA
            x = rx
            y = ry
        }

        x *= panel.scale
        y *= panel.scale

        x += panel.translation.x
        y -= panel.translation.y

        x += cx
        y += cy
        return CGPoint(x: x, y: y)
    }
}

// MARK: - Tool Palette

struct ToolPalette: View {
    @ObservedObject var model: DICOMModel
    @ObservedObject private var aiService = AIService.shared

    var body: some View {
        VStack(spacing: 2) {
            ForEach(ActiveTool.allCases.filter { $0 != .aiAnalyze }) { tool in
                Button(action: { model.activeTool = tool }) {
                    Image(systemName: tool.icon)
                        .font(.system(size: 14))
                        .frame(width: 32, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(model.activeTool == tool ? Color.accentColor.opacity(0.3) : Color.clear)
                        )
                        .foregroundStyle(model.activeTool == tool ? .white : .secondary)
                }
                .buttonStyle(.plain)
                .help("\(tool.rawValue) (\(tool.shortcutHint))")
            }
        }
        .padding(4)
        .background(.ultraThinMaterial)
        .cornerRadius(8)
    }
}

// MARK: - Cursor Info Overlay (Value Readout)

struct CursorInfoOverlay: View {
    @ObservedObject var panel: PanelState

    var body: some View {
        VStack {
            HStack {
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if panel.hasCursorPatientPosition {
                        Text(String(format: "x: %.1f  y: %.1f  z: %.1f",
                             panel.cursorPatientX, panel.cursorPatientY, panel.cursorPatientZ))
                    }
                    Text("Value: \(PixelValueUnit.format(panel.cursorHU, unit: panel.valueUnit))  [\(panel.cursorPixelX), \(panel.cursorPixelY)]")
                }
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.white)
                .padding(4)
                .background(.black.opacity(0.6))
                .cornerRadius(4)
                .padding(8)
            }
            Spacer()
        }
        .allowsHitTesting(false)
    }
}
