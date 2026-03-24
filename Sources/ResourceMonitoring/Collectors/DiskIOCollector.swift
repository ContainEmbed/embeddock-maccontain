//===----------------------------------------------------------------------===//
//
// Disk I/O Collector — Protocol + Implementation
//
//===----------------------------------------------------------------------===//

import Foundation
import Containerization
import Logging

// MARK: - Disk I/O Collecting Protocol

/// Protocol for disk I/O metric collection.
protocol DiskIOCollecting: ResourceCollector where Metrics == DiskIOMetrics {}

// MARK: - Pod Disk I/O Collector

/// Collects disk I/O metrics from `/proc/diskstats` inside the Linux guest.
///
/// Parses the virtio block device (`vda`) counters and delta-calculates
/// per-second throughput and operation rates.
actor PodDiskIOCollector: DiskIOCollecting, AnyResourceCollector {

    let metricType: MetricType = .diskIO
    private(set) var isAvailable: Bool = true

    // MARK: - Dependencies

    private let pod: LinuxPod
    private let logger: Logger

    // MARK: - Delta State

    private var previousReadOps: UInt64 = 0
    private var previousReadBytes: UInt64 = 0
    private var previousWriteOps: UInt64 = 0
    private var previousWriteBytes: UInt64 = 0
    private var previousTimestamp: ContinuousClock.Instant?

    // MARK: - Initialization

    init(pod: LinuxPod, logger: Logger) {
        self.pod = pod
        self.logger = logger
    }

    // MARK: - Collection

    func collect() async -> DiskIOMetrics {
        let now = ContinuousClock.now

        guard let raw = await readProcDiskstats(),
              let snapshot = parseDiskstats(raw) else {
            isAvailable = false
            return .unavailable
        }

        let elapsed: Double
        if let prevTimestamp = previousTimestamp {
            let duration = now - prevTimestamp
            elapsed = duration.totalSeconds
        } else {
            elapsed = 0
        }

        var readBytesPerSec: Double = 0
        var writeBytesPerSec: Double = 0
        var readOpsPerSec: Double = 0
        var writeOpsPerSec: Double = 0

        if elapsed > 0 {
            let deltaReadBytes = snapshot.readBytes > previousReadBytes ? snapshot.readBytes - previousReadBytes : 0
            let deltaWriteBytes = snapshot.writeBytes > previousWriteBytes ? snapshot.writeBytes - previousWriteBytes : 0
            let deltaReadOps = snapshot.readOps > previousReadOps ? snapshot.readOps - previousReadOps : 0
            let deltaWriteOps = snapshot.writeOps > previousWriteOps ? snapshot.writeOps - previousWriteOps : 0

            readBytesPerSec = Double(deltaReadBytes) / elapsed
            writeBytesPerSec = Double(deltaWriteBytes) / elapsed
            readOpsPerSec = Double(deltaReadOps) / elapsed
            writeOpsPerSec = Double(deltaWriteOps) / elapsed
        }

        previousReadOps = snapshot.readOps
        previousReadBytes = snapshot.readBytes
        previousWriteOps = snapshot.writeOps
        previousWriteBytes = snapshot.writeBytes
        previousTimestamp = now
        isAvailable = true

        return DiskIOMetrics(
            readBytes: snapshot.readBytes,
            writeBytes: snapshot.writeBytes,
            readBytesPerSec: readBytesPerSec,
            writeBytesPerSec: writeBytesPerSec,
            readOps: snapshot.readOps,
            writeOps: snapshot.writeOps,
            readOpsPerSec: readOpsPerSec,
            writeOpsPerSec: writeOpsPerSec
        )
    }

    func reset() async {
        previousReadOps = 0
        previousReadBytes = 0
        previousWriteOps = 0
        previousWriteBytes = 0
        previousTimestamp = nil
    }

    // MARK: - /proc/diskstats Parsing

    private func readProcDiskstats() async -> String? {
        let collector = OutputCollector()
        do {
            let process = try await pod.execInContainer(
                "main",
                processID: "metric-diskio-\(UUID().uuidString.prefix(8))",
                configuration: { config in
                    config.arguments = ["cat", "/proc/diskstats"]
                    config.workingDirectory = "/"
                    config.stdout = collector
                }
            )
            try await process.start()
            let status = try await process.wait(timeoutInSeconds: 3)
            guard status.exitCode == 0 else { return nil }
            return collector.getString()
        } catch {
            return nil
        }
    }

    /// Parse `/proc/diskstats` for the primary block device.
    ///
    /// Format (fields):
    /// ```
    ///  major minor name reads_completed reads_merged sectors_read ms_reading
    ///  writes_completed writes_merged sectors_written ms_writing
    ///  ios_in_progress ms_doing_io weighted_ms_doing_io
    /// ```
    ///
    /// Sectors are 512 bytes each.
    private func parseDiskstats(_ raw: String) -> DiskSnapshot? {
        // Look for vda (virtio) first, then sda, then any non-partition device
        let devicePriority = ["vda", "sda", "xvda"]

        for deviceName in devicePriority {
            if let snapshot = parseDeviceLine(raw, device: deviceName) {
                return snapshot
            }
        }

        // Fallback: first non-partition, non-loop, non-ram device
        for line in raw.split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard fields.count >= 14 else { continue }
            let name = String(fields[2])
            // Skip partitions (vda1, sda1), loop devices, ram devices
            if name.last?.isNumber == true && name.dropLast().last?.isLetter == true { continue }
            if name.hasPrefix("loop") || name.hasPrefix("ram") { continue }
            if let snapshot = parseDeviceLine(raw, device: name) {
                return snapshot
            }
        }

        return nil
    }

    private func parseDeviceLine(_ raw: String, device: String) -> DiskSnapshot? {
        for line in raw.split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard fields.count >= 14 else { continue }
            let name = String(fields[2])
            guard name == device else { continue }

            guard let readOps = UInt64(fields[3]),
                  let readSectors = UInt64(fields[5]),
                  let writeOps = UInt64(fields[7]),
                  let writeSectors = UInt64(fields[9]) else { continue }

            return DiskSnapshot(
                readOps: readOps,
                readBytes: readSectors * 512,
                writeOps: writeOps,
                writeBytes: writeSectors * 512
            )
        }
        return nil
    }
}

// MARK: - Disk Snapshot (internal)

private struct DiskSnapshot {
    let readOps: UInt64
    let readBytes: UInt64
    let writeOps: UInt64
    let writeBytes: UInt64
}

// MARK: - Duration Extension

private extension Swift.Duration {
    var totalSeconds: Double {
        let (seconds, attoseconds) = self.components
        return Double(seconds) + Double(attoseconds) * 1e-18
    }
}
