// MemoryMonitor — External process memory recorder for DICOM viewer benchmarks.
// Monitors one or more apps (by process name) and records memory metrics to CSV.
// Uses the same APIs as Activity Monitor for fair cross-app comparison.
//
// Usage:
//   MemoryMonitor --process OpenDicomViewer --process Horos --interval 0.5 --output results.csv
//   MemoryMonitor --process OpenDicomViewer  (defaults: 500ms interval, stdout)

import Foundation
import Darwin

// MARK: - libproc declarations

@_silgen_name("proc_listpids")
func proc_listpids(_ type: UInt32, _ typeinfo: UInt32, _ buffer: UnsafeMutableRawPointer?, _ buffersize: Int32) -> Int32

@_silgen_name("proc_pid_rusage")
func proc_pid_rusage(_ pid: Int32, _ flavor: Int32, _ buffer: UnsafeMutablePointer<rusage_info_v4>) -> Int32

@_silgen_name("proc_pidpath")
func proc_pidpath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer, _ buffersize: UInt32) -> Int32

// MARK: - Memory snapshot from external process

struct ProcessMemory {
    let pid: Int32
    let name: String
    let footprintMB: Double      // phys_footprint — matches Activity Monitor "Memory"
    let residentMB: Double       // physical pages in RAM
    let peakFootprintMB: Double  // lifetime max footprint
}

struct DetailedMemory {
    let pid: Int32
    let name: String
    let footprintMB: Double
    let dirtyMB: Double       // non-evictable heap allocations
    let swappedMB: Double     // swapped/compressed
    let cleanMB: Double       // evictable (file-backed, purgeable)
}

func findPIDs(named processName: String) -> [Int32] {
    let bufSize = proc_listpids(1, 0, nil, 0) // PROC_ALL_PIDS = 1
    guard bufSize > 0 else { return [] }
    let count = Int(bufSize) / MemoryLayout<Int32>.size
    var pids = [Int32](repeating: 0, count: count)
    let _ = proc_listpids(1, 0, &pids, bufSize)

    var matches: [Int32] = []
    var pathBuf = [CChar](repeating: 0, count: 4096)
    for pid in pids where pid > 0 {
        let len = proc_pidpath(pid, &pathBuf, 4096)
        if len > 0 {
            let path = String(cString: pathBuf)
            let binary = (path as NSString).lastPathComponent
            if binary == processName || binary.hasPrefix(processName) {
                matches.append(pid)
            }
        }
    }
    return matches
}

func getProcessMemory(pid: Int32, name: String) -> ProcessMemory? {
    var info = rusage_info_v4()
    let result = proc_pid_rusage(pid, 4, &info) // RUSAGE_INFO_V4 = 4
    guard result == 0 else { return nil }

    let toMB = 1024.0 * 1024.0
    return ProcessMemory(
        pid: pid,
        name: name,
        footprintMB: Double(info.ri_phys_footprint) / toMB,
        residentMB: Double(info.ri_resident_size) / toMB,
        peakFootprintMB: Double(info.ri_lifetime_max_phys_footprint) / toMB
    )
}

/// Run `footprint` CLI to get dirty/swapped/clean breakdown
func getDetailedMemory(pid: Int32, name: String) -> DetailedMemory? {
    let pipe = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/footprint")
    process.arguments = ["--pid", "\(pid)", "--swapped"]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
        process.waitUntilExit()
    } catch { return nil }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else { return nil }

    // Parse footprint output.
    // Header line: "OpenDicomViewer [PID]: 64-bit    Footprint: 33 MB ..."
    // Table columns: Dirty | Clean | Reclaimable | Regions | Category
    // TOTAL row: "  33 MB      20 MB          0 B       8257    TOTAL"
    var footprint = 0.0, dirty = 0.0, swapped = 0.0, clean = 0.0

    for line in output.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Header line with overall footprint
        if trimmed.contains("Footprint:") {
            if let range = trimmed.range(of: "Footprint:") {
                footprint = parseSize(String(trimmed[range.upperBound...]))
            }
        }

        // TOTAL summary row — with --swapped, columns: Dirty, (Swapped), Clean, Reclaimable
        if trimmed.hasSuffix("TOTAL") {
            let sizes = parseSizesFromRow(trimmed)
            // sizes[0]=Dirty, sizes[1]=Swapped, sizes[2]=Clean, sizes[3]=Reclaimable
            if sizes.count >= 3 {
                dirty = sizes[0]
                swapped = sizes[1]
                clean = sizes[2]
            }
        }
    }

    return DetailedMemory(
        pid: pid, name: name,
        footprintMB: footprint, dirtyMB: dirty,
        swappedMB: swapped, cleanMB: clean
    )
}

func parseSize(_ str: String) -> Double {
    // Extract a number followed by optional unit
    let pattern = #"(\d+\.?\d*)\s*(KB|MB|GB|TB|K|M|G|T|bytes|B)?"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
          let match = regex.matches(in: str, range: NSRange(str.startIndex..., in: str)).first,
          let numRange = Range(match.range(at: 1), in: str),
          let value = Double(str[numRange]) else { return 0 }

    let unit: String
    if let unitRange = Range(match.range(at: 2), in: str) {
        unit = String(str[unitRange]).uppercased()
    } else {
        unit = "B"
    }

    switch unit {
    case "K", "KB": return value / 1024.0
    case "M", "MB": return value
    case "G", "GB": return value * 1024.0
    case "T", "TB": return value * 1024.0 * 1024.0
    default: return value / (1024.0 * 1024.0)
    }
}

/// Parse all "number unit" pairs from a row (e.g., "33 MB      20 MB          0 B")
func parseSizesFromRow(_ str: String) -> [Double] {
    let pattern = #"(\d+\.?\d*)\s*(KB|MB|GB|TB|B)\b"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let matches = regex.matches(in: str, range: NSRange(str.startIndex..., in: str))
    return matches.compactMap { match -> Double? in
        guard let numRange = Range(match.range(at: 1), in: str),
              let unitRange = Range(match.range(at: 2), in: str),
              let value = Double(str[numRange]) else { return nil }
        let unit = String(str[unitRange])
        switch unit {
        case "KB": return value / 1024.0
        case "MB": return value
        case "GB": return value * 1024.0
        case "TB": return value * 1024.0 * 1024.0
        case "B": return value / (1024.0 * 1024.0)
        default: return value
        }
    }
}

/// Get system memory pressure level
func getMemoryPressure() -> String {
    let pipe = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
    process.arguments = ["-n", "kern.memorystatus_vm_pressure_level"]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
    } catch { return "unknown" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let val = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
    switch val {
    case "1": return "normal"
    case "2": return "warn"
    case "4": return "critical"
    default: return "level_\(val)"
    }
}

// MARK: - Main

let args = CommandLine.arguments
var processNames: [String] = []
var interval: TimeInterval = 0.5
var outputPath: String? = nil
var detailedInterval: Int = 10 // run footprint every N samples

var i = 1
while i < args.count {
    switch args[i] {
    case "--process", "-p":
        i += 1; if i < args.count { processNames.append(args[i]) }
    case "--interval", "-i":
        i += 1; if i < args.count { interval = Double(args[i]) ?? 0.5 }
    case "--output", "-o":
        i += 1; if i < args.count { outputPath = args[i] }
    case "--detailed-every":
        i += 1; if i < args.count { detailedInterval = Int(args[i]) ?? 10 }
    case "--help", "-h":
        print("""
        MemoryMonitor — External memory recorder for DICOM viewer benchmarks

        Usage:
          MemoryMonitor --process <name> [--process <name2>] [options]

        Options:
          --process, -p <name>    Process name to monitor (repeatable)
          --interval, -i <sec>    Sampling interval in seconds (default: 0.5)
          --output, -o <path>     Output CSV path (default: stdout)
          --detailed-every <N>    Run detailed footprint every N samples (default: 10)
          --help, -h              Show this help

        Examples:
          MemoryMonitor -p OpenDicomViewer -p Horos -p OsiriX
          MemoryMonitor -p OpenDicomViewer -i 1.0

        Runs continuously until Ctrl+C. Automatically detects app launches/quits
        and tracks trial numbers (open app 3x = trials 1, 2, 3).
        Output CSV is auto-timestamped (e.g., memory_benchmark_20260406_143022.csv).
        """)
        exit(0)
    default:
        break
    }
    i += 1
}

if processNames.isEmpty {
    processNames = ["OpenDicomViewer", "Horos", "OsiriX"]
    fputs("No --process specified, monitoring: \(processNames.joined(separator: ", "))\n", stderr)
}

// Set up output — auto-add timestamp to filename so runs don't overwrite
let csvHeader = "timestamp,elapsed_s,process,pid,trial,footprint_mb,resident_mb,peak_footprint_mb,dirty_mb,swapped_mb,clean_mb,memory_pressure\n"

var fileHandle: FileHandle? = nil
do {
    let df = DateFormatter()
    df.dateFormat = "yyyyMMdd_HHmmss"
    let tsStr = df.string(from: Date())

    var finalPath: String
    if let path = outputPath {
        // Insert timestamp before extension: results.csv → results_20260406_123456.csv
        let url = URL(fileURLWithPath: path)
        let base = url.deletingPathExtension().path
        let ext = url.pathExtension.isEmpty ? "csv" : url.pathExtension
        finalPath = "\(base)_\(tsStr).\(ext)"
    } else {
        let desktop = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop").path
        finalPath = "\(desktop)/memory_benchmark_\(tsStr).csv"
    }

    FileManager.default.createFile(atPath: finalPath, contents: nil)
    fileHandle = FileHandle(forWritingAtPath: finalPath)
    fileHandle?.write(csvHeader.data(using: .utf8)!)
    fputs("Recording to: \(finalPath)\n", stderr)
}

if fileHandle == nil {
    print(csvHeader, terminator: "")
}

func writeLine(_ line: String) {
    if let fh = fileHandle {
        fh.write((line + "\n").data(using: .utf8)!)
    } else {
        print(line)
    }
}

fputs("Monitoring: \(processNames.joined(separator: ", "))\n", stderr)
fputs("Runs continuously — open/close/reopen apps as needed.\n", stderr)
fputs("Press Ctrl+C to stop when all 9 trials are done.\n\n", stderr)

let startTime = CFAbsoluteTimeGetCurrent()
var sampleCount = 0
var trialTracker: [String: Int] = [:]  // count how many times each app appeared
var activeApps: Set<String> = []

signal(SIGINT) { _ in
    fputs("\nStopped.\n", stderr)
    exit(0)
}

var lastPIDs: [String: Int32] = [:]  // track PID changes to detect new launches

while true {
    let elapsed = CFAbsoluteTimeGetCurrent() - startTime
    let ts = ISO8601DateFormatter().string(from: Date())
    let pressure = getMemoryPressure()
    let doDetailed = (sampleCount % detailedInterval == 0)

    for name in processNames {
        let pids = findPIDs(named: name)

        if pids.isEmpty {
            // App closed — detect transition from running → not running
            if activeApps.contains(name) {
                activeApps.remove(name)
                let trial = trialTracker[name] ?? 0
                fputs("  ✓ \(name) closed (trial \(trial) complete)\n", stderr)
                lastPIDs.removeValue(forKey: name)
            }
            continue
        }

        for pid in pids {
            // Detect new launch (PID changed or first time)
            if lastPIDs[name] != pid {
                lastPIDs[name] = pid
                if !activeApps.contains(name) {
                    trialTracker[name, default: 0] += 1
                    activeApps.insert(name)
                    let trial = trialTracker[name]!
                    fputs("  → \(name) detected (pid \(pid), trial \(trial))\n", stderr)
                }
            }

            if let mem = getProcessMemory(pid: pid, name: name) {
                var dirty = 0.0, swapped = 0.0, clean = 0.0
                let trial = trialTracker[name] ?? 1

                if doDetailed, let detail = getDetailedMemory(pid: pid, name: name) {
                    dirty = detail.dirtyMB
                    swapped = detail.swappedMB
                    clean = detail.cleanMB
                }

                let line = "\(ts),\(String(format: "%.1f", elapsed)),\(name),\(pid),\(trial)," +
                    "\(String(format: "%.1f", mem.footprintMB))," +
                    "\(String(format: "%.1f", mem.residentMB))," +
                    "\(String(format: "%.1f", mem.peakFootprintMB))," +
                    "\(String(format: "%.1f", dirty))," +
                    "\(String(format: "%.1f", swapped))," +
                    "\(String(format: "%.1f", clean))," +
                    "\(pressure)"
                writeLine(line)

                if sampleCount % 4 == 0 {
                    fputs("[\(String(format: "%6.1f", elapsed))s] \(name) #\(trial) (pid \(pid)): " +
                          "footprint=\(String(format: "%.0f", mem.footprintMB))MB " +
                          "peak=\(String(format: "%.0f", mem.peakFootprintMB))MB " +
                          "pressure=\(pressure)" +
                          (doDetailed ? " dirty=\(String(format: "%.0f", dirty))MB clean=\(String(format: "%.0f", clean))MB" : "") +
                          "\n", stderr)
                }
            }
        }
    }

    sampleCount += 1
    Thread.sleep(forTimeInterval: interval)
}

fileHandle?.closeFile()
fputs("Done. \(sampleCount) samples recorded.\n", stderr)
