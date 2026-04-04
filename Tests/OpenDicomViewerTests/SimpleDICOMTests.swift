// SimpleDICOMTests.swift
// OpenDicomViewer Tests
//
// Tests for the pure-Swift DICOM parser (SimpleDICOM.swift).
// Constructs minimal DICOM byte sequences to validate tag parsing,
// VR handling, transfer syntax detection, and element extraction.
// Licensed under the MIT License. See LICENSE for details.

import XCTest
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
