// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "myKikau",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "myKikau", targets: ["App"])
    ],
    dependencies: [
        // Auto-update framework for direct (non-App-Store) distribution.
        // Floor pinned to the 2.9 line (current stable as of writing); SPM will
        // resolve the newest compatible 2.x release.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0")
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
            exclude: ["Info.plist"]
        ),
        .target(
            name: "Core",
            path: "Sources/Core"
        ),
        .target(
            name: "Features",
            dependencies: ["Core"],
            path: "Sources/Features"
        ),
        .target(
            name: "UI",
            dependencies: ["Core", "Features"],
            path: "Sources/UI"
        ),
        .testTarget(
            name: "myKikauTests",
            dependencies: ["Core", "Features"],
            path: "Tests/myKikauTests"
        )
    ]
)