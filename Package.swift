// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TidyBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "TidyBarCore",
            targets: ["TidyBarCore"]
        ),
        .executable(
            name: "TidyBar",
            targets: ["TidyBar"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "TidyBarCore",
            path: "Sources/TidyBarCore",
            exclude: ["GEMINI.md"]
        ),
        .executableTarget(
            name: "TidyBar",
            dependencies: ["TidyBarCore"],
            path: "Sources/TidyBar",
            exclude: ["GEMINI.md"]
        ),
        .testTarget(
            name: "TidyBarTests",
            dependencies: ["TidyBarCore"],
            path: "Tests/TidyBarTests",
            exclude: ["GEMINI.md"]
        )
    ]
)
