//===----------------------------------------------------------------------===//
//
// CPU Metrics — Resource Monitoring Data Model
//
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - CPU Metrics

/// CPU usage metrics for a container.
///
/// Captures both aggregate and per-core CPU utilization derived from
/// `pod.statistics()` (cumulative microseconds) and optionally
/// `/proc/stat` (per-core breakdown with user/system/idle split).
public struct CPUMetrics: Sendable, Equatable {

    /// Overall CPU usage as a percentage (0.0 – 100.0 × core count).
    public let usagePercent: Double

    /// Cumulative CPU time in microseconds (from `pod.statistics()`).
    public let cumulativeUsageUsec: UInt64

    /// Per-core usage percentages, if available from `/proc/stat`.
    public let perCoreUsagePercent: [Double]?

    /// User-space CPU time percentage.
    public let userPercent: Double?

    /// Kernel/system CPU time percentage.
    public let systemPercent: Double?

    /// Idle time percentage.
    public let idlePercent: Double?

    /// Number of CPU cores allocated to the VM.
    public let coreCount: Int

    /// Sentinel for when collection fails or data is not yet available.
    public static let unavailable = CPUMetrics(
        usagePercent: 0,
        cumulativeUsageUsec: 0,
        perCoreUsagePercent: nil,
        userPercent: nil,
        systemPercent: nil,
        idlePercent: nil,
        coreCount: 0
    )
}
