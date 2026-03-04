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

// MARK: - Guest Bridge

/// Manages the guest-side bridge for forwarding connections to services
/// inside the container.
///
/// The container app listens directly on a Unix domain socket (direct mode).
/// No socat or other bridge process is needed — vminitd connects to the
/// guest Unix socket via the framework's `relayUnixSocket` API.
///
/// Architecture:
/// ```
/// Host (macOS)                       Guest (Linux Container)
/// ─────────────                      ─────────────────────────
/// relayUnixSocket → vminitd  ──────► [Container app on /tmp/bridge.sock]
/// ```
actor GuestBridge {
    private let pod: LinuxPod
    private let logger: Logger
    private var isRunning = false

    init(pod: LinuxPod, logger: Logger) {
        self.pod = pod
        self.logger = logger
    }

    /// Whether the bridge is currently active.
    var isBridgeRunning: Bool {
        isRunning
    }

    // MARK: - Direct Socket Mode

    /// Wait for the container app to create its Unix socket.
    ///
    /// In direct mode the container app listens on the Unix socket natively,
    /// eliminating:
    /// - socat process (fork per connection)
    /// - socat installation time (apk add)
    /// - Guest TCP stack for the data path
    ///
    /// Polls until the socket file appears inside the container.
    func startDirectMode(socketPath: String, pollTimeout: Duration = .seconds(10)) async throws {
        guard !isRunning else {
            logger.warning("⚠️ [GuestBridge] Bridge already running")
            return
        }

        logger.info("🔗 [GuestBridge] Direct mode: waiting for app to create \(socketPath)")

        let deadline = ContinuousClock.now + pollTimeout
        var found = false

        while ContinuousClock.now < deadline {
            do {
                let process = try await pod.execInContainer(
                    "main",
                    processID: "check-sock-\(UUID().uuidString.prefix(8))",
                    configuration: { config in
                        config.arguments = ["sh", "-c", "test -S \(socketPath)"]
                        config.workingDirectory = "/"
                    }
                )
                try await process.start()
                let status = try await process.wait(timeoutInSeconds: 3)
                if status.exitCode == 0 {
                    found = true
                    break
                }
            } catch {
                // Ignore transient exec failures during container boot
            }
            try await Task.sleep(for: .milliseconds(200))
        }

        guard found else {
            throw ContainerizationError(
                .timeout,
                message: "Direct mode: Unix socket \(socketPath) not created within \(pollTimeout). "
                    + "Ensure the container app sets UNIX_SOCKET=\(socketPath) and listens on it."
            )
        }

        isRunning = true
        logger.info("✅ [GuestBridge] Direct mode active — no socat needed")
    }

    // MARK: - Lifecycle

    /// Stop the bridge (resets state).
    func stopBridge() async {
        guard isRunning else { return }
        isRunning = false
        logger.info("✅ [GuestBridge] Bridge stopped")
    }

    // MARK: - Health Check

    /// Check if the Unix socket still exists inside the container.
    func checkBridgeHealth(socketPath: String) async -> Bool {
        guard isRunning else { return false }

        do {
            let process = try await pod.execInContainer(
                "main",
                processID: "check-bridge-\(UUID().uuidString.prefix(8))",
                configuration: { config in
                    config.arguments = ["sh", "-c", "test -S \(socketPath)"]
                    config.workingDirectory = "/"
                }
            )
            try await process.start()
            let status = try await process.wait(timeoutInSeconds: 5)
            return status.exitCode == 0
        } catch {
            logger.warning("⚠️ [GuestBridge] Health check failed: \(error)")
            return false
        }
    }
}
