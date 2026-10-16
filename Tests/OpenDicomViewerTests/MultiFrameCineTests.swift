import Foundation
import Testing
import AppKit
@testable import OpenDicomViewer

/// A local folder of multi-frame cine files. Set ODV_CINE_FIXTURE to point
/// at one; both tests are reported as skipped (not passed) when it's missing.
private let s42Fixture = ProcessInfo.processInfo.environment["ODV_CINE_FIXTURE"]
    ?? "/Volumes/RazorDrive/Downloads/S42"

private func s42FixtureAvailable() -> Bool {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: s42Fixture, isDirectory: &isDir), isDir.boolValue else {
        return false
    }
    let files = (try? FileManager.default.contentsOfDirectory(atPath: s42Fixture)) ?? []
    return files.contains(where: { $0.hasSuffix(".dcm") })
}

@Test(.enabled(if: s42FixtureAvailable(), "cine fixture not available (set ODV_CINE_FIXTURE)"))
func s42FixtureDecoderInitializesAndYieldsFirstFrame() throws {
    let files = try FileManager.default
        .contentsOfDirectory(atPath: s42Fixture)
        .filter { $0.hasSuffix(".dcm") }
        .sorted()
    #expect(files.count == 11)

    let firstURL = URL(fileURLWithPath: "\(s42Fixture)/\(files[0])")
    let start = Date()
    guard let decoder = MultiFrameDecoder(url: firstURL) else {
        Issue.record("MultiFrameDecoder failed on \(firstURL.lastPathComponent)")
        return
    }
    let elapsed = Date().timeIntervalSince(start)
    #expect(elapsed < 10.0, "Decoder init took \(elapsed)s, expected < 10s")
    #expect(decoder.effectiveFrameCount > 1)
    let firstFrame = decoder.frameImage(at: 0)
    #expect(firstFrame != nil, "frameImage(at: 0) returned nil")

    // Later frames must also decode — this locks the thumbnail-popup path that
    // shows frames at hover positions other than the start.
    let midIdx = decoder.effectiveFrameCount / 2
    #expect(decoder.frameCGImage(at: midIdx) != nil, "frameCGImage at mid frame returned nil")
    let lastIdx = decoder.effectiveFrameCount - 1
    #expect(decoder.frameCGImage(at: lastIdx) != nil, "frameCGImage at last frame returned nil")
}

@Test(.enabled(if: s42FixtureAvailable(), "cine fixture not available (set ODV_CINE_FIXTURE)"))
func s42FixtureGroupingProducesOneSeriesPerFile() throws {

    let files = try FileManager.default
        .contentsOfDirectory(atPath: s42Fixture)
        .filter { $0.hasSuffix(".dcm") }
        .sorted()

    var contexts: [DicomImageContext] = []
    for name in files {
        let url = URL(fileURLWithPath: "\(s42Fixture)/\(name)")
        guard let fh = try? FileHandle(forReadingFrom: url) else { continue }
        defer { fh.closeFile() }
        let data = fh.readData(ofLength: 65_536)
        let parser = SimpleDicomParser(data: data)
        guard let (elements, _, _) = try? parser.parse(stopAtPixelData: true) else { continue }

        func getStr(_ g: UInt16, _ e: UInt16) -> String? {
            elements.first(where: { $0.tag == DicomTag(group: g, element: e) })?.stringValue
        }
        func getInt(_ g: UInt16, _ e: UInt16) -> Int? {
            if let s = getStr(g, e), let v = Int(s.trimmingCharacters(in: .whitespaces)) { return v }
            return elements.first(where: { $0.tag == DicomTag(group: g, element: e) })?.intValue
        }

        let seriesUID = getStr(0x0020, 0x000E) ?? "unknown"
        let nf = getInt(0x0028, 0x0008) ?? 1
        contexts.append(DicomImageContext(
            url: url,
            sopInstanceUID: "1.2.826.0.1.3680043.10.99.\(contexts.count + 1)",
            seriesUID: seriesUID,
            seriesDescription: getStr(0x0008, 0x103E) ?? "No Description",
            instanceNumber: getInt(0x0020, 0x0013) ?? 0,
            seriesNumber: getInt(0x0020, 0x0011) ?? 0,
            zLocation: nil,
            imagePosition: nil,
            imageOrientation: nil,
            pixelSpacing: nil,
            sliceThickness: nil,
            spacingBetweenSlices: nil,
            frameOfReferenceUID: nil,
            studyInstanceUID: nil,
            numberOfFrames: nf
        ))
    }

    #expect(contexts.count == 11)
    for ctx in contexts {
        #expect(ctx.numberOfFrames > 1, "Expected multi-frame: \(ctx.url.lastPathComponent) has \(ctx.numberOfFrames)")
    }
    let uniqueSeriesUIDs = Set(contexts.map { $0.seriesUID })
    let grouped = Dictionary(grouping: contexts, by: { $0.seriesGroupingKey })
    #expect(grouped.count == contexts.count,
            "Expected \(contexts.count) synthetic series (one per file); got \(grouped.count) from \(uniqueSeriesUIDs.count) real SeriesInstanceUIDs")
    for (_, imgs) in grouped { #expect(imgs.count == 1) }
}
