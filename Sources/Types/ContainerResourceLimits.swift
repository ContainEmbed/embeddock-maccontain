//===----------------------------------------------------------------------===//
//
// Container Resource Limits — Public Configuration Type
//
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - Container Resource Limits

/// Resource limits for a container's virtual machine.
///
/// Configure CPU cores and memory before starting a container.
/// Since Apple's Virtualization Framework does not support live
/// resource modification (hotplug), changing limits on a running
/// container requires a stop-and-restart cycle.
///
/// Usage:
/// ```swift
/// engine.resourceLimits = ContainerResourceLimits(cpuCores: 4, memoryBytes: 1024 * 1024 * 1024)
/// try await engine.startFromImage(imageFile: url, port: 3000)
/// ```
public struct ContainerResourceLimits: Sendable, Equatable {

    /// Number of CPU cores allocated to the container VM.
    public let cpuCores: Int

    /// Memory allocated to the container VM, in bytes.
    public let memoryBytes: UInt64

    /// Create resource limits with the given CPU and memory allocation.
    ///
    /// - Parameters:
    ///   - cpuCores: Number of CPU cores (must be >= 1). Default: 2.
    ///   - memoryBytes: Memory in bytes (must be >= 128 MiB). Default: 512 MiB.
    public init(cpuCores: Int = 2, memoryBytes: UInt64 = 512 * 1024 * 1024) {
        precondition(cpuCores >= 1, "CPU cores must be at least 1")
        precondition(memoryBytes >= 128 * 1024 * 1024, "Memory must be at least 128 MiB")
        self.cpuCores = cpuCores
        self.memoryBytes = memoryBytes
    }

    // MARK: - Presets

    /// Default: 2 CPU cores, 512 MiB memory.
    public static let `default` = ContainerResourceLimits()

    /// Minimal: 1 CPU core, 256 MiB memory.
    public static let minimal = ContainerResourceLimits(cpuCores: 1, memoryBytes: 256 * 1024 * 1024)

    /// Performance: 4 CPU cores, 1 GiB memory.
    public static let performance = ContainerResourceLimits(cpuCores: 4, memoryBytes: 1024 * 1024 * 1024)

    // MARK: - Display

    /// Memory formatted for display (e.g., "512 MB", "1.0 GB").
    public var memoryDescription: String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(memoryBytes)
        var unitIndex = 0
        while value >= 1024 && unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 { return String(format: "%.0f %@", value, units[unitIndex]) }
        return String(format: "%.1f %@", value, units[unitIndex])
    }
}

// MARK: - Internal Bridge

extension ContainerResourceLimits {
    /// Convert to internal PodConfiguration for the VM layer.
    func toPodConfiguration() -> PodConfiguration {
        PodConfiguration(
            cpus: cpuCores,
            memoryInBytes: memoryBytes,
            networkAddress: PodConfiguration.default.networkAddress,
            networkGateway: PodConfiguration.default.networkGateway,
            bootlogPath: nil
        )
    }
}
