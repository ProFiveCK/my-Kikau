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
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                "Core",
                "Features",
                "UI",
            ],
            path: "Sources/App"
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