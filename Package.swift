// swift-tools-version: 5.10
import PackageDescription

/// Complete data-race checking on every source target, so a new violation
/// shows up as a warning now rather than as a wall of errors when the package
/// moves to the Swift 6 language mode.
let strictConcurrency: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
    // Key paths and closures that capture only Sendable values are Sendable.
    .enableUpcomingFeature("InferSendableFromCaptures"),
]

let package = Package(
    name: "myKikau",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "myKikau", targets: ["App"]),
        // Read-only command-line companion for scripts and fleet tooling.
        .executable(name: "mykikau-cli", targets: ["CLI"]),
        // Root helper, started by launchd on demand. See Sources/Helper/main.swift.
        .executable(name: "myKikauHelper", targets: ["Helper"]),
    ],
    dependencies: [
        // Auto-update framework for direct (non-App-Store) distribution.
        // Floor pinned to the 2.9 line (current stable as of writing); SPM will
        // resolve the newest compatible 2.x release.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                "Core",
                "Features",
                "UI",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/App",
            exclude: ["Info.plist"],
            swiftSettings: strictConcurrency
        ),
        .executableTarget(
            name: "CLI",
            dependencies: ["Core", "Features"],
            path: "Sources/CLI",
            swiftSettings: strictConcurrency
        ),
        .executableTarget(
            name: "Helper",
            dependencies: ["Core"],
            path: "Sources/Helper",
            exclude: ["com.profiveck.myKikau.helper.plist"],
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "Core",
            path: "Sources/Core",
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "Features",
            dependencies: ["Core"],
            path: "Sources/Features",
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "UI",
            dependencies: ["Core", "Features"],
            path: "Sources/UI",
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "myKikauTests",
            dependencies: ["Core", "Features"],
            path: "Tests/myKikauTests"
        ),
    ]
)
