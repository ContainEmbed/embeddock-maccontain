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
    /// - Parameters:
    ///   - pod: The started LinuxPod.
    ///   - options: Configuration for the post-launch phase.
    /// - Returns: A `PostLaunchResult` with all resources and status.
    func handle(pod: LinuxPod, options: PostLaunchOptions) async -> PostLaunchResult {
        let port = options.port
        var isHealthy = true
        var healthWarning: String?

        // 1. HTTP health check (OCI image path only)
        if options.performHealthCheck {
            logger.info("🩺 [PostLaunchHandler] Starting health check on port \(port)...")
            let httpResponding = await diagnosticsHelper.testHTTPResponseWithRetry(pod: pod, port: port)
            if !httpResponding {
                // Gather extra context so the user knows exactly what went wrong.
                let portListening = await diagnosticsHelper.isPortListening(
                    pod: pod, containerID: "main", port: port
                )
                if portListening {
                    logger.warning("⚠️ [PostLaunchHandler] Port \(port) is listening but HTTP probe failed (no curl/wget, or non-HTTP service)")
                    // The server IS up — it just didn't respond to our probe tool.
                    // Treat as healthy with a soft warning so port-forwarding still works.
                    isHealthy = true
                    healthWarning = nil
                    logger.info("✅ [PostLaunchHandler] Port \(port) confirmed listening — treating as healthy")
                } else {
                    logger.warning("⚠️ [PostLaunchHandler] HTTP server not responding and port \(port) not listening")
                    isHealthy = false
                    healthWarning = "HTTP not responding on port \(port) — the server may still be starting or the image may not expose this port"
                }
            }
        }

        // 2. Communication setup
        let (commManager, commReady) = await setupCommunication(pod: pod, port: port)

        // 3. Wire container operations
        containerOperations.configure(
            pod: pod,
            communicationManager: commManager,
            diagnosticsHelper: diagnosticsHelper
        )

        // 4. Port forwarding
        let (forwarder, forwardingStatus, containerURL) = await setupPortForwarding(
            pod: pod,
            port: port
        )

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
            logger.info("✅ [PostLaunchHandler] Communication layer ready")
        } catch {
            logger.warning("⚠️ [PostLaunchHandler] Communication layer setup failed: \(error)")
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
            logger.info("✅ [PostLaunchHandler] Port forwarding active on localhost:\(port)")
            return (forwarder, forwarder.status, "http://localhost:\(port)")
        } catch {
            logger.warning("⚠️ [PostLaunchHandler] Port forwarding setup failed: \(error)")
            return (nil, .error(error.localizedDescription), "http://localhost:\(port)")
        }
    }
}
