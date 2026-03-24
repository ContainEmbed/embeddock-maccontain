//===----------------------------------------------------------------------===//
//
// Network Metrics — Resource Monitoring Data Model
//
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - Network Metrics

/// Network I/O metrics for a container.
///
/// Aggregates per-interface counters parsed from `/proc/net/dev`
/// inside the Linux guest, with delta-calculated per-second rates.
public struct NetworkMetrics: Sendable, Equatable {

    /// Per-interface breakdown.
    public let interfaces: [InterfaceMetrics]

    /// Aggregate bytes received per second across all interfaces.
    public let totalRxBytesPerSec: Double

    /// Aggregate bytes transmitted per second across all interfaces.
    public let totalTxBytesPerSec: Double

    /// Aggregate cumulative received bytes.
    public let totalRxBytes: UInt64

    /// Aggregate cumulative transmitted bytes.
    public let totalTxBytes: UInt64

    /// Sentinel for when collection fails or data is not yet available.
    public static let unavailable = NetworkMetrics(
        interfaces: [],
        totalRxBytesPerSec: 0,
        totalTxBytesPerSec: 0,
        totalRxBytes: 0,
        totalTxBytes: 0
    )
}

// MARK: - Interface Metrics

/// Metrics for a single network interface.
public struct InterfaceMetrics: Sendable, Equatable {

    /// Interface name (e.g. "eth0").
    public let name: String

    /// Cumulative bytes received.
    public let rxBytes: UInt64

    /// Cumulative bytes transmitted.
    public let txBytes: UInt64

    /// Cumulative packets received.
    public let rxPackets: UInt64

    /// Cumulative packets transmitted.
    public let txPackets: UInt64

    /// Cumulative receive errors.
    public let rxErrors: UInt64

    /// Cumulative transmit errors.
    public let txErrors: UInt64

    /// Receive throughput in bytes per second.
    public let rxBytesPerSec: Double

    /// Transmit throughput in bytes per second.
    public let txBytesPerSec: Double
}
