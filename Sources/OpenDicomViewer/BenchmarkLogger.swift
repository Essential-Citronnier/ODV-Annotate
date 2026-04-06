// BenchmarkLogger.swift
// OpenDicomViewer
//
// Lightweight performance logger for manuscript benchmarks.
// Logs timing data to stderr and to ~/Desktop/odv_benchmark.csv.
// Enable by setting BENCHMARK_MODE=1 environment variable or
// launching with --benchmark flag.
// Licensed under the MIT License. See LICENSE for details.

import Foundation
import Darwin

struct MemorySnapshot {
    let footprintMB: Double   // phys_footprint — matches Activity Monitor "Memory"
    let internalMB: Double    // dirty memory (heap allocs, can't be evicted)
    let compressedMB: Double  // pages compressed by the OS
    let purgeableMB: Double   // purgeable (NSCache etc, OS can discard freely)
}

final class BenchmarkLogger {
    static let shared = BenchmarkLogger()

    let enabled: Bool
    private let logURL: URL
    private let lock = NSLock()
    private var timers: [String: CFAbsoluteTime] = [:]

    private init() {
        enabled = ProcessInfo.processInfo.environment["BENCHMARK_MODE"] == "1"
            || CommandLine.arguments.contains("--benchmark")

        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        logURL = desktop.appendingPathComponent("odv_benchmark.csv")

        if enabled {
            // Write CSV header if file doesn't exist
            if !FileManager.default.fileExists(atPath: logURL.path) {
                let header = "timestamp,event,dataset,value_ms,footprint_mb,dirty_mb,compressed_mb,purgeable_mb,detail\n"
                try? header.write(to: logURL, atomically: true, encoding: .utf8)
            }
            log(event: "session_start", detail: "Benchmark session started")
        }
    }

    /// Start a named timer
    func start(_ name: String) {
        guard enabled else { return }
        lock.lock()
        timers[name] = CFAbsoluteTimeGetCurrent()
        lock.unlock()
    }

    /// Stop a named timer and log the elapsed time
    @discardableResult
    func stop(_ name: String, dataset: String = "", detail: String = "") -> Double {
        guard enabled else { return 0 }
        lock.lock()
        let startTime = timers.removeValue(forKey: name)
        lock.unlock()

        guard let start = startTime else { return 0 }
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0 // ms
        log(event: name, dataset: dataset, valueMs: elapsed, detail: detail)
        return elapsed
    }

    /// Log a single event with optional value
    func log(event: String, dataset: String = "", valueMs: Double = 0, detail: String = "") {
        guard enabled else { return }

        let mem = currentMemorySnapshot()
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "\(ts),\(event),\(dataset)," +
            "\(String(format: "%.1f", valueMs))," +
            "\(String(format: "%.1f", mem.footprintMB))," +
            "\(String(format: "%.1f", mem.internalMB))," +
            "\(String(format: "%.1f", mem.compressedMB))," +
            "\(String(format: "%.1f", mem.purgeableMB))," +
            "\(detail)"

        // Print to stderr for real-time monitoring
        fputs("[BENCH] \(event): \(String(format: "%.1f", valueMs))ms | " +
              "footprint=\(String(format: "%.0f", mem.footprintMB))MB " +
              "dirty=\(String(format: "%.0f", mem.internalMB))MB " +
              "compressed=\(String(format: "%.0f", mem.compressedMB))MB " +
              "purgeable=\(String(format: "%.0f", mem.purgeableMB))MB | \(detail)\n", stderr)

        // Append to CSV
        lock.lock()
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write((line + "\n").data(using: .utf8)!)
            handle.closeFile()
        }
        lock.unlock()
    }

    /// Backward-compatible convenience
    func currentMemoryMB() -> Double {
        return currentMemorySnapshot().footprintMB
    }

    /// Full memory breakdown using task_vm_info
    func currentMemorySnapshot() -> MemorySnapshot {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let toMB = 1024.0 * 1024.0
            return MemorySnapshot(
                footprintMB: Double(info.phys_footprint) / toMB,
                internalMB: Double(info.internal) / toMB,
                compressedMB: Double(info.compressed) / toMB,
                purgeableMB: Double(info.purgeable_volatile_pmap) / toMB
            )
        }
        return MemorySnapshot(footprintMB: 0, internalMB: 0, compressedMB: 0, purgeableMB: 0)
    }
}
