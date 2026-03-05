//===----------------------------------------------------------------------===//
//
// Container Lifecycle Protocol
//
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - Container Lifecycle

/// Manages the lifecycle of a container: initialisation, start, and stop.
///
/// Consumers observe state changes through `ContainerEngineDelegate`.
@MainActor
public protocol ContainerLifecycle: AnyObject {

    /// Current unified status of the container engine.
    var status: ContainerStatus { get }

    /// The URL where the container service is reachable (e.g. `http://localhost:3000`).
    var containerURL: String? { get }

    /// Whether a communication channel to the container is established.
    var isCommunicationReady: Bool { get }

    /// Convenience — `true` when the engine is in any active state.
    var isRunning: Bool { get }

    /// One-time setup: image store, event loop, composition modules.
    func initialize() async throws

    /// Start a container from an OCI image archive.
    func startFromImage(imageFile: URL, port: Int) async throws

    /// Pull and start a Node.js container with the given JS file.
    func startNodeServer(jsFile: URL, imageName: String, port: Int) async throws

    /// Stop the currently running container.
    func stop() async throws
}
