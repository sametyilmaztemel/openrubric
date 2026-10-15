// swift-tools-version: 6.0
import PackageDescription

// The app target is macOS-only (AppKit + ScreenCaptureKit). Declaring it
// conditionally keeps `swift build` / `swift test` green on Linux dev
// machines while macOS CI builds and ships the executable.
var products: [Product] = [
    .library(name: "OpenRubricCore", targets: ["OpenRubricCore"]),
]
var targets: [Target] = [
    // Platform-agnostic logic: prompt building, answer parsing,
    // crop geometry, Anthropic + OpenAI-compatible clients.
    // Unit-tested on CI.
    .target(name: "OpenRubricCore"),
    .testTarget(
        name: "OpenRubricCoreTests",
        dependencies: ["OpenRubricCore"]
    ),
]

#if os(macOS)
// Menu bar app: hotkey, ScreenCaptureKit crop, hidden AnswerPanel,
// Keychain-backed settings. macOS only.
products.append(.executable(name: "OpenRubric", targets: ["OpenRubricApp"]))
targets.append(
    .executableTarget(
        name: "OpenRubricApp",
        dependencies: ["OpenRubricCore"]
    )
)
// App-layer tests: settings v1->v2 migration (UserDefaults-based) and other
// AppKit-bound logic. Depends on the executable target so `@testable import
// OpenRubricApp` reaches the internal store. Compiled only on macOS.
targets.append(
    .testTarget(
        name: "OpenRubricAppTests",
        dependencies: ["OpenRubricApp"]
    )
)
#endif

let package = Package(
    name: "OpenRubric",
    platforms: [
        .macOS(.v15)
    ],
    products: products,
    targets: targets
)
