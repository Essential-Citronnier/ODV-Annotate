// AIService.swift
// OpenDicomViewer
//
// HTTP client for communicating with the local MLX Gemma 4 E4B server.
// Provides async methods for AI-assisted DICOM annotation.
// Licensed under the MIT License. See LICENSE for details.

import SwiftUI
import AppKit

// MARK: - Server Status

enum AIServerStatus: Equatable {
    case stopped
    case starting
    case ready
    case error(String)

    var displayText: String {
        switch self {
        case .stopped: return "AI Server Stopped"
        case .starting: return "AI Server Starting..."
        case .ready: return "AI Ready"
        case .error(let msg): return "AI Error: \(msg)"
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var color: Color {
        switch self {
        case .stopped: return .gray
        case .starting: return .yellow
        case .ready: return .green
        case .error: return .red
        }
    }
}

// MARK: - API Data Types

struct AIBoundingBox: Codable, Identifiable {
    var id: String { "\(x)-\(y)-\(width)-\(height)-\(label)" }
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let label: String
    let confidence: Double
}

struct AIAnalysisResult: Codable {
    let findings: [String]
    let bounding_boxes: [AIBoundingBox]
    let description: String
    let raw_response: String?
}

struct AIROIDescription: Codable {
    let label: String
    let description: String
    let confidence: Double
    let raw_response: String?
}

struct AIAbnormalityRegion: Codable, Identifiable {
    var id: String { "\(x)-\(y)-\(label)" }
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let label: String
    let confidence: Double
    let severity: String
}

struct AIDetectAbnormalitiesResponse: Codable {
    let regions: [AIAbnormalityRegion]
    let raw_response: String?
}

struct AIWindowInfo: Codable {
    let modality: String
    let description: String
    let window_center: Double?
    let window_width: Double?
    let body_part: String
}

struct AIHealthResponse: Codable {
    /// "loading" | "ready" | "error"
    let status: String
    let model: String
    let memory_usage_mb: Double?
    /// Server process id; lets the manager confirm a listener is the process it spawned.
    let pid: Int32?
    let revision: String?
    /// Why the model failed to load, when `status == "error"`.
    let error: String?
}

/// Outcome of one /health request.
enum AIHealthProbe: Equatable {
    /// Our server (it accepted this launch's token).
    case ours(status: String, pid: Int32?, error: String?)
    /// Something is listening on the port but rejected our token: another
    /// app, a stale server from an earlier launch, or a hostile listener.
    case foreign
    /// Nothing answered.
    case unreachable
}

// MARK: - Severity

/// Severity of an AI-flagged region, parsed leniently from model output.
///
/// Anything the model invents ("urgent", "", "N/A") maps to `.unknown`, which
/// renders in a neutral colour: a misspelt "Severe" must never look benign.
enum AISeverity: String, CaseIterable {
    case normal, mild, moderate, severe, critical, unknown

    init(parsing raw: String) {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self = AISeverity(rawValue: key) ?? .unknown
    }

    var color: Color {
        switch self {
        case .critical, .severe: return .red
        case .moderate: return .orange
        case .mild: return .yellow
        case .normal: return .green
        case .unknown: return .gray
        }
    }

    var displayName: String { rawValue.capitalized }
}

// MARK: - Box Sanitizing

enum AIBoxSanitizer {
    /// Smallest normalized side kept; thinner boxes are model noise.
    static let minimumSide: Double = 0.002

    /// Clamp a normalized (0-1) box to the image, or nil when nothing usable
    /// is left. The server already does this; the client repeats it so a
    /// differently-behaved server (e.g. one adopted via ODV_AI_TOKEN) cannot
    /// draw outside the image or produce NaN geometry.
    static func normalizedRect(x: Double, y: Double, width: Double, height: Double) -> CGRect? {
        guard [x, y, width, height].allSatisfy(\.isFinite) else { return nil }
        let clamp: (Double) -> Double = { min(max($0, 0), 1) }
        let left = clamp(min(x, x + width)), right = clamp(max(x, x + width))
        let top = clamp(min(y, y + height)), bottom = clamp(max(y, y + height))
        guard right - left >= minimumSide, bottom - top >= minimumSide else { return nil }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// Confidence clamped to [0, 1]; non-finite values become 0.
    static func confidence(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}

struct AIAnalyzeMode: Codable, Identifiable, Hashable {
    let key: String
    let label: String
    let description: String
    var id: String { key }
}

struct AIModesResponse: Codable {
    let modes: [String: AIModeMeta]
    let `default`: String

    struct AIModeMeta: Codable {
        let label: String
        let description: String
    }
}

// MARK: - AI Service

class AIService: ObservableObject {
    static let shared = AIService()

    @Published var serverStatus: AIServerStatus = .stopped
    @Published var isInferencing: Bool = false
    /// Whether the user has acknowledged the "not for diagnostic use" notice.
    /// Persisted so it is shown once per installation, before the first run.
    @Published var hasShownDisclaimer: Bool = UserDefaults.standard.bool(forKey: AIService.disclaimerKey) {
        didSet { UserDefaults.standard.set(hasShownDisclaimer, forKey: AIService.disclaimerKey) }
    }
    @Published var availableModes: [AIAnalyzeMode] = []
    @Published var selectedMode: String = "clinical"

    private static let disclaimerKey = "AIDiagnosticDisclaimerAcknowledged"

    /// Per-launch secret the server requires in `tokenHeader`. Set by
    /// AIServerManager before it launches or adopts a server.
    var authToken: String = ""
    static let tokenHeader = "X-ODV-Token"

    private let baseURL: URL
    private let session: URLSession

    private init() {
        self.baseURL = URL(string: "http://127.0.0.1:8741")!
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120  // model inference can be slow
        config.timeoutIntervalForResource = 180
        self.session = URLSession(configuration: config)
    }

    // MARK: - Health Check

    /// One /health request, classified. Does not touch `serverStatus`.
    func probeHealth() async -> AIHealthProbe {
        var request = authorizedRequest(baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 5
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else {
            return .unreachable
        }
        guard http.statusCode == 200 else { return .foreign }
        guard let health = try? JSONDecoder().decode(AIHealthResponse.self, from: data) else {
            return .foreign
        }
        return .ours(status: health.status, pid: health.pid, error: health.error)
    }

    func checkHealth() async {
        let probe = await probeHealth()
        let status: AIServerStatus
        switch probe {
        case .ours(let state, _, let error):
            switch state {
            case "ready": status = .ready
            case "error": status = .error(error ?? "Model failed to load")
            default: status = .starting
            }
        case .foreign:
            status = .error("Port 8741 is used by another process")
        case .unreachable:
            status = .stopped
        }
        await MainActor.run {
            // A launched server is unreachable until uvicorn binds; that is
            // still "starting". The manager reports a real exit itself.
            if status == .stopped && serverStatus == .starting { return }
            serverStatus = status
        }
        if status.isReady && availableModes.isEmpty {
            await fetchModes()
        }
    }

    /// Poll health until ready, a load error, or timeout.
    func waitForReady(timeout: TimeInterval = 120) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            await checkHealth()
            if serverStatus.isReady { return true }
            if case .error = serverStatus { return false }
            if Task.isCancelled { return false }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return false
    }

    private func authorizedRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(authToken, forHTTPHeaderField: Self.tokenHeader)
        return request
    }

    // MARK: - Disclaimer

    /// Show the one-time "not for diagnostic use" notice. Returns whether the
    /// caller may proceed with an AI run.
    @MainActor
    func confirmDisclaimerIfNeeded() -> Bool {
        guard !hasShownDisclaimer else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "AI output is not for diagnostic use"
        alert.informativeText = """
            The AI assistant runs a general-purpose vision-language model (Gemma 4) \
            locally. Its findings, boxes, severities and confidence values are \
            model-generated, unvalidated, and may be wrong or missing.

            Use it for research and education only. Do not use it to make or \
            support clinical decisions.
            """
        alert.addButton(withTitle: "I Understand")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        hasShownDisclaimer = true
        return true
    }

    // MARK: - Fetch Modes

    func fetchModes() async {
        do {
            let request = authorizedRequest(baseURL.appendingPathComponent("modes"))
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return }
            let decoded = try JSONDecoder().decode(AIModesResponse.self, from: data)
            let modes = decoded.modes.map { key, meta in
                AIAnalyzeMode(key: key, label: meta.label, description: meta.description)
            }.sorted { $0.key < $1.key }
            await MainActor.run {
                self.availableModes = modes
                self.selectedMode = decoded.default
            }
        } catch {
            // Keep existing defaults
        }
    }

    // MARK: - Image Conversion

    private func imageToBase64PNG(_ image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        return pngData.base64EncodedString()
    }

    // MARK: - Analyze Image

    func analyzeImage(_ image: NSImage, modality: String = "Unknown",
                      seriesDescription: String = "", bodyPart: String = "",
                      windowCenter: Double? = nil, windowWidth: Double? = nil,
                      mode: String? = nil) async throws -> AIAnalysisResult {
        guard serverStatus.isReady else {
            throw AIServiceError.serverNotReady
        }
        guard let base64 = imageToBase64PNG(image) else {
            throw AIServiceError.imageConversionFailed
        }

        let windowInfo = AIWindowInfo(
            modality: modality,
            description: seriesDescription,
            window_center: windowCenter,
            window_width: windowWidth,
            body_part: bodyPart
        )

        struct RequestBody: Codable {
            let image: String
            let window_info: AIWindowInfo
            let mode: String
        }

        let body = RequestBody(image: base64, window_info: windowInfo, mode: mode ?? selectedMode)
        return try await post(endpoint: "analyze", body: body)
    }

    // MARK: - Describe ROI

    func describeROI(_ image: NSImage, roi: CGRect, context: String = "") async throws -> AIROIDescription {
        guard serverStatus.isReady else {
            throw AIServiceError.serverNotReady
        }
        guard let base64 = imageToBase64PNG(image) else {
            throw AIServiceError.imageConversionFailed
        }

        struct ROIRect: Codable {
            let x: Double, y: Double, width: Double, height: Double
        }
        struct RequestBody: Codable {
            let image: String
            let roi: ROIRect
            let context: String
        }

        let body = RequestBody(
            image: base64,
            roi: ROIRect(x: roi.origin.x, y: roi.origin.y,
                        width: roi.width, height: roi.height),
            context: context
        )
        return try await post(endpoint: "describe-roi", body: body)
    }

    // MARK: - Detect Abnormalities

    func detectAbnormalities(_ image: NSImage, modality: String = "Unknown") async throws -> AIDetectAbnormalitiesResponse {
        guard serverStatus.isReady else {
            throw AIServiceError.serverNotReady
        }
        guard let base64 = imageToBase64PNG(image) else {
            throw AIServiceError.imageConversionFailed
        }

        struct RequestBody: Codable {
            let image: String
            let modality: String
        }

        let body = RequestBody(image: base64, modality: modality)
        return try await post(endpoint: "detect-abnormalities", body: body)
    }

    // MARK: - HTTP Helper

    private func post<T: Encodable, R: Decodable>(endpoint: String, body: T) async throws -> R {
        var request = authorizedRequest(baseURL.appendingPathComponent(endpoint))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        await MainActor.run { isInferencing = true }
        defer { Task { @MainActor in isInferencing = false } }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIServiceError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 503 {
                throw AIServiceError.serverNotReady
            }
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AIServiceError.serverError(httpResponse.statusCode, errorText)
        }

        return try JSONDecoder().decode(R.self, from: data)
    }
}

// MARK: - Errors

enum AIServiceError: LocalizedError {
    case serverNotReady
    case imageConversionFailed
    case invalidResponse
    case serverError(Int, String)

    var errorDescription: String? {
        switch self {
        case .serverNotReady:
            return "AI server is not running. Start it from the AI menu."
        case .imageConversionFailed:
            return "Failed to convert image for AI analysis."
        case .invalidResponse:
            return "Invalid response from AI server."
        case .serverError(let code, let message):
            return "AI server error (\(code)): \(message)"
        }
    }
}
