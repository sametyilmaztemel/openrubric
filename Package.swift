// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenRubric",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "OpenRubricCore", targets: ["OpenRubricCore"]),
    ],
    targets: [
        // Platform-agnostic logic: prompt building, answer parsing,
        // crop geometry, OpenAI-compatible client. Unit-tested on CI.
        .target(name: "OpenRubricCore"),
        .testTarget(
            name: "OpenRubricCoreTests",
            dependencies: ["OpenRubricCore"]
        ),
    ]
)
