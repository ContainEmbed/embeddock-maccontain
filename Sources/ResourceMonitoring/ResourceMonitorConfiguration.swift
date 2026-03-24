//===----------------------------------------------------------------------===//
//
// Resource Monitor Configuration
//
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - Resource Monitor Configuration

/// Configuration for the `ResourceMonitor`.
///
/// Controls collection interval, which metrics to collect, and
/// how much history to retain.
public struct ResourceMonitorConfiguration: Sendable {

    /// Interval between metric collection cycles.
    public let collectionInterval: Duration

    /// Whether to collect detailed metrics from `/proc` files
    /// (per-core CPU, meminfo breakdown). When `false`, only
    /// `pod.statistics()` is used for CPU and memory.
    public let collectDetailedMetrics: Bool

    /// Maximum number of snapshots to retain in the history buffer.
    public let historyBufferSize: Int

    /// Whether to collect network metrics from `/proc/net/dev`.
    public let collectNetworkMetrics: Bool

    /// Whether to collect disk I/O metrics from `/proc/diskstats`.
    public let collectDiskIOMetrics: Bool

    public init(
        collectionInterval: Duration = .seconds(2),
        collectDetailedMetrics: Bool = true,
        historyBufferSize: Int = 300,
        collectNetworkMetrics: Bool = true,
        collectDiskIOMetrics: Bool = true
    ) {
        self.collectionInterval = collectionInterval
        self.collectDetailedMetrics = collectDetailedMetrics
        self.historyBufferSize = historyBufferSize
        self.collectNetworkMetrics = collectNetworkMetrics
        self.collectDiskIOMetrics = collectDiskIOMetrics
    }

    /// Default configuration: 2-second interval, all metrics, 300-snapshot history.
    public static let `default` = ResourceMonitorConfiguration()

    /// Lightweight configuration: 2-second interval, only `pod.statistics()`,
    /// 60-snapshot history, no `/proc` reads.
    public static let lightweight = ResourceMonitorConfiguration(
        collectionInterval: .seconds(2),
        collectDetailedMetrics: false,
        historyBufferSize: 60,
        collectNetworkMetrics: false,
        collectDiskIOMetrics: false
    )
}
