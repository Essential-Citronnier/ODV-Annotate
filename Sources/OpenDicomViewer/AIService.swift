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
    let status: String
    let model: String
    let memory_usage_mb: Double?
}

// MARK: - AI Service

class AIService: ObservableObject {
    static let shared = AIService()

    @Published var serverStatus: AIServerStatus = .stopped
    @Published var isInferencing: Bool = false
    @Published var hasShownDisclaimer: Bool = false

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

    func checkHealth() async {
        do {
            let url = baseURL.appendingPathComponent("health")
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                await MainActor.run { serverStatus = .error("Unexpected response") }
                return
            }
            let health = try JSONDecoder().decode(AIHealthResponse.self, from: data)
            await MainActor.run {
                serverStatus = health.status == "ready" ? .ready : .starting
            }
        } catch {
            await MainActor.run {
                serverStatus = .stopped
            }
        }
    }

    /// Poll health until ready or timeout
    func waitForReady(timeout: TimeInterval = 120) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            await checkHealth()
            if serverStatus.isReady { return true }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return false
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
                      windowCenter: Double? = nil, windowWidth: Double? = nil) async throws -> AIAnalysisResult {
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
        }

        let body = RequestBody(image: base64, window_info: windowInfo)
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
        let url = baseURL.appendingPathComponent(endpoint)
        var request = URLRequest(url: url)
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
