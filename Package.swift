// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Morph",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MorphCore", targets: ["MorphCore"]),
        .executable(name: "Morph", targets: ["MorphApp"]),
        .executable(name: "MorphQuickConvert", targets: ["MorphQuickConvert"]),
        .executable(name: "MorphChecks", targets: ["MorphChecks"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
        .package(url: "https://github.com/mattt/swift-toml.git", exact: "2.0.0"),
    ],
    targets: [
        .target(
            name: "MorphCore",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
                .product(name: "TOML", package: "swift-toml"),
            ]
        ),
        .executableTarget(name: "MorphApp", dependencies: ["MorphCore"]),
        .executableTarget(name: "MorphQuickConvert", dependencies: ["MorphCore"]),
        .executableTarget(name: "MorphChecks", dependencies: ["MorphCore"], path: "Tests/MorphChecks"),
    ],
    swiftLanguageVersions: [.v5]
)
