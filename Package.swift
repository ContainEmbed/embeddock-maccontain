// swift-tools-version: 6.2
//===----------------------------------------------------------------------===//
//
// EmbedDock - Embedded Container Library for macOS
//
//===----------------------------------------------------------------------===//

import PackageDescription

let package = Package(
    name: "EmbedDock",
    platforms: [.macOS("15")],
    products: [
        .library(
            name: "EmbedDock",
            targets: ["EmbedDock"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/containerization.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
    ],
    targets: [
        .target(
            name: "EmbedDock",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationArchive", package: "containerization"),
                .product(name: "ContainerizationEXT4", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                .product(name: "ContainerizationIO", package: "containerization"),
            ],
            resources: [
                .copy("Resources")
            ]
        ),
    ]
)
