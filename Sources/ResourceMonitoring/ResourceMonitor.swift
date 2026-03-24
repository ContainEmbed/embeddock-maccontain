//===----------------------------------------------------------------------===//
//
// Resource Monitor — Orchestrating Actor
//
//===----------------------------------------------------------------------===//

import Foundation
import Containerization
import Logging

// MARK: - Resource Monitor

/// Orchestrates periodic collection of all resource metrics.
///
/// The `ResourceMonitor` owns individual collectors and runs them on a
/// configurable timer. It produces an `AsyncStream<ResourceSnapshot>`
/// that UI layers consume, and also supports an `onSnapshot` callback
/// for integration with the existing `ContainerEngineDelegate` pattern.
///
/// **Lifecycle:** Created when a container starts, stopped when it stops.
actor ResourceMonitor {

    // MARK: - Configuration

    private let configuration: ResourceMonitorConfiguration
    private let logger: Logger

    // MARK: - Collectors (composed)

    private let cpuCollector: PodCPUCollector
    private let memoryCollector: PodMemoryCollector
    private let networkCollector: PodNetworkCollector?
    private let diskIOCollector: PodDiskIOCollector?
    private let gpuCollector: UnavailableGPUCollector

    // MARK: - State

    private var collectionTask: Task<Void, Never>?
    private var sequenceNumber: UInt64 = 0
    private var snapshotHistory: [ResourceSnapshot] = []
    private var streamContinuation: AsyncStream<ResourceSnapshot>.Continuation?

    // MARK: - Public Stream

    /// The async stream of resource snapshots.
    ///
    /// Consumers iterate this with `for await snapshot in monitor.snapshots { ... }`.
    nonisolated let snapshots: AsyncStream<ResourceSnapshot>

    // MARK: - Delegate Bridge

    /// Callback invoked on each new snapshot.
    ///
    /// Set by `DefaultContainerEngine` to forward snapshots to `ContainerEngineDelegate`.
    var onSnapshot: (@Sendable (ResourceSnapshot) -> Void)?

    /// Set the snapshot callback from outside the actor's isolation domain.
    func setOnSnapshot(_ handler: (@Sendable (ResourceSnapshot) -> Void)?) {
        self.onSnapshot = handler
    }

    // MARK: - Initialization

    init(
        pod: LinuxPod,
        coreCount: Int,
        totalMemoryBytes: UInt64,
        configuration: ResourceMonitorConfiguration = .default,
        logger: Logger
    ) {
        self.configuration = configuration
        self.logger = logger

        // Compose collectors
        self.cpuCollector = PodCPUCollector(
            pod: pod,
            coreCount: coreCount,
            collectDetailed: configuration.collectDetailedMetrics,
            logger: logger
        )
        self.memoryCollector = PodMemoryCollector(
            pod: pod,
            totalMemoryBytes: totalMemoryBytes,
            collectDetailed: configuration.collectDetailedMetrics,
            logger: logger
        )
        self.networkCollector = configuration.collectNetworkMetrics
            ? PodNetworkCollector(pod: pod, logger: logger)
            : nil
        self.diskIOCollector = configuration.collectDiskIOMetrics
            ? PodDiskIOCollector(pod: pod, logger: logger)
            : nil
        self.gpuCollector = UnavailableGPUCollector()

        // Create the AsyncStream with stored continuation
        var continuation: AsyncStream<ResourceSnapshot>.Continuation!
        self.snapshots = AsyncStream<ResourceSnapshot>(bufferingPolicy: .bufferingNewest(1)) { cont in
            continuation = cont
        }
        self.streamContinuation = continuation
    }

    // MARK: - Lifecycle

    /// Start the periodic collection loop.
    func start() {
        guard collectionTask == nil else {
            logger.warning("[ResourceMonitor] Already running")
            return
        }

        logger.info("[ResourceMonitor] Starting with interval \(configuration.collectionInterval)")

        collectionTask = Task { [weak self] in
            guard let self else { return }
            let sleepDuration = self.configuration.collectionInterval
            var previousTimestamp = ContinuousClock.now

            while !Task.isCancelled {
                try? await Task.sleep(for: sleepDuration)
                guard !Task.isCancelled else { break }

                let now = ContinuousClock.now
                let interval = now - previousTimestamp
                previousTimestamp = now

                let snapshot = await self.collectAll(intervalSeconds: interval.totalSeconds)
                await self.emit(snapshot)
            }
        }
    }

    /// Stop the periodic collection loop and reset all collectors.
    func stop() async {
        collectionTask?.cancel()
        collectionTask = nil
        streamContinuation?.finish()

        // Reset all collectors for clean restart
        await cpuCollector.reset()
        await memoryCollector.reset()
        await networkCollector?.reset()
        await diskIOCollector?.reset()
        await gpuCollector.reset()

        snapshotHistory.removeAll()
        sequenceNumber = 0

        logger.info("[ResourceMonitor] Stopped")
    }

    /// Return the history buffer of recent snapshots.
    func history() -> [ResourceSnapshot] {
        snapshotHistory
    }

    /// Return the most recent snapshot, if any.
    func latestSnapshot() -> ResourceSnapshot? {
        snapshotHistory.last
    }

    // MARK: - Private — Collection

    private func collectAll(intervalSeconds: TimeInterval) async -> ResourceSnapshot {
        var missingTypes: [MetricType] = []

        // Run collectors in parallel where possible.
        // CPU + Memory (pod.statistics) in parallel with Network + DiskIO (exec).
        async let cpuResult = cpuCollector.collect()
        async let memoryResult = memoryCollector.collect()
        async let networkResult = collectNetwork()
        async let diskIOResult = collectDiskIO()

        let cpu = await cpuResult
        let memory = await memoryResult
        let (network, networkMissing) = await networkResult
        let (diskIO, diskIOMissing) = await diskIOResult
        let gpu = GPUMetrics.unavailable

        if cpu == .unavailable { missingTypes.append(.cpu) }
        if memory == .unavailable { missingTypes.append(.memory) }
        if networkMissing { missingTypes.append(.network) }
        if diskIOMissing { missingTypes.append(.diskIO) }
        missingTypes.append(.gpu) // Always missing until GPU support is added

        // Determine quality — GPU unavailability doesn't count as degraded
        let quality: SnapshotQuality
        let significantMissing = missingTypes.filter { $0 != .gpu }
        if significantMissing.isEmpty {
            quality = .complete
        } else {
            quality = .degraded(missing: missingTypes)
        }

        sequenceNumber += 1

        return ResourceSnapshot(
            timestamp: Date(),
            intervalSeconds: intervalSeconds,
            cpu: cpu,
            memory: memory,
            network: network,
            diskIO: diskIO,
            gpu: gpu,
            sequenceNumber: sequenceNumber,
            quality: quality
        )
    }

    private func collectNetwork() async -> (NetworkMetrics, Bool) {
        guard let collector = networkCollector else {
            return (.unavailable, true)
        }
        let result = await collector.collect()
        return (result, result == .unavailable)
    }

    private func collectDiskIO() async -> (DiskIOMetrics, Bool) {
        guard let collector = diskIOCollector else {
            return (.unavailable, true)
        }
        let result = await collector.collect()
        return (result, result == .unavailable)
    }

    // MARK: - Private — Emit

    private func emit(_ snapshot: ResourceSnapshot) {
        // Update history buffer
        snapshotHistory.append(snapshot)
        if snapshotHistory.count > configuration.historyBufferSize {
            snapshotHistory.removeFirst(snapshotHistory.count - configuration.historyBufferSize)
        }

        // Push to AsyncStream
        streamContinuation?.yield(snapshot)

        // Invoke delegate callback
        onSnapshot?(snapshot)
    }
}

// MARK: - Duration Extension

private extension Swift.Duration {
    var totalSeconds: TimeInterval {
        let (seconds, attoseconds) = self.components
        return Double(seconds) + Double(attoseconds) * 1e-18
    }
}
