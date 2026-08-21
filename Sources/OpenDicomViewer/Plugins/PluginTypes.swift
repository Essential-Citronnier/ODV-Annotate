// PluginTypes.swift
// OpenDicomViewer
//
// Shared vocabulary for the plugin layer: manifest model, capability kinds,
// install state, and result payloads. See PLUGIN_PROTOCOL.md for the normative
// contract this mirrors.
// Licensed under the MIT License. See LICENSE for details.

import Foundation
import CoreGraphics

// MARK: - Protocol version

/// Major protocol version this host speaks. A plugin reporting a different
/// major version is refused rather than called.
let kPluginProtocolVersion = 1

// MARK: - Execution model

/// How the host supervises a plugin's process.
enum PluginExecution: String, Codable, Sendable {
    /// Long-lived HTTP server; independent one-shot requests.
    case residentServer = "resident-server"
    /// Long-lived HTTP server holding per-image encoder state across requests.
    case session
    /// Subprocess spawned per invocation; exits when done.
    case oneShot = "one-shot"

    /// Whether the host keeps a process alive between invocations.
    var isResident: Bool { self != .oneShot }
}

// MARK: - Capability kinds

/// What a task consumes.
enum PluginInputKind: String, Codable, Sendable {
    /// One rendered slice, transported as base64 PNG.
    case slice2d
    /// A DICOM series directory, transported as a filesystem path.
    case series3d
    /// Normalized rect, 0–1.
    case roi
    /// Normalized click prompts with foreground/background labels.
    case points
    /// Normalized box prompt.
    case box
    /// Free text (prompt or clinical context).
    case text
}

/// What a task produces, and therefore which host renderer receives it.
enum PluginOutputKind: String, Codable, Sendable {
    case text
    case bbox
    case mask2d
    /// Path to a binary DICOM SEG file.
    case seg3d
    case metrics
}

// MARK: - License gating

enum PluginLicenseGate: String, Codable, Sendable {
    /// Weights download without conditions.
    case open
    /// User must register a license key locally before weights resolve.
    case licenseKey = "license-key"
    /// User must accept terms externally and place the checkpoint manually.
    case gatedDownload = "gated-download"
}

struct PluginLicense: Codable, Sendable, Equatable {
    let gate: PluginLicenseGate
    /// Human-readable license name, e.g. "Apache-2.0".
    let identifier: String
    let termsURL: String?
    /// Expected prefix of a license key, e.g. "aca_". Used for input validation only.
    let keyFormat: String?
    /// Shown verbatim in the store when the gate is not `open`.
    let instructions: String?

    enum CodingKeys: String, CodingKey {
        case gate, identifier
        case termsURL = "terms_url"
        case keyFormat = "key_format"
        case instructions
    }
}

// MARK: - Weights

/// Where a weight artifact comes from. The store never executes remote code;
/// these describe data downloads only.
enum PluginWeightSource: String, Codable, Sendable {
    case huggingface
    /// Fetched through TotalSegmentator's own weight downloader.
    case totalsegTask = "totalseg-task"
    /// User places the file manually (gated download).
    case manual
}

struct PluginWeight: Codable, Sendable, Equatable {
    let id: String
    let source: PluginWeightSource
    /// Hugging Face repo id, when applicable.
    let repo: String?
    /// TotalSegmentator task name, when applicable.
    let task: String?
    /// Expected filename for manually placed checkpoints.
    let filename: String?
    let sizeGB: Double

    enum CodingKeys: String, CodingKey {
        case id, source, repo, task, filename
        case sizeGB = "size_gb"
    }
}

// MARK: - Task options

/// A user-adjustable knob a task exposes. Kept deliberately small: enum, bool,
/// or number. Anything richer belongs in the adapter's own defaults.
struct PluginOption: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case `enum`, bool, number
    }

    let type: Kind
    let label: String?
    let values: [String]?
    let defaultValue: OptionValue?

    enum CodingKeys: String, CodingKey {
        case type, label, values
        case defaultValue = "default"
    }

    /// Heterogeneous default: string for enum, bool for bool, double for number.
    enum OptionValue: Codable, Sendable, Equatable {
        case string(String)
        case bool(Bool)
        case number(Double)

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) { self = .bool(b); return }
            if let d = try? c.decode(Double.self) { self = .number(d); return }
            if let s = try? c.decode(String.self) { self = .string(s); return }
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "Unsupported option default")
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let s): try c.encode(s)
            case .bool(let b): try c.encode(b)
            case .number(let d): try c.encode(d)
            }
        }
    }
}

// MARK: - Manifest

struct PluginTask: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let label: String
    let summary: String
    let inputs: [PluginInputKind]
    let outputs: [PluginOutputKind]
    let license: PluginLicense
    let weights: [PluginWeight]
    let options: [String: PluginOption]?
    /// Peak memory for this task, when it differs from the plugin's figure.
    ///
    /// Tasks within one plugin can have footprints that differ by an order of
    /// magnitude — a full-resolution whole-body segmentation against a 3 mm one —
    /// and the arbiter admits work against a declaration, so a single
    /// plugin-wide number is either wrong for the heavy task or needlessly
    /// pessimistic for the light one. Optional: when absent the plugin's
    /// `ram_gb` applies.
    let ramGB: Double?

    enum CodingKeys: String, CodingKey {
        case id, label, summary, inputs, outputs, license, weights, options
        case ramGB = "ram_gb"
    }

    /// Total download size for this task's weights, in GB.
    var weightsSizeGB: Double { weights.reduce(0) { $0 + $1.sizeGB } }
}

struct PluginDescriptor: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let name: String
    let vendor: String
    let summary: String
    let execution: PluginExecution
    /// Directory under `plugins/` holding the adapter.
    let adapterDir: String
    /// Adapter entry point relative to `adapterDir`.
    let entry: String
    let requirements: String
    /// Declared peak resident memory. The arbiter admits work against this.
    let ramGB: Double
    /// Declared disk footprint of the environment, excluding weights.
    let diskGB: Double
    let maxSessions: Int?
    let requiresAppleSilicon: Bool
    let tasks: [PluginTask]

    enum CodingKeys: String, CodingKey {
        case id, name, vendor, summary, execution, entry, requirements, tasks
        case adapterDir = "adapter_dir"
        case ramGB = "ram_gb"
        case diskGB = "disk_gb"
        case maxSessions = "max_sessions"
        case requiresAppleSilicon = "requires_apple_silicon"
    }

    func task(id taskID: String) -> PluginTask? {
        tasks.first { $0.id == taskID }
    }

    /// Declared peak memory for a task: the task's own figure when it carries
    /// one, otherwise the plugin's. Callers should always budget through this
    /// rather than reading `ramGB` directly, so a per-task declaration is never
    /// silently ignored.
    func declaredRAMGB(forTask taskID: String) -> Double {
        task(id: taskID)?.ramGB ?? ramGB
    }
}

struct PluginManifest: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let protocolVersion: Int
    let plugins: [PluginDescriptor]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case protocolVersion = "protocol"
        case plugins
    }

    func plugin(id: String) -> PluginDescriptor? {
        plugins.first { $0.id == id }
    }

    /// Load the manifest bundled with the app.
    ///
    /// The manifest ships inside the bundle by design — the store never fetches
    /// a plugin list from the network, so the set of installable plugins is
    /// fixed at build time and reviewable in version control.
    static func loadBundled() throws -> PluginManifest {
        guard let url = Bundle.main.url(forResource: "plugins", withExtension: "json") else {
            throw PluginError.manifestMissing
        }
        return try load(contentsOf: url)
    }

    static func load(contentsOf url: URL) throws -> PluginManifest {
        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        guard manifest.protocolVersion == kPluginProtocolVersion else {
            throw PluginError.protocolMismatch(
                expected: kPluginProtocolVersion, found: manifest.protocolVersion)
        }
        return manifest
    }
}

// MARK: - Task addressing

/// Fully qualifies a task across plugins. Used as a dictionary key for install
/// state and as the unit the store lists.
struct PluginTaskRef: Hashable, Codable, Sendable, CustomStringConvertible {
    let pluginID: String
    let taskID: String

    var description: String { "\(pluginID)/\(taskID)" }
}

// MARK: - Install state

enum PluginInstallState: Equatable, Sendable {
    case notInstalled
    /// Gated task awaiting a license key or a manually placed checkpoint.
    case resolvingLicense
    case downloading(progress: Double)
    case installing(progress: Double)
    case ready
    case failed(String)

    var isReady: Bool { self == .ready }

    var isBusy: Bool {
        switch self {
        case .downloading, .installing: return true
        default: return false
        }
    }

    /// Fractional progress for the store's progress bar, when meaningful.
    var progress: Double? {
        switch self {
        case .downloading(let p), .installing(let p): return p
        default: return nil
        }
    }

    var displayText: String {
        switch self {
        case .notInstalled: return "Not installed"
        case .resolvingLicense: return "License required"
        case .downloading(let p): return "Downloading… \(Int(p * 100))%"
        case .installing(let p): return "Installing… \(Int(p * 100))%"
        case .ready: return "Ready"
        case .failed(let m): return "Failed: \(m)"
        }
    }
}

// MARK: - Runtime state

/// Lifecycle of a resident plugin process.
enum PluginRuntimeState: Equatable, Sendable {
    case stopped
    case starting
    case ready
    case stopping
    case error(String)

    var isReady: Bool { self == .ready }
}

// MARK: - Invocation payloads

/// Inputs for one task invocation, assembled by the host from panel state.
struct PluginInvocation: Sendable {
    var sessionID: String?
    /// Base64-encoded PNG of the rendered slice.
    var slice2d: String?
    /// Filesystem path to a DICOM series directory.
    var series3d: String?
    var roi: CGRect?
    var points: [PluginPoint]?
    var box: CGRect?
    var text: String?
    var options: [String: PluginOption.OptionValue] = [:]
}

/// A normalized click prompt. `isForeground == false` marks a background
/// (subtractive) click in SAM-style prompting.
struct PluginPoint: Codable, Sendable, Equatable {
    let x: Double
    let y: Double
    let isForeground: Bool

    enum CodingKeys: String, CodingKey {
        case x, y
        case isForeground = "label"
    }

    init(x: Double, y: Double, isForeground: Bool) {
        self.x = x
        self.y = y
        self.isForeground = isForeground
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        isForeground = (try c.decode(Int.self, forKey: .isForeground)) != 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
        try c.encode(isForeground ? 1 : 0, forKey: .isForeground)
    }
}

// MARK: - Result payloads

struct PluginBoundingBox: Codable, Sendable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let label: String
    let confidence: Double
    /// Optional severity tag, used by abnormality-style tasks.
    let severity: String?
}

/// A 2D mask, run-length encoded row-major starting with a background run.
/// See PLUGIN_PROTOCOL.md §5.
struct PluginMask2D: Codable, Sendable, Equatable {
    let width: Int
    let height: Int
    let rle: [Int]
    let label: String?
    let confidence: Double?

    /// Decode the run-length encoding into a row-major boolean bitmap.
    ///
    /// Returns nil when the runs do not sum to `width * height`, which is the
    /// only structural error the encoding admits.
    func decodeMask() -> [Bool]? {
        let total = width * height
        guard total > 0 else { return nil }
        var out = [Bool](repeating: false, count: total)
        var index = 0
        var isForeground = false
        for run in rle {
            guard run >= 0, index + run <= total else { return nil }
            if isForeground && run > 0 {
                for i in index..<(index + run) { out[i] = true }
            }
            index += run
            isForeground.toggle()
        }
        return index == total ? out : nil
    }
}

/// Everything a task can return. Only the kinds the task declared are populated.
struct PluginResult: Sendable {
    var text: String?
    var bboxes: [PluginBoundingBox] = []
    var masks: [PluginMask2D] = []
    /// Absolute path to a binary DICOM SEG file.
    var seg3dPath: String?
    var metrics: [String: Double] = [:]
    var elapsedMS: Int?
    /// Unparsed model output, retained for the inspector's raw view.
    var raw: String?
}

// MARK: - Errors

/// Error codes the protocol defines. `licenseRequired` is routed to the store's
/// license gate rather than shown as a generic failure.
enum PluginErrorCode: String, Codable, Sendable {
    case notReady = "not_ready"
    case badInput = "bad_input"
    case licenseRequired = "license_required"
    case outOfMemory = "out_of_memory"
    case internalError = "internal"
}

enum PluginError: LocalizedError, Equatable {
    case manifestMissing
    case protocolMismatch(expected: Int, found: Int)
    case unknownPlugin(String)
    case unknownTask(PluginTaskRef)
    case notInstalled(PluginTaskRef)
    case notReady(String)
    case licenseRequired(PluginTaskRef, message: String)
    case insufficientMemory(required: Double, available: Double)
    case unsupportedInput(PluginInputKind)
    case adapter(code: PluginErrorCode, message: String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .manifestMissing:
            return "Plugin manifest not found in the application bundle."
        case .protocolMismatch(let expected, let found):
            return "Plugin protocol mismatch: host speaks v\(expected), manifest declares v\(found)."
        case .unknownPlugin(let id):
            return "Unknown plugin: \(id)"
        case .unknownTask(let ref):
            return "Unknown task: \(ref)"
        case .notInstalled(let ref):
            return "\(ref) is not installed. Install it from the Plugin Store."
        case .notReady(let detail):
            return "Plugin is not ready: \(detail)"
        case .licenseRequired(_, let message):
            return message
        case .insufficientMemory(let required, let available):
            return String(format: "Not enough memory: %.1f GB required, %.1f GB available.",
                          required, available)
        case .unsupportedInput(let kind):
            return "This task does not accept \(kind.rawValue) input."
        case .adapter(_, let message):
            return message
        case .transport(let detail):
            return "Could not reach the plugin process: \(detail)"
        }
    }
}
