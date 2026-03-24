//===----------------------------------------------------------------------===//
//
// GPU Metrics — Resource Monitoring Data Model
//
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - GPU Metrics

/// GPU metrics for a container.
///
/// Apple Virtualization does not currently support GPU passthrough for
/// Linux guests. This struct exists to future-proof the API surface.
/// The `isAvailable` flag will be `false` and all numeric fields zero
/// until GPU support is added.
public struct GPUMetrics: Sendable, Equatable {

    /// Whether GPU metrics are available for this container.
    public let isAvailable: Bool

    /// GPU utilization percentage (0.0 – 100.0).
    public let utilizationPercent: Double

    /// GPU memory usage in bytes.
    public let memoryUsageBytes: UInt64

    /// Total GPU memory in bytes.
    public let memoryTotalBytes: UInt64

    /// GPU temperature in Celsius, if available.
    public let temperatureCelsius: Double?

    /// GPU power consumption in watts, if available.
    public let powerWatts: Double?

    /// Sentinel — GPU is not available.
    public static let unavailable = GPUMetrics(
        isAvailable: false,
        utilizationPercent: 0,
        memoryUsageBytes: 0,
        memoryTotalBytes: 0,
        temperatureCelsius: nil,
        powerWatts: nil
    )
}
