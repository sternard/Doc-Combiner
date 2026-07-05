// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "DocCombiner",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "DocCombinerCore",
            targets: ["DocCombinerCore"]
        ),
        .executable(
            name: "doc-combiner",
            targets: ["DocCombinerCLI"]
        ),
        .executable(
            name: "DocCombinerApp",
            targets: ["DocCombinerApp"]
        )
    ],
    targets: [
        .target(
            name: "DocCombinerCore"
        ),
        .executableTarget(
            name: "DocCombinerCLI",
            dependencies: ["DocCombinerCore"]
        ),
        .executableTarget(
            name: "DocCombinerApp",
            dependencies: ["DocCombinerCore"]
        ),
        .testTarget(
            name: "DocCombinerCoreTests",
            dependencies: ["DocCombinerCore"]
        )
    ]
)
