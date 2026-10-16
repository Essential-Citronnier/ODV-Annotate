// PluginInstallRecord.swift
// OpenDicomViewer
//
// Persisted installation state for plugin tasks, and the on-disk layout the
// installer and the runtime share. Mirrors the state machine in
// PLUGIN_PROTOCOL.md section 7.
// Licensed under the MIT License. See LICENSE for details.

import Foundation

// MARK: - Filesystem layout

/// Where the plugin subsystem keeps everything it owns.
///
/// Every path is derived from a single `root` so that tests can point the whole
/// subsystem at a temporary directory, and so that no code elsewhere has to
/// reconstruct the Application Support layout by hand.
struct PluginPaths: Sendable, Equatable {
    let root: URL

    init(root: URL) {
        self.root = root
    }

    /// The location used by the running application.
    static var standard: PluginPaths {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return PluginPaths(
            root: appSupport
                .appendingPathComponent("OpenDicomViewer", isDirectory: true)
                .appendingPathComponent("plugins", isDirectory: true))
    }

    /// Plugin identifiers come from a manifest that ships inside the bundle and
    /// is reviewed like source, so they are already trustworthy. Folding them to
    /// a safe character set anyway keeps a future manifest edit from being able
    /// to escape `root` through a path separator or a parent reference.
    static func safeComponent(_ identifier: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let folded = String(identifier.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return folded == "." || folded == ".." || folded.isEmpty ? "plugin" : folded
    }

    var stateFile: URL {
        root.appendingPathComponent("state.json", isDirectory: false)
    }

    func pluginRoot(_ pluginID: String) -> URL {
        root.appendingPathComponent(Self.safeComponent(pluginID), isDirectory: true)
    }

    /// Each plugin gets its own virtualenv: MLX and torch are not co-installable
    /// in practice, and an isolated env confines a broken install to one plugin
    /// (PLUGIN_PROTOCOL.md section 7).
    func venv(_ pluginID: String) -> URL {
        pluginRoot(pluginID).appendingPathComponent(".venv", isDirectory: true)
    }

    func venvPython(_ pluginID: String) -> URL {
        venv(pluginID).appendingPathComponent("bin/python3", isDirectory: false)
    }

    func venvPip(_ pluginID: String) -> URL {
        venv(pluginID).appendingPathComponent("bin/pip", isDirectory: false)
    }

    func weightsRoot(_ pluginID: String) -> URL {
        pluginRoot(pluginID).appendingPathComponent("weights", isDirectory: true)
    }

    func weightDirectory(pluginID: String, weightID: String) -> URL {
        weightsRoot(pluginID).appendingPathComponent(Self.safeComponent(weightID), isDirectory: true)
    }

    /// File the host writes into a downloaded weight directory once the install
    /// hook has exited 0. Its absence means the download never finished
    /// (PLUGIN_PROTOCOL.md section 7).
    static let weightCompletionMarker = ".odv-download-complete"

    /// File the host writes into a plugin's venv once `pip install -r` has
    /// succeeded, holding the SHA-256 of the requirements file it installed.
    /// A mismatch with the adapter's current requirements means the venv was
    /// built for an older lock and must be reinstalled.
    static let requirementsMarker = ".odv-requirements-sha256"

    func requirementsMarker(_ pluginID: String) -> URL {
        venv(pluginID).appendingPathComponent(Self.requirementsMarker, isDirectory: false)
    }

    /// Absolute path a `gated-download` checkpoint must be placed at. The store
    /// shows this string verbatim, so it has to be stable and predictable.
    func manualWeightPath(pluginID: String, weight: PluginWeight) -> URL {
        weightDirectory(pluginID: pluginID, weightID: weight.id)
            .appendingPathComponent(weight.filename ?? "\(weight.id).bin", isDirectory: false)
    }

    /// Scratch parent for one-shot invocations.
    func runsRoot(_ pluginID: String) -> URL {
        pluginRoot(pluginID).appendingPathComponent("runs", isDirectory: true)
    }

    func newRunDirectory(pluginID: String) -> URL {
        runsRoot(pluginID).appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    func createDirectories(for pluginID: String) throws {
        try FileManager.default.createDirectory(at: weightsRoot(pluginID), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runsRoot(pluginID), withIntermediateDirectories: true)
    }
}

// MARK: - Persisted state

/// Codable mirror of `PluginInstallState`.
///
/// `PluginInstallState` carries associated values and is deliberately not
/// Codable; persisting a flat phase plus an optional fraction keeps state.json
/// readable and stops a change to the UI-facing enum from silently invalidating
/// files already on users' disks.
enum PluginInstallPhase: String, Codable, Sendable {
    case notInstalled = "not_installed"
    case resolvingLicense = "resolving_license"
    case downloading
    case installing
    case ready
    case failed
}

struct PluginInstallRecord: Codable, Equatable, Sendable {
    var pluginID: String
    var taskID: String
    var phase: PluginInstallPhase
    var progress: Double?
    var failureMessage: String?
    /// Identifiers of weights whose files have been verified present.
    var installedWeightIDs: [String]
    /// Absolute path per weight id, so `reverify()` can check them without
    /// re-deriving the layout from a manifest that may have changed.
    var weightPaths: [String: String]
    var bytesOnDisk: Int64
    var updatedAt: Date
    var venvPath: String?
    var adapterPath: String?
    /// Whether the task's license gate has been satisfied.
    ///
    /// This is a boolean and nothing else. A `license-key` gate is satisfied by
    /// handing the key to the underlying tool, which stores it in its own
    /// configuration directory; ODV never writes the key here, to the manifest,
    /// or to a log (PLUGIN_PROTOCOL.md section 6).
    var licenseAcknowledged: Bool

    enum CodingKeys: String, CodingKey {
        case pluginID = "plugin_id"
        case taskID = "task_id"
        case phase, progress
        case failureMessage = "failure_message"
        case installedWeightIDs = "installed_weight_ids"
        case weightPaths = "weight_paths"
        case bytesOnDisk = "bytes_on_disk"
        case updatedAt = "updated_at"
        case venvPath = "venv_path"
        case adapterPath = "adapter_path"
        case licenseAcknowledged = "license_acknowledged"
    }

    init(ref: PluginTaskRef,
         phase: PluginInstallPhase = .notInstalled,
         progress: Double? = nil,
         failureMessage: String? = nil,
         installedWeightIDs: [String] = [],
         weightPaths: [String: String] = [:],
         bytesOnDisk: Int64 = 0,
         updatedAt: Date = Date(),
         venvPath: String? = nil,
         adapterPath: String? = nil,
         licenseAcknowledged: Bool = false) {
        self.pluginID = ref.pluginID
        self.taskID = ref.taskID
        self.phase = phase
        self.progress = progress
        self.failureMessage = failureMessage
        self.installedWeightIDs = installedWeightIDs
        self.weightPaths = weightPaths
        self.bytesOnDisk = bytesOnDisk
        self.updatedAt = updatedAt
        self.venvPath = venvPath
        self.adapterPath = adapterPath
        self.licenseAcknowledged = licenseAcknowledged
    }

    var ref: PluginTaskRef { PluginTaskRef(pluginID: pluginID, taskID: taskID) }

    /// Bridge to the enum the store UI binds to.
    var installState: PluginInstallState {
        get {
            switch phase {
            case .notInstalled: return .notInstalled
            case .resolvingLicense: return .resolvingLicense
            case .downloading: return .downloading(progress: progress ?? 0)
            case .installing: return .installing(progress: progress ?? 0)
            case .ready: return .ready
            case .failed: return .failed(failureMessage ?? "Installation failed.")
            }
        }
        set {
            switch newValue {
            case .notInstalled:
                phase = .notInstalled; progress = nil; failureMessage = nil
            case .resolvingLicense:
                phase = .resolvingLicense; progress = nil; failureMessage = nil
            case .downloading(let p):
                phase = .downloading; progress = p; failureMessage = nil
            case .installing(let p):
                phase = .installing; progress = p; failureMessage = nil
            case .ready:
                phase = .ready; progress = nil; failureMessage = nil
            case .failed(let message):
                phase = .failed; progress = nil; failureMessage = message
            }
            updatedAt = Date()
        }
    }
}

/// Envelope written to state.json. The version field lets a later host migrate
/// rather than discard a user's install state.
struct PluginInstallStateFile: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var records: [PluginInstallRecord]

    init(version: Int = PluginInstallStateFile.currentVersion, records: [PluginInstallRecord] = []) {
        self.version = version
        self.records = records
    }
}

// MARK: - Store

/// Reads and writes the install-state file.
///
/// Records are held in memory and flushed on every mutation. Writes go through
/// a temporary file and `rename(2)`, which is atomic within a volume: a crash
/// leaves either the previous state.json or the new one, never a half-written
/// file that would strand every plugin at launch.
final class PluginInstallStore: @unchecked Sendable {
    let paths: PluginPaths

    private let lock = NSLock()
    private var storage: [PluginTaskRef: PluginInstallRecord] = [:]

    /// Called by `reverify` for a ready record whose downloaded weight has no
    /// completion marker: returns whether the directory is a finished download
    /// from before the marker existed, writing the marker if so. Replaceable
    /// in tests; see `PluginWeightCompletion.adoptLegacyDownload`.
    var adoptLegacyDownload: (URL, PluginWeight) -> Bool = {
        PluginWeightCompletion.adoptLegacyDownload(at: $0, weight: $1)
    }

    init(paths: PluginPaths) {
        self.paths = paths
    }

    // MARK: Loading

    /// Load state.json if present. A corrupt or unreadable file is treated as an
    /// empty store rather than a fatal error: losing install bookkeeping costs a
    /// re-verify, whereas refusing to launch costs the user the application.
    @discardableResult
    func load() -> Bool {
        guard let data = try? Data(contentsOf: paths.stateFile) else { return false }
        guard let file = try? Self.decoder.decode(PluginInstallStateFile.self, from: data) else { return false }
        lock.lock()
        storage = Dictionary(uniqueKeysWithValues: file.records.map { ($0.ref, $0) })
        lock.unlock()
        return true
    }

    // MARK: Reading

    var allRecords: [PluginInstallRecord] {
        lock.lock(); defer { lock.unlock() }
        return storage.values.sorted { $0.ref.description < $1.ref.description }
    }

    func record(for ref: PluginTaskRef) -> PluginInstallRecord? {
        lock.lock(); defer { lock.unlock() }
        return storage[ref]
    }

    /// Install state for a task, defaulting to `.notInstalled` for anything the
    /// store has never seen.
    func state(for ref: PluginTaskRef) -> PluginInstallState {
        record(for: ref)?.installState ?? .notInstalled
    }

    /// Every task of `pluginID` the store considers installed to any degree.
    func records(forPlugin pluginID: String) -> [PluginInstallRecord] {
        allRecords.filter { $0.pluginID == pluginID }
    }

    // MARK: Writing

    /// Mutate a record in place, creating it if absent, then persist.
    @discardableResult
    func update(_ ref: PluginTaskRef, _ mutate: (inout PluginInstallRecord) -> Void) throws -> PluginInstallRecord {
        lock.lock()
        var record = storage[ref] ?? PluginInstallRecord(ref: ref)
        mutate(&record)
        record.updatedAt = Date()
        storage[ref] = record
        let snapshot = Array(storage.values)
        lock.unlock()
        try write(snapshot)
        return record
    }

    @discardableResult
    func setState(_ state: PluginInstallState, for ref: PluginTaskRef) throws -> PluginInstallRecord {
        try update(ref) { $0.installState = state }
    }

    func forget(_ ref: PluginTaskRef) throws {
        lock.lock()
        storage[ref] = nil
        let snapshot = Array(storage.values)
        lock.unlock()
        try write(snapshot)
    }

    // MARK: Re-verification

    /// Reconcile persisted state against the filesystem, per PLUGIN_PROTOCOL.md
    /// section 7: a task marked ready whose venv or weights have vanished falls
    /// back to `.notInstalled` here, at launch, rather than failing at first use
    /// with an error the user cannot interpret.
    ///
    /// `fileExists` is injectable so the policy can be tested without staging a
    /// venv on disk.
    ///
    /// Returns the tasks whose state changed.
    @discardableResult
    func reverify(
        manifest: PluginManifest,
        venvIsCurrent: (PluginDescriptor) -> Bool = { _ in true },
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [PluginTaskRef] {
        lock.lock()
        var changed: [PluginTaskRef] = []
        var updated = storage

        for (ref, record) in storage {
            // A task that left the manifest has no store row to display and no
            // adapter to run; drop it rather than keeping an orphan.
            guard let plugin = manifest.plugin(id: ref.pluginID),
                  let task = plugin.task(id: ref.taskID) else {
                updated[ref] = nil
                changed.append(ref)
                continue
            }

            var revised = record
            switch record.phase {
            case .downloading, .installing:
                // No supervisor survived whatever ended the last session, so the
                // environment is half-built. Start over rather than resume.
                revised.installState = .notInstalled
            case .ready:
                if let demoted = Self.demotion(for: record, task: task, fileExists: fileExists,
                                               adoptLegacy: adoptLegacyDownload) {
                    revised.installState = demoted
                } else if record.venvPath != nil && !venvIsCurrent(plugin) {
                    // The adapter's requirements changed since this venv was
                    // built (an app update moved the lock). Reinstalling re-runs
                    // pip into a fresh venv and reuses the weights on disk.
                    revised.installState = .notInstalled
                }
            default:
                break
            }

            if revised.phase != record.phase {
                revised.updatedAt = Date()
                updated[ref] = revised
                changed.append(ref)
            }
        }

        storage = updated
        let snapshot = Array(storage.values)
        lock.unlock()

        if !changed.isEmpty {
            try? write(snapshot)
        }
        return changed.sorted { $0.description < $1.description }
    }

    /// The reason a `ready` record is no longer ready, or nil if it still is.
    private static func demotion(
        for record: PluginInstallRecord,
        task: PluginTask,
        fileExists: (String) -> Bool,
        adoptLegacy: (URL, PluginWeight) -> Bool
    ) -> PluginInstallState? {
        if task.license.gate != .open && !record.licenseAcknowledged {
            return .resolvingLicense
        }
        if let venv = record.venvPath, !fileExists(venv) {
            return .notInstalled
        }
        for weight in task.weights {
            guard let path = record.weightPaths[weight.id] else { return .notInstalled }
            if !fileExists(path) {
                // A manually placed checkpoint that disappeared is a license-gate
                // problem again, not a download the host can retry on its own.
                return weight.source == .manual ? .resolvingLicense : .notInstalled
            }
            // Section 7: a downloaded weight counts as present only with the
            // completion marker. Without it the directory may hold a download
            // a crash cut short -- or a finished one from before the marker
            // existed, which is adopted when it looks complete. Otherwise
            // re-installing re-runs the hook, which resumes into the same
            // directory rather than starting over.
            if weight.source != .manual {
                let directory = URL(fileURLWithPath: path)
                let marker = directory.appendingPathComponent(PluginPaths.weightCompletionMarker).path
                if !fileExists(marker) && !adoptLegacy(directory, weight) { return .notInstalled }
            }
        }
        return nil
    }

    // MARK: Atomic persistence

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func write(_ records: [PluginInstallRecord]) throws {
        let file = PluginInstallStateFile(
            records: records.sorted { $0.ref.description < $1.ref.description })
        let data = try Self.encoder.encode(file)

        let directory = paths.stateFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let temporary = directory.appendingPathComponent(".state-\(UUID().uuidString).tmp")
        try data.write(to: temporary)
        guard rename(temporary.path, paths.stateFile.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw PluginError.transport("Could not persist plugin state (errno \(code)).")
        }
    }
}

// MARK: - Disk accounting

enum PluginDiskUsage {
    /// Bytes allocated beneath `url`, or zero when the path does not exist.
    ///
    /// Uses allocated rather than logical size so the figure shown in the store
    /// matches what the user would recover by removing the plugin.
    static func bytes(at url: URL) -> Int64 {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return 0 }
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = manager.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [], errorHandler: nil) else { return 0 }

        var total: Int64 = 0
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}
