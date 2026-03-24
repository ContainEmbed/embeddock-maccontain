//===----------------------------------------------------------------------===//
//
// GPU Collector — Protocol + Placeholder Implementation
//
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - GPU Collecting Protocol

/// Protocol for GPU metric collection.
protocol GPUCollecting: ResourceCollector where Metrics == GPUMetrics {}

// MARK: - Unavailable GPU Collector

/// Placeholder GPU collector that always returns unavailable.
///
/// Apple Virtualization does not currently support GPU passthrough
/// for Linux guests. This collector exists to satisfy the protocol
/// and allow future extension without breaking changes.
actor UnavailableGPUCollector: GPUCollecting, AnyResourceCollector {

    let metricType: MetricType = .gpu
    let isAvailable: Bool = false

    func collect() async -> GPUMetrics {
        .unavailable
    }

    func reset() async {
        // No-op
    }
}
