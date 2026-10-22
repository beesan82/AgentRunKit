// swift-tools-version: 6.1

import PackageDescription

// Pocket Agent fork (beesan82): AgentRunKit 6.1.0 without AgentRunKitMLX and its mlx-swift-lm
// 2.30.x dependency, so an app can use mlx-swift-lm 3.x (MLXFoundationModels) alongside AgentRunKit.

let package = Package(
    name: "AgentRunKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(name: "AgentRunKit", targets: ["AgentRunKit"]),
        .library(name: "AgentRunKitTesting", targets: ["AgentRunKitTesting"]),
        .library(name: "AgentRunKitFoundationModels", targets: ["AgentRunKitFoundationModels"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.4.3"),
    ],
    targets: [
        .target(name: "AgentRunKit"),
        .target(name: "AgentRunKitTesting", dependencies: ["AgentRunKit"]),
        .testTarget(name: "AgentRunKitTests", dependencies: ["AgentRunKit", "AgentRunKitTesting"]),
        .target(
            name: "AgentRunKitFoundationModels",
            dependencies: ["AgentRunKit"]
        ),
        .testTarget(
            name: "AgentRunKitFoundationModelsTests",
            dependencies: ["AgentRunKitFoundationModels"]
        )
    ]
)
