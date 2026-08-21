// swift-tools-version:6.3
import PackageDescription

// Mirrors sdk/swift/Package.swift so SwiftPM finds a manifest at the
// repository root - a git-URL dependency has no way to point at a
// subdirectory. Both describe the same sources; a consumer resolves
// this one, `cd sdk/swift && swift build` resolves the other.

// The engine links as static archives `zig build ios` / `ios-simulator`
// install into zig-out. Naming them here means a consumer points
// LIBRARY_SEARCH_PATHS at that directory per slice instead of hand-copying
// the -l list out of the demo; docs/INTEGRATION-iOS.md is the guide.
let engineLinkerSettings: [LinkerSetting] = [
    .linkedLibrary("gosslens", .when(platforms: [.iOS])),
    .linkedLibrary("gpupixel", .when(platforms: [.iOS])),
    .linkedLibrary("angle", .when(platforms: [.iOS])),
    .linkedLibrary("yuv", .when(platforms: [.iOS])),
    .linkedLibrary("bgfx", .when(platforms: [.iOS])),
    .linkedLibrary("tflite", .when(platforms: [.iOS])),
    .linkedLibrary("xnnpack", .when(platforms: [.iOS])),
    .linkedLibrary("xnnpack-fp16arith", .when(platforms: [.iOS])),
    .linkedLibrary("xnnpack-neonfp16arith", .when(platforms: [.iOS])),
    .linkedLibrary("xnnpack-neonfp16arith_aarch64", .when(platforms: [.iOS])),
    .linkedLibrary("xnnpack-neondot", .when(platforms: [.iOS])),
    .linkedLibrary("xnnpack-neondot_aarch64", .when(platforms: [.iOS])),
    .linkedLibrary("xnnpack-neondotfp16arith", .when(platforms: [.iOS])),
    .linkedLibrary("xnnpack-neoni8mm", .when(platforms: [.iOS])),
    .linkedLibrary("xnnpack-aarch64", .when(platforms: [.iOS])),
    .linkedLibrary("absl", .when(platforms: [.iOS])),
    .linkedLibrary("ruy", .when(platforms: [.iOS])),
    .linkedLibrary("farmhash", .when(platforms: [.iOS])),
    .linkedLibrary("fft2d", .when(platforms: [.iOS])),
    .linkedLibrary("flatbuffers", .when(platforms: [.iOS])),
    .linkedLibrary("cpuinfo", .when(platforms: [.iOS])),
    .linkedLibrary("pthreadpool", .when(platforms: [.iOS])),
    .linkedLibrary("quickjs", .when(platforms: [.iOS])),
    .linkedLibrary("jolt", .when(platforms: [.iOS])),
    .linkedLibrary("z", .when(platforms: [.iOS])),
    .linkedLibrary("c++", .when(platforms: [.iOS])),
    .linkedFramework("Metal", .when(platforms: [.iOS])),
    .linkedFramework("QuartzCore", .when(platforms: [.iOS])),
    .linkedFramework("CoreMedia", .when(platforms: [.iOS])),
    .linkedFramework("CoreVideo", .when(platforms: [.iOS])),
    .linkedFramework("IOSurface", .when(platforms: [.iOS])),
    .linkedFramework("VideoToolbox", .when(platforms: [.iOS])),
    .linkedFramework("AVFoundation", .when(platforms: [.iOS])),
]

let package = Package(
    name: "Gosslens",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "Gosslens", targets: ["Gosslens"]),
    ],
    targets: [
        .target(name: "CGosslens", path: "sdk/swift/Sources/CGosslens"),
        .target(
            name: "Gosslens",
            dependencies: ["CGosslens"],
            path: "sdk/swift/Sources/Gosslens",
            linkerSettings: engineLinkerSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
