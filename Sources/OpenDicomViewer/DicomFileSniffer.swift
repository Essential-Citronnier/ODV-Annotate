// DicomFileSniffer.swift
// OpenDicomViewer
//
// Cheap content-based DICOM detection for directory scanning. Files are
// accepted regardless of extension when they carry the Part 10 "DICM" magic
// at offset 128 or start with a plausible preamble-less dataset. Obvious
// non-DICOM files are rejected by extension/name before any I/O.
// Licensed under the MIT License. See LICENSE for details.

import Foundation

enum DicomFileSniffer {
    /// Extensions that are never DICOM; skipped without reading the file.
    static let nonDicomExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "bmp", "tif", "tiff", "heic", "webp", "svg",
        "txt", "md", "rtf", "csv", "tsv", "json", "xml", "html", "htm", "yaml", "yml", "ini", "log",
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "zip", "gz", "tgz", "bz2", "xz", "7z", "rar", "tar", "dmg", "iso",
        "exe", "dll", "so", "dylib", "app", "bat", "sh", "py", "js", "swift", "plist",
        "mp4", "mov", "avi", "mkv", "mp3", "wav", "m4a",
        "nii", "nrrd", "mha", "mhd", "raw", "stl", "obj",
    ]

    /// Names that are never images.
    private static let skippedNames: Set<String> = ["DICOMDIR", "LOCKFILE", "VERSION", ".DS_STORE", "THUMBS.DB", "DESKTOP.INI"]

    /// Returns true when the file should be handed to the DICOM parsers.
    static func isCandidate(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if name.hasPrefix(".") { return false }
        if skippedNames.contains(name.uppercased()) { return false }
        if nonDicomExtensions.contains(url.pathExtension.lowercased()) { return false }
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        let header = (try? fh.read(upToCount: 132)) ?? Data()
        return SimpleDicomParser.isLikelyDICOM(header: header)
    }
}
