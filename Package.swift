// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Morph",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MorphCore", targets: ["MorphCore"]),
        .executable(name: "Morph", targets: ["MorphApp"]),
        .executable(name: "MorphChecks", targets: ["MorphChecks"]),
    ],
    targets: [
        .target(name: "MorphCore"),
        .executableTarget(name: "MorphApp", dependencies: ["MorphCore"]),
        .executableTarget(name: "MorphChecks", dependencies: ["MorphCore"], path: "Tests/MorphChecks"),
    ],
    swiftLanguageVersions: [.v5]
)
