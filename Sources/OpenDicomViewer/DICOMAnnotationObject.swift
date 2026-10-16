// DICOMAnnotationObject.swift
// OpenDicomViewer
//
// Lightweight readers for selected DICOM annotation-derived objects that can
// be rendered as 2D overlays on matching source images. The implementation
// intentionally supports GSPS vector/text annotations, RTSTRUCT planar
// contours, and native binary DICOM SEG masks. Richer SR content remains
// detected for inspection.
// Licensed under the MIT License. See LICENSE for details.

import CoreGraphics
import Foundation
import simd

enum DICOMOverlayCoordinateSpace: String {
    case pixel = "PIXEL"
    case display = "DISPLAY"
}

enum DICOMImportedOverlayGeometry {
    case polyline(points: [CGPoint], closed: Bool)
    case point(CGPoint)
    case ellipse(points: [CGPoint])
    case text(value: String, anchor: CGPoint)
    case mask(width: Int, height: Int, bitmap: Data)
}

struct DICOMImportedOverlay: Identifiable {
    let id = UUID()
    let sourceURL: URL
    let sourceKind: DICOMDerivedObjectKind
    let label: String
    let coordinateSpace: DICOMOverlayCoordinateSpace
    let geometry: DICOMImportedOverlayGeometry
}

struct DICOMOverlayPrimitive {
    let referencedSOPInstanceUIDs: Set<String>
    let label: String
    let coordinateSpace: DICOMOverlayCoordinateSpace
    let geometry: DICOMImportedOverlayGeometry
}

struct DICOMPatientContour {
    let referencedSOPInstanceUID: String?
    let roiNumber: Int?
    let label: String
    let points: [SIMD3<Double>]
    let closed: Bool
    /// ROI's Referenced Frame of Reference UID (3006,0024)
    var frameOfReferenceUID: String? = nil
}

struct DICOMSegmentationFrame {
    let referencedSOPInstanceUID: String?
    let segmentNumber: Int?
    let label: String
    let width: Int
    let height: Int
    let bitmap: Data
    /// Plane Position (Patient) of the frame, from the per-frame functional groups
    var imagePosition: SIMD3<Double>? = nil
    /// Plane Orientation (Patient), per-frame or shared
    var imageOrientation: [Double]? = nil
}

struct DICOMAnnotationObject {
    let url: URL
    let kind: DICOMDerivedObjectKind
    let label: String
    let frameOfReferenceUID: String?
    let graphics: [DICOMOverlayPrimitive]
    let contours: [DICOMPatientContour]
    let segmentFrames: [DICOMSegmentationFrame]

    func resolvedOverlays(for imageContext: DicomImageContext) -> [DICOMImportedOverlay] {
        var overlays: [DICOMImportedOverlay] = []

        for graphic in graphics {
            if !graphic.referencedSOPInstanceUIDs.isEmpty,
               !graphic.referencedSOPInstanceUIDs.contains(imageContext.sopInstanceUID) {
                continue
            }
            overlays.append(DICOMImportedOverlay(
                sourceURL: url,
                sourceKind: kind,
                label: graphic.label,
                coordinateSpace: graphic.coordinateSpace,
                geometry: graphic.geometry
            ))
        }

        for frame in segmentFrames where segmentFrameApplies(frame, to: imageContext) {
            guard frame.width > 0, frame.height > 0, frame.bitmap.count == frame.width * frame.height else {
                continue
            }

            overlays.append(DICOMImportedOverlay(
                sourceURL: url,
                sourceKind: kind,
                label: frame.label,
                coordinateSpace: .pixel,
                geometry: .mask(width: frame.width, height: frame.height, bitmap: frame.bitmap)
            ))
        }

        guard let ipp = imageContext.imagePosition,
              let iop = imageContext.imageOrientation, iop.count == 6,
              let spacing = imageContext.pixelSpacing else {
            return overlays
        }

        if let objectFOR = frameOfReferenceUID,
           let imageFOR = imageContext.frameOfReferenceUID,
           !objectFOR.isEmpty,
           !imageFOR.isEmpty,
           objectFOR != imageFOR {
            return overlays
        }

        let rowDir = SIMD3<Double>(iop[0], iop[1], iop[2])
        let colDir = SIMD3<Double>(iop[3], iop[4], iop[5])
        let normal = simd_normalize(simd_cross(rowDir, colDir))
        let rowSpacing = max(spacing.x, 0.000_001)
        let colSpacing = max(spacing.y, 0.000_001)
        let planeTolerance = max(imageContext.sliceThickness ?? imageContext.spacingBetweenSlices ?? 1.0, 1.0) / 2.0 + 0.25

        for contour in contours {
            if let ref = contour.referencedSOPInstanceUID, !ref.isEmpty, ref != imageContext.sopInstanceUID {
                continue
            }
            // Per-ROI frame of reference must match the image's when both are known
            if let roiFOR = contour.frameOfReferenceUID, !roiFOR.isEmpty,
               let imageFOR = imageContext.frameOfReferenceUID, !imageFOR.isEmpty,
               roiFOR != imageFOR {
                continue
            }

            var pixelPoints: [CGPoint] = []
            var maxPlaneDistance = 0.0

            for point in contour.points {
                let delta = point - ipp
                let planeDistance = abs(simd_dot(delta, normal))
                maxPlaneDistance = max(maxPlaneDistance, planeDistance)
                let x = simd_dot(delta, rowDir) / colSpacing
                let y = simd_dot(delta, colDir) / rowSpacing
                guard x.isFinite, y.isFinite else {
                    pixelPoints.removeAll()
                    break
                }
                pixelPoints.append(CGPoint(x: x, y: y))
            }

            guard pixelPoints.count >= 2 else { continue }
            if contour.referencedSOPInstanceUID == nil && maxPlaneDistance > planeTolerance {
                continue
            }

            overlays.append(DICOMImportedOverlay(
                sourceURL: url,
                sourceKind: kind,
                label: contour.label,
                coordinateSpace: .pixel,
                geometry: .polyline(points: pixelPoints, closed: contour.closed)
            ))
        }

        return overlays
    }

    /// A SEG frame applies to an image when it references the image's SOP
    /// Instance, or — lacking derivation references — when it lies in the
    /// image's plane within the same frame of reference. Frames that can be
    /// placed neither way are not drawn (they used to appear on every image
    /// of every series).
    private func segmentFrameApplies(_ frame: DICOMSegmentationFrame, to imageContext: DicomImageContext) -> Bool {
        if let ref = frame.referencedSOPInstanceUID, !ref.isEmpty {
            return ref == imageContext.sopInstanceUID
        }
        guard let objectFOR = frameOfReferenceUID, !objectFOR.isEmpty,
              let imageFOR = imageContext.frameOfReferenceUID, objectFOR == imageFOR,
              let framePos = frame.imagePosition,
              let ipp = imageContext.imagePosition,
              let iop = imageContext.imageOrientation, iop.count == 6 else {
            return false
        }
        if let frameIOP = frame.imageOrientation, frameIOP.count == 6,
           zip(frameIOP, iop).contains(where: { abs($0 - $1) > 0.01 }) {
            return false
        }
        let normal = simd_normalize(simd_cross(SIMD3(iop[0], iop[1], iop[2]), SIMD3(iop[3], iop[4], iop[5])))
        let tolerance = max(imageContext.sliceThickness ?? imageContext.spacingBetweenSlices ?? 1.0, 1.0) / 2.0
        // Same plane, and the frame's origin coincides with the image's
        let delta = framePos - ipp
        return abs(simd_dot(delta, normal)) <= tolerance && simd_length(delta) <= tolerance + 0.5
    }
}

enum DICOMAnnotationObjectParser {
    static func parse(url: URL, kind: DICOMDerivedObjectKind) -> DICOMAnnotationObject? {
        guard kind == .grayscaleSoftcopyPresentationState ||
              kind == .colorSoftcopyPresentationState ||
              kind == .blendingSoftcopyPresentationState ||
              kind == .rtStructureSet ||
              kind == .dicomSegmentation else {
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            let elements = try DICOMElementTreeParser.parseFile(data)
            switch kind {
            case .grayscaleSoftcopyPresentationState, .colorSoftcopyPresentationState, .blendingSoftcopyPresentationState:
                return parsePresentationState(url: url, kind: kind, elements: elements)
            case .rtStructureSet:
                return parseRTStructureSet(url: url, elements: elements)
            case .dicomSegmentation:
                return parseSegmentation(url: url, elements: elements)
            default:
                return nil
            }
        } catch {
            return nil
        }
    }

    private static func parsePresentationState(url: URL, kind: DICOMDerivedObjectKind, elements: [DICOMTreeElement]) -> DICOMAnnotationObject? {
        let label = elements.string(0x0070, 0x0080) ?? elements.string(0x0008, 0x103E) ?? kind.rawValue
        var graphics: [DICOMOverlayPrimitive] = []

        for annotationItem in elements.sequenceItems(0x0070, 0x0001) {
            let units = DICOMOverlayCoordinateSpace(rawValue: annotationItem.string(0x0070, 0x0005)?.uppercased() ?? "") ?? .pixel
            let referencedSOPs = Set(annotationItem.sequenceItems(0x0008, 0x1140).compactMap {
                $0.string(0x0008, 0x1155)
            })
            let layer = annotationItem.string(0x0070, 0x0002) ?? label

            for objectItem in annotationItem.sequenceItems(0x0070, 0x0009) {
                let type = objectItem.string(0x0070, 0x0023)?.uppercased() ?? "POLYLINE"
                let values = objectItem.float32Values(0x0070, 0x0022)
                guard values.count >= 2 else { continue }
                let points = stride(from: 0, to: values.count - 1, by: 2).map {
                    CGPoint(x: CGFloat(values[$0]), y: CGFloat(values[$0 + 1]))
                }

                let geometry: DICOMImportedOverlayGeometry
                switch type {
                case "POINT":
                    geometry = .point(points[0])
                case "CIRCLE", "ELLIPSE":
                    geometry = .ellipse(points: points)
                case "INTERPOLATED":
                    geometry = .polyline(points: points, closed: false)
                default:
                    let filled = objectItem.string(0x0070, 0x0024)?.uppercased() == "Y"
                    let closesItself = points.count > 2 && points.first == points.last
                    geometry = .polyline(points: points, closed: filled || closesItself)
                }

                graphics.append(DICOMOverlayPrimitive(
                    referencedSOPInstanceUIDs: referencedSOPs,
                    label: layer,
                    coordinateSpace: units,
                    geometry: geometry
                ))
            }

            for textItem in annotationItem.sequenceItems(0x0070, 0x0008) {
                guard let value = textItem.string(0x0070, 0x0006), !value.isEmpty else { continue }
                let textUnits = DICOMOverlayCoordinateSpace(rawValue: textItem.string(0x0070, 0x0004)?.uppercased() ?? "") ?? units
                let anchorValues = textItem.float32Values(0x0070, 0x0014)
                let boxValues = textItem.float32Values(0x0070, 0x0010)
                let anchor: CGPoint
                if anchorValues.count >= 2 {
                    anchor = CGPoint(x: CGFloat(anchorValues[0]), y: CGFloat(anchorValues[1]))
                } else if boxValues.count >= 2 {
                    anchor = CGPoint(x: CGFloat(boxValues[0]), y: CGFloat(boxValues[1]))
                } else {
                    continue
                }
                graphics.append(DICOMOverlayPrimitive(
                    referencedSOPInstanceUIDs: referencedSOPs,
                    label: layer,
                    coordinateSpace: textUnits,
                    geometry: .text(value: value, anchor: anchor)
                ))
            }
        }

        guard !graphics.isEmpty else { return nil }
        return DICOMAnnotationObject(
            url: url,
            kind: kind,
            label: label,
            frameOfReferenceUID: elements.string(0x0020, 0x0052),
            graphics: graphics,
            contours: [],
            segmentFrames: []
        )
    }

    private static func parseRTStructureSet(url: URL, elements: [DICOMTreeElement]) -> DICOMAnnotationObject? {
        let label = elements.string(0x3006, 0x0002) ?? elements.string(0x0008, 0x103E) ?? DICOMDerivedObjectKind.rtStructureSet.rawValue
        var roiNames: [Int: String] = [:]
        var roiFrames: [Int: String] = [:]

        for roiItem in elements.sequenceItems(0x3006, 0x0020) {
            guard let number = roiItem.int(0x3006, 0x0022) else { continue }
            roiNames[number] = roiItem.string(0x3006, 0x0026) ?? "ROI \(number)"
            // Referenced Frame of Reference UID (3006,0024)
            if let frame = roiItem.string(0x3006, 0x0024), !frame.isEmpty {
                roiFrames[number] = frame
            }
        }
        // RTSTRUCT rarely carries (0020,0052) itself; the frame of reference
        // lives in Referenced Frame of Reference Sequence (3006,0010).
        let referencedFrame = elements.sequenceItems(0x3006, 0x0010)
            .compactMap { $0.string(0x0020, 0x0052) }.first(where: { !$0.isEmpty })

        var contours: [DICOMPatientContour] = []
        for roiContourItem in elements.sequenceItems(0x3006, 0x0039) {
            let roiNumber = roiContourItem.int(0x3006, 0x0084)
            let roiLabel = roiNumber.flatMap { roiNames[$0] } ?? label

            for contourItem in roiContourItem.sequenceItems(0x3006, 0x0040) {
                let values = contourItem.doubleValues(0x3006, 0x0050)
                guard values.count >= 6 else { continue }
                let points = stride(from: 0, to: values.count - 2, by: 3).map {
                    SIMD3<Double>(values[$0], values[$0 + 1], values[$0 + 2])
                }
                let referencedSOP = contourItem.sequenceItems(0x3006, 0x0016).first?.string(0x0008, 0x1155)
                let geometricType = contourItem.string(0x3006, 0x0042)?.uppercased() ?? "CLOSED_PLANAR"
                contours.append(DICOMPatientContour(
                    referencedSOPInstanceUID: referencedSOP,
                    roiNumber: roiNumber,
                    label: roiLabel,
                    points: points,
                    closed: geometricType.contains("CLOSED"),
                    frameOfReferenceUID: roiNumber.flatMap { roiFrames[$0] } ?? referencedFrame
                ))
            }
        }

        guard !contours.isEmpty else { return nil }
        return DICOMAnnotationObject(
            url: url,
            kind: .rtStructureSet,
            label: label,
            frameOfReferenceUID: elements.string(0x0020, 0x0052) ?? referencedFrame ?? roiFrames.values.first,
            graphics: [],
            contours: contours,
            segmentFrames: []
        )
    }

    private static func parseSegmentation(url: URL, elements: [DICOMTreeElement]) -> DICOMAnnotationObject? {
        let segmentationType = elements.string(0x0062, 0x0001)?.uppercased() ?? ""
        guard segmentationType == "BINARY" else { return nil }

        let rows = elements.int(0x0028, 0x0010) ?? 0
        let columns = elements.int(0x0028, 0x0011) ?? 0
        let numberOfFrames = elements.int(0x0028, 0x0008) ?? 1
        let bitsAllocated = elements.int(0x0028, 0x0100) ?? 0
        let samplesPerPixel = elements.int(0x0028, 0x0002) ?? 1
        guard rows > 0,
              columns > 0,
              numberOfFrames > 0,
              bitsAllocated == 1,
              samplesPerPixel == 1,
              let pixelElement = elements.first(0x7FE0, 0x0010) else {
            return nil
        }

        var segmentLabels: [Int: String] = [:]
        for segmentItem in elements.sequenceItems(0x0062, 0x0002) {
            guard let number = segmentItem.int(0x0062, 0x0004) else { continue }
            segmentLabels[number] = segmentItem.string(0x0062, 0x0005) ?? "Segment \(number)"
        }

        let label = elements.string(0x0008, 0x103E) ?? DICOMDerivedObjectKind.dicomSegmentation.rawValue
        let frameItems = elements.sequenceItems(0x5200, 0x9230)
        let sharedOrientation = elements.sequenceItems(0x5200, 0x9229).first?
            .sequenceItems(0x0020, 0x9116).first?.doubleValues(0x0020, 0x0037)
        let frameCount = min(numberOfFrames, frameItems.isEmpty ? numberOfFrames : frameItems.count)
        let pixelsPerFrame = rows * columns
        var frames: [DICOMSegmentationFrame] = []

        for frameIndex in 0..<frameCount {
            guard let bitmap = unpackBinaryMaskFrame(
                pixelData: pixelElement.data,
                frameIndex: frameIndex,
                pixelCount: pixelsPerFrame
            ) else {
                continue
            }

            let frameItem = frameIndex < frameItems.count ? frameItems[frameIndex] : []
            let segmentNumber = frameItem.sequenceItems(0x0062, 0x000A).first?.int(0x0062, 0x000B)
            let segmentLabel = segmentNumber.flatMap { segmentLabels[$0] } ?? label
            let referencedSOP = referencedSOPInstanceUID(fromSegmentationFrame: frameItem)
            // Plane Position Sequence (0020,9113) → ImagePositionPatient
            let position = frameItem.sequenceItems(0x0020, 0x9113).first?.doubleValues(0x0020, 0x0032)
            // Plane Orientation Sequence (0020,9116), per-frame or shared (5200,9229)
            let orientation = frameItem.sequenceItems(0x0020, 0x9116).first?.doubleValues(0x0020, 0x0037)
                ?? sharedOrientation

            frames.append(DICOMSegmentationFrame(
                referencedSOPInstanceUID: referencedSOP,
                segmentNumber: segmentNumber,
                label: segmentLabel,
                width: columns,
                height: rows,
                bitmap: bitmap,
                imagePosition: position.flatMap { $0.count == 3 ? SIMD3($0[0], $0[1], $0[2]) : nil },
                imageOrientation: orientation.flatMap { $0.count == 6 ? $0 : nil }
            ))
        }

        guard !frames.isEmpty else { return nil }
        return DICOMAnnotationObject(
            url: url,
            kind: .dicomSegmentation,
            label: label,
            frameOfReferenceUID: elements.string(0x0020, 0x0052),
            graphics: [],
            contours: [],
            segmentFrames: frames
        )
    }

    private static func referencedSOPInstanceUID(fromSegmentationFrame frameItem: [DICOMTreeElement]) -> String? {
        for derivationItem in frameItem.sequenceItems(0x0008, 0x9124) {
            for sourceItem in derivationItem.sequenceItems(0x0008, 0x2112) {
                if let uid = sourceItem.string(0x0008, 0x1155), !uid.isEmpty {
                    return uid
                }
            }
        }
        return nil
    }

    private static func unpackBinaryMaskFrame(pixelData: Data, frameIndex: Int, pixelCount: Int) -> Data? {
        guard pixelCount > 0 else { return nil }
        let bitStart = frameIndex * pixelCount
        let bitEnd = bitStart + pixelCount
        guard (bitEnd + 7) / 8 <= pixelData.count else { return nil }

        var bitmap = Data(count: pixelCount)
        for pixelIndex in 0..<pixelCount {
            let bitIndex = bitStart + pixelIndex
            let byte = pixelData[bitIndex / 8]
            bitmap[pixelIndex] = ((byte >> UInt8(bitIndex % 8)) & 0x01) == 1 ? 1 : 0
        }
        return bitmap
    }
}

struct DICOMTreeElement {
    let tag: DicomTag
    let vr: VR
    let data: Data
    let items: [[DICOMTreeElement]]

    var stringValue: String? {
        data.robustString()?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Binary VRs decode as binary. Trying text first misreads them: US 49 is
    /// `31 00`, which reads as "1" once the NUL is trimmed, so SEG segment
    /// numbers 48–57 became 0–9. Implicit-VR elements arrive as UN, so text is
    /// accepted only when every byte is one a DICOM IS value can hold (text VRs
    /// pad with a space, never a NUL).
    var intValue: Int? {
        switch vr {
        case .US, .UL: return unsignedBinaryValue
        case .SS:
            guard data.count == 2 else { return nil }
            return Int(Int16(bitPattern: UInt16(unsignedBinaryValue ?? 0)))
        case .SL:
            guard data.count == 4 else { return nil }
            return Int(Int32(bitPattern: UInt32(unsignedBinaryValue ?? 0)))
        default:
            break
        }
        let isTextInteger = !data.isEmpty && data.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x20 || $0 == 0x2B || $0 == 0x2D
        }
        if isTextInteger || vr == .IS,
           let str = stringValue, let value = Int(str.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return value
        }
        return unsignedBinaryValue
    }

    private var unsignedBinaryValue: Int? {
        if data.count == 2 {
            var val: UInt16 = 0
            _ = withUnsafeMutableBytes(of: &val) { data.copyBytes(to: $0) }
            return Int(UInt16(littleEndian: val))
        }
        if data.count == 4 {
            var val: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &val) { data.copyBytes(to: $0) }
            return Int(UInt32(littleEndian: val))
        }
        return nil
    }

    func float32Values(littleEndian: Bool = true) -> [Double] {
        guard data.count >= 4 else { return [] }
        var values: [Double] = []
        var index = 0
        while index + 4 <= data.count {
            var word: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &word) {
                data.copyBytes(to: $0, from: index..<(index + 4))
            }
            word = littleEndian ? UInt32(littleEndian: word) : UInt32(bigEndian: word)
            values.append(Double(Float32(bitPattern: word)))
            index += 4
        }
        return values
    }

    func doubleValues() -> [Double] {
        guard let str = stringValue, !str.isEmpty else { return [] }
        return str
            .components(separatedBy: "\\")
            .compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

extension Array where Element == DICOMTreeElement {
    func first(_ group: UInt16, _ element: UInt16) -> DICOMTreeElement? {
        first { $0.tag == DicomTag(group: group, element: element) }
    }

    func string(_ group: UInt16, _ element: UInt16) -> String? {
        first(group, element)?.stringValue
    }

    func int(_ group: UInt16, _ element: UInt16) -> Int? {
        first(group, element)?.intValue
    }

    func float32Values(_ group: UInt16, _ element: UInt16) -> [Double] {
        first(group, element)?.float32Values() ?? []
    }

    func doubleValues(_ group: UInt16, _ element: UInt16) -> [Double] {
        first(group, element)?.doubleValues() ?? []
    }

    func sequenceItems(_ group: UInt16, _ element: UInt16) -> [[DICOMTreeElement]] {
        first(group, element)?.items ?? []
    }
}

final class DICOMElementTreeParser {
    private let data: Data
    private var offset: Int
    private var isExplicitVR: Bool
    private var isLittleEndian: Bool
    private let shouldInferTransferSyntaxFromMetaHeader: Bool

    private static let longVRs: Set<String> = ["OB", "OD", "OF", "OL", "OV", "OW", "SQ", "SV", "UC", "UN", "UR", "UT", "UV"]
    private static let knownSequenceTags: Set<DicomTag> = [
        DicomTag(group: 0x0008, element: 0x1140),
        DicomTag(group: 0x0008, element: 0x2112),
        DicomTag(group: 0x0008, element: 0x9124),
        DicomTag(group: 0x0020, element: 0x9113),
        DicomTag(group: 0x0020, element: 0x9116),
        DicomTag(group: 0x0028, element: 0x9110),
        DicomTag(group: 0x0062, element: 0x0002),
        DicomTag(group: 0x0062, element: 0x000A),
        DicomTag(group: 0x0070, element: 0x0001),
        DicomTag(group: 0x0070, element: 0x0008),
        DicomTag(group: 0x0070, element: 0x0009),
        DicomTag(group: 0x3006, element: 0x0016),
        DicomTag(group: 0x3006, element: 0x0020),
        DicomTag(group: 0x3006, element: 0x0039),
        DicomTag(group: 0x3006, element: 0x0040),
        DicomTag(group: 0x5200, element: 0x9229),
        DicomTag(group: 0x5200, element: 0x9230),
    ]

    init(
        data: Data,
        offset: Int = 0,
        isExplicitVR: Bool = true,
        isLittleEndian: Bool = true,
        shouldInferTransferSyntaxFromMetaHeader: Bool = false
    ) {
        self.data = data
        self.offset = offset
        self.isExplicitVR = isExplicitVR
        self.isLittleEndian = isLittleEndian
        self.shouldInferTransferSyntaxFromMetaHeader = shouldInferTransferSyntaxFromMetaHeader
    }

    static func parseFile(_ data: Data) throws -> [DICOMTreeElement] {
        let startOffset: Int
        let explicitVR: Bool
        let inferTransferSyntaxFromMetaHeader: Bool
        if data.count >= 132,
           String(data: data.subdata(in: 128..<132), encoding: .ascii) == "DICM" {
            startOffset = 132
            explicitVR = true
            inferTransferSyntaxFromMetaHeader = true
        } else {
            startOffset = 0
            explicitVR = looksExplicitVR(data: data, offset: startOffset)
            inferTransferSyntaxFromMetaHeader = false
        }
        let parser = DICOMElementTreeParser(
            data: data,
            offset: startOffset,
            isExplicitVR: explicitVR,
            shouldInferTransferSyntaxFromMetaHeader: inferTransferSyntaxFromMetaHeader
        )
        return try parser.parseDataSet()
    }

    private static func looksExplicitVR(data: Data, offset: Int) -> Bool {
        guard offset + 6 <= data.count else { return true }
        let vrData = data.subdata(in: (offset + 4)..<(offset + 6))
        guard let vrString = String(data: vrData, encoding: .ascii) else { return false }
        return VR(rawValue: vrString) != nil
    }

    private func parseDataSet(stopAtItemDelimiter: Bool = false) throws -> [DICOMTreeElement] {
        var elements: [DICOMTreeElement] = []
        var transferSyntaxUID: String?
        var transferSyntaxApplied = !shouldInferTransferSyntaxFromMetaHeader

        while offset + 8 <= data.count {
            let tag = try peekTag()
            if tag.group == 0xFFFE {
                if tag.element == 0xE00D || tag.element == 0xE0DD {
                    if stopAtItemDelimiter {
                        offset += 8
                        break
                    }
                    offset += 8
                    continue
                }
                break
            }

            if !transferSyntaxApplied && tag.group != 0x0002 {
                applyTransferSyntax(transferSyntaxUID)
                transferSyntaxApplied = true
            }

            let element = try parseElement(forceExplicitVR: tag.group == 0x0002)
            if element.tag == DicomTag(group: 0x0002, element: 0x0010) {
                transferSyntaxUID = element.stringValue
            }
            elements.append(element)
        }
        return elements
    }

    private func parseElement(forceExplicitVR: Bool = false) throws -> DICOMTreeElement {
        let group = try readUInt16()
        let elementNumber = try readUInt16()
        let tag = DicomTag(group: group, element: elementNumber)
        let explicit = forceExplicitVR || isExplicitVR

        let vr: VR
        let length: UInt32
        if explicit {
            let vrString = try readASCII(length: 2)
            vr = VR(rawValue: vrString) ?? .unknown
            if Self.longVRs.contains(vrString) {
                _ = try readUInt16()
                length = try readUInt32()
            } else {
                length = UInt32(try readUInt16())
            }
        } else {
            vr = Self.knownSequenceTags.contains(tag) ? .SQ : .UN
            length = try readUInt32()
        }

        if vr == .SQ {
            let items = try parseSequenceItems(length: length)
            return DICOMTreeElement(tag: tag, vr: vr, data: Data(), items: items)
        }

        if length == UInt32.max {
            // Undefined length on a non-SQ: encapsulated pixel data, an implicit
            // VR sequence we don't know by tag, or UN (content is implicit VR LE).
            let isPixelData = tag == DicomTag(group: 0x7FE0, element: 0x0010)
            if !isPixelData {
                let saved = (offset, isExplicitVR, isLittleEndian)
                if explicit && vr == .UN { isExplicitVR = false; isLittleEndian = true }
                if let items = try? parseSequenceItems(length: length) {
                    isExplicitVR = saved.1
                    isLittleEndian = saved.2
                    return DICOMTreeElement(tag: tag, vr: .SQ, data: Data(), items: items)
                }
                (offset, isExplicitVR, isLittleEndian) = saved
            }
            let valueStart = offset
            skipUndefinedLengthValue()
            let safeRange = valueStart..<min(offset, data.count)
            return DICOMTreeElement(tag: tag, vr: vr, data: data.subdata(in: safeRange), items: [])
        }

        let valueLength = Int(length)
        let end = min(offset + valueLength, data.count)
        let value = data.subdata(in: offset..<end)
        offset = end
        return DICOMTreeElement(tag: tag, vr: vr, data: value, items: [])
    }

    private func parseSequenceItems(length: UInt32) throws -> [[DICOMTreeElement]] {
        let sequenceEnd = length == UInt32.max ? data.count : min(offset + Int(length), data.count)
        var items: [[DICOMTreeElement]] = []

        while offset + 8 <= sequenceEnd {
            let tag = try readTag()
            let itemLength = try readUInt32()

            if tag.group == 0xFFFE && tag.element == 0xE0DD {
                break
            }
            guard tag.group == 0xFFFE && tag.element == 0xE000 else {
                if length == UInt32.max { throw DicomError.invalidFile }
                break
            }

            if itemLength == UInt32.max {
                let itemParser = DICOMElementTreeParser(
                    data: data,
                    offset: offset,
                    isExplicitVR: isExplicitVR,
                    isLittleEndian: isLittleEndian
                )
                let parsed = try itemParser.parseDataSet(stopAtItemDelimiter: true)
                offset = itemParser.offset
                items.append(parsed)
            } else {
                let itemEnd = min(offset + Int(itemLength), data.count)
                let itemData = data.subdata(in: offset..<itemEnd)
                let itemParser = DICOMElementTreeParser(
                    data: itemData,
                    isExplicitVR: isExplicitVR,
                    isLittleEndian: isLittleEndian
                )
                items.append(try itemParser.parseDataSet())
                offset = itemEnd
            }
        }

        if length != UInt32.max {
            offset = sequenceEnd
        }
        return items
    }

    private func applyTransferSyntax(_ uid: String?) {
        let normalized = uid?.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines)) ?? "1.2.840.10008.1.2.1"
        switch normalized {
        case "1.2.840.10008.1.2":
            isExplicitVR = false
            isLittleEndian = true
        case "1.2.840.10008.1.2.2":
            isExplicitVR = true
            isLittleEndian = false
        default:
            isExplicitVR = true
            isLittleEndian = true
        }
    }

    /// Skip an undefined-length value. Walks items structurally (tracking
    /// nesting) so an inner Sequence Delimitation Item doesn't end the outer
    /// value; falls back to a byte scan for malformed content.
    private func skipUndefinedLengthValue() {
        let start = offset
        if let end = try? skipItems(depth: 0) {
            offset = end
            return
        }
        offset = start
        while offset + 8 <= data.count {
            if data[offset] == 0xFE,
               data[offset + 1] == 0xFF,
               data[offset + 2] == 0xDD,
               data[offset + 3] == 0xE0 {
                offset += 8
                return
            }
            offset += 1
        }
        offset = data.count
    }

    private func skipItems(depth: Int) throws -> Int {
        guard depth < 64 else { throw DicomError.invalidFile }
        while true {
            let tag = try readTag()
            let length = try readUInt32()
            guard tag.group == 0xFFFE else { throw DicomError.invalidFile }
            if tag.element == 0xE0DD { return offset }
            guard tag.element == 0xE000 else { throw DicomError.invalidFile }
            if length == UInt32.max {
                let itemParser = DICOMElementTreeParser(
                    data: data,
                    offset: offset,
                    isExplicitVR: isExplicitVR,
                    isLittleEndian: isLittleEndian
                )
                _ = try itemParser.parseDataSet(stopAtItemDelimiter: true)
                offset = itemParser.offset
            } else {
                guard offset + Int(length) <= data.count else { throw DicomError.endOfFile }
                offset += Int(length)
            }
        }
    }

    private func peekTag() throws -> DicomTag {
        let saved = offset
        let tag = try readTag()
        offset = saved
        return tag
    }

    private func readTag() throws -> DicomTag {
        DicomTag(group: try readUInt16(), element: try readUInt16())
    }

    private func readUInt16() throws -> UInt16 {
        guard offset + 2 <= data.count else { throw DicomError.endOfFile }
        var value: UInt16 = 0
        _ = withUnsafeMutableBytes(of: &value) {
            data.copyBytes(to: $0, from: offset..<(offset + 2))
        }
        offset += 2
        return isLittleEndian ? UInt16(littleEndian: value) : UInt16(bigEndian: value)
    }

    private func readUInt32() throws -> UInt32 {
        guard offset + 4 <= data.count else { throw DicomError.endOfFile }
        var value: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &value) {
            data.copyBytes(to: $0, from: offset..<(offset + 4))
        }
        offset += 4
        return isLittleEndian ? UInt32(littleEndian: value) : UInt32(bigEndian: value)
    }

    private func readASCII(length: Int) throws -> String {
        guard offset + length <= data.count else { throw DicomError.endOfFile }
        let value = String(data: data.subdata(in: offset..<(offset + length)), encoding: .ascii) ?? ""
        offset += length
        return value
    }
}
