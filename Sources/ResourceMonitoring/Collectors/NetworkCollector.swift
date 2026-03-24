//===----------------------------------------------------------------------===//
//
// Network Collector — Protocol + Implementation
//
//===----------------------------------------------------------------------===//

import Foundation
import Containerization
import Logging

// MARK: - Network Collecting Protocol

/// Protocol for network metric collection.
protocol NetworkCollecting: ResourceCollector where Metrics == NetworkMetrics {}

// MARK: - Pod Network Collector

/// Collects network metrics from `/proc/net/dev` inside the Linux guest.
///
/// Parses per-interface counters and delta-calculates per-second rates.
actor PodNetworkCollector: NetworkCollecting, AnyResourceCollector {

    let metricType: MetricType = .network
    private(set) var isAvailable: Bool = true

    // MARK: - Dependencies

    private let pod: LinuxPod
    private let logger: Logger

    // MARK: - Delta State

    private var previousInterfaces: [String: InterfaceSnapshot] = [:]
    private var previousTimestamp: ContinuousClock.Instant?

    // MARK: - Initialization

    init(pod: LinuxPod, logger: Logger) {
        self.pod = pod
        self.logger = logger
    }

    // MARK: - Collection

    func collect() async -> NetworkMetrics {
        let now = ContinuousClock.now

        guard let raw = await readProcNetDev() else {
            isAvailable = false
            return .unavailable
        }

        let currentInterfaces = parseProcNetDev(raw)
        guard !currentInterfaces.isEmpty else {
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

        var interfaceMetrics: [InterfaceMetrics] = []
        var totalRxPerSec: Double = 0
        var totalTxPerSec: Double = 0
        var totalRx: UInt64 = 0
        var totalTx: UInt64 = 0

        for (name, current) in currentInterfaces {
            // Skip loopback
            guard name != "lo" else { continue }

            var rxPerSec: Double = 0
            var txPerSec: Double = 0

            if elapsed > 0, let prev = previousInterfaces[name] {
                let deltaRx = current.rxBytes > prev.rxBytes ? current.rxBytes - prev.rxBytes : 0
                let deltaTx = current.txBytes > prev.txBytes ? current.txBytes - prev.txBytes : 0
                rxPerSec = Double(deltaRx) / elapsed
                txPerSec = Double(deltaTx) / elapsed
            }

            totalRxPerSec += rxPerSec
            totalTxPerSec += txPerSec
            totalRx += current.rxBytes
            totalTx += current.txBytes

            interfaceMetrics.append(InterfaceMetrics(
                name: name,
                rxBytes: current.rxBytes,
                txBytes: current.txBytes,
                rxPackets: current.rxPackets,
                txPackets: current.txPackets,
                rxErrors: current.rxErrors,
                txErrors: current.txErrors,
                rxBytesPerSec: rxPerSec,
                txBytesPerSec: txPerSec
            ))
        }

        previousInterfaces = currentInterfaces
        previousTimestamp = now
        isAvailable = true

        return NetworkMetrics(
            interfaces: interfaceMetrics,
            totalRxBytesPerSec: totalRxPerSec,
            totalTxBytesPerSec: totalTxPerSec,
            totalRxBytes: totalRx,
            totalTxBytes: totalTx
        )
    }

    func reset() async {
        previousInterfaces = [:]
        previousTimestamp = nil
    }

    // MARK: - /proc/net/dev Parsing

    private func readProcNetDev() async -> String? {
        let collector = OutputCollector()
        do {
            let process = try await pod.execInContainer(
                "main",
                processID: "metric-network-\(UUID().uuidString.prefix(8))",
                configuration: { config in
                    config.arguments = ["cat", "/proc/net/dev"]
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

    /// Parse `/proc/net/dev` into per-interface snapshots.
    ///
    /// Format:
    /// ```
    /// Inter-|   Receive                                                |  Transmit
    ///  face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    ///   eth0: 1234   56   0   0   0   0   0   0   5678   90   0   0   0   0   0   0
    /// ```
    private func parseProcNetDev(_ raw: String) -> [String: InterfaceSnapshot] {
        var result: [String: InterfaceSnapshot] = [:]

        for line in raw.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colonIndex = trimmed.firstIndex(of: ":") else { continue }

            let name = String(trimmed[trimmed.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let rest = trimmed[trimmed.index(after: colonIndex)...]
            let values = rest.split(separator: " ").compactMap { UInt64($0) }

            // /proc/net/dev has 16 columns: 8 receive + 8 transmit
            guard values.count >= 10 else { continue }

            result[name] = InterfaceSnapshot(
                rxBytes: values[0],
                rxPackets: values[1],
                rxErrors: values[2],
                txBytes: values[8],
                txPackets: values[9],
                txErrors: values[10]
            )
        }

        return result
    }
}

// MARK: - Interface Snapshot (internal)

private struct InterfaceSnapshot {
    let rxBytes: UInt64
    let rxPackets: UInt64
    let rxErrors: UInt64
    let txBytes: UInt64
    let txPackets: UInt64
    let txErrors: UInt64
}

// MARK: - Duration Extension

private extension Swift.Duration {
    var totalSeconds: Double {
        let (seconds, attoseconds) = self.components
        return Double(seconds) + Double(attoseconds) * 1e-18
    }
}
