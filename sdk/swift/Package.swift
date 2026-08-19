// swift-tools-version:6.3
import PackageDescription

let package = Package(
    name: "Gosslens",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "Gosslens", targets: ["Gosslens"]),
    ],
    targets: [
        .target(name: "CGosslens"),
        .target(name: "Gosslens", dependencies: ["CGosslens"]),
    ],
    swiftLanguageModes: [.v6]
)
