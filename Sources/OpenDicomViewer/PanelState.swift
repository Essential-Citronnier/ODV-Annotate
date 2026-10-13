// PanelState.swift
// OpenDicomViewer
//
// Defines the per-panel state model and supporting enums for the multi-panel
// viewer architecture.
//
// Key types:
//   ViewerLayout       — Layout configuration (1x1, 2x1, 1x2, 2x2)
//   NavigationDirection — Arrow key navigation actions
//   PanelMode          — Display mode per panel (2D slice, MPR sagittal/coronal, MIP)
//   PanelState         — Observable state for a single viewer panel, including:
//                         series/image assignment, window/level, zoom/pan,
//                         spatial metadata, histogram, cursor readout, and
//                         display modifiers (invert, rotate, flip)
//
// PanelState is a reference type (class) so multiple views can observe the
// same panel instance. Shared resources (caches, series data) live in DICOMModel.
// Licensed under the MIT License. See LICENSE for details.

import SwiftUI
import DCMTKWrapper

// MARK: - Layout Configuration
enum ViewerLayout: String, CaseIterable, Identifiable {
    case single = "1×1"
    case twoHorizontal = "2×1"
    case twoVertical = "1×2"
    case quad = "2×2"

    var id: String { rawValue }

    var rows: Int {
        switch self {
        case .single, .twoHorizontal: return 1
        case .twoVertical, .quad: return 2
        }
    }

    var columns: Int {
        switch self {
        case .single, .twoVertical: return 1
        case .twoHorizontal, .quad: return 2
        }
    }

    var panelCount: Int { rows * columns }

    var iconName: String {
        switch self {
        case .single:          return "rectangle"
        case .twoHorizontal:   return "rectangle.split.2x1"
        case .twoVertical:     return "rectangle.split.1x2"
        case .quad:            return "rectangle.split.2x2"
        }
    }
}

// MARK: - Navigation Direction
enum NavigationDirection {
    case nextImage, prevImage, nextSeries, prevSeries
}

// MARK: - Panel Display Mode
enum PanelMode: String, CaseIterable, Identifiable {
    case slice2D = "Slice"
    case mprSagittal = "Sagittal"
    case mprCoronal = "Coronal"
    case mip = "MIP"

    var id: String { rawValue }
}

// MARK: - Active Tool
enum ActiveTool: String, CaseIterable, Identifiable {
    case select = "Select"
    case pan = "Pan"
    case windowLevel = "W/L"
    case zoom = "Zoom"
    case roiWL = "ROI W/L"
    case roiStats = "ROI Stats"
    case ruler = "Ruler"
    case angle = "Angle"
    case eraser = "Eraser"
    case aiAnalyze = "AI Analyze"
    /// Click prompting for promptable segmentation (SAM family). A plain click
    /// adds a foreground point; option-click subtracts a background point.
    case aiPoint = "AI Point"
    /// Box prompting for promptable segmentation.
    case aiBox = "AI Box"

    var id: String { rawValue }

    /// Whether this tool drives a promptable-segmentation session, which the
    /// host opens lazily on first prompt and closes when the slice changes.
    var isPromptTool: Bool { self == .aiPoint || self == .aiBox }

    var icon: String {
        switch self {
        case .select: return "cursorarrow"
        case .pan: return "arrow.up.and.down.and.arrow.left.and.right"
        case .windowLevel: return "sun.max"
        case .zoom: return "magnifyingglass"
        case .roiWL: return "rectangle.dashed"
        case .roiStats: return "chart.bar.xaxis"
        case .ruler: return "ruler"
        case .angle: return "angle"
        case .eraser: return "eraser"
        case .aiAnalyze: return "brain"
        case .aiPoint: return "hand.tap"
        case .aiBox: return "rectangle.and.hand.point.up.left"
        }
    }

    var shortcutHint: String {
        switch self {
        case .select: return "V"
        case .pan: return "P"
        case .windowLevel: return "W"
        case .zoom: return "Z"
        case .roiWL: return "O"
        case .roiStats: return "S"
        case .ruler: return "D"
        case .angle: return "N"
        case .eraser: return "E"
        case .aiAnalyze: return "G"
        case .aiPoint: return "K"
        case .aiBox: return "B"
        }
    }
}

// MARK: - Annotations
enum AnnotationType {
    case ruler(start: CGPoint, end: CGPoint, distanceMM: Double)
    case angle(vertex: CGPoint, arm1: CGPoint, arm2: CGPoint, degrees: Double)
    case roiStats(rect: CGRect, mean: Double, max: Double, min: Double, stdDev: Double, count: Int)

    // AI-generated annotations (coordinates are in pixel space, same as manual annotations)
    case aiStructure(rect: CGRect, label: String, confidence: Double)
    case aiFinding(rect: CGRect, description: String, severity: String)
    case aiROILabel(rect: CGRect, label: String, description: String, confidence: Double)

    /// A 2D mask returned by a promptable segmentation plugin (SAM-family).
    /// `mask` is a row-major bitmap over a `width` x `height` grid in image
    /// pixel space; `bounds` is its tight bounding rect, precomputed so hit
    /// testing and label placement do not have to rescan the bitmap.
    case aiMask(mask: [Bool], width: Int, height: Int, bounds: CGRect,
                label: String, confidence: Double)
}

/// Identifies the exact pixels a panel displays, so an AI result computed on
/// one slice is never drawn over another.
struct AnnotationSlice: Equatable, Hashable {
    let seriesIndex: Int
    let panelMode: PanelMode
    /// Image index (2D), voxel index (MPR) or slab centre (MIP).
    let index: Int
    /// Frame within a multi-frame image; 0 otherwise.
    let frame: Int
    /// MIP slab thickness; 0 for other modes.
    let slab: Int
}

struct Annotation: Identifiable {
    let id = UUID()
    let type: AnnotationType
    var isAI: Bool = false
    /// The slice this annotation was computed on. nil means it is not bound
    /// to a slice and shows wherever the panel is (manual measurements).
    var slice: AnnotationSlice? = nil

    func isVisible(on current: AnnotationSlice) -> Bool {
        slice == nil || slice == current
    }
}

// MARK: - Panel State
/// Per-panel observable state. Each panel in the multi-panel viewer gets its own instance.
/// Shared resources (caches, queues, series data) remain in DICOMModel.
class PanelState: ObservableObject, Identifiable {
    let id: UUID = UUID()

    // Series/Image Assignment
    @Published var seriesIndex: Int = -1
    @Published var imageIndex: Int = -1

    // Panel display mode
    @Published var panelMode: PanelMode = .slice2D

    // MPR position (voxel index for orthogonal slices)
    @Published var mprSliceIndex: Int = 0

    // MIP slab projection
    @Published var mipSlabPosition: Int = 0    // center slice index (scrollable)
    @Published var mipSlabThickness: Int = 10  // number of slices in the slab

    // Rendered Image
    @Published var image: NSImage? = nil

    // Display dimensions (from NSImage.size, which may differ from raw pixel
    // dimensions for MPR views with non-isotropic voxels)
    var displayImageWidth: CGFloat = 0
    var displayImageHeight: CGFloat = 0

    /// Set the display image and update display dimensions from its size.
    /// Use this instead of assigning `image` directly so that overlay
    /// coordinate transforms use the correct (aspect-ratio-corrected) size.
    func setDisplayImage(_ img: NSImage) {
        image = img
        displayImageWidth = img.size.width
        displayImageHeight = img.size.height
    }

    // Window/Level
    @Published var windowWidth: Double = 0
    @Published var windowCenter: Double = 0
    var initialWindowWidth: Double = 0
    var initialWindowCenter: Double = 0

    // View Transform (zoom/pan)
    @Published var scale: CGFloat = 1.0
    @Published var translation: CGPoint = .zero

    // Histogram
    @Published var histogramData: [Double] = []
    @Published var minPixelValue: Double = 0.0
    @Published var maxPixelValue: Double = 1.0

    // DICOM Tags
    @Published var tags: [DicomElement] = []

    // UI State
    @Published var currentSeriesInfo: String = ""
    @Published var currentImageInfo: String = ""
    @Published var errorMessage: String? = nil
    @Published var isLoading: Bool = false
    @Published var cacheProgress: Double = 0.0

    // Raw Data for Re-rendering (not published - internal use)
    var rawPixelData: Data? = nil
    var imageWidth: Int = 0
    var imageHeight: Int = 0
    var bitDepth: Int = 8
    var samples: Int = 1
    var isMonochrome1: Bool = false
    var isSigned: Bool = false
    var dcmtkImage: DCMTKImageObject? = nil

    /// Whether raw pixel data is available for CPU re-rendering
    var isRawDataAvailable: Bool { rawPixelData != nil }

    // Spatial Metadata (for cross-reference lines)
    @Published var imagePositionPatient: (Double, Double, Double)? = nil
    @Published var imageOrientationPatient: [Double]? = nil  // 6 values
    @Published var pixelSpacing: (Double, Double)? = nil

    // Cursor tracking (HU readout)
    @Published var showCursorInfo: Bool = false
    @Published var cursorPixelX: Int = 0
    @Published var cursorPixelY: Int = 0
    @Published var cursorHU: Double = 0
    @Published var cursorPatientX: Double = 0
    @Published var cursorPatientY: Double = 0
    @Published var cursorPatientZ: Double = 0
    @Published var hasCursorPatientPosition: Bool = false

    // ROI W/L tool
    @Published var isROIMode: Bool = false
    @Published var roiRect: CGRect? = nil  // in pixel coordinates, used during drag

    // Per-panel loading queue (prevents cross-panel cancellation)
    let loadingQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()

    // Group selection for simultaneous scrolling
    @Published var isGroupSelected: Bool = false

    // Display modifiers
    @Published var isInverted: Bool = false
    @Published var rotationSteps: Int = 0       // 0=0°, 1=90°CW, 2=180°, 3=270°CW
    @Published var isFlippedH: Bool = false      // Horizontal flip (left-right)
    @Published var isFlippedV: Bool = false       // Vertical flip (up-down)

    // Annotations
    @Published var annotations: [Annotation] = []
    @Published var importedOverlays: [DICOMImportedOverlay] = []

    // In-progress annotation preview
    @Published var rulerPreviewStart: CGPoint? = nil
    @Published var rulerPreviewEnd: CGPoint? = nil
    @Published var anglePreviewPoints: [CGPoint] = []

    // Multi-frame / Cine state
    @Published var isMultiFrame: Bool = false
    @Published var numberOfFrames: Int = 0
    @Published var currentFrameIndex: Int = 0
    @Published var isPlaying: Bool = false
    @Published var playbackSpeed: Double = 1.0
    @Published var cineRate: Double = 30.0
    @Published var frameTimeMs: Double = 33.33
    @Published var loopPlayback: Bool = true

    /// Internal frame counter updated every tick (not @Published, no SwiftUI cascade)
    var cineInternalFrame: Int = 0
    /// Weak reference to the NSView for direct cine frame rendering (bypasses SwiftUI)
    weak var cineDisplayView: NSView?

    // AI Analysis State
    @Published var aiAnalysisInProgress: Bool = false
    @Published var aiError: String? = nil
    @Published var aiDescription: String? = nil
    /// The slice `aiDescription` was computed on.
    @Published var aiDescriptionSlice: AnnotationSlice? = nil
    @Published var showAIAnnotations: Bool = false
    /// Scalar measurements returned by a plugin task declaring `metrics`.
    @Published var pluginMetrics: [String: Double] = [:]
    @Published var selectedAnnotationID: UUID? = nil

    /// Reset panel to empty state
    func reset() {
        seriesIndex = -1
        imageIndex = -1
        panelMode = .slice2D
        mprSliceIndex = 0
        mipSlabPosition = 0
        mipSlabThickness = 10
        image = nil
        displayImageWidth = 0
        displayImageHeight = 0
        windowWidth = 0
        windowCenter = 0
        initialWindowWidth = 0
        initialWindowCenter = 0
        scale = 1.0
        translation = .zero
        histogramData = []
        minPixelValue = 0.0
        maxPixelValue = 1.0
        tags = []
        currentSeriesInfo = ""
        currentImageInfo = ""
        errorMessage = nil
        isLoading = false
        cacheProgress = 0.0
        rawPixelData = nil
        imageWidth = 0
        imageHeight = 0
        bitDepth = 8
        samples = 1
        isMonochrome1 = false
        isSigned = false
        dcmtkImage = nil
        imagePositionPatient = nil
        imageOrientationPatient = nil
        pixelSpacing = nil
        showCursorInfo = false
        cursorPixelX = 0
        cursorPixelY = 0
        cursorHU = 0
        cursorPatientX = 0
        cursorPatientY = 0
        cursorPatientZ = 0
        hasCursorPatientPosition = false
        isROIMode = false
        roiRect = nil
        isGroupSelected = false
        isInverted = false
        rotationSteps = 0
        isFlippedH = false
        isFlippedV = false
        annotations = []
        importedOverlays = []
        rulerPreviewStart = nil
        rulerPreviewEnd = nil
        anglePreviewPoints = []
        isMultiFrame = false
        numberOfFrames = 0
        currentFrameIndex = 0
        isPlaying = false
        playbackSpeed = 1.0
        cineRate = 30.0
        frameTimeMs = 33.33
        loopPlayback = true
        cineInternalFrame = 0
        cineDisplayView = nil
        aiAnalysisInProgress = false
        aiError = nil
        aiDescription = nil
        aiDescriptionSlice = nil
        showAIAnnotations = false
        selectedAnnotationID = nil
    }

    /// The slice currently on screen, for binding and filtering AI annotations.
    var currentSlice: AnnotationSlice {
        switch panelMode {
        case .slice2D:
            return AnnotationSlice(seriesIndex: seriesIndex, panelMode: panelMode,
                                   index: imageIndex,
                                   frame: isMultiFrame ? currentFrameIndex : 0, slab: 0)
        case .mprSagittal, .mprCoronal:
            return AnnotationSlice(seriesIndex: seriesIndex, panelMode: panelMode,
                                   index: mprSliceIndex, frame: 0, slab: 0)
        case .mip:
            return AnnotationSlice(seriesIndex: seriesIndex, panelMode: panelMode,
                                   index: mipSlabPosition, frame: 0, slab: mipSlabThickness)
        }
    }

    /// Annotations to draw on the slice currently displayed.
    /// During cine playback `currentFrameIndex` is not updated per frame, so
    /// slice-bound annotations are hidden rather than shown on the wrong frame.
    var visibleAnnotations: [Annotation] {
        let current = currentSlice
        return annotations.filter {
            $0.slice == nil || (!isPlaying && $0.isVisible(on: current))
        }
    }

    /// The AI description, if it belongs to the slice on screen.
    var visibleAIDescription: String? {
        guard let description = aiDescription,
              aiDescriptionSlice == nil || aiDescriptionSlice == currentSlice else { return nil }
        return description
    }

    /// Remove only AI-generated annotations
    func clearAIAnnotations() {
        annotations.removeAll(where: { $0.isAI })
        aiDescription = nil
        aiDescriptionSlice = nil
        aiError = nil
    }
}
