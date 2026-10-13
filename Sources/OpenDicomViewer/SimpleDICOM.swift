// SimpleDICOM.swift
// OpenDicomViewer
//
// Pure-Swift DICOM file parser. Reads DICOM Part 10 files without any
// external library dependencies. Used for fast metadata extraction during
// directory scanning (series UID, instance number, spatial metadata, etc.)
// while the heavier DCMTK wrapper handles pixel data decoding.
//
// Key types:
//   DicomTag           — (group, element) tag identifier with standard name lookup
//   DicomVR            — Value Representation enum (all standard DICOM VRs)
//   DicomElement       — Parsed tag: tag, VR, data, and convenience accessors
//   SimpleDicomParser  — Streaming parser that reads tags sequentially from Data,
//                        supports both explicit and implicit VR, little/big endian,
//                        and can stop at PixelData for fast header-only parsing
// Licensed under the MIT License. See LICENSE for details.

import Foundation

enum DicomError: Error {
    case invalidFile
    case notDicom
    case unsupportedTransferSyntax
    case endOfFile
}

enum VR: String {
    case AE, AS, AT, CS, DA, DS, DT, FL, FD, IS, LO, LT, OB, OD, OF, OL, OV, OW, PN, SH, SL, SQ, SS, ST, SV, TM, UC, UI, UL, UN, UR, US, UT, UV
    case unknown
}

struct DicomTag: Equatable, Hashable, CustomStringConvertible {
    let group: UInt16
    let element: UInt16
    
    var description: String {
        return String(format: "(%04X,%04X)", group, element)
    }
}

struct DicomElement: Identifiable {
    let tag: DicomTag
    let vr: VR
    let length: Int
    let data: Data
    
    var id: String { tag.description }
    
    var stringValue: String? {
        return data.robustString()
    }
    
    var intValue: Int? {
        if data.count == 2 {
            var val: UInt16 = 0
            _ = withUnsafeMutableBytes(of: &val) { data.copyBytes(to: $0) }
            return Int(val)
        } else if data.count == 4 {
             var val: UInt32 = 0
             _ = withUnsafeMutableBytes(of: &val) { data.copyBytes(to: $0) }
             return Int(val)
        }
        return nil
    }
}

extension Data {
    func robustString() -> String? {
        // 1. Try UTF-8
        if let s = String(data: self, encoding: .utf8) {
            return s.trimmingCharacters(in: .controlCharacters).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 2. Try Korean EUC-KR (Common in KR Medical)
        let eucKR = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0949)))
        if let s = String(data: self, encoding: eucKR) {
             return s.trimmingCharacters(in: .controlCharacters).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 3. Try ISO-Latin-1 (Default DICOM)
        if let s = String(data: self, encoding: .isoLatin1) {
             return s.trimmingCharacters(in: .controlCharacters).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 4. Fallback ASCII (Lossy)
        if let s = String(data: self, encoding: .ascii) {
             return s.trimmingCharacters(in: .controlCharacters).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
}

class SimpleDicomParser {
    let data: Data
    var offset: Int = 0
    var isLittleEndian: Bool = true
    var isExplicitVR: Bool = true 
    var debugMode: Bool = false
    
    /// Byte offset where the dataset (or file meta group) begins: 132 for
    /// Part 10 files, 0 for preamble-less raw datasets.
    private(set) var datasetStart: Int = 132
    /// Encoding used for the dataset when there is no File Meta transfer syntax.
    private var rawDatasetExplicitVR: Bool = false

    init(data: Data) {
        self.data = data
    }

    /// Cheap DICOM sniff over the first bytes of a file: either the "DICM"
    /// magic at offset 128, or a preamble-less dataset that starts with a
    /// plausible group 0002/0008 element (implicit or explicit VR little endian).
    static func isLikelyDICOM(header: Data) -> Bool {
        if hasPart10Preamble(header) { return true }
        return rawDatasetEncoding(header) != nil
    }

    private static func hasPart10Preamble(_ d: Data) -> Bool {
        guard d.count >= 132 else { return false }
        let base = d.startIndex
        return d[base + 128] == 0x44 && d[base + 129] == 0x49 && d[base + 130] == 0x43 && d[base + 131] == 0x4D
    }

    /// For a preamble-less dataset, returns whether it is explicit VR (true) or
    /// implicit VR (false), or nil if the leading bytes don't look like DICOM.
    static func rawDatasetEncoding(_ d: Data) -> Bool? {
        guard d.count >= 12 else { return nil }
        let b = [UInt8](d.prefix(12))
        let group = UInt16(b[0]) | UInt16(b[1]) << 8
        let element = UInt16(b[2]) | UInt16(b[3]) << 8
        // Datasets almost always open with group 0008 (or a stray meta group);
        // the first element number is small (e.g. 0005, 0008, 0016).
        guard group == 0x0008 || group == 0x0002, element < 0x0100 else { return nil }
        // Explicit VR: bytes 4-5 are two uppercase letters forming a known VR.
        if b[4] >= 0x41, b[4] <= 0x5A, b[5] >= 0x41, b[5] <= 0x5A,
           let vrStr = String(bytes: b[4...5], encoding: .ascii), VR(rawValue: vrStr) != nil {
            return true
        }
        // Implicit VR: 32-bit little-endian length that is even-ish and sane.
        let len = UInt32(b[4]) | UInt32(b[5]) << 8 | UInt32(b[6]) << 16 | UInt32(b[7]) << 24
        if len < 0x10000 { return false }
        return nil
    }

    func parse(stopAtPixelData: Bool = false) throws -> ([DicomElement], Data?, String?) {
        if Self.hasPart10Preamble(data) {
            offset = 132
        } else if let explicit = Self.rawDatasetEncoding(data) {
            // Preamble-less dataset (common for older .IMA / UID-named files)
            offset = 0
            rawDatasetExplicitVR = explicit
        } else if data.count < 132 {
            throw DicomError.invalidFile
        } else {
            throw DicomError.notDicom
        }
        datasetStart = offset
        
        if debugMode { print("DICM Header found. File size: \(data.count)") }
        
        var elements: [DicomElement] = []
        var pixelData: Data? = nil
        var transferSyntaxUID: String? = nil
        
        isLittleEndian = true
        isExplicitVR = true
        
        while offset < data.count {
             // Safety check for EOF peeking
             guard offset + 4 <= data.count else { 
                 if debugMode { print("Ending parse loop: Near EOF at \(offset)") }
                 break 
             }
             let groupNext = withUnsafeBytes(of: UInt16(0)) { ptr -> UInt16 in
                 var temp: UInt16 = 0
                 _ = withUnsafeMutableBytes(of: &temp) { 
                     data.copyBytes(to: $0, from: offset..<offset+2) 
                 }
                 return temp
             }.littleEndian 
             
             if groupNext != 0x0002 {
                 if let syntax = transferSyntaxUID {
                     applyTransferSyntax(syntax)
                 } else {
                     isExplicitVR = rawDatasetExplicitVR
                     isLittleEndian = true
                 }
             }
             
            // Early stop: peek at next tag to avoid reading massive pixel data
            // elements (multi-frame files can have 2GB+ encapsulated pixel data)
            if stopAtPixelData && offset + 4 <= data.count {
                var peekG: UInt16 = 0
                var peekE: UInt16 = 0
                _ = withUnsafeMutableBytes(of: &peekG) { data.copyBytes(to: $0, from: offset..<offset+2) }
                _ = withUnsafeMutableBytes(of: &peekE) { data.copyBytes(to: $0, from: (offset+2)..<(offset+4)) }
                peekG = isLittleEndian ? peekG.littleEndian : peekG.bigEndian
                peekE = isLittleEndian ? peekE.littleEndian : peekE.bigEndian
                if peekG == 0x7FE0 && peekE == 0x0010 {
                    // Record a zero-length placeholder so callers can see the pixel data tag
                    // was encountered without us having read its (potentially huge) bytes.
                    let pixelTag = DicomTag(group: 0x7FE0, element: 0x0010)
                    elements.append(DicomElement(tag: pixelTag, vr: .OW, length: 0, data: Data()))
                    return (elements, nil, transferSyntaxUID)
                }
            }

            do {
                let element = try parseElement()
                elements.append(element)

                if element.tag == DicomTag(group: 0x0002, element: 0x0010) {
                 transferSyntaxUID = element.stringValue
                 if debugMode { print("Transfer Syntax: \(transferSyntaxUID ?? "nil")") }
             }

             if element.tag == DicomTag(group: 0x7FE0, element: 0x0010) {
                 if debugMode { print("Pixel Data Found! Length: \(element.length)") }
                 pixelData = element.data
                    if stopAtPixelData {
                        return (elements, nil, transferSyntaxUID)
                    }
                 }
            } catch DicomError.endOfFile {
                // If we hit EOF during an element parse, just stop and return what we have (truncated file support)
                // EOF reached — return captured elements
                break
            } catch {
                throw error
            }
        }
        
        return (elements, pixelData, transferSyntaxUID)
    }
    
    private func parseElement() throws -> DicomElement {
        let group = try readUInt16()
        let element = try readUInt16()
        let tag = DicomTag(group: group, element: element)
        
        var vr: VR = .unknown
        var length: Int = 0
        
        let isActuallyExplicit = isExplicitVR || (group == 0x0002)
        
        if isActuallyExplicit {
            let vrStr = try readString(length: 2)
            vr = VR(rawValue: vrStr) ?? .unknown
            
            if ["OB", "OD", "OF", "OL", "OV", "OW", "SQ", "SV", "UC", "UN", "UR", "UT", "UV"].contains(vrStr) {
                offset += 2
                let l = try readUInt32()
                length = Int(l)
            } else {
                let l = try readUInt16()
                length = Int(l)
            }
        } else {
            let l = try readUInt32()
            length = Int(l)
            vr = lookupVR(tag: tag)
        }
        
        if length == -1 || length == 0xFFFFFFFF {
             // Undefined length: SQ, encapsulated pixel data, or UN (whose
             // content is always implicit VR little endian).
             let contentIsImplicit = isActuallyExplicit && vr == .UN
             let d = readUndefinedLengthValue(contentIsImplicit: contentIsImplicit)
             return DicomElement(tag: tag, vr: vr, length: d.count, data: d)
        }
        
        // Tolerant read: if EOF, read what we have
        let runEnd = offset + length
        let safeEnd = min(runEnd, data.count)
        let actualLength = safeEnd - offset
        
        let valueData = data.subdata(in: offset..<safeEnd)
        offset = safeEnd // Advance by actual read amount
        
        // If we extracted less than expected, we might want to warn or just proceed.
        // For visualizer, proceeding is better.
        // However, if we are NOT at the end, this might desync the parser.
        // But usually mismatch happens at the very end (Pixel Data).
        
        // If we strictly enforced checks before, we would throw.
        // Now we return the partial element.
        
        return DicomElement(tag: tag, vr: vr, length: actualLength, data: valueData)
    }
    
    private func readUInt16() throws -> UInt16 {
        guard offset + 2 <= data.count else { throw DicomError.endOfFile }
        var val: UInt16 = 0
        _ = withUnsafeMutableBytes(of: &val) { valPtr in
            data.copyBytes(to: valPtr, from: offset..<offset+2)
        }
        offset += 2
        return isLittleEndian ? val.littleEndian : val.bigEndian
    }
    
    private func readUInt32() throws -> UInt32 {
        guard offset + 4 <= data.count else { throw DicomError.endOfFile }
        var val: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &val) { valPtr in
            data.copyBytes(to: valPtr, from: offset..<offset+4)
        }
        offset += 4
        return isLittleEndian ? val.littleEndian : val.bigEndian
    }
    
    private func readString(length: Int) throws -> String {
        guard offset + length <= data.count else { throw DicomError.endOfFile }
        let d = data.subdata(in: offset..<offset+length)
        offset += length
        return d.robustString() ?? ""
    }
    
    /// Read the value of an undefined-length element, returning its content
    /// (without the trailing Sequence Delimitation Item). Walks items and
    /// nested datasets structurally so a nested undefined-length sequence's
    /// delimiter isn't mistaken for the outer one; falls back to a byte scan
    /// when the content isn't well-formed.
    private func readUndefinedLengthValue(contentIsImplicit: Bool) -> Data {
        let startIndex = offset
        let savedExplicit = isExplicitVR
        let savedLE = isLittleEndian
        if contentIsImplicit { isExplicitVR = false; isLittleEndian = true }
        defer { isExplicitVR = savedExplicit; isLittleEndian = savedLE }

        if let end = try? skipItems(depth: 0) {
            offset = end
            return data.subdata(in: startIndex..<max(startIndex, end - 8))
        }
        offset = startIndex
        return readUntitledSequenceByScanning()
    }

    /// Skip a sequence of items up to and including its Sequence Delimitation
    /// Item. Returns the offset just past the delimiter.
    private func skipItems(depth: Int) throws -> Int {
        guard depth < 64 else { throw DicomError.invalidFile }
        while true {
            let g = try readUInt16()
            let e = try readUInt16()
            let len = try readUInt32()
            guard g == 0xFFFE else { throw DicomError.invalidFile }
            switch e {
            case 0xE0DD:  // Sequence Delimitation Item
                return offset
            case 0xE000:  // Item (or encapsulated fragment)
                if len == 0xFFFFFFFF {
                    try skipItemDataset(depth: depth + 1)
                } else {
                    guard offset + Int(len) <= data.count else { throw DicomError.endOfFile }
                    offset += Int(len)
                }
            default:
                throw DicomError.invalidFile
            }
        }
    }

    /// Skip the elements of an undefined-length item up to and including its
    /// Item Delimitation Item.
    private func skipItemDataset(depth: Int) throws {
        while true {
            let g = try readUInt16()
            let e = try readUInt16()
            if g == 0xFFFE {
                _ = try readUInt32()
                if e == 0xE00D { return }
                throw DicomError.invalidFile
            }
            var vrStr = ""
            var len: UInt32
            if isExplicitVR {
                vrStr = try readString(length: 2)
                guard VR(rawValue: vrStr) != nil else { throw DicomError.invalidFile }
                if ["OB", "OD", "OF", "OL", "OV", "OW", "SQ", "SV", "UC", "UN", "UR", "UT", "UV"].contains(vrStr) {
                    offset += 2
                    len = try readUInt32()
                } else {
                    len = UInt32(try readUInt16())
                }
            } else {
                len = try readUInt32()
            }
            if len == 0xFFFFFFFF {
                if isExplicitVR && vrStr == "UN" {
                    let savedExplicit = isExplicitVR
                    isExplicitVR = false
                    defer { isExplicitVR = savedExplicit }
                    _ = try skipItems(depth: depth + 1)
                } else {
                    _ = try skipItems(depth: depth + 1)
                }
            } else {
                guard offset + Int(len) <= data.count else { throw DicomError.endOfFile }
                offset += Int(len)
            }
        }
    }

    /// Legacy fallback: scan for the first Sequence Delimitation Item.
    private func readUntitledSequenceByScanning() -> Data {
        let startIndex = offset
        while offset + 4 <= data.count {
             let b1 = data[offset]
             let b2 = data[offset+1]
             let b3 = data[offset+2]
             let b4 = data[offset+3]

             let isLE = (b1 == 0xFE && b2 == 0xFF && b3 == 0xDD && b4 == 0xE0)
             let isBE = (b1 == 0xFF && b2 == 0xFE && b3 == 0xE0 && b4 == 0xDD)

             if isLE || isBE {
                 offset += 8
                 return data.subdata(in: startIndex..<offset-8)
             }
             offset += 1
        }
        return data.subdata(in: startIndex..<data.count)
    }
    
    private func lookupVR(tag: DicomTag) -> VR {
        if tag.group == 0x7FE0 && tag.element == 0x0010 { return .OW } 
        return .UN
    }
    
    private func applyTransferSyntax(_ uid: String) {
        // Implicit VR Little Endian
        if uid == "1.2.840.10008.1.2" {
             isExplicitVR = false
             isLittleEndian = true
             return
        }
        
        // Explicit VR Big Endian
        if uid == "1.2.840.10008.1.2.2" {
             isExplicitVR = true
             isLittleEndian = false
             return
        }
        
        // Default: Explicit VR Little Endian
        // This covers:
        // - 1.2.840.10008.1.2.1 (Explicit VR Little Endian)
        // - 1.2.840.10008.1.2.4.xx (JPEG Encapsulated, always Explicit VR LE)
        // - 1.2.840.10008.1.2.5 (RLE, Explicit VR LE)
        isExplicitVR = true
        isLittleEndian = true
        }
    
    // Fallback: Scan entire data for a specific tag pattern (Explicit VR)
    func findTagRaw(_ target: DicomTag) -> String? {
        let g = target.group
        let e = target.element
        
        let targetBytes: [UInt8]
        if isLittleEndian {
            targetBytes = [
                UInt8(g & 0xFF), UInt8(g >> 8),
                UInt8(e & 0xFF), UInt8(e >> 8)
            ]
        } else {
             targetBytes = [
                 UInt8(g >> 8), UInt8(g & 0xFF),
                 UInt8(e >> 8), UInt8(e & 0xFF)
             ]
        }
        
        // Naive search
        // Optimization: Start searching after meta header (132 + 128?)
        var searchIdx = datasetStart
        
        while searchIdx < min(data.count, 65_536) - 8 {
            if data[searchIdx] == targetBytes[0] &&
               data[searchIdx+1] == targetBytes[1] &&
               data[searchIdx+2] == targetBytes[2] &&
               data[searchIdx+3] == targetBytes[3] {
                
                // Found Tag. Check VR.
                let vrOffset = searchIdx + 4
                guard vrOffset + 2 <= data.count else { return nil }
                
                let vrBytes = data.subdata(in: vrOffset..<vrOffset+2)
                let vrStr = String(data: vrBytes, encoding: .ascii) ?? ""
                
                if VR(rawValue: vrStr) != nil {
                    // Valid explicit VR found
                     var valOffset = vrOffset + 2
                     var length = 0
                     
                     if ["OB", "OD", "OF", "OL", "OV", "OW", "SQ", "SV", "UC", "UN", "UR", "UT", "UV"].contains(vrStr) {
                         valOffset += 2 // Reserved
                         guard valOffset + 4 <= data.count else { break }
                         // Length is 32-bit
                         let lData = data.subdata(in: valOffset..<valOffset+4)
                         length = Int(lData.withUnsafeBytes { $0.load(as: UInt32.self) }) // Endianness?
                         // Assuming LE for simplified scan, or check isLittleEndian
                         if !isLittleEndian {
                             // Fix endian if BE
                             let val = lData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                             length = Int(val)
                         }
                         valOffset += 4
                     } else {
                         // Length is 16-bit
                         guard valOffset + 2 <= data.count else { break }
                         let lData = data.subdata(in: valOffset..<valOffset+2)
                         let val = lData.withUnsafeBytes { $0.load(as: UInt16.self) }
                         length = Int(isLittleEndian ? val : val.bigEndian)
                         valOffset += 2
                     }
                     
                     if length > 0 && length < 1000 && valOffset + length <= data.count {
                         let valData = data.subdata(in: valOffset..<valOffset+length)
                         return String(data: valData, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters).trimmingCharacters(in: .whitespacesAndNewlines)
                             ?? String(data: valData, encoding: .ascii)?.trimmingCharacters(in: .controlCharacters).trimmingCharacters(in: .whitespacesAndNewlines)
                     }
                }
            }
            searchIdx += 1
        }
        return nil
    }
}
