// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MemoryMonitor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "MemoryMonitor")
    ]
)
