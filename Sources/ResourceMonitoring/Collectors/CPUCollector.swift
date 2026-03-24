//===----------------------------------------------------------------------===//
//
// CPU Collector — Protocol + Implementation
//
//===----------------------------------------------------------------------===//

import Foundation
import Containerization
import Logging

// MARK: - CPU Collecting Protocol

/// Protocol for CPU metric collection.
protocol CPUCollecting: ResourceCollector where Metrics == CPUMetrics {}

// MARK: - Pod CPU Collector

/// Collects CPU metrics using `pod.statistics()` and optionally `/proc/stat`.
///
/// Delta-calculates CPU percentage from cumulative microsecond counters
/// between successive collection intervals.
actor PodCPUCollector: CPUCollecting, AnyResourceCollector {

    let metricType: MetricType = .cpu
    private(set) var isAvailable: Bool = true

    // MARK: - Dependencies

    private let pod: LinuxPod
    private let coreCount: Int
    private let collectDetailed: Bool
    private let logger: Logger

    // MARK: - Delta State

    private var previousUsageUsec: UInt64 = 0
    private var previousTimestamp: ContinuousClock.Instant?
    private var previousProcStat: ProcStatSnapshot?

    // MARK: - Initialization

    init(pod: LinuxPod, coreCount: Int, collectDetailed: Bool, logger: Logger) {
        self.pod = pod
        self.coreCount = coreCount
        self.collectDetailed = collectDetailed
        self.logger = logger
    }

    // MARK: - Collection

    func collect() async -> CPUMetrics {
        let now = ContinuousClock.now

        // 1. Get cumulative CPU usage from pod.statistics()
        var currentUsageUsec: UInt64 = 0
        do {
            let stats = try await pod.statistics()
            for stat in stats {
                currentUsageUsec += stat.cpu?.usageUsec ?? 0
            }
        } catch {
            logger.debug("[CPUCollector] pod.statistics() failed: \(error.localizedDescription)")
            isAvailable = false
            return .unavailable
        }

        // 2. Calculate delta percentage
        var usagePercent: Double = 0
        if let prevTimestamp = previousTimestamp {
            let elapsed = now - prevTimestamp
            let elapsedUsec = elapsed.totalMicroseconds
            if elapsedUsec > 0 {
                let deltaUsec = currentUsageUsec.subtractingClamped(previousUsageUsec)
                usagePercent = (Double(deltaUsec) / Double(elapsedUsec)) * 100.0
            }
        }

        // 3. Optionally collect detailed /proc/stat breakdown
        var perCore: [Double]?
        var userPct: Double?
        var systemPct: Double?
        var idlePct: Double?

        if collectDetailed {
            if let procStat = await readProcStat() {
                if let prev = previousProcStat {
                    let parsed = parseProcStatDelta(previous: prev, current: procStat)
                    perCore = parsed.perCore
                    userPct = parsed.user
                    systemPct = parsed.system
                    idlePct = parsed.idle
                }
                previousProcStat = procStat
            }
        }

        // 4. Store state for next delta
        previousUsageUsec = currentUsageUsec
        previousTimestamp = now
        isAvailable = true

        return CPUMetrics(
            usagePercent: usagePercent,
            cumulativeUsageUsec: currentUsageUsec,
            perCoreUsagePercent: perCore,
            userPercent: userPct,
            systemPercent: systemPct,
            idlePercent: idlePct,
            coreCount: coreCount
        )
    }

    func reset() async {
        previousUsageUsec = 0
        previousTimestamp = nil
        previousProcStat = nil
    }

    // MARK: - /proc/stat Parsing

    private func readProcStat() async -> ProcStatSnapshot? {
        let collector = OutputCollector()
        do {
            let process = try await pod.execInContainer(
                "main",
                processID: "metric-cpu-\(UUID().uuidString.prefix(8))",
                configuration: { config in
                    config.arguments = ["cat", "/proc/stat"]
                    config.workingDirectory = "/"
                    config.stdout = collector
                }
            )
            try await process.start()
            let status = try await process.wait(timeoutInSeconds: 3)
            guard status.exitCode == 0 else { return nil }
            return ProcStatSnapshot.parse(collector.getString())
        } catch {
            return nil
        }
    }

    private func parseProcStatDelta(previous: ProcStatSnapshot, current: ProcStatSnapshot) -> ProcStatParsed {
        let deltaTotal = current.totalAll.subtractingClamped(previous.totalAll)
        guard deltaTotal > 0 else {
            return ProcStatParsed(perCore: nil, user: nil, system: nil, idle: nil)
        }

        let deltaUser = current.user.subtractingClamped(previous.user)
        let deltaSystem = current.system.subtractingClamped(previous.system)
        let deltaIdle = current.idle.subtractingClamped(previous.idle)

        let userPct = Double(deltaUser) / Double(deltaTotal) * 100.0
        let systemPct = Double(deltaSystem) / Double(deltaTotal) * 100.0
        let idlePct = Double(deltaIdle) / Double(deltaTotal) * 100.0

        // Per-core
        var perCore: [Double]?
        if current.perCoreTotals.count == previous.perCoreTotals.count, !current.perCoreTotals.isEmpty {
            perCore = zip(previous.perCoreTotals, current.perCoreTotals).map { prev, curr in
                let dt = curr.total.subtractingClamped(prev.total)
                let di = curr.idle.subtractingClamped(prev.idle)
                guard dt > 0 else { return 0 }
                return (1.0 - Double(di) / Double(dt)) * 100.0
            }
        }

        return ProcStatParsed(perCore: perCore, user: userPct, system: systemPct, idle: idlePct)
    }
}

// MARK: - /proc/stat Data Structures

struct ProcStatSnapshot: Sendable {
    let user: UInt64
    let nice: UInt64
    let system: UInt64
    let idle: UInt64
    let iowait: UInt64
    let irq: UInt64
    let softirq: UInt64
    let totalAll: UInt64
    let perCoreTotals: [(idle: UInt64, total: UInt64)]

    static func parse(_ raw: String) -> ProcStatSnapshot? {
        let lines = raw.split(separator: "\n")
        guard let cpuLine = lines.first(where: { $0.hasPrefix("cpu ") }) else { return nil }

        let values = cpuLine.split(separator: " ").dropFirst().compactMap { UInt64($0) }
        guard values.count >= 7 else { return nil }

        let user = values[0]
        let nice = values[1]
        let system = values[2]
        let idle = values[3]
        let iowait = values[4]
        let irq = values[5]
        let softirq = values[6]
        let total = values.reduce(0, +)

        // Per-core lines: cpu0, cpu1, ...
        var perCore: [(idle: UInt64, total: UInt64)] = []
        for line in lines where line.hasPrefix("cpu") && !line.hasPrefix("cpu ") {
            let vals = line.split(separator: " ").dropFirst().compactMap { UInt64($0) }
            if vals.count >= 4 {
                let coreTotal = vals.reduce(0, +)
                let coreIdle = vals[3]
                perCore.append((idle: coreIdle, total: coreTotal))
            }
        }

        return ProcStatSnapshot(
            user: user, nice: nice, system: system, idle: idle,
            iowait: iowait, irq: irq, softirq: softirq,
            totalAll: total, perCoreTotals: perCore
        )
    }
}

private struct ProcStatParsed {
    let perCore: [Double]?
    let user: Double?
    let system: Double?
    let idle: Double?
}

// MARK: - Helpers

private extension UInt64 {
    func subtractingClamped(_ other: UInt64) -> UInt64 {
        self > other ? self - other : 0
    }
}

private extension Swift.Duration {
    var totalMicroseconds: UInt64 {
        let (seconds, attoseconds) = self.components
        return UInt64(seconds) * 1_000_000 + UInt64(attoseconds / 1_000_000_000_000)
    }
}
