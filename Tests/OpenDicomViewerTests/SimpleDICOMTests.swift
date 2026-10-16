// SimpleDICOMTests.swift
// OpenDicomViewer Tests
//
// Tests for the pure-Swift DICOM parser (SimpleDICOM.swift).
// Constructs minimal DICOM byte sequences to validate tag parsing,
// VR handling, transfer syntax detection, and element extraction.
// Licensed under the MIT License. See LICENSE for details.

import XCTest
import CoreGraphics
import simd
@testable import OpenDicomViewer

final class SimpleDICOMTests: XCTestCase {

    // MARK: - DicomTag

    func testDicomTagEquality() {
        let tag1 = DicomTag(group: 0x0010, element: 0x0010)
        let tag2 = DicomTag(group: 0x0010, element: 0x0010)
        let tag3 = DicomTag(group: 0x0010, element: 0x0020)
        XCTAssertEqual(tag1, tag2)
        XCTAssertNotEqual(tag1, tag3)
    }

    func testDicomTagDescription() {
        let tag = DicomTag(group: 0x0008, element: 0x0060)
        XCTAssertEqual(tag.description, "(0008,0060)")
    }

    func testDicomTagHashable() {
        let tag1 = DicomTag(group: 0x0008, element: 0x0060)
        let tag2 = DicomTag(group: 0x0008, element: 0x0060)
        var set = Set<DicomTag>()
        set.insert(tag1)
        set.insert(tag2)
        XCTAssertEqual(set.count, 1)
    }

    // MARK: - VR Enum

    func testVRFromRawValue() {
        XCTAssertEqual(VR(rawValue: "CS"), .CS)
        XCTAssertEqual(VR(rawValue: "UI"), .UI)
        XCTAssertEqual(VR(rawValue: "US"), .US)
        XCTAssertEqual(VR(rawValue: "OB"), .OB)
        XCTAssertEqual(VR(rawValue: "SQ"), .SQ)
        XCTAssertNil(VR(rawValue: "XX"))  // invalid VR returns nil
    }

    // MARK: - DicomElement

    func testDicomElementStringValue() {
        let tag = DicomTag(group: 0x0010, element: 0x0010)
        let nameData = "DOE^JOHN".data(using: .utf8)!
        let element = DicomElement(tag: tag, vr: .PN, length: nameData.count, data: nameData)
        XCTAssertEqual(element.stringValue, "DOE^JOHN")
    }

    func testDicomElementIntValueUInt16() {
        let tag = DicomTag(group: 0x0028, element: 0x0010) // Rows
        var value: UInt16 = 512
        let data = Data(bytes: &value, count: 2)
        let element = DicomElement(tag: tag, vr: .US, length: 2, data: data)
        XCTAssertEqual(element.intValue, 512)
    }

    func testDicomElementIntValueUInt32() {
        let tag = DicomTag(group: 0x0028, element: 0x0010)
        var value: UInt32 = 65536
        let data = Data(bytes: &value, count: 4)
        let element = DicomElement(tag: tag, vr: .UL, length: 4, data: data)
        XCTAssertEqual(element.intValue, 65536)
    }

    func testDicomElementIntValueInvalidSize() {
        let tag = DicomTag(group: 0x0028, element: 0x0010)
        let data = Data([0x01, 0x02, 0x03]) // 3 bytes - not valid for int
        let element = DicomElement(tag: tag, vr: .UN, length: 3, data: data)
        XCTAssertNil(element.intValue)
    }

    func testDicomElementId() {
        let tag = DicomTag(group: 0x0008, element: 0x0060)
        let element = DicomElement(tag: tag, vr: .CS, length: 0, data: Data())
        XCTAssertEqual(element.id, "(0008,0060)")
    }

    // MARK: - Data.robustString()

    func testRobustStringUTF8() {
        let data = "Hello World".data(using: .utf8)!
        XCTAssertEqual(data.robustString(), "Hello World")
    }

    func testRobustStringTrimsWhitespace() {
        let data = "  CT  \0".data(using: .utf8)!
        XCTAssertEqual(data.robustString(), "CT")
    }

    func testRobustStringLatin1Fallback() {
        // Create bytes that are valid ISO-8859-1 but might not be valid UTF-8
        // 0xE9 is e-acute in Latin-1
        let data = Data([0x63, 0x61, 0x66, 0xE9]) // "cafe" with accented e
        let result = data.robustString()
        XCTAssertNotNil(result)
    }

    // MARK: - SimpleDicomParser — minimal DICOM file parsing

    /// Build a minimal valid DICOM file with explicit VR little-endian.
    /// Structure: 128-byte preamble + "DICM" + File Meta Information + data elements.
    private func buildMinimalDICOM(elements: [(group: UInt16, element: UInt16, vr: String, value: Data)]) -> Data {
        var data = Data(count: 128)  // 128-byte preamble (all zeros)
        data.append("DICM".data(using: .ascii)!)  // Magic number

        // File Meta Information Group Length (0002,0000) — we'll compute later
        // Transfer Syntax UID (0002,0010) — Explicit VR Little Endian
        let transferSyntax = "1.2.840.10008.1.2.1"
        var metaElements = Data()

        // (0002,0010) Transfer Syntax UID
        metaElements.append(contentsOf: uint16LE(0x0002))
        metaElements.append(contentsOf: uint16LE(0x0010))
        metaElements.append("UI".data(using: .ascii)!)
        let tsData = transferSyntax.data(using: .ascii)!
        // Pad to even length
        var tsPadded = tsData
        if tsPadded.count % 2 != 0 { tsPadded.append(0x00) }
        metaElements.append(contentsOf: uint16LE(UInt16(tsPadded.count)))
        metaElements.append(tsPadded)

        // File Meta Information Group Length (0002,0000)
        data.append(contentsOf: uint16LE(0x0002))
        data.append(contentsOf: uint16LE(0x0000))
        data.append("UL".data(using: .ascii)!)
        data.append(contentsOf: uint16LE(4))
        data.append(contentsOf: uint32LE(UInt32(metaElements.count)))

        // Append the meta elements
        data.append(metaElements)

        // Append user-provided data elements
        for elem in elements {
            data.append(contentsOf: uint16LE(elem.group))
            data.append(contentsOf: uint16LE(elem.element))
            data.append(elem.vr.data(using: .ascii)!)

            // Check if this VR uses 4-byte length
            let longVRs = ["OB", "OD", "OF", "OL", "OV", "OW", "SQ", "SV", "UC", "UN", "UR", "UT", "UV"]
            if longVRs.contains(elem.vr) {
                data.append(contentsOf: uint16LE(0)) // reserved
                data.append(contentsOf: uint32LE(UInt32(elem.value.count)))
            } else {
                data.append(contentsOf: uint16LE(UInt16(elem.value.count)))
            }
            data.append(elem.value)
        }

        return data
    }

    private func uint16LE(_ val: UInt16) -> [UInt8] {
        return [UInt8(val & 0xFF), UInt8(val >> 8)]
    }

    private func uint32LE(_ val: UInt32) -> [UInt8] {
        return [
            UInt8(val & 0xFF),
            UInt8((val >> 8) & 0xFF),
            UInt8((val >> 16) & 0xFF),
            UInt8((val >> 24) & 0xFF)
        ]
    }

    private func dicomText(_ value: String, padByte: UInt8 = 0x20) -> Data {
        var data = Data(value.utf8)
        if data.count % 2 != 0 {
            data.append(padByte)
        }
        return data
    }

    private func dicomElement(_ group: UInt16, _ element: UInt16, _ vr: String, _ value: Data) -> Data {
        var data = Data()
        data.append(contentsOf: uint16LE(group))
        data.append(contentsOf: uint16LE(element))
        data.append(vr.data(using: .ascii)!)
        let longVRs = ["OB", "OD", "OF", "OL", "OV", "OW", "SQ", "SV", "UC", "UN", "UR", "UT", "UV"]
        if longVRs.contains(vr) {
            data.append(contentsOf: uint16LE(0))
            data.append(contentsOf: uint32LE(UInt32(value.count)))
        } else {
            data.append(contentsOf: uint16LE(UInt16(value.count)))
        }
        data.append(value)
        return data
    }

    private func sequenceItem(_ dataSet: Data) -> Data {
        var data = Data()
        data.append(contentsOf: uint16LE(0xFFFE))
        data.append(contentsOf: uint16LE(0xE000))
        data.append(contentsOf: uint32LE(UInt32(dataSet.count)))
        data.append(dataSet)
        return data
    }

    private func float32Data(_ values: [Float32]) -> Data {
        var data = Data()
        for value in values {
            var bits = value.bitPattern.littleEndian
            data.append(Data(bytes: &bits, count: 4))
        }
        return data
    }

    private func uint16Data(_ value: UInt16) -> Data {
        var littleEndian = value.littleEndian
        return Data(bytes: &littleEndian, count: 2)
    }

    private func fixtureURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(relativePath)
    }

    func testParserRejectsTooSmallData() {
        let data = Data(count: 100)  // Less than 132 bytes
        let parser = SimpleDicomParser(data: data)
        XCTAssertThrowsError(try parser.parse()) { error in
            XCTAssertTrue(error is DicomError)
        }
    }

    func testParserRejectsNonDICMFile() {
        var data = Data(count: 128)
        data.append("NOPE".data(using: .ascii)!)  // Wrong magic
        data.append(Data(count: 100)) // Some padding
        let parser = SimpleDicomParser(data: data)
        XCTAssertThrowsError(try parser.parse()) { error in
            guard let dicomError = error as? DicomError else {
                XCTFail("Expected DicomError, got \(error)")
                return
            }
            XCTAssertEqual(String(describing: dicomError), String(describing: DicomError.notDicom))
        }
    }

    func testParserParsesMinimalExplicitVRLE() throws {
        // Build a minimal DICOM with a Patient Name and Modality
        let patientName = "DOE^JOHN".data(using: .ascii)!
        var patientNamePadded = patientName
        if patientNamePadded.count % 2 != 0 { patientNamePadded.append(0x20) }

        let modality = "CT".data(using: .ascii)!

        let dicomData = buildMinimalDICOM(elements: [
            (group: 0x0008, element: 0x0060, vr: "CS", value: modality),       // Modality
            (group: 0x0010, element: 0x0010, vr: "PN", value: patientNamePadded), // Patient Name
        ])

        let parser = SimpleDicomParser(data: dicomData)
        let (elements, _, transferSyntax) = try parser.parse(stopAtPixelData: true)

        // Should have parsed the meta elements + our 2 elements
        XCTAssertGreaterThanOrEqual(elements.count, 3) // group length + transfer syntax + at least 1

        // Check transfer syntax was detected
        XCTAssertEqual(transferSyntax, "1.2.840.10008.1.2.1")

        // Find Modality element
        let modalityElem = elements.first { $0.tag == DicomTag(group: 0x0008, element: 0x0060) }
        XCTAssertNotNil(modalityElem)
        XCTAssertEqual(modalityElem?.stringValue, "CT")
        XCTAssertEqual(modalityElem?.vr, .CS)

        // Find Patient Name element
        let nameElem = elements.first { $0.tag == DicomTag(group: 0x0010, element: 0x0010) }
        XCTAssertNotNil(nameElem)
        XCTAssertEqual(nameElem?.stringValue, "DOE^JOHN")
        XCTAssertEqual(nameElem?.vr, .PN)
    }

    func testParserParsesUInt16Element() throws {
        // Rows (0028,0010) with US VR and value 256
        var rowsValue: UInt16 = 256
        let rowsData = Data(bytes: &rowsValue, count: 2)

        let dicomData = buildMinimalDICOM(elements: [
            (group: 0x0028, element: 0x0010, vr: "US", value: rowsData),
        ])

        let parser = SimpleDicomParser(data: dicomData)
        let (elements, _, _) = try parser.parse(stopAtPixelData: true)

        let rowsElem = elements.first { $0.tag == DicomTag(group: 0x0028, element: 0x0010) }
        XCTAssertNotNil(rowsElem)
        XCTAssertEqual(rowsElem?.intValue, 256)
        XCTAssertEqual(rowsElem?.vr, .US)
    }

    func testParserParsesMultipleElements() throws {
        var rows: UInt16 = 512
        let rowsData = Data(bytes: &rows, count: 2)
        var cols: UInt16 = 512
        let colsData = Data(bytes: &cols, count: 2)
        var bits: UInt16 = 16
        let bitsData = Data(bytes: &bits, count: 2)

        let dicomData = buildMinimalDICOM(elements: [
            (group: 0x0028, element: 0x0010, vr: "US", value: rowsData),   // Rows
            (group: 0x0028, element: 0x0011, vr: "US", value: colsData),   // Columns
            (group: 0x0028, element: 0x0100, vr: "US", value: bitsData),   // Bits Allocated
        ])

        let parser = SimpleDicomParser(data: dicomData)
        let (elements, _, _) = try parser.parse(stopAtPixelData: true)

        let rowsElem = elements.first { $0.tag == DicomTag(group: 0x0028, element: 0x0010) }
        let colsElem = elements.first { $0.tag == DicomTag(group: 0x0028, element: 0x0011) }
        let bitsElem = elements.first { $0.tag == DicomTag(group: 0x0028, element: 0x0100) }

        XCTAssertEqual(rowsElem?.intValue, 512)
        XCTAssertEqual(colsElem?.intValue, 512)
        XCTAssertEqual(bitsElem?.intValue, 16)
    }

    func testParserStopsAtPixelData() throws {
        // Build DICOM with a small fake pixel data element
        var rows: UInt16 = 4
        let rowsData = Data(bytes: &rows, count: 2)

        let pixelBytes = Data(repeating: 0x42, count: 32) // 4x4 x 2 bytes

        let dicomData = buildMinimalDICOM(elements: [
            (group: 0x0028, element: 0x0010, vr: "US", value: rowsData),
            (group: 0x7FE0, element: 0x0010, vr: "OW", value: pixelBytes), // Pixel Data
        ])

        let parser = SimpleDicomParser(data: dicomData)
        let (elements, pixelData, _) = try parser.parse(stopAtPixelData: true)

        // When stopAtPixelData is true, pixelData should be nil (parser returns early)
        XCTAssertNil(pixelData)

        // The pixel data element should still be in the elements list
        let pxElem = elements.first { $0.tag == DicomTag(group: 0x7FE0, element: 0x0010) }
        XCTAssertNotNil(pxElem)
    }

    func testParserExtractsPixelDataWhenNotStopping() throws {
        var rows: UInt16 = 4
        let rowsData = Data(bytes: &rows, count: 2)

        let pixelBytes = Data(repeating: 0x42, count: 32)

        let dicomData = buildMinimalDICOM(elements: [
            (group: 0x0028, element: 0x0010, vr: "US", value: rowsData),
            (group: 0x7FE0, element: 0x0010, vr: "OW", value: pixelBytes),
        ])

        let parser = SimpleDicomParser(data: dicomData)
        let (_, pixelData, _) = try parser.parse(stopAtPixelData: false)

        // When not stopping, pixel data should be extracted
        XCTAssertNotNil(pixelData)
        XCTAssertEqual(pixelData?.count, 32)
    }

    func testParserDecimalStringElement() throws {
        // RescaleSlope (0028,1053) = "1.5" as DS VR
        let dsValue = "1.5 ".data(using: .ascii)! // padded to even length

        let dicomData = buildMinimalDICOM(elements: [
            (group: 0x0028, element: 0x1053, vr: "DS", value: dsValue),
        ])

        let parser = SimpleDicomParser(data: dicomData)
        let (elements, _, _) = try parser.parse(stopAtPixelData: true)

        let slopeElem = elements.first { $0.tag == DicomTag(group: 0x0028, element: 0x1053) }
        XCTAssertNotNil(slopeElem)
        if let str = slopeElem?.stringValue, let val = Double(str.trimmingCharacters(in: .whitespacesAndNewlines)) {
            XCTAssertEqual(val, 1.5, accuracy: 0.001)
        } else {
            XCTFail("Could not parse DS value")
        }
    }

    // MARK: - DICOM-derived object classification

    func testDerivedObjectClassificationBySOPClassUID() {
        XCTAssertEqual(
            DICOMDerivedObjectParser.classify(
                sopClassUID: "1.2.840.10008.5.1.4.1.1.11.1",
                modality: ""
            ),
            .grayscaleSoftcopyPresentationState
        )
        XCTAssertEqual(
            DICOMDerivedObjectParser.classify(
                sopClassUID: "1.2.840.10008.5.1.4.1.1.481.3",
                modality: ""
            ),
            .rtStructureSet
        )
        XCTAssertEqual(
            DICOMDerivedObjectParser.classify(
                sopClassUID: "1.2.840.10008.5.1.4.1.1.66.4",
                modality: ""
            ),
            .dicomSegmentation
        )
        XCTAssertEqual(
            DICOMDerivedObjectParser.classify(
                sopClassUID: "1.2.840.10008.5.1.4.1.1.88.33",
                modality: ""
            ),
            .structuredReport
        )
        XCTAssertNil(
            DICOMDerivedObjectParser.classify(
                sopClassUID: "1.2.840.10008.5.1.4.1.1.2",
                modality: "CT"
            )
        )
    }

    func testDerivedObjectClassificationByModalityFallback() {
        XCTAssertEqual(DICOMDerivedObjectParser.classify(sopClassUID: "", modality: "RTSTRUCT"), .rtStructureSet)
        XCTAssertEqual(DICOMDerivedObjectParser.classify(sopClassUID: "", modality: "SEG"), .dicomSegmentation)
        XCTAssertEqual(DICOMDerivedObjectParser.classify(sopClassUID: "", modality: "SR"), .structuredReport)
        XCTAssertEqual(DICOMDerivedObjectParser.classify(sopClassUID: "", modality: "KO"), .keyObjectSelection)
        XCTAssertEqual(DICOMDerivedObjectParser.classify(sopClassUID: "", modality: "PR"), .grayscaleSoftcopyPresentationState)
    }

    func testDerivedObjectParserReadsMinimalRTStructureSet() throws {
        let sopClassUID = "1.2.840.10008.5.1.4.1.1.481.3"
        let dicomData = buildMinimalDICOM(elements: [
            (group: 0x0008, element: 0x0016, vr: "UI", value: dicomText(sopClassUID, padByte: 0x00)),
            (group: 0x0008, element: 0x0060, vr: "CS", value: dicomText("RTSTRUCT")),
            (group: 0x0008, element: 0x103E, vr: "LO", value: dicomText("Contours")),
            (group: 0x0020, element: 0x000D, vr: "UI", value: dicomText("1.2.3.4.5", padByte: 0x00)),
            (group: 0x0020, element: 0x000E, vr: "UI", value: dicomText("1.2.3.4.5.6", padByte: 0x00)),
            (group: 0x0020, element: 0x0013, vr: "IS", value: dicomText("7")),
            (group: 0x3006, element: 0x0002, vr: "SH", value: dicomText("LIVER")),
        ])

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenDicomViewer-\(UUID().uuidString)")
            .appendingPathExtension("dcm")
        try dicomData.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let summary = try XCTUnwrap(DICOMDerivedObjectParser.parse(url: url))
        XCTAssertEqual(summary.kind, .rtStructureSet)
        XCTAssertEqual(summary.sopClassUID, sopClassUID)
        XCTAssertEqual(summary.modality, "RTSTRUCT")
        XCTAssertEqual(summary.displayTitle, "LIVER")
        XCTAssertEqual(summary.seriesDescription, "Contours")
        XCTAssertEqual(summary.studyInstanceUID, "1.2.3.4.5")
        XCTAssertEqual(summary.seriesUID, "1.2.3.4.5.6")
        XCTAssertEqual(summary.instanceNumber, 7)
        XCTAssertTrue(summary.tags.contains { $0.tag == DicomTag(group: 0x3006, element: 0x0002) })
    }

    func testGSPSParserReadsGraphicAnnotation() throws {
        let referencedSOP = "1.2.826.0.1.3680043.10.99.100"
        var referencedImageItem = Data()
        referencedImageItem.append(dicomElement(0x0008, 0x1155, "UI", dicomText(referencedSOP, padByte: 0x00)))

        var graphicObjectItem = Data()
        graphicObjectItem.append(dicomElement(0x0070, 0x0020, "US", Data([0x02, 0x00])))
        graphicObjectItem.append(dicomElement(0x0070, 0x0021, "US", Data([0x02, 0x00])))
        graphicObjectItem.append(dicomElement(0x0070, 0x0022, "FL", float32Data([0, 0, 32, 32])))
        graphicObjectItem.append(dicomElement(0x0070, 0x0023, "CS", dicomText("POLYLINE")))

        var annotationItem = Data()
        annotationItem.append(dicomElement(0x0008, 0x1140, "SQ", sequenceItem(referencedImageItem)))
        annotationItem.append(dicomElement(0x0070, 0x0002, "CS", dicomText("MEASURE")))
        annotationItem.append(dicomElement(0x0070, 0x0005, "CS", dicomText("PIXEL")))
        annotationItem.append(dicomElement(0x0070, 0x0009, "SQ", sequenceItem(graphicObjectItem)))

        let dicomData = buildMinimalDICOM(elements: [
            (group: 0x0008, element: 0x0016, vr: "UI", value: dicomText("1.2.840.10008.5.1.4.1.1.11.1", padByte: 0x00)),
            (group: 0x0008, element: 0x0018, vr: "UI", value: dicomText("1.2.826.0.1.3680043.10.99.200", padByte: 0x00)),
            (group: 0x0008, element: 0x0060, vr: "CS", value: dicomText("PR")),
            (group: 0x0070, element: 0x0080, vr: "CS", value: dicomText("TEST_GSPS")),
            (group: 0x0070, element: 0x0001, vr: "SQ", value: sequenceItem(annotationItem)),
        ])

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenDicomViewer-gsps-\(UUID().uuidString)")
            .appendingPathExtension("dcm")
        try dicomData.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let object = try XCTUnwrap(DICOMAnnotationObjectParser.parse(url: url, kind: .grayscaleSoftcopyPresentationState))
        XCTAssertEqual(object.graphics.count, 1)
        let context = DicomImageContext(
            url: URL(fileURLWithPath: "/tmp/source.dcm"),
            sopInstanceUID: referencedSOP,
            seriesUID: "series",
            seriesDescription: "series",
            instanceNumber: 1,
            seriesNumber: 1,
            zLocation: nil,
            imagePosition: nil,
            imageOrientation: nil,
            pixelSpacing: nil,
            sliceThickness: nil,
            spacingBetweenSlices: nil,
            frameOfReferenceUID: nil,
            studyInstanceUID: nil,
            numberOfFrames: 1
        )
        let overlays = object.resolvedOverlays(for: context)
        XCTAssertEqual(overlays.count, 1)
        if case .polyline(let points, let closed) = overlays[0].geometry {
            XCTAssertFalse(closed)
            XCTAssertEqual(points, [CGPoint(x: 0, y: 0), CGPoint(x: 32, y: 32)])
        } else {
            XCTFail("Expected polyline overlay")
        }
    }

    func testRTStructureSetParserProjectsReferencedContourToPixelSpace() throws {
        let referencedSOP = "1.2.826.0.1.3680043.10.99.300"

        var roiItem = Data()
        roiItem.append(dicomElement(0x3006, 0x0022, "IS", dicomText("1")))
        roiItem.append(dicomElement(0x3006, 0x0026, "LO", dicomText("ROI_A")))

        var contourImageItem = Data()
        contourImageItem.append(dicomElement(0x0008, 0x1155, "UI", dicomText(referencedSOP, padByte: 0x00)))

        var contourItem = Data()
        contourItem.append(dicomElement(0x3006, 0x0016, "SQ", sequenceItem(contourImageItem)))
        contourItem.append(dicomElement(0x3006, 0x0042, "CS", dicomText("CLOSED_PLANAR")))
        contourItem.append(dicomElement(0x3006, 0x0046, "IS", dicomText("4")))
        contourItem.append(dicomElement(0x3006, 0x0050, "DS", dicomText("0\\0\\0\\10\\0\\0\\10\\10\\0\\0\\10\\0")))

        var roiContourItem = Data()
        roiContourItem.append(dicomElement(0x3006, 0x0084, "IS", dicomText("1")))
        roiContourItem.append(dicomElement(0x3006, 0x0040, "SQ", sequenceItem(contourItem)))

        let dicomData = buildMinimalDICOM(elements: [
            (group: 0x0008, element: 0x0016, vr: "UI", value: dicomText("1.2.840.10008.5.1.4.1.1.481.3", padByte: 0x00)),
            (group: 0x0008, element: 0x0060, vr: "CS", value: dicomText("RTSTRUCT")),
            (group: 0x3006, element: 0x0002, vr: "SH", value: dicomText("STRUCT")),
            (group: 0x0020, element: 0x0052, vr: "UI", value: dicomText("1.2.3.frame", padByte: 0x00)),
            (group: 0x3006, element: 0x0020, vr: "SQ", value: sequenceItem(roiItem)),
            (group: 0x3006, element: 0x0039, vr: "SQ", value: sequenceItem(roiContourItem)),
        ])

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenDicomViewer-rtstruct-\(UUID().uuidString)")
            .appendingPathExtension("dcm")
        try dicomData.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let object = try XCTUnwrap(DICOMAnnotationObjectParser.parse(url: url, kind: .rtStructureSet))
        XCTAssertEqual(object.contours.count, 1)

        let context = DicomImageContext(
            url: URL(fileURLWithPath: "/tmp/source.dcm"),
            sopInstanceUID: referencedSOP,
            seriesUID: "series",
            seriesDescription: "series",
            instanceNumber: 1,
            seriesNumber: 1,
            zLocation: 0,
            imagePosition: SIMD3<Double>(0, 0, 0),
            imageOrientation: [1, 0, 0, 0, 1, 0],
            pixelSpacing: SIMD2<Double>(1, 1),
            sliceThickness: 1,
            spacingBetweenSlices: 1,
            frameOfReferenceUID: "1.2.3.frame",
            studyInstanceUID: nil,
            numberOfFrames: 1
        )

        let overlays = object.resolvedOverlays(for: context)
        XCTAssertEqual(overlays.count, 1)
        XCTAssertEqual(overlays[0].label, "ROI_A")
        if case .polyline(let points, let closed) = overlays[0].geometry {
            XCTAssertTrue(closed)
            XCTAssertEqual(points, [
                CGPoint(x: 0, y: 0),
                CGPoint(x: 10, y: 0),
                CGPoint(x: 10, y: 10),
                CGPoint(x: 0, y: 10),
            ])
        } else {
            XCTFail("Expected RTSTRUCT polyline overlay")
        }
    }

    func testTreeElementIntValueDecodesBinaryVRsAsBinary() {
        let tag = DicomTag(group: 0x0062, element: 0x0004)
        func element(_ vr: VR, _ bytes: [UInt8]) -> DICOMTreeElement {
            DICOMTreeElement(tag: tag, vr: vr, data: Data(bytes), items: [])
        }
        // US 48–57 are the bytes "0"–"9" followed by a NUL.
        for number in 48...57 {
            XCTAssertEqual(element(.US, [UInt8(number), 0]).intValue, number)
            XCTAssertEqual(element(.UN, [UInt8(number), 0]).intValue, number)
        }
        XCTAssertEqual(element(.US, [0x31, 0x31]).intValue, 0x3131)
        XCTAssertEqual(element(.SS, [0xFF, 0xFF]).intValue, -1)
        XCTAssertEqual(element(.SL, [0xFE, 0xFF, 0xFF, 0xFF]).intValue, -2)
        XCTAssertEqual(element(.UL, [0x00, 0x00, 0x01, 0x00]).intValue, 65536)
        // Text integers still read as text, explicit or implicit.
        XCTAssertEqual(element(.IS, Array("12".utf8)).intValue, 12)
        XCTAssertEqual(element(.UN, Array("7 ".utf8)).intValue, 7)
    }

    func testDICOMSegmentationParserReadsBinaryMaskFrame() throws {
        let referencedSOP = "1.2.826.0.1.3680043.10.99.400"

        var segmentItem = Data()
        segmentItem.append(dicomElement(0x0062, 0x0004, "US", uint16Data(1)))
        segmentItem.append(dicomElement(0x0062, 0x0005, "LO", dicomText("TUMOR")))

        var sourceImageItem = Data()
        sourceImageItem.append(dicomElement(0x0008, 0x1155, "UI", dicomText(referencedSOP, padByte: 0x00)))

        var derivationItem = Data()
        derivationItem.append(dicomElement(0x0008, 0x2112, "SQ", sequenceItem(sourceImageItem)))

        var segmentIdentificationItem = Data()
        segmentIdentificationItem.append(dicomElement(0x0062, 0x000B, "US", uint16Data(1)))

        var frameItem = Data()
        frameItem.append(dicomElement(0x0008, 0x9124, "SQ", sequenceItem(derivationItem)))
        frameItem.append(dicomElement(0x0062, 0x000A, "SQ", sequenceItem(segmentIdentificationItem)))

        let dicomData = buildMinimalDICOM(elements: [
            (group: 0x0008, element: 0x0016, vr: "UI", value: dicomText("1.2.840.10008.5.1.4.1.1.66.4", padByte: 0x00)),
            (group: 0x0008, element: 0x0060, vr: "CS", value: dicomText("SEG")),
            (group: 0x0008, element: 0x103E, vr: "LO", value: dicomText("Binary SEG")),
            (group: 0x0028, element: 0x0002, vr: "US", value: uint16Data(1)),
            (group: 0x0028, element: 0x0008, vr: "IS", value: dicomText("1")),
            (group: 0x0028, element: 0x0010, vr: "US", value: uint16Data(2)),
            (group: 0x0028, element: 0x0011, vr: "US", value: uint16Data(2)),
            (group: 0x0028, element: 0x0100, vr: "US", value: uint16Data(1)),
            (group: 0x0028, element: 0x0101, vr: "US", value: uint16Data(1)),
            (group: 0x0062, element: 0x0001, vr: "CS", value: dicomText("BINARY")),
            (group: 0x0062, element: 0x0002, vr: "SQ", value: sequenceItem(segmentItem)),
            (group: 0x5200, element: 0x9230, vr: "SQ", value: sequenceItem(frameItem)),
            (group: 0x7FE0, element: 0x0010, vr: "OB", value: Data([0b0000_1001])),
        ])

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenDicomViewer-seg-\(UUID().uuidString)")
            .appendingPathExtension("dcm")
        try dicomData.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let object = try XCTUnwrap(DICOMAnnotationObjectParser.parse(url: url, kind: .dicomSegmentation))
        XCTAssertEqual(object.segmentFrames.count, 1)

        let context = DicomImageContext(
            url: URL(fileURLWithPath: "/tmp/source.dcm"),
            sopInstanceUID: referencedSOP,
            seriesUID: "series",
            seriesDescription: "series",
            instanceNumber: 1,
            seriesNumber: 1,
            zLocation: nil,
            imagePosition: nil,
            imageOrientation: nil,
            pixelSpacing: nil,
            sliceThickness: nil,
            spacingBetweenSlices: nil,
            frameOfReferenceUID: nil,
            studyInstanceUID: nil,
            numberOfFrames: 1
        )

        let overlays = object.resolvedOverlays(for: context)
        XCTAssertEqual(overlays.count, 1)
        XCTAssertEqual(overlays[0].label, "TUMOR")
        if case .mask(let width, let height, let bitmap) = overlays[0].geometry {
            XCTAssertEqual(width, 2)
            XCTAssertEqual(height, 2)
            XCTAssertEqual(Array(bitmap), [1, 0, 0, 1])
        } else {
            XCTFail("Expected SEG mask overlay")
        }
    }

    func testPublicOFFISGSPSFixtureParsesGraphicOverlay() throws {
        let url = fixtureURL("Tests/Fixtures/PublicDICOMAnnotations/OFFIS_GSPS/gsps_256x256_16x16_1.0x1.0.dcm")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("OFFIS GSPS fixture not present")
        }
        let object = try XCTUnwrap(DICOMAnnotationObjectParser.parse(url: url, kind: .grayscaleSoftcopyPresentationState))
        XCTAssertFalse(object.graphics.isEmpty)
    }

    func testPublicPydicomRTStructFixtureParsesContoursWithoutPreamble() throws {
        let url = fixtureURL("Tests/Fixtures/PublicDICOMAnnotations/pydicom_RTSTRUCT/rtstruct.dcm")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("pydicom RTSTRUCT fixture not present")
        }
        let object = try XCTUnwrap(DICOMAnnotationObjectParser.parse(url: url, kind: .rtStructureSet))
        XCTAssertFalse(object.contours.isEmpty)
    }

    func testPublicHighdicomSEGFixtureParsesBinaryMasks() throws {
        let url = fixtureURL("Tests/Fixtures/PublicDICOMAnnotations/highdicom_SEG/seg_image_ct_binary.dcm")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("highdicom SEG fixture not present")
        }

        let object = try XCTUnwrap(DICOMAnnotationObjectParser.parse(url: url, kind: .dicomSegmentation))
        XCTAssertEqual(object.segmentFrames.count, 3)

        let context = DicomImageContext(
            url: URL(fileURLWithPath: "/tmp/source.dcm"),
            sopInstanceUID: "1.3.6.1.4.1.5962.1.1.0.0.0.1196530851.28319.0.94",
            seriesUID: "series",
            seriesDescription: "series",
            instanceNumber: 1,
            seriesNumber: 1,
            zLocation: nil,
            imagePosition: nil,
            imageOrientation: nil,
            pixelSpacing: nil,
            sliceThickness: nil,
            spacingBetweenSlices: nil,
            frameOfReferenceUID: nil,
            studyInstanceUID: nil,
            numberOfFrames: 1
        )

        let overlays = object.resolvedOverlays(for: context)
        XCTAssertEqual(overlays.count, 1)
        if case .mask(let width, let height, let bitmap) = overlays[0].geometry {
            XCTAssertEqual(width, 16)
            XCTAssertEqual(height, 16)
            XCTAssertEqual(bitmap.reduce(0) { $0 + Int($1) }, 127)
        } else {
            XCTFail("Expected SEG mask overlay")
        }
    }

    // MARK: - DicomError

    func testDicomErrorTypes() {
        // Just verify the error cases exist and can be instantiated
        let err1 = DicomError.invalidFile
        let err2 = DicomError.notDicom
        let err3 = DicomError.unsupportedTransferSyntax
        let err4 = DicomError.endOfFile

        XCTAssertNotNil(err1)
        XCTAssertNotNil(err2)
        XCTAssertNotNil(err3)
        XCTAssertNotNil(err4)
    }
}
