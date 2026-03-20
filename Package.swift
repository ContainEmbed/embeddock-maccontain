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
        .package(url: "https://github.com/apple/containerization.git", exact: "0.26.5"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
    ],
    targets: [
        .binaryTarget(
            name: "EmbedDockResources",
            url: "https://github.com/ContainEmbed/embeddock-maccontain/releases/download/0.2.0/EmbedDockResources.artifactbundle.zip",
            checksum: "d5c33a56eeaca15c9d5756ea3ca7cf53c1caaf45211c053e9669849b5c9d2230"
        ),
        .plugin(
            name: "CopyResourcesPlugin",
            capability: .buildTool(),
            dependencies: ["EmbedDockResources"]
        ),
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
            path: "Sources",
            exclude: ["LinuxGuest"],
            plugins: ["CopyResourcesPlugin"]
        ),
    ]
)
