// LocalAIEnvironment.swift
// OpenDicomViewer
//
// Small, testable pieces of the local-AI setup shared by the built-in server
// (AIServerManager) and the plugin installer: whether an existing virtualenv
// still belongs to the interpreter that would recreate it, the system proxy
// translated into the variables pip and huggingface_hub read, free disk space,
// and where the Hugging Face hub cache keeps a model snapshot.
// Licensed under the MIT License. See LICENSE for details.

import Foundation
import CFNetwork

// MARK: - Virtualenv validity

/// A venv records the interpreter it was made from in `pyvenv.cfg` and links
/// `bin/python3` to it. When the app that bundles that interpreter moves (run
/// from the DMG, from an App Translocation path, or dragged elsewhere), the
/// links dangle or point at a stale copy, and the venv must be rebuilt.
enum PythonVenvCheck {

    /// `key = value` lines of a pyvenv.cfg.
    static func parseConfig(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    /// Whether a venv's config names `expectedHome` (the interpreter's bin
    /// directory) and, when known, the same major.minor Python version.
    static func configMatches(_ config: [String: String],
                              expectedHome: String,
                              expectedMajorMinor: String?) -> Bool {
        guard let home = config["home"], !home.isEmpty else { return false }
        guard canonical(home) == canonical(expectedHome) else { return false }
        if let expectedMajorMinor {
            // Python 3.11+ writes `version`; virtualenv-made envs `version_info`.
            guard let version = config["version"] ?? config["version_info"] else { return false }
            let parts = version.split(separator: ".")
            guard parts.count >= 2, "\(parts[0]).\(parts[1])" == expectedMajorMinor else {
                return false
            }
        }
        return true
    }

    /// Whether the venv at `venv` is usable with the interpreter at `python`
    /// (a `.../bin/python3` path). When `python` is nil (a development build
    /// using whatever Python it found) only the venv's own interpreter link is
    /// checked.
    static func isUsable(venv: URL, python: String?) -> Bool {
        let venvPython = venv.appendingPathComponent("bin/python3").path
        // fileExists follows the symlink, so a dangling link reads as absent.
        guard FileManager.default.fileExists(atPath: venvPython) else { return false }
        guard let python else { return true }
        guard let text = try? String(contentsOf: venv.appendingPathComponent("pyvenv.cfg"),
                                     encoding: .utf8) else { return false }
        let bin = URL(fileURLWithPath: python).deletingLastPathComponent()
        return configMatches(parseConfig(text), expectedHome: bin.path,
                             expectedMajorMinor: majorMinorVersion(ofPythonAt: python))
    }

    /// major.minor of a python-build-standalone layout, read from its
    /// `lib/pythonX.Y` directory so no process has to be run.
    static func majorMinorVersion(ofPythonAt python: String) -> String? {
        let lib = URL(fileURLWithPath: python)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: lib.path) else {
            return nil
        }
        let versions = entries.filter { $0.hasPrefix("python3.") }
            .map { String($0.dropFirst("python".count)) }
        return versions.count == 1 ? versions[0] : nil
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

// MARK: - System proxy

/// The macOS proxy configuration translated into HTTP(S)_PROXY / NO_PROXY.
///
/// Python's networking stack (pip, httpx, requests) knows nothing of the
/// system proxy settings, so behind a corporate proxy every download failed
/// with a timeout the user could not act on. Variables already present in the
/// environment win: a developer who exported them meant them.
enum SystemProxyEnvironment {

    /// Variables for `settings` (a CFNetworkCopySystemProxySettings dictionary).
    static func variables(from settings: [String: Any]) -> [String: String] {
        func enabled(_ key: String) -> Bool {
            (settings[key] as? NSNumber)?.boolValue ?? false
        }
        func proxyURL(hostKey: String, portKey: String) -> String? {
            guard let host = settings[hostKey] as? String, !host.isEmpty else { return nil }
            let port = (settings[portKey] as? NSNumber)?.intValue
            return "http://\(host)" + (port.map { ":\($0)" } ?? "")
        }

        var result: [String: String] = [:]
        if enabled("HTTPSEnable"), let url = proxyURL(hostKey: "HTTPSProxy", portKey: "HTTPSPort") {
            result["HTTPS_PROXY"] = url
            result["https_proxy"] = url
        }
        if enabled("HTTPEnable"), let url = proxyURL(hostKey: "HTTPProxy", portKey: "HTTPPort") {
            result["HTTP_PROXY"] = url
            result["http_proxy"] = url
            // An HTTP-only proxy is what many networks configure for both.
            if result["HTTPS_PROXY"] == nil {
                result["HTTPS_PROXY"] = url
                result["https_proxy"] = url
            }
        }
        guard !result.isEmpty else { return [:] }

        var exceptions = ["127.0.0.1", "localhost", "::1"]
        if let list = settings["ExceptionsList"] as? [String] {
            // Python's NO_PROXY matches suffixes; "*.corp" becomes ".corp".
            exceptions += list.map { $0.hasPrefix("*.") ? String($0.dropFirst()) : $0 }
        }
        let noProxy = exceptions.joined(separator: ",")
        result["NO_PROXY"] = noProxy
        result["no_proxy"] = noProxy
        return result
    }

    /// Whether the system uses a PAC file, which cannot be translated.
    static func usesAutoConfig(_ settings: [String: Any]) -> Bool {
        (settings["ProxyAutoConfigEnable"] as? NSNumber)?.boolValue ?? false
    }

    static func currentSettings() -> [String: Any] {
        guard let unmanaged = CFNetworkCopySystemProxySettings() else { return [:] }
        return (unmanaged.takeRetainedValue() as? [String: Any]) ?? [:]
    }

    /// `environment` with the system proxy added where it sets none itself.
    static func applying(to environment: [String: String],
                         settings: [String: Any] = currentSettings()) -> [String: String] {
        let alreadySet = ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy",
                          "ALL_PROXY", "all_proxy"].contains { environment[$0] != nil }
        guard !alreadySet else { return environment }
        var result = environment
        for (key, value) in variables(from: settings) where result[key] == nil {
            result[key] = value
        }
        return result
    }
}

// MARK: - Disk space

enum LocalAIDiskSpace {
    /// Bytes available for important usage on the volume holding `url`.
    static func availableBytes(at url: URL = FileManager.default.homeDirectoryForCurrentUser) -> Int64? {
        var probe = url
        // The directory may not exist yet; ask about its nearest ancestor.
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// A user-facing message when fewer than `requiredBytes` are free, else nil.
    static func shortfallMessage(requiredBytes: Int64, availableBytes: Int64?, what: String) -> String? {
        guard let availableBytes, availableBytes < requiredBytes else { return nil }
        let gb: (Int64) -> String = { String(format: "%.1f", Double($0) / 1_000_000_000) }
        return "Not enough disk space: \(gb(availableBytes)) GB available, about "
            + "\(gb(requiredBytes)) GB needed for \(what).\nFree up space and try again."
    }
}

// MARK: - Hugging Face cache

enum HuggingFaceCache {
    /// The hub cache directory, honouring HF_HUB_CACHE and HF_HOME as
    /// huggingface_hub does.
    static func hubDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let explicit = environment["HF_HUB_CACHE"], !explicit.isEmpty {
            return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
        }
        let home = environment["HF_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/huggingface").path
        return URL(fileURLWithPath: (home as NSString).expandingTildeInPath)
            .appendingPathComponent("hub")
    }

    /// Whether `repo` at `revision` (a commit hash) is fully in the cache.
    static func snapshotExists(repo: String, revision: String,
                               environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let snapshot = hubDirectory(environment: environment)
            .appendingPathComponent("models--" + repo.replacingOccurrences(of: "/", with: "--"))
            .appendingPathComponent("snapshots")
            .appendingPathComponent(revision)
        let manager = FileManager.default
        guard manager.fileExists(atPath: snapshot.appendingPathComponent("config.json").path),
              let entries = try? manager.contentsOfDirectory(atPath: snapshot.path) else { return false }
        // Each file is linked in as it finishes, so an interrupted download
        // can leave config.json without the weights.
        return entries.contains { name in
            name.hasSuffix(".safetensors")
                && manager.fileExists(atPath: snapshot.appendingPathComponent(name).path)
        }
    }
}
