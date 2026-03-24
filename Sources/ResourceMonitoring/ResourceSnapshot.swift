//===----------------------------------------------------------------------===//
//
// Resource Snapshot — Aggregate Metrics Container
//
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - Resource Snapshot

/// A point-in-time snapshot of all container resource metrics.
///
/// This is the primary data type delivered via `AsyncStream` and the
/// delegate callback. UI layers map this directly to display elements.
public struct ResourceSnapshot: Sendable, Equatable {

    /// Timestamp of when this snapshot was collected.
    public let timestamp: Date

    /// Time interval since the previous snapshot (seconds).
    public let intervalSeconds: TimeInterval

    /// CPU metrics.
    public let cpu: CPUMetrics

    /// Memory metrics.
    public let memory: MemoryMetrics

    /// Network I/O metrics.
    public let network: NetworkMetrics

    /// Disk I/O metrics.
    public let diskIO: DiskIOMetrics

    /// GPU metrics (placeholder until GPU passthrough is supported).
    public let gpu: GPUMetrics

    /// Monotonically increasing sequence number for ordering.
    public let sequenceNumber: UInt64

    /// Whether the snapshot is complete or degraded.
    public let quality: SnapshotQuality
}

// MARK: - Snapshot Quality

/// Describes the completeness of a resource snapshot.
public enum SnapshotQuality: Sendable, Equatable {

    /// All collectors reported successfully.
    case complete

    /// Some collectors failed; the listed metric types are missing or stale.
    case degraded(missing: [MetricType])

    /// Collection failed entirely.
    case failed(reason: String)
}

// MARK: - Metric Type

/// Enumeration of resource metric types, used for quality reporting.
public enum MetricType: String, Sendable, Equatable, CaseIterable {
    case cpu
    case memory
    case network
    case diskIO
    case gpu
}
