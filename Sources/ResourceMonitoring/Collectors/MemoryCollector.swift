//===----------------------------------------------------------------------===//
//
// Memory Collector — Protocol + Implementation
//
//===----------------------------------------------------------------------===//

import Foundation
import Containerization
import Logging

// MARK: - Memory Collecting Protocol

/// Protocol for memory metric collection.
protocol MemoryCollecting: ResourceCollector where Metrics == MemoryMetrics {}

// MARK: - Pod Memory Collector

/// Collects memory metrics using `pod.statistics()` and `/proc/meminfo`.
actor PodMemoryCollector: MemoryCollecting, AnyResourceCollector {

    let metricType: MetricType = .memory
    private(set) var isAvailable: Bool = true

    // MARK: - Dependencies

    private let pod: LinuxPod
    private let totalMemoryBytes: UInt64
    private let collectDetailed: Bool
    private let logger: Logger

    // MARK: - Initialization

    init(pod: LinuxPod, totalMemoryBytes: UInt64, collectDetailed: Bool, logger: Logger) {
        self.pod = pod
        self.totalMemoryBytes = totalMemoryBytes
        self.collectDetailed = collectDetailed
        self.logger = logger
    }

    // MARK: - Collection

    func collect() async -> MemoryMetrics {
        // 1. Get memory usage from pod.statistics()
        var usageBytes: UInt64 = 0
        do {
            let stats = try await pod.statistics()
            for stat in stats {
                usageBytes += stat.memory?.usageBytes ?? 0
            }
        } catch {
            logger.debug("[MemoryCollector] pod.statistics() failed: \(error.localizedDescription)")
            isAvailable = false
            return .unavailable
        }

        let usagePercent = totalMemoryBytes > 0
            ? (Double(usageBytes) / Double(totalMemoryBytes)) * 100.0
            : 0

        // 2. Optionally collect detailed /proc/meminfo
        var freeBytes: UInt64?
        var availableBytes: UInt64?
        var buffersBytes: UInt64?
        var cachedBytes: UInt64?
        var swapUsedBytes: UInt64?
        var swapTotalBytes: UInt64?

        if collectDetailed, let meminfo = await readProcMeminfo() {
            freeBytes = meminfo["MemFree"]
            availableBytes = meminfo["MemAvailable"]
            buffersBytes = meminfo["Buffers"]
            cachedBytes = meminfo["Cached"]
            let swapTotal = meminfo["SwapTotal"] ?? 0
            let swapFree = meminfo["SwapFree"] ?? 0
            swapTotalBytes = swapTotal
            swapUsedBytes = swapTotal > swapFree ? swapTotal - swapFree : 0
        }

        isAvailable = true

        return MemoryMetrics(
            usageBytes: usageBytes,
            totalBytes: totalMemoryBytes,
            usagePercent: usagePercent,
            freeBytes: freeBytes,
            availableBytes: availableBytes,
            buffersBytes: buffersBytes,
            cachedBytes: cachedBytes,
            swapUsedBytes: swapUsedBytes,
            swapTotalBytes: swapTotalBytes
        )
    }

    func reset() async {
        // No delta state to reset
    }

    // MARK: - /proc/meminfo Parsing

    private func readProcMeminfo() async -> [String: UInt64]? {
        let collector = OutputCollector()
        do {
            let process = try await pod.execInContainer(
                "main",
                processID: "metric-memory-\(UUID().uuidString.prefix(8))",
                configuration: { config in
                    config.arguments = ["cat", "/proc/meminfo"]
                    config.workingDirectory = "/"
                    config.stdout = collector
                }
            )
            try await process.start()
            let status = try await process.wait(timeoutInSeconds: 3)
            guard status.exitCode == 0 else { return nil }
            return parseMeminfo(collector.getString())
        } catch {
            return nil
        }
    }

    /// Parse `/proc/meminfo` output into key-value pairs (values in bytes).
    private func parseMeminfo(_ raw: String) -> [String: UInt64] {
        var result: [String: UInt64] = [:]
        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: ":")
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let valueParts = parts[1].split(separator: " ")
            guard let value = valueParts.first, let numericValue = UInt64(value) else { continue }
            // /proc/meminfo reports in kB
            let isKB = valueParts.count > 1 && valueParts[1] == "kB"
            result[key] = isKB ? numericValue * 1024 : numericValue
        }
        return result
    }
}
