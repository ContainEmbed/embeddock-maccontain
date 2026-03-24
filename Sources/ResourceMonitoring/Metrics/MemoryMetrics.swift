//===----------------------------------------------------------------------===//
//
// Memory Metrics — Resource Monitoring Data Model
//
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - Memory Metrics

/// Memory usage metrics for a container.
///
/// Captures aggregate usage from `pod.statistics()` and detailed
/// breakdown from `/proc/meminfo` inside the Linux guest.
public struct MemoryMetrics: Sendable, Equatable {

    /// Current memory usage in bytes (from `pod.statistics()`).
    public let usageBytes: UInt64

    /// Total memory available to the VM in bytes.
    public let totalBytes: UInt64

    /// Usage as a percentage (0.0 – 100.0).
    public let usagePercent: Double

    /// Free memory in bytes (from `/proc/meminfo`).
    public let freeBytes: UInt64?

    /// Available memory in bytes (`MemAvailable` from `/proc/meminfo`).
    public let availableBytes: UInt64?

    /// Memory used by buffers in bytes.
    public let buffersBytes: UInt64?

    /// Memory used by page cache in bytes.
    public let cachedBytes: UInt64?

    /// Swap usage in bytes.
    public let swapUsedBytes: UInt64?

    /// Total swap space in bytes.
    public let swapTotalBytes: UInt64?

    /// Sentinel for when collection fails or data is not yet available.
    public static let unavailable = MemoryMetrics(
        usageBytes: 0,
        totalBytes: 0,
        usagePercent: 0,
        freeBytes: nil,
        availableBytes: nil,
        buffersBytes: nil,
        cachedBytes: nil,
        swapUsedBytes: nil,
        swapTotalBytes: nil
    )
}
