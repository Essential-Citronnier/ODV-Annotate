// VolumeCache.swift
// OpenDicomViewer
//
// Keying and LRU bookkeeping for built 3D volumes. A volume is identified by
// its series plus the exact set of files it was built from, so a series that
// gains images during a scan (or a re-load of a different study reusing the
// same SeriesInstanceUID) never serves a stale volume.
// Licensed under the MIT License. See LICENSE for details.

import Foundation

enum VolumeCacheKey {
    /// "<series id>#<file count>-<hash of sorted file paths>"
    static func make(for series: DicomSeries) -> String {
        make(seriesID: series.id, paths: series.images.map { $0.url.path })
    }

    static func make(seriesID: String, paths: [String]) -> String {
        // FNV-1a over the sorted paths: stable across runs (unlike Hasher)
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for path in paths.sorted() {
            for byte in path.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01B3
            }
            hash ^= 0xFF
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return "\(seriesID)#\(paths.count)-\(String(hash, radix: 16))"
    }
}

/// Least-recently-used volume cache bounded by entry count and total bytes.
/// Not thread-safe; callers hold their own lock.
struct VolumeLRUCache {
    let maxEntries: Int
    let maxBytes: Int
    private var entries: [String: (volume: VolumeData, lastUse: UInt64)] = [:]
    private var clock: UInt64 = 0

    init(maxEntries: Int, maxBytes: Int) {
        self.maxEntries = max(1, maxEntries)
        self.maxBytes = maxBytes
    }

    var count: Int { entries.count }
    var totalBytes: Int { entries.values.reduce(0) { $0 + $1.volume.memoryBytes } }
    var keys: [String] { Array(entries.keys) }

    mutating func get(_ key: String) -> VolumeData? {
        guard let entry = entries[key] else { return nil }
        clock += 1
        entries[key] = (entry.volume, clock)
        return entry.volume
    }

    mutating func set(_ key: String, _ volume: VolumeData) {
        clock += 1
        entries[key] = (volume, clock)
        // Evict least recently used, always keeping the newest entry
        while entries.count > 1 && (entries.count > maxEntries || totalBytes > maxBytes) {
            guard let oldest = entries.filter({ $0.key != key }).min(by: { $0.value.lastUse < $1.value.lastUse })?.key else { break }
            entries.removeValue(forKey: oldest)
        }
    }

    mutating func removeAll() {
        entries.removeAll()
    }
}
