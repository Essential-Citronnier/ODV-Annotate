// MultiFrameDecoder.swift
// OpenDicomViewer
//
// Efficient decoder for multi-frame (cine/video) DICOM files.
// Uses memory-mapped I/O to avoid loading entire files into memory,
// and parses encapsulated pixel data to extract individual JPEG
// frames on demand with prefetch caching for smooth playback.
// Licensed under the MIT License. See LICENSE for details.

import Foundation
import AppKit
import ImageIO
import DCMTKWrapper

func cineLog(_ msg: String) {
    let line = "[\(Date())] \(msg)\n"
    let tempDir = FileManager.default.temporaryDirectory
    let path = tempDir.appendingPathComponent("odv_cine_debug_\(ProcessInfo.processInfo.processIdentifier).log").path
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile()
        if let data = line.data(using: .utf8) {
            fh.write(data)
        }
        fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
    }
}

/// One encapsulated pixel data item (fragment): where its item tag starts
/// and where its bytes are.
struct EncapsulatedFragment: Equatable {
    let itemOffset: Int
    let dataOffset: Int
    let length: Int
}

class MultiFrameDecoder {
    let url: URL
    let numberOfFrames: Int
    let frameWidth: Int
    let frameHeight: Int
    let bitsAllocated: Int
    let samplesPerPixel: Int
    let cineRate: Double
    let frameTimeMs: Double
    let isColor: Bool

    /// How frames are turned into images
    enum DecodePath: Equatable {
        case raw        // uncompressed: Swift decode with a fixed window
        case imageIO    // baseline JPEG, color JPEG 2000 via ImageIO
        case dcmtk      // JPEG Lossless, JPEG-LS, RLE, 12-bit JPEG, ... via DCMTK
        case openJPEG   // monochrome JPEG 2000 via the wrapper's OpenJPEG decoder
    }
    let decodePath: DecodePath
    /// Window applied to every frame (modality units); nil for ImageIO frames
    let window: (width: Double, center: Double)?

    private let mappedData: Data
    /// Fragments making up each frame (one or more per frame)
    private var frameTable: [[(offset: Int, length: Int)]] = []
    private let isEncapsulated: Bool
    private let isSigned: Bool
    private let isBigEndian: Bool
    private let pixelAttributes: DicomPixelAttributes
    private var dcmtkDecoder: DCMTKFrameDecoder?
    private let dcmtkLock = NSLock()
    private let frameCache = NSCache<NSNumber, NSImage>()
    private let prefetchQueue = DispatchQueue(label: "com.opendicomviewer.framePrefetch", qos: .userInitiated)

    // Decode-ahead ring buffer for smooth cine playback
    private var ringBuffer: [Int: CGImage] = [:]  // frame index -> decoded CGImage
    private let ringBufferLock = NSLock()
    private let ringBufferSize = 60  // ~2 seconds at 30fps
    private var ringBufferDecoding = false
    private var ringBufferTarget: Int = 0  // Target frame to decode ahead to

    /// Transfer syntaxes ImageIO can't decode (or decodes without DICOM
    /// semantics), routed through DCMTK instead.
    static let dcmtkTransferSyntaxes: Set<String> = [
        "1.2.840.10008.1.2.4.51",   // JPEG Extended (12-bit)
        "1.2.840.10008.1.2.4.57",   // JPEG Lossless
        "1.2.840.10008.1.2.4.70",   // JPEG Lossless SV1
        "1.2.840.10008.1.2.4.80",   // JPEG-LS Lossless
        "1.2.840.10008.1.2.4.81",   // JPEG-LS Near-Lossless
        "1.2.840.10008.1.2.5",      // RLE Lossless
        "1.2.840.10008.1.2.1.99",   // Deflated Explicit VR LE
    ]

    /// JPEG 2000 (lossless, lossy). DCMTK 3.6.8 has no JPEG 2000 codec, so
    /// monochrome frames go through the wrapper's OpenJPEG decoder, which
    /// keeps 16-bit precision and applies the Modality LUT; ImageIO would
    /// tone-map them without DICOM windowing.
    static let jpeg2000TransferSyntaxes: Set<String> = [
        "1.2.840.10008.1.2.4.90",
        "1.2.840.10008.1.2.4.91",
    ]

    static func decodePath(transferSyntax ts: String, bitsStored: Int, isColor: Bool = false) -> DecodePath {
        let uncompressed: Set<String> = ["", "1.2.840.10008.1.2", "1.2.840.10008.1.2.1", "1.2.840.10008.1.2.2"]
        if uncompressed.contains(ts) { return .raw }
        if dcmtkTransferSyntaxes.contains(ts) { return .dcmtk }
        if jpeg2000TransferSyntaxes.contains(ts) && !isColor { return .openJPEG }
        // Baseline JPEG declared with >8-bit data can't be shown by ImageIO
        if ts == "1.2.840.10008.1.2.4.50" && bitsStored > 8 { return .dcmtk }
        return .imageIO
    }

    /// Failable init - returns nil if file is not a valid multi-frame DICOM.
    init?(url: URL) {
        let initStart = CFAbsoluteTimeGetCurrent()
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        cineLog("DECODER init start: \(url.lastPathComponent), size: \(ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file))")
        // 1. Memory-map the file
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        guard data.count > 132 else { return nil }
        self.mappedData = data
        self.url = url

        // 2. Parse header metadata using SimpleDicomParser
        let parser = SimpleDicomParser(data: data)
        guard let (elements, _, parsedTS) = try? parser.parse(stopAtPixelData: true) else { return nil }
        let pixelDataOffset = parser.offset  // Points at the (7FE0,0010) tag

        // Helper closures for tag lookup
        let getStr: (UInt16, UInt16) -> String? = { group, elem in
            elements.first(where: { $0.tag == DicomTag(group: group, element: elem) })?.stringValue
        }
        let getInt: (UInt16, UInt16) -> Int? = { group, elem in
            guard let el = elements.first(where: { $0.tag == DicomTag(group: group, element: elem) }) else {
                return nil
            }
            // IS (integer string) or US (binary uint16/uint32)
            if let s = el.stringValue, let v = Int(s.trimmingCharacters(in: .whitespaces)) {
                return v
            }
            return el.intValue
        }

        // Extract NumberOfFrames (0028,0008) - IS type; must be > 1 for multi-frame
        guard let nf = getInt(0x0028, 0x0008), nf > 1 else { return nil }
        self.numberOfFrames = nf

        let transferSyntax = (parsedTS ?? getStr(0x0002, 0x0010) ?? "")
            .trimmingCharacters(in: .controlCharacters.union(.whitespaces))
        let bigEndian = transferSyntax == "1.2.840.10008.1.2.2"
        self.isBigEndian = bigEndian
        let attributes = DicomPixelAttributes(elements: elements, bigEndian: bigEndian)
        self.pixelAttributes = attributes

        // Dimensions
        self.frameWidth  = attributes.columns ?? 0
        self.frameHeight = attributes.rows ?? 0
        self.bitsAllocated  = attributes.bitsAllocated
        self.samplesPerPixel = attributes.samplesPerPixel
        self.isSigned = attributes.pixelRepresentation == 1

        // PhotometricInterpretation (0028,0004)
        let photo = attributes.photometric.uppercased()
        self.isColor = photo.contains("RGB") || photo.contains("YBR") || photo.contains("PALETTE")

        let path = MultiFrameDecoder.decodePath(transferSyntax: transferSyntax, bitsStored: attributes.bitsStored,
                                                isColor: isColor || attributes.samplesPerPixel > 1)
        self.decodePath = path
        self.isEncapsulated = path != .raw

        // Timing: CineRate (0018,0040) IS, FrameTime (0018,1063) DS (ms/frame)
        // Prefer FrameTime; fall back to CineRate; default 30 fps
        let rawCineRate: Double
        if let cr = getInt(0x0018, 0x0040), cr > 0 {
            rawCineRate = Double(cr)
        } else {
            rawCineRate = 30.0
        }

        if let ftStr = getStr(0x0018, 0x1063),
           let ft = Double(ftStr.trimmingCharacters(in: .whitespaces)),
           ft > 0 {
            self.frameTimeMs = ft
            self.cineRate = 1000.0 / ft
        } else {
            self.cineRate = rawCineRate
            self.frameTimeMs = 1000.0 / rawCineRate
        }

        // 3. Build the frame table
        let parseStart = CFAbsoluteTimeGetCurrent()
        var table: [[(offset: Int, length: Int)]] = []
        switch path {
        case .imageIO, .openJPEG:
            guard let frames = MultiFrameDecoder.encapsulatedFrameTable(
                data: data, pixelDataTagOffset: pixelDataOffset, numberOfFrames: nf,
                transferSyntax: transferSyntax, fileURL: url) else {
                cineLog("DECODER encapsulated frame table FAILED for \(url.lastPathComponent)")
                return nil
            }
            table = frames
        case .raw:
            var flat: [(offset: Int, length: Int)] = []
            MultiFrameDecoder.buildRawFrameTable(
                data: data,
                frameTable: &flat,
                pixelDataTagOffset: pixelDataOffset,
                numberOfFrames: nf,
                frameWidth: frameWidth,
                frameHeight: frameHeight,
                bitsAllocated: bitsAllocated,
                samplesPerPixel: samplesPerPixel
            )
            guard !flat.isEmpty else {
                cineLog("DECODER buildRawFrameTable FAILED for \(url.lastPathComponent)")
                return nil
            }
            table = flat.map { [$0] }
        case .dcmtk:
            guard let dec = DCMTKFrameDecoder(path: url.path), dec.frameCount > 0 else {
                cineLog("DECODER DCMTK frame decoder FAILED for \(url.lastPathComponent)")
                return nil
            }
            self.dcmtkDecoder = dec
            // Frames are addressed by index; offsets are unused for this path
            table = Array(repeating: [], count: min(nf, dec.frameCount))
        }
        cineLog("DECODER Frame table built: \(table.count) frames in \(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - parseStart))s for \(url.lastPathComponent)")

        // Limit to declared frame count
        if table.count > nf {
            table = Array(table.prefix(nf))
        }
        self.frameTable = table

        // 4. One window for all frames (modality units): the file's stored
        // window, else the first frame's range. Per-frame auto-windowing made
        // brightness flicker during playback.
        switch path {
        case .raw:
            if let w = attributes.windowWidth, w > 0, let c = attributes.windowCenter {
                self.window = (w, c)
            } else if let first = table.first?.first, first.offset + first.length <= data.count,
                      let decoded = PlainPixelDecoder.decode(pixelData: data.subdata(in: first.offset..<(first.offset + first.length)),
                                                             attributes: attributes, bigEndian: bigEndian),
                      decoded.samples == 1 {
                let w = PixelValues.defaultWindow(storedWidth: nil, storedCenter: nil, data: decoded.data,
                                                  bits: decoded.bitDepth, isSigned: decoded.isSigned)
                self.window = (w.width, w.center)
            } else {
                self.window = nil
            }
        case .dcmtk:
            var c = 0.0, w = 0.0, lo = 0.0, hi = 0.0
            if let dec = dcmtkDecoder, dec.getStoredWindowCenter(&c, width: &w), w > 0 {
                self.window = (w, c)
            } else if let dec = dcmtkDecoder, dec.getMinMax(ofFrame: 0, min: &lo, max: &hi) {
                self.window = (max(hi - lo, 1), (hi + lo) / 2)
            } else {
                self.window = nil
            }
        case .openJPEG:
            if let w = attributes.windowWidth, w > 0, let c = attributes.windowCenter {
                self.window = (w, c)
            } else if let decoded = MultiFrameDecoder.decodeJPEG2000(
                        MultiFrameDecoder.joinedFrame(table.first ?? [], in: data), attributes: attributes),
                      decoded.samples == 1 {
                let w = PixelValues.defaultWindow(storedWidth: nil, storedCenter: nil, data: decoded.data,
                                                  bits: decoded.bitDepth, isSigned: decoded.isSigned)
                self.window = (w.width, w.center)
            } else {
                self.window = nil
            }
        case .imageIO:
            self.window = nil
        }

        // 5. Configure cache
        frameCache.countLimit = 120
        frameCache.totalCostLimit = 500 * 1024 * 1024 // 500 MB
        cineLog("DECODER init COMPLETE: \(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - initStart))s total for \(url.lastPathComponent) (\(min(nf, table.count)) effective frames, path \(path))")
    }

    // MARK: - Frame Access

    /// Return a decoded frame image at the given index. Checks the cache first.
    func frameImage(at index: Int) -> NSImage? {
        guard index >= 0 && index < effectiveFrameCount else { return nil }

        let key = NSNumber(value: index)
        if let cached = frameCache.object(forKey: key) {
            return cached
        }
        guard let cg = frameCGImage(at: index) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        frameCache.setObject(image, forKey: key)
        return image
    }

    /// Compressed bytes of a frame: a zero-copy slice for single-fragment
    /// frames, concatenated fragments otherwise.
    private func frameBytes(at index: Int) -> Data? {
        MultiFrameDecoder.joinedFrame(frameTable[index], in: mappedData)
    }

    private static func joinedFrame(_ fragments: [(offset: Int, length: Int)], in data: Data) -> Data? {
        guard !fragments.isEmpty,
              fragments.allSatisfy({ $0.offset >= 0 && $0.offset + $0.length <= data.count }) else { return nil }
        if fragments.count == 1 {
            let f = fragments[0]
            return data[f.offset..<(f.offset + f.length)]
        }
        var joined = Data(capacity: fragments.reduce(0) { $0 + $1.length })
        for f in fragments { joined.append(data[f.offset..<(f.offset + f.length)]) }
        return joined
    }

    /// Decode one JPEG 2000 frame to modality values via OpenJPEG
    /// (sign extension per PixelRepresentation, RescaleSlope/Intercept).
    static func decodeJPEG2000(_ codestream: Data?, attributes: DicomPixelAttributes) -> DecodedPixelBuffer? {
        guard let codestream = codestream, !codestream.isEmpty else { return nil }
        var w = 0, h = 0, bits = 0, spp = 0
        var signed: ObjCBool = false
        guard let data = DCMTKHelper.decodeJPEG2000Frame(
            Data(codestream), pixelRepresentation: attributes.pixelRepresentation,
            rescaleSlope: attributes.rescaleSlope, rescaleIntercept: attributes.rescaleIntercept,
            width: &w, height: &h, bitDepth: &bits, samples: &spp, isSigned: &signed) else { return nil }
        return DecodedPixelBuffer(data: data, width: w, height: h, bitDepth: bits, samples: spp, isSigned: signed.boolValue)
    }

    /// Decode a frame directly to CGImage (faster than NSImage for display pipeline)
    func frameCGImage(at index: Int) -> CGImage? {
        guard index >= 0 && index < effectiveFrameCount else { return nil }

        switch decodePath {
        case .raw:
            guard let frameData = frameBytes(at: index) else { return nil }
            return renderRawFrame(frameData)
        case .dcmtk:
            return dcmtkFrame(at: index)
        case .openJPEG:
            guard let decoded = MultiFrameDecoder.decodeJPEG2000(frameBytes(at: index), attributes: pixelAttributes),
                  decoded.width == frameWidth, decoded.height == frameHeight else { return nil }
            return renderDecodedFrame(decoded)
        case .imageIO:
            if let frameData = frameBytes(at: index),
               let source = CGImageSourceCreateWithData(frameData as CFData, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
                return image
            }
            // ImageIO couldn't decode this codestream; let DCMTK try
            return dcmtkFrame(at: index)
        }
    }

    private func dcmtkFrame(at index: Int) -> CGImage? {
        dcmtkLock.lock()
        if dcmtkDecoder == nil { dcmtkDecoder = DCMTKFrameDecoder(path: url.path) }
        let decoder = dcmtkDecoder
        dcmtkLock.unlock()
        guard let decoder = decoder else { return nil }
        let w = window ?? (0, 0)
        return decoder.copyFrameImage(index, ww: w.width, wc: w.center)
    }

    /// Prefetch frames ahead of the current position for smooth playback.
    func prefetch(around index: Int, count: Int = 15) {
        prefetchQueue.async { [weak self] in
            guard let self = self else { return }
            let start = max(0, index)
            let end = min(self.effectiveFrameCount - 1, index + count)
            guard start <= end else { return }
            for i in start...end {
                _ = self.frameImage(at: i)
            }
        }
    }

    /// Number of frames that can actually be extracted (may be less than
    /// numberOfFrames if the file is truncated).
    var effectiveFrameCount: Int {
        min(numberOfFrames, frameTable.count)
    }

    /// Evict all cached frames, e.g. on a memory-pressure notification.
    func clearCache() {
        frameCache.removeAllObjects()
    }

    // MARK: - Ring Buffer

    /// Start filling the ring buffer ahead of the given frame index
    func startRingBuffer(from startIndex: Int) {
        ringBufferLock.lock()
        ringBufferTarget = startIndex
        let alreadyDecoding = ringBufferDecoding
        ringBufferDecoding = true
        ringBufferLock.unlock()

        guard !alreadyDecoding else { return }

        prefetchQueue.async { [weak self] in
            self?.fillRingBuffer()
        }
    }

    /// Stop the ring buffer (call when playback stops)
    func stopRingBuffer() {
        ringBufferLock.lock()
        ringBufferDecoding = false
        ringBuffer.removeAll()
        ringBufferLock.unlock()
    }

    /// Get a pre-decoded frame from the ring buffer (returns nil on miss)
    func ringBufferImage(at index: Int) -> CGImage? {
        ringBufferLock.lock()
        let img = ringBuffer[index]
        ringBufferLock.unlock()
        return img
    }

    /// Advance the ring buffer target (called each frame during playback)
    func advanceRingBuffer(to index: Int) {
        ringBufferLock.lock()
        ringBufferTarget = index
        // Evict frames more than ringBufferSize/2 behind current position
        let evictBefore = index - ringBufferSize / 2
        let keysToRemove = ringBuffer.keys.filter { $0 < evictBefore }
        for key in keysToRemove {
            ringBuffer.removeValue(forKey: key)
        }
        ringBufferLock.unlock()
    }

    /// Background worker that continuously fills the ring buffer ahead of playback
    private func fillRingBuffer() {
        while true {
            ringBufferLock.lock()
            guard ringBufferDecoding else {
                ringBufferLock.unlock()
                return
            }
            let target = ringBufferTarget
            ringBufferLock.unlock()

            // Find the next frame that needs decoding
            var decoded = false
            for i in 0..<ringBufferSize {
                let frameIdx = target + i
                guard frameIdx < effectiveFrameCount else { break }

                ringBufferLock.lock()
                let alreadyDecoded = ringBuffer[frameIdx] != nil
                let stillActive = ringBufferDecoding
                ringBufferLock.unlock()

                guard stillActive else { return }
                if alreadyDecoded { continue }

                // Decode this frame
                if let cgImage = frameCGImage(at: frameIdx) {
                    ringBufferLock.lock()
                    ringBuffer[frameIdx] = cgImage
                    ringBufferLock.unlock()
                    decoded = true
                    break  // Decode one frame per iteration to check for stop
                }
            }

            if !decoded {
                // All frames in window are decoded, sleep briefly
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
    }

    // MARK: - Raw (Uncompressed) Frame Support

    /// Build a frame offset table for uncompressed multi-frame pixel data.
    /// Raw pixel data is a contiguous blob; each frame is exactly frameSize bytes.
    private static func buildRawFrameTable(
        data: Data,
        frameTable: inout [(offset: Int, length: Int)],
        pixelDataTagOffset: Int,
        numberOfFrames: Int,
        frameWidth: Int,
        frameHeight: Int,
        bitsAllocated: Int,
        samplesPerPixel: Int
    ) {
        guard pixelDataTagOffset >= 0 else { return }
        guard frameWidth > 0, frameHeight > 0, bitsAllocated > 0, samplesPerPixel > 0 else { return }

        let bytesPerSample = max(1, bitsAllocated / 8)
        let frameSize = frameWidth * frameHeight * bytesPerSample * samplesPerPixel
        guard frameSize > 0 else { return }

        // Advance past tag (4 bytes), then VR/length header
        var pixelDataStart = pixelDataTagOffset + 4
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            guard pixelDataStart + 2 <= data.count else { return }
            let vr0 = base[pixelDataStart]
            let vr1 = base[pixelDataStart + 1]
            // Explicit VR OB or OW: VR(2) + reserved(2) + 32-bit length(4) = 8 bytes
            if vr0 == 0x4F && (vr1 == 0x42 || vr1 == 0x57) {
                pixelDataStart += 8
            } else {
                // Implicit VR: 32-bit length only (4 bytes)
                pixelDataStart += 4
            }
        }

        for i in 0..<numberOfFrames {
            let offset = pixelDataStart + i * frameSize
            let end = offset + frameSize
            guard end <= data.count else { break }
            frameTable.append((offset: offset, length: frameSize))
        }
    }

    /// Render one uncompressed frame to an 8-bit CGImage: decode with the
    /// Modality LUT (BitsAllocated, byte order, planar config handled by
    /// PlainPixelDecoder), then apply the decoder-wide window and MONOCHROME1.
    private func renderRawFrame(_ frameData: Data) -> CGImage? {
        guard frameWidth > 0, frameHeight > 0,
              let decoded = PlainPixelDecoder.decode(pixelData: frameData, attributes: pixelAttributes, bigEndian: isBigEndian)
        else { return nil }
        return renderDecodedFrame(decoded)
    }

    /// Render a decoded frame (modality values or 8-bit RGB) to an 8-bit
    /// CGImage with the decoder-wide window and MONOCHROME1 inversion.
    private func renderDecodedFrame(_ decoded: DecodedPixelBuffer) -> CGImage? {
        guard frameWidth > 0, frameHeight > 0 else { return nil }
        let totalPixels = frameWidth * frameHeight
        guard decoded.data.count >= totalPixels * decoded.samples * PixelValues.bytesPerSample(bits: decoded.bitDepth) else { return nil }

        if decoded.samples == 3 {
            guard let provider = CGDataProvider(data: decoded.data as CFData) else { return nil }
            return CGImage(
                width: frameWidth, height: frameHeight,
                bitsPerComponent: 8, bitsPerPixel: 24,
                bytesPerRow: frameWidth * 3,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil,
                shouldInterpolate: true, intent: .defaultIntent
            )
        }

        let (ww, wc): (Double, Double)
        if let w = window {
            (ww, wc) = (max(w.width, 1), w.center)
        } else {
            let r = PixelValues.minMax(data: decoded.data, bits: decoded.bitDepth, isSigned: decoded.isSigned)
            (ww, wc) = (max(r.max - r.min, 1), (r.max + r.min) / 2)
        }
        let windowBottom = wc - ww / 2.0
        let invert = pixelAttributes.isMonochrome1

        var gray = Data(count: totalPixels)
        decoded.data.withUnsafeBytes { raw in
            gray.withUnsafeMutableBytes { dst in
                let out = dst.bindMemory(to: UInt8.self)
                for i in 0..<totalPixels {
                    let v = PixelValues.value(in: raw, index: i, bits: decoded.bitDepth, isSigned: decoded.isSigned) ?? 0
                    var norm = (v - windowBottom) / ww * 255.0
                    if invert { norm = 255.0 - norm }
                    out[i] = UInt8(max(0, min(255, norm)))
                }
            }
        }
        guard let provider = CGDataProvider(data: gray as CFData) else { return nil }
        return CGImage(
            width: frameWidth, height: frameHeight,
            bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: frameWidth,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent
        )
    }

    // MARK: - Encapsulated Pixel Data Parser

    /// Walk the encapsulated item sequence of PixelData (7FE0,0010) and
    /// group fragments into frames.
    ///
    /// Layout:
    ///   PixelData tag + VR + length (FFFFFFFF)
    ///   Item 0 : Basic Offset Table (FFFE,E000) + length + UInt32 offsets
    ///   Item 1…: fragments (a frame may span several)
    ///   Sequence Delimiter (FFFE,E0DD)
    ///
    /// Item headers are read with FileHandle seeks so only ~8 bytes per item
    /// are paged in, instead of touching every page of a multi-GB mapping.
    static func encapsulatedFrameTable(
        data: Data,
        pixelDataTagOffset: Int,
        numberOfFrames: Int,
        transferSyntax: String,
        fileURL: URL
    ) -> [[(offset: Int, length: Int)]]? {
        guard pixelDataTagOffset >= 0, pixelDataTagOffset + 8 <= data.count else { return nil }
        guard let fh = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? fh.close() }

        func read(_ offset: Int, _ count: Int) -> Data? {
            guard offset >= 0, offset + count <= data.count else { return nil }
            fh.seek(toFileOffset: UInt64(offset))
            let d = fh.readData(ofLength: count)
            return d.count == count ? d : nil
        }
        func u32(_ d: Data, _ at: Int) -> Int {
            Int(d[d.startIndex + at]) | Int(d[d.startIndex + at + 1]) << 8
                | Int(d[d.startIndex + at + 2]) << 16 | Int(d[d.startIndex + at + 3]) << 24
        }

        // Tag (4) then explicit "OB"/"OW" + reserved + length (8), or implicit length (4)
        var offset = pixelDataTagOffset + 4
        if let vr = read(offset, 2), vr[vr.startIndex] == 0x4F,
           vr[vr.startIndex + 1] == 0x42 || vr[vr.startIndex + 1] == 0x57 {
            offset += 8
        } else {
            offset += 4
        }

        var basicOffsetTable: [UInt32] = []
        var fragments: [EncapsulatedFragment] = []
        var isFirstItem = true
        while let header = read(offset, 8) {
            let b = [UInt8](header)
            if b[0] == 0xFE && b[1] == 0xFF && b[2] == 0xDD && b[3] == 0xE0 { break }        // sequence end
            guard b[0] == 0xFE && b[1] == 0xFF && b[2] == 0x00 && b[3] == 0xE0 else { break } // item
            let len = u32(header, 4)
            guard len != 0xFFFF_FFFF else { break }
            let dataStart = offset + 8
            if isFirstItem {
                isFirstItem = false
                if len >= 4, let bot = read(dataStart, len) {
                    basicOffsetTable = stride(from: 0, to: len - 3, by: 4).map { UInt32(u32(bot, $0)) }
                }
            } else if len > 0 && dataStart + len <= data.count {
                fragments.append(EncapsulatedFragment(itemOffset: offset, dataOffset: dataStart, length: len))
            }
            offset = dataStart + len
        }
        guard !fragments.isEmpty else { return nil }

        let isRLE = transferSyntax == "1.2.840.10008.1.2.5"
        let frames = groupFragments(fragments, basicOffsetTable: basicOffsetTable, numberOfFrames: numberOfFrames) { fragment in
            if isRLE { return true }  // RLE: exactly one fragment per frame
            guard let head = read(fragment.dataOffset, min(12, fragment.length)) else { return false }
            return startsCodestream([UInt8](head))
        }
        let table = frames.map { $0.map { (offset: $0.dataOffset, length: $0.length) } }
        return table.isEmpty ? nil : table
    }

    /// True when bytes begin a new image codestream: JPEG / JPEG-LS SOI
    /// (FFD8 FF), J2K SOC+SIZ (FF4F FF51) or a JP2 signature box.
    static func startsCodestream(_ b: [UInt8]) -> Bool {
        if b.count >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF { return true }
        if b.count >= 4 && b[0] == 0xFF && b[1] == 0x4F && b[2] == 0xFF && b[3] == 0x51 { return true }
        if b.count >= 8 && b[4] == 0x6A && b[5] == 0x50 && b[6] == 0x20 && b[7] == 0x20 { return true }
        return false
    }

    /// Group fragments into frames:
    /// 1. Basic Offset Table present: frame i holds the fragments whose item
    ///    offset (relative to the first fragment item) is in [BOT[i], BOT[i+1]).
    /// 2. One fragment per frame.
    /// 3. A single frame: all fragments.
    /// 4. Otherwise a new frame starts at each fragment that begins a codestream.
    static func groupFragments(
        _ fragments: [EncapsulatedFragment],
        basicOffsetTable: [UInt32],
        numberOfFrames: Int,
        startsFrame: (EncapsulatedFragment) -> Bool
    ) -> [[EncapsulatedFragment]] {
        guard let first = fragments.first else { return [] }

        if !basicOffsetTable.isEmpty {
            let starts = basicOffsetTable.map { first.itemOffset + Int($0) }
            if zip(starts, starts.dropFirst()).allSatisfy({ $0 < $1 }) {
                var frames: [[EncapsulatedFragment]] = Array(repeating: [], count: starts.count)
                for f in fragments {
                    // Last BOT entry whose start is <= this fragment's item offset
                    guard let idx = starts.lastIndex(where: { $0 <= f.itemOffset }) else { continue }
                    frames[idx].append(f)
                }
                if frames.allSatisfy({ !$0.isEmpty }) { return frames }
            }
        }
        if fragments.count == numberOfFrames {
            return fragments.map { [$0] }
        }
        if numberOfFrames == 1 {
            return [fragments]
        }
        var frames: [[EncapsulatedFragment]] = []
        for f in fragments {
            if frames.isEmpty || startsFrame(f) {
                frames.append([f])
            } else {
                frames[frames.count - 1].append(f)
            }
        }
        return frames
    }
}
