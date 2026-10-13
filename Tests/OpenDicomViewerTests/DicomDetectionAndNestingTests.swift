// DicomDetectionAndNestingTests.swift
// OpenDicomViewer Tests
//
// Content-based DICOM detection for folder scans (preamble-less and
// arbitrarily named files) and nested undefined-length sequence parsing.
// Licensed under the MIT License. See LICENSE for details.

import XCTest
@testable import OpenDicomViewer

final class DicomDetectionAndNestingTests: XCTestCase {
    typealias S = SyntheticDICOM

    // MARK: - Detection (folder scan)

    func testSnifferAcceptsPart10WithUIDName() throws {
        let file = S.image(.init(), pixelBytes: S.le16(Array(repeating: 0, count: 16)))
        let url = try S.writeTemp(file, name: "1.2.840.113619.2.55.3.604688.1234")
        XCTAssertTrue(DicomFileSniffer.isCandidate(url))
    }

    func testSnifferAcceptsPreamblelessImplicitIMA() throws {
        var spec = S.ImageSpec()
        spec.includePreamble = false
        spec.transferSyntax = S.implicitLE
        let file = S.image(spec, pixelBytes: S.le16(Array(repeating: 0, count: 16)))
        let url = try S.writeTemp(file, name: "IM000001.IMA")
        XCTAssertTrue(DicomFileSniffer.isCandidate(url))
    }

    func testSnifferAcceptsDotDicomExtension() throws {
        let file = S.image(.init(), pixelBytes: S.le16(Array(repeating: 0, count: 16)))
        let url = try S.writeTemp(file, name: "scan.dicom")
        XCTAssertTrue(DicomFileSniffer.isCandidate(url))
    }

    func testSnifferRejectsNonDicom() throws {
        let png = try S.writeTemp(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 0, count: 200)), name: "image")
        XCTAssertFalse(DicomFileSniffer.isCandidate(png))
        let txt = try S.writeTemp(Data("hello world, this is not a DICOM file at all".utf8), name: "README")
        XCTAssertFalse(DicomFileSniffer.isCandidate(txt))
        // Extension-based skip doesn't even need DICOM-invalid content
        let file = S.image(.init(), pixelBytes: S.le16(Array(repeating: 0, count: 16)))
        let jpg = try S.writeTemp(file, name: "photo.jpg")
        XCTAssertFalse(DicomFileSniffer.isCandidate(jpg))
        let hidden = try S.writeTemp(file, name: ".DS_Store")
        XCTAssertFalse(DicomFileSniffer.isCandidate(hidden))
    }

    func testParserReadsPreamblelessImplicitDataset() throws {
        var spec = S.ImageSpec()
        spec.includePreamble = false
        spec.transferSyntax = S.implicitLE
        spec.seriesUID = "9.8.7.6"
        let file = S.image(spec, pixelBytes: S.le16(Array(0..<16)))
        let parser = SimpleDicomParser(data: file)
        let (elements, pixels, ts) = try parser.parse()
        XCTAssertNil(ts)
        XCTAssertEqual(elements.first(where: { $0.tag == DicomTag(group: 0x0020, element: 0x000E) })?.stringValue, "9.8.7.6")
        XCTAssertEqual(elements.first(where: { $0.tag == DicomTag(group: 0x0028, element: 0x0010) })?.intValue, 4)
        XCTAssertEqual(pixels?.count, 32)
    }

    func testParserReadsPreamblelessExplicitDataset() throws {
        var spec = S.ImageSpec()
        spec.includePreamble = false
        spec.transferSyntax = S.explicitLE
        let file = S.image(spec, pixelBytes: S.le16(Array(0..<16)))
        let (elements, _, _) = try SimpleDicomParser(data: file).parse(stopAtPixelData: true)
        XCTAssertEqual(elements.first(where: { $0.tag == DicomTag(group: 0x0010, element: 0x0010) })?.stringValue, "TEST^SYNTHETIC")
    }

    // MARK: - Nested undefined-length sequences

    /// SQ(undef) { Item(undef) { SQ(undef) { Item(undef) { (0008,0100) } } } }, then PatientName.
    private func nestedDataset(explicit: Bool) -> Data {
        let innerElement = S.element(0x0008, 0x0100, "SH", S.text("CODE1"), explicit: explicit)
        let innerSeq = S.undefinedSequence(0x0008, 0x1115, items: [S.undefinedItem(innerElement)], explicit: explicit)
        let outerItem = S.undefinedItem(innerSeq + S.element(0x0008, 0x1150, "UI", S.text("1.2.3", pad: 0), explicit: explicit))
        let outerSeq = S.undefinedSequence(0x0008, 0x1140, items: [outerItem, S.definedItem(Data())], explicit: explicit)
        var ds = Data()
        ds.append(S.element(0x0008, 0x0060, "CS", S.text("CT"), explicit: explicit))
        ds.append(outerSeq)
        ds.append(S.element(0x0010, 0x0010, "PN", S.text("AFTER^NESTED"), explicit: explicit))
        ds.append(S.element(0x0020, 0x000E, "UI", S.text("5.6.7", pad: 0), explicit: explicit))
        return ds
    }

    func testSimpleParserHandlesNestedUndefinedLengthSequencesExplicit() throws {
        let file = S.part10(transferSyntax: S.explicitLE, dataset: nestedDataset(explicit: true))
        let (elements, _, _) = try SimpleDicomParser(data: file).parse()
        XCTAssertEqual(elements.first(where: { $0.tag == DicomTag(group: 0x0010, element: 0x0010) })?.stringValue, "AFTER^NESTED")
        XCTAssertEqual(elements.first(where: { $0.tag == DicomTag(group: 0x0020, element: 0x000E) })?.stringValue, "5.6.7")
        // The inner element must not leak out as a top-level element
        XCTAssertNil(elements.first(where: { $0.tag == DicomTag(group: 0x0008, element: 0x0100) }))
    }

    func testSimpleParserHandlesNestedUndefinedLengthSequencesImplicit() throws {
        let file = S.part10(transferSyntax: S.implicitLE, dataset: nestedDataset(explicit: false))
        let (elements, _, _) = try SimpleDicomParser(data: file).parse()
        XCTAssertEqual(elements.first(where: { $0.tag == DicomTag(group: 0x0010, element: 0x0010) })?.stringValue, "AFTER^NESTED")
    }

    func testSimpleParserHandlesUndefinedLengthUNWithImplicitContent() throws {
        // Explicit VR file with a private UN element of undefined length whose
        // content is implicit VR LE and itself nests an undefined-length item.
        let implicitInner = S.undefinedSequence(0x0009, 0x1002, items: [S.undefinedItem(S.element(0x0009, 0x1003, "", Data("AB".utf8), explicit: false))], explicit: false)
        let un = S.undefinedSequence(0x0009, 0x1001, items: [S.undefinedItem(implicitInner)], vr: "UN", explicit: true)
        var ds = Data()
        ds.append(S.element(0x0009, 0x0010, "LO", S.text("PRIVATE")))
        ds.append(un)
        ds.append(S.element(0x0010, 0x0010, "PN", S.text("AFTER^UN")))
        let (elements, _, _) = try SimpleDicomParser(data: S.part10(dataset: ds)).parse()
        XCTAssertEqual(elements.first(where: { $0.tag == DicomTag(group: 0x0010, element: 0x0010) })?.stringValue, "AFTER^UN")
    }

    func testTreeParserHandlesNestedUndefinedLengthInUnknownImplicitSequence() throws {
        // Implicit VR: (0009,1001) is unknown, so the tree parser can't infer SQ
        // from the tag and must walk the undefined-length value structurally.
        let inner = S.undefinedSequence(0x0009, 0x1002, items: [S.undefinedItem(S.element(0x0008, 0x0100, "", S.text("X1"), explicit: false))], explicit: false)
        let outer = S.undefinedSequence(0x0009, 0x1001, items: [S.undefinedItem(inner)], explicit: false)
        var ds = Data()
        ds.append(S.element(0x0008, 0x0060, "", S.text("SEG"), explicit: false))
        ds.append(outer)
        ds.append(S.element(0x0010, 0x0010, "", S.text("AFTER^TREE"), explicit: false))
        let elements = try DICOMElementTreeParser.parseFile(S.part10(transferSyntax: S.implicitLE, dataset: ds))
        XCTAssertEqual(elements.first(where: { $0.tag == DicomTag(group: 0x0010, element: 0x0010) })?.stringValue, "AFTER^TREE")
        let parsedOuter = elements.first(where: { $0.tag == DicomTag(group: 0x0009, element: 0x1001) })
        XCTAssertEqual(parsedOuter?.items.count, 1)
    }
}
