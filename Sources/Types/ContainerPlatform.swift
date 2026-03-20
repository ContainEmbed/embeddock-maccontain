//===----------------------------------------------------------------------===//
//
// ContainerPlatform — Public wrapper hiding ContainerizationOCI.Platform
//
//===----------------------------------------------------------------------===//

import ContainerizationOCI

/// Platform targeting for OCI container image pulls.
///
/// This type wraps `ContainerizationOCI.Platform` so that consumers of EmbedDock
/// do not need to import ContainerizationOCI directly.
public struct ContainerPlatform: Sendable, Equatable {

    /// The operating system, e.g. `"linux"`.
    public let os: String

    /// The CPU architecture, e.g. `"amd64"` or `"arm64"`.
    public let architecture: String

    /// An optional CPU variant, e.g. `"v8"` for arm64.
    public let variant: String?

    public init(os: String, architecture: String, variant: String? = nil) {
        self.os = os
        self.architecture = architecture
        self.variant = variant
    }

    // MARK: - Common Presets

    /// Linux/amd64 (x86-64)
    public static let linuxAMD64 = ContainerPlatform(os: "linux", architecture: "amd64")

    /// Linux/arm64
    public static let linuxARM64 = ContainerPlatform(os: "linux", architecture: "arm64")

    /// Linux/arm64/v8
    public static let linuxARM64v8 = ContainerPlatform(os: "linux", architecture: "arm64", variant: "v8")

    /// The platform matching the current host machine.
    public static var current: ContainerPlatform {
        let native = ContainerizationOCI.Platform.current
        return ContainerPlatform(native)
    }
}

// MARK: - Internal Bridge (not visible to EmbedDock consumers)

extension ContainerPlatform {
    /// Initialise from the internal ContainerizationOCI type.
    init(_ platform: ContainerizationOCI.Platform) {
        self.os = platform.os
        self.architecture = platform.architecture
        self.variant = platform.variant
    }

    /// Convert to the internal ContainerizationOCI type for use inside EmbedDock.
    func toPlatform() -> ContainerizationOCI.Platform {
        ContainerizationOCI.Platform(arch: architecture, os: os, variant: variant)
    }
}
