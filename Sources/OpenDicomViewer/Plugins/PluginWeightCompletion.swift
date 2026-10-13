// PluginWeightCompletion.swift
// OpenDicomViewer
//
// What the `.odv-download-complete` marker records, how a weight directory
// written before the marker existed is recognised as finished, and where the
// one shared copy of the Gemma model lives.
// Licensed under the MIT License. See LICENSE for details.

import Foundation

// MARK: - Completion marker

/// The contents of a weight directory's completion marker.
///
/// The marker's existence is what `PluginInstaller.isCompleteDownload` checks.
/// Its contents add the revision the files were fetched at, so another reader
/// -- the built-in AI server, which pins the same Gemma commit -- can tell
/// whether the directory holds the model it would otherwise download. Older
/// markers held only a timestamp; they still mean "complete", with no
/// revision on record.
enum PluginWeightCompletion {

    static func markerContents(revision: String?, date: Date = Date()) -> String {
        var lines = ["completed=" + ISO8601DateFormatter().string(from: date)]
        if let revision, !revision.isEmpty { lines.append("revision=" + revision) }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The revision a marker records, if any.
    static func revision(inMarker text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "revision" {
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    /// The commit a weight directory holds: from the marker when it records
    /// one, else from the hub's own bookkeeping. `snapshot_download` into a
    /// `local_dir` leaves `.cache/huggingface/download/<file>.metadata`, whose
    /// first line is the commit hash the file came from.
    static func recordedRevision(at directory: URL) -> String? {
        let marker = directory.appendingPathComponent(PluginPaths.weightCompletionMarker)
        if let text = try? String(contentsOf: marker, encoding: .utf8),
           let revision = revision(inMarker: text) {
            return revision
        }
        return hubMetadataRevision(at: directory)
    }

    /// The single commit every hub metadata file in `directory` agrees on, or
    /// nil when there are none or they disagree (a half-updated directory).
    static func hubMetadataRevision(at directory: URL) -> String? {
        let metadata = directory.appendingPathComponent(".cache/huggingface/download",
                                                        isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(atPath: metadata.path) else {
            return nil
        }
        var revisions = Set<String>()
        for case let relative as String in enumerator where relative.hasSuffix(".metadata") {
            let url = metadata.appendingPathComponent(relative)
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let first = text.split(whereSeparator: \.isNewline).first else { continue }
            revisions.insert(first.trimmingCharacters(in: .whitespaces))
        }
        return revisions.count == 1 ? revisions.first : nil
    }

    // MARK: Installs from before the marker

    /// Whether a weight directory with no marker nevertheless holds a finished
    /// download.
    ///
    /// Installs made before the marker existed have none, and demoting them
    /// all to "not installed" made every user re-download gigabytes they
    /// already had. A directory passes only when nothing suggests it is
    /// partial:
    ///
    /// - no `*.incomplete` file (the hub's resumable staging) anywhere in it;
    /// - for a Hugging Face weight, `config.json` and the weights present --
    ///   every shard a `model.safetensors.index.json` names, or else at least
    ///   one weight file -- and, when the manifest pins a revision and the hub
    ///   recorded one, the same revision;
    /// - at least 90% of the manifest's `size_gb` on disk, which a download cut
    ///   short almost never reaches (the shards dominate the size).
    static func looksComplete(directory: URL, weight: PluginWeight) -> Bool {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard weight.source != .manual,
              manager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }

        var totalBytes: Int64 = 0
        var names = Set<String>()
        guard let enumerator = manager.enumerator(atPath: directory.path) else { return false }
        while let relative = enumerator.nextObject() as? String {
            if relative.hasSuffix(".incomplete") { return false }
            guard let attributes = enumerator.fileAttributes,
                  attributes[.type] as? FileAttributeType == .typeRegular else { continue }
            if relative.hasPrefix(".cache/") || relative == PluginPaths.weightCompletionMarker {
                continue
            }
            names.insert(relative)
            totalBytes += (attributes[.size] as? NSNumber)?.int64Value ?? 0
        }
        guard !names.isEmpty else { return false }

        if weight.source == .huggingface {
            guard names.contains("config.json") else { return false }
            let index = directory.appendingPathComponent("model.safetensors.index.json")
            if let data = try? Data(contentsOf: index),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let map = object["weight_map"] as? [String: String] {
                guard !map.isEmpty, Set(map.values).isSubset(of: names) else { return false }
            } else {
                let weightSuffixes = [".safetensors", ".bin", ".pt", ".pth"]
                guard names.contains(where: { name in weightSuffixes.contains { name.hasSuffix($0) } })
                else { return false }
            }
            if let pinned = weight.revision, let found = hubMetadataRevision(at: directory),
               found != pinned {
                return false
            }
        }

        let expected = weight.sizeGB * 1_000_000_000
        return Double(totalBytes) >= expected * 0.9
    }

    /// Write the marker for a pre-marker install that `looksComplete`, and
    /// report whether the directory now counts as finished. A directory that
    /// already has a marker is left alone and reported finished.
    @discardableResult
    static func adoptLegacyDownload(at directory: URL, weight: PluginWeight) -> Bool {
        let marker = directory.appendingPathComponent(PluginPaths.weightCompletionMarker)
        if FileManager.default.fileExists(atPath: marker.path) { return true }
        guard looksComplete(directory: directory, weight: weight) else { return false }
        let revision = weight.revision.flatMap { pinned in
            hubMetadataRevision(at: directory) == pinned ? pinned : nil
        }
        do {
            try Data(markerContents(revision: revision).utf8).write(to: marker, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - The shared Gemma model

/// One copy of the Gemma weights for both engines.
///
/// The built-in AI server and the Gemma plugin load the same pinned snapshot.
/// Each used to fetch its own: the server into the Hugging Face hub cache, the
/// plugin into its weight directory under Application Support, 5.2 GB twice.
/// Now whichever engine installs second reuses the first's files:
///
/// - The built-in server loads from the plugin's weight directory when that
///   holds a finished download (completion marker) of the pinned revision,
///   via `ODV_MODEL_DIR`, and never downloads.
/// - The plugin's install hook links the hub-cache snapshot into its weight
///   directory (hard links, so no second copy) when the pinned revision is
///   complete there, and never downloads.
enum SharedGemmaWeights {
    static let pluginID = "gemma-4-e4b"
    static let weightID = "gemma-4-e4b-it-4bit"

    static func pluginDirectory(paths: PluginPaths = .standard) -> URL {
        paths.weightDirectory(pluginID: pluginID, weightID: weightID)
    }

    /// The plugin's weight directory, when it holds `revision` completely.
    static func installedDirectory(revision: String, paths: PluginPaths = .standard) -> URL? {
        let directory = pluginDirectory(paths: paths)
        guard PluginInstaller.isCompleteDownload(at: directory),
              FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("config.json").path),
              PluginWeightCompletion.recordedRevision(at: directory) == revision
        else { return nil }
        return directory
    }
}
