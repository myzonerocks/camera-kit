// swift-tools-version:6.3
import PackageDescription

// Mirrors sdk/swift/Package.swift so SwiftPM finds a manifest at the
// repository root - a git-URL dependency has no way to point at a
// subdirectory. Both describe the same sources; a consumer resolves
// this one, `cd sdk/swift && swift build` resolves the other.
let package = Package(
    name: "Gosslens",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "Gosslens", targets: ["Gosslens"]),
    ],
    targets: [
        .target(name: "CGosslens", path: "sdk/swift/Sources/CGosslens"),
        .target(name: "Gosslens", dependencies: ["CGosslens"], path: "sdk/swift/Sources/Gosslens"),
    ],
    swiftLanguageModes: [.v6]
)
