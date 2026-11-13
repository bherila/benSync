// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BenSyncCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "BenSyncCore", targets: ["BenSyncCore"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "BenSyncCore", dependencies: ["CSQLite"]),
        .testTarget(name: "BenSyncCoreTests", dependencies: ["BenSyncCore"]),
    ],
    swiftLanguageModes: [.v5]
)
