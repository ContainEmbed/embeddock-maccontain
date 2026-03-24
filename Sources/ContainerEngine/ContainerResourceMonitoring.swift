//===----------------------------------------------------------------------===//
//
// Container Resource Monitoring — Sub-Protocol
//
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - Container Resource Monitoring

/// Real-time resource monitoring for a running container.
///
/// This protocol provides access to continuous resource metric streams
/// and on-demand snapshot retrieval. Monitoring is active only while
/// a container is in the `.running` state.
@MainActor
public protocol ContainerResourceMonitoring {

    /// Whether resource monitoring is currently active.
    var isMonitoringResources: Bool { get }

    /// The resource limits of the currently running container, if any.
    ///
    /// Returns `nil` when no container is running. When a container is active,
    /// reflects the actual CPU and memory allocation used during VM creation.
    var activeResourceLimits: ContainerResourceLimits? { get }

    /// The most recent resource snapshot, if monitoring is active.
    var latestResourceSnapshot: ResourceSnapshot? { get }

    /// An `AsyncStream` of resource snapshots updated on each collection cycle.
    ///
    /// Returns `nil` if monitoring is not active. The stream finishes
    /// when the container stops or monitoring is explicitly stopped.
    ///
    /// Usage:
    /// ```swift
    /// if let stream = engine.resourceSnapshotStream {
    ///     for await snapshot in stream {
    ///         updateUI(with: snapshot)
    ///     }
    /// }
    /// ```
    var resourceSnapshotStream: AsyncStream<ResourceSnapshot>? { get }

    /// Start resource monitoring with the given configuration.
    ///
    /// Automatically called when a container starts, but can be
    /// manually restarted with different configuration.
    func startResourceMonitoring(configuration: ResourceMonitorConfiguration) async throws

    /// Stop resource monitoring.
    ///
    /// Automatically called when a container stops.
    func stopResourceMonitoring() async

    /// Get the history buffer of recent snapshots.
    ///
    /// Returns up to `configuration.historyBufferSize` snapshots.
    func resourceSnapshotHistory() async -> [ResourceSnapshot]
}
