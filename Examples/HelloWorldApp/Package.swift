// swift-tools-version: 6.2
//===----------------------------------------------------------------------===//
// HelloWorldApp - Example application demonstrating EmbedDock usage
//
// Build:   swift build
// Sign:    codesign --force --sign - --entitlements vz.entitlements \
//            .build/arm64-apple-macosx/debug/HelloWorldApp
// Run:     .build/arm64-apple-macosx/debug/HelloWorldApp
//===----------------------------------------------------------------------===//

import PackageDescription

let package = Package(
    name: "HelloWorldApp",
    platforms: [.macOS("15")],
    dependencies: [
        // For local development, uncomment the line below and comment the URL dependency:
        // .package(path: "../../"),
        .package(url: "https://github.com/ContainEmbed/embeddock-maccontain.git", from: "0.2.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "HelloWorldApp",
            dependencies: [
                .product(name: "EmbedDock", package: "embeddock-maccontain"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        ),
    ]
)
