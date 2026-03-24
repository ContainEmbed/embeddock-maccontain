//===----------------------------------------------------------------------===//
//
// Resource Collector — Base Protocols
//
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - Resource Collector

/// Base protocol for all resource metric collectors.
///
/// Each collector is responsible for a single metric category.
/// Collectors are actors for thread safety and may maintain internal
/// state for delta calculations between collection intervals.
protocol ResourceCollector: Actor {

    /// The type of metrics this collector produces.
    associatedtype Metrics: Sendable & Equatable

    /// Collect the current metric values.
    ///
    /// Implementations should be lightweight (target < 100ms).
    /// If collection fails, return the `.unavailable` sentinel.
    func collect() async -> Metrics

    /// Reset any internal state (e.g. previous values for delta calculation).
    ///
    /// Called when monitoring is stopped and restarted.
    func reset() async
}

// MARK: - Any Resource Collector

/// Type-erased base for heterogeneous collector identification.
///
/// Allows the `ResourceMonitor` to query collector availability
/// and type without knowing the concrete `Metrics` associated type.
protocol AnyResourceCollector: Actor {

    /// The metric type this collector produces.
    var metricType: MetricType { get }

    /// Whether this collector is currently operational.
    var isAvailable: Bool { get }

    /// Reset the collector's internal state.
    func reset() async
}
