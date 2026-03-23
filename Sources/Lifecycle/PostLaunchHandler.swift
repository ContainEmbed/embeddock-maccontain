//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the Containerization project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import Foundation
import Containerization
import ContainerizationError
import Logging

/// Configuration describing what the post-launch handler should do.
struct PostLaunchOptions {
    /// Whether to perform an HTTP health check after the pod starts.
    let performHealthCheck: Bool
    /// Label used for diagnostic reports on failure.
    let phaseName: String
    /// Port the containerized application listens on.
    let port: Int

    static func imageStart(port: Int) -> PostLaunchOptions {
        PostLaunchOptions(performHealthCheck: true, phaseName: "startContainerFromImage", port: port)
    }

    static func nodeServer(port: Int) -> PostLaunchOptions {
        PostLaunchOptions(performHealthCheck: false, phaseName: "startNodeServer", port: port)
    }
}

/// Result of the post-launch phase, containing all resources the caller needs.
struct PostLaunchResult {
    let communicationManager: ContainerCommunicationManager?
    let isCommunicationReady: Bool
    let portForwarder: TcpPortForwarder?
    let containerURL: String
    let portForwardingStatus: ForwardingStatus
    let isHealthy: Bool
    let healthWarning: String?
    let diagnosticReport: DiagnosticReport?
}

/// Handles the shared post-launch steps after a pod is created and started.
///
/// Both `startContainerFromImage` and `startNodeServer` share the same
/// post-launch sequence:
/// 1. Optional HTTP health check
/// 2. Communication channel setup
/// 3. Container operations wiring
/// 4. TCP port forwarding
///
/// This class encapsulates that sequence and returns a `PostLaunchResult`
/// so the caller (ContainerManager) can apply the result to its state.
@MainActor
final class PostLaunchHandler {

    // MARK: - Dependencies

    private let diagnosticsHelper: DiagnosticsHelper
    private let containerOperations: ContainerOperations
    private let logger: Logger

    // MARK: - Initialization

    init(
        diagnosticsHelper: DiagnosticsHelper,
        containerOperations: ContainerOperations,
        logger: Logger
    ) {
        self.diagnosticsHelper = diagnosticsHelper
        self.containerOperations = containerOperations
        self.logger = logger
    }

    // MARK: - Public API

    /// Perform all post-launch steps and return the result.
    ///
    /// Optimization E: Health check, communication setup, and port forwarding
    /// now run in parallel instead of sequentially. Only ContainerOperations
    /// wiring must wait for communication setup.
    ///
    /// - Parameters:
    ///   - pod: The started LinuxPod.
    ///   - options: Configuration for the post-launch phase.
    /// - Returns: A `PostLaunchResult` with all resources and status.
    func handle(pod: LinuxPod, options: PostLaunchOptions) async -> PostLaunchResult {
        let startTime = ContinuousClock.now
        let port = options.port

        // ── Fire all three independent operations in parallel ────────────
        async let healthResult = performHealthCheck(
            pod: pod, port: port, enabled: options.performHealthCheck
        )
        async let commResult = setupCommunication(pod: pod, port: port)
        async let forwardingResult = setupPortForwarding(pod: pod, port: port)

        // Wait for communication first (needed for wiring ContainerOperations)
        let (commManager, commReady) = await commResult

        // Wire container operations (synchronous, depends on commManager)
        containerOperations.configure(
            pod: pod,
            communicationManager: commManager,
            diagnosticsHelper: diagnosticsHelper
        )

        // Await remaining parallel results
        let (isHealthy, healthWarning) = await healthResult
        let (forwarder, forwardingStatus, containerURL) = await forwardingResult

        logger.info("[PostLaunchHandler] Post-launch completed in \(ContinuousClock.now - startTime) (healthy=\(isHealthy), comm=\(commReady), forwarding=\(forwardingStatus))")

        return PostLaunchResult(
            communicationManager: commManager,
            isCommunicationReady: commReady,
            portForwarder: forwarder,
            containerURL: containerURL,
            portForwardingStatus: forwardingStatus,
            isHealthy: isHealthy,
            healthWarning: healthWarning,
            diagnosticReport: nil
        )
    }

    // MARK: - Private Steps

    /// Perform HTTP health check if enabled.
    private func performHealthCheck(
        pod: LinuxPod,
        port: Int,
        enabled: Bool
    ) async -> (Bool, String?) {
        guard enabled else {
            return (true, nil)
        }

        let httpResponding = await diagnosticsHelper.testHTTPResponseWithRetry(pod: pod, port: port)

        if httpResponding {
            return (true, nil)
        }

        // HTTP probe failed — check if port is at least listening
        let portListening = await diagnosticsHelper.isPortListening(
            pod: pod, containerID: "main", port: port
        )

        if portListening {
            logger.debug("[PostLaunchHandler] Port \(port) listening but HTTP probe failed — treating as healthy")
            return (true, nil)
        }

        logger.warning("[PostLaunchHandler] Port \(port) not listening after startup")
        return (false, "HTTP not responding on port \(port) — the server may still be starting or the image may not expose this port")
    }

    /// Creates a CommunicationManager and sets up HTTP communication.
    private func setupCommunication(
        pod: LinuxPod,
        port: Int
    ) async -> (ContainerCommunicationManager, Bool) {
        let commManager = ContainerCommunicationManager(pod: pod, logger: logger)
        var isReady = false

        do {
            _ = try await commManager.setupHTTPCommunication(port: port)
            isReady = true
        } catch {
            logger.warning("[PostLaunchHandler] Communication setup failed: \(error.localizedDescription)")
        }

        return (commManager, isReady)
    }

    /// Creates a TcpPortForwarder and attempts to start it.
    private func setupPortForwarding(
        pod: LinuxPod,
        port: Int
    ) async -> (TcpPortForwarder?, ForwardingStatus, String) {
        let forwarder = TcpPortForwarder(
            hostPort: UInt16(port),
            containerPort: UInt16(port),
            pod: pod,
            logger: logger
        )

        do {
            try await forwarder.start()
            return (forwarder, forwarder.status, "http://localhost:\(port)")
        } catch {
            logger.warning("[PostLaunchHandler] Port forwarding failed: \(error.localizedDescription)")
            return (nil, .error(error.localizedDescription), "http://localhost:\(port)")
        }
    }
}
