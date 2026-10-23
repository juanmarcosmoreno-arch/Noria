// swift-tools-version: 6.0
import PackageDescription

// NoriaCore holds every piece of Noria that is not UI: file-system access,
// scanners, safety rules, cleaning, persistence and recommendations.
// It depends only on Foundation so it can be built and tested headlessly
// (including on Linux CI), while the SwiftUI app target links it.
let package = Package(
    name: "NoriaCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NoriaCore", targets: ["NoriaCore"])
    ],
    targets: [
        .target(name: "NoriaCore"),
        .testTarget(name: "NoriaCoreTests", dependencies: ["NoriaCore"])
    ]
)
