//===----------------------------------------------------------------------===//
//
// Disk I/O Metrics — Resource Monitoring Data Model
//
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - Disk I/O Metrics

/// Disk I/O metrics for a container.
///
/// Captures cumulative read/write counters parsed from `/proc/diskstats`
/// inside the Linux guest, with delta-calculated per-second throughput.
public struct DiskIOMetrics: Sendable, Equatable {

    /// Total bytes read (cumulative).
    public let readBytes: UInt64

    /// Total bytes written (cumulative).
    public let writeBytes: UInt64

    /// Read throughput in bytes per second.
    public let readBytesPerSec: Double

    /// Write throughput in bytes per second.
    public let writeBytesPerSec: Double

    /// Number of read operations (cumulative).
    public let readOps: UInt64

    /// Number of write operations (cumulative).
    public let writeOps: UInt64

    /// Read operations per second.
    public let readOpsPerSec: Double

    /// Write operations per second.
    public let writeOpsPerSec: Double

    /// Sentinel for when collection fails or data is not yet available.
    public static let unavailable = DiskIOMetrics(
        readBytes: 0,
        writeBytes: 0,
        readBytesPerSec: 0,
        writeBytesPerSec: 0,
        readOps: 0,
        writeOps: 0,
        readOpsPerSec: 0,
        writeOpsPerSec: 0
    )
}
