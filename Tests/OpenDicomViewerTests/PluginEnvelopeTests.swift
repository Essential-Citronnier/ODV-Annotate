// PluginEnvelopeTests.swift
// Stdout from an install hook carries three kinds of line — progress objects,
// error envelopes, and free-form logs — and the host must tell them apart.
// Misclassifying an envelope as a log line is silent: the install still fails,
// but a license gate becomes an unactionable "exit 1".

import XCTest
@testable import OpenDicomViewer

final class PluginEnvelopeTests: XCTestCase {

    func testParsesLicenseRequiredEnvelope() throws {
        let line = """
        {"ok": false, "error": {"code": "license_required", \
        "message": "Accept the terms at https://example.invalid and place sam3.pt", \
        "recoverable": true}}
        """
        let envelope = try XCTUnwrap(PluginErrorEnvelope.parse(line))
        XCTAssertEqual(envelope.code, .licenseRequired)
        XCTAssertTrue(envelope.message.contains("sam3.pt"))
    }

    func testUnknownCodeFallsBackToInternal() throws {
        let line = #"{"ok": false, "error": {"code": "wat", "message": "boom"}}"#
        let envelope = try XCTUnwrap(PluginErrorEnvelope.parse(line))
        XCTAssertEqual(envelope.code, .internalError)
        XCTAssertEqual(envelope.message, "boom")
    }

    func testEnvelopeWithoutErrorPayloadStillParses() throws {
        let envelope = try XCTUnwrap(PluginErrorEnvelope.parse(#"{"ok": false}"#))
        XCTAssertEqual(envelope.code, .internalError)
        XCTAssertFalse(envelope.message.isEmpty)
    }

    /// The two structured line kinds must not claim each other's lines.
    func testProgressLinesAreNotEnvelopes() {
        let progress = #"{"progress": 0.5, "message": "Downloading…"}"#
        XCTAssertNil(PluginErrorEnvelope.parse(progress))
        XCTAssertNotNil(PluginProgressLine.parse(progress))
    }

    func testEnvelopesAreNotProgressLines() {
        let envelope = #"{"ok": false, "error": {"code": "internal", "message": "x"}}"#
        XCTAssertNil(PluginProgressLine.parse(envelope))
        XCTAssertNotNil(PluginErrorEnvelope.parse(envelope))
    }

    func testSuccessEnvelopeIsNotAFailure() {
        XCTAssertNil(PluginErrorEnvelope.parse(#"{"ok": true, "outputs": {}}"#))
    }

    func testLogLinesAreNeither() {
        for line in ["Downloading weights", "", "  ", "not json {", "[1,2,3]"] {
            XCTAssertNil(PluginErrorEnvelope.parse(line), "envelope from: \(line)")
            XCTAssertNil(PluginProgressLine.parse(line), "progress from: \(line)")
        }
    }

    func testEnvelopeBoxCarriesValueAcrossThreads() {
        let box = ErrorEnvelopeBox()
        XCTAssertNil(box.value)
        let expectation = expectation(description: "written off the calling thread")
        DispatchQueue.global().async {
            box.value = PluginErrorEnvelope(code: .outOfMemory, message: "no room")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(box.value?.code, .outOfMemory)
    }
}
