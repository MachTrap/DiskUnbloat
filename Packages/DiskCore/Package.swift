// swift-tools-version: 6.3
import PackageDescription
let package = Package(name: "DiskCore", platforms: [.macOS(.v26)], products: [.library(name: "DiskCore", targets: ["DiskCore"])], targets: [.systemLibrary(name: "CSQLite"), .target(name: "DiskCore", dependencies: ["CSQLite"]), .executableTarget(name: "DiskBenchmark", dependencies: ["DiskCore"]), .testTarget(name: "DiskCoreTests", dependencies: ["DiskCore"])])
