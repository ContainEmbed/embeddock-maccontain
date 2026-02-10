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
import ContainerizationExtras
import Logging

// MARK: - Cleanup Phase

/// Represents a phase in the cleanup process.
enum CleanupPhase: String {
    case portForwarder = "Port Forwarder"
    case communication = "Communication"
    case pod = "Pod"
    case state = "State"
}

// MARK: - Cleanup Result

/// Result of a cleanup phase.
struct CleanupResult {
    let phase: CleanupPhase
    let success: Bool
    let duration: TimeInterval
    let error: Error?
}

// MARK: - Cleanup Coordinator

/// Coordinates the orderly shutdown of container resources.
///
/// Ensures resources are cleaned up in the correct order with proper timeouts,
/// following the Coordinator pattern for managing complex multi-step processes.
actor CleanupCoordinator {
    private let logger: Logger
    
    /// Default timeouts for each cleanup phase.
    struct Timeouts {
        let portForwarder: UInt32
        let communication: UInt32
        let pod: UInt32
        let master: UInt32
        
        static let `default` = Timeouts(
            portForwarder: 5,
            communication: 3,
            pod: 15,
            master: 30
        )
        
        static let aggressive = Timeouts(
            portForwarder: 2,
            communication: 1,
            pod: 5,
            master: 10
        )
    }
    
    init(logger: Logger) {
        self.logger = logger
    }
    
    // MARK: - Full Cleanup
    
    /// Perform a complete cleanup of all container resources.
    ///
    /// This method is idempotent - calling it multiple times is safe.
    ///
    /// - Parameters:
    ///   - pod: The Linux pod to stop (optional).
    ///   - portForwarder: The port forwarder to stop (optional).
    ///   - communicationManager: The communication manager to disconnect (optional).
    ///   - timeouts: Timeout configuration for each phase.
    /// - Returns: Array of cleanup results for each phase.
    @discardableResult
    func performFullCleanup(
        pod: LinuxPod?,
        portForwarder: TcpPortForwarder?,
        communicationManager: CommunicationManager?,
        timeouts: Timeouts = .default
    ) async -> [CleanupResult] {
        logger.info("🧹 [CleanupCoordinator] Starting full cleanup sequence")
        var results: [CleanupResult] = []
        
        // Phase 1: Stop port forwarding (non-blocking, quick)
        if let forwarder = portForwarder {
            let result = await stopPortForwarder(forwarder, timeout: timeouts.portForwarder)
            results.append(result)
        }
        
        // Phase 2: Disconnect communication (non-blocking, quick)
        if let commManager = communicationManager {
            let result = await stopCommunication(commManager, timeout: timeouts.communication)
            results.append(result)
        }
        
        // Phase 3: Stop pod (may take longer)
        if let pod = pod {
            let result = await stopPod(pod, timeout: timeouts.pod)
            results.append(result)
        }
        
        logCleanupSummary(results)
        return results
    }
    
    /// Perform cleanup with a master timeout that cancels everything if exceeded.
    ///
    /// - Parameters:
    ///   - pod: The Linux pod to stop.
    ///   - portForwarder: The port forwarder to stop.
    ///   - communicationManager: The communication manager to disconnect.
    ///   - masterTimeout: Maximum time for entire cleanup.
    /// - Returns: True if cleanup completed within timeout.
    func performCleanupWithMasterTimeout(
        pod: LinuxPod?,
        portForwarder: TcpPortForwarder?,
        communicationManager: CommunicationManager?,
        masterTimeout: UInt32 = 30
    ) async -> Bool {
        logger.info("🧹 [CleanupCoordinator] Starting cleanup with \(masterTimeout)s master timeout")
        
        do {
            try await Timeout.run(seconds: masterTimeout) { [self] in
                await self.performFullCleanup(
                    pod: pod,
                    portForwarder: portForwarder,
                    communicationManager: communicationManager
                )
            }
            logger.info("✅ [CleanupCoordinator] Cleanup completed within timeout")
            return true
        } catch {
            logger.error("⏰ [CleanupCoordinator] Cleanup timed out after \(masterTimeout)s")
            return false
        }
    }
    
    // MARK: - Individual Cleanup Methods
    
    /// Stop the port forwarder with timeout.
    private func stopPortForwarder(_ forwarder: TcpPortForwarder, timeout: UInt32) async -> CleanupResult {
        logger.debug("🔄 [Cleanup] Stopping port forwarder...")
        let startTime = Date()
        
        do {
            try await Timeout.run(seconds: timeout) {
                await forwarder.stop()
            }
            let duration = Date().timeIntervalSince(startTime)
            logger.debug("✅ [Cleanup] Port forwarder stopped in \(String(format: "%.2f", duration))s")
            return CleanupResult(phase: .portForwarder, success: true, duration: duration, error: nil)
        } catch {
            let duration = Date().timeIntervalSince(startTime)
            logger.warning("⚠️ [Cleanup] Port forwarder stop timed out after \(timeout)s")
            return CleanupResult(phase: .portForwarder, success: false, duration: duration, error: error)
        }
    }
    
    /// Stop the communication manager with timeout.
    private func stopCommunication(_ commManager: CommunicationManager, timeout: UInt32) async -> CleanupResult {
        logger.debug("🔄 [Cleanup] Disconnecting communication...")
        let startTime = Date()
        
        do {
            try await Timeout.run(seconds: timeout) {
                await commManager.disconnect()
            }
            let duration = Date().timeIntervalSince(startTime)
            logger.debug("✅ [Cleanup] Communication disconnected in \(String(format: "%.2f", duration))s")
            return CleanupResult(phase: .communication, success: true, duration: duration, error: nil)
        } catch {
            let duration = Date().timeIntervalSince(startTime)
            logger.warning("⚠️ [Cleanup] Communication disconnect timed out after \(timeout)s")
            return CleanupResult(phase: .communication, success: false, duration: duration, error: error)
        }
    }
    
    /// Stop the pod with timeout.
    private func stopPod(_ pod: LinuxPod, timeout: UInt32) async -> CleanupResult {
        logger.debug("🔄 [Cleanup] Stopping pod...")
        let startTime = Date()
        
        do {
            try await Timeout.run(seconds: timeout) {
                try await pod.stop()
            }
            let duration = Date().timeIntervalSince(startTime)
            logger.debug("✅ [Cleanup] Pod stopped in \(String(format: "%.2f", duration))s")
            return CleanupResult(phase: .pod, success: true, duration: duration, error: nil)
        } catch is CancellationError {
            let duration = Date().timeIntervalSince(startTime)
            logger.warning("⚠️ [Cleanup] Pod stop timed out after \(timeout)s, VM may be orphaned")
            return CleanupResult(phase: .pod, success: false, duration: duration, error: nil)
        } catch {
            let duration = Date().timeIntervalSince(startTime)
            logger.warning("⚠️ [Cleanup] Pod stop error: \(error)")
            return CleanupResult(phase: .pod, success: false, duration: duration, error: error)
        }
    }
    
    // MARK: - Logging
    
    private func logCleanupSummary(_ results: [CleanupResult]) {
        let successful = results.filter { $0.success }.count
        let total = results.count
        let totalDuration = results.reduce(0) { $0 + $1.duration }
        
        if successful == total {
            logger.info("✅ [CleanupCoordinator] All \(total) phases completed successfully in \(String(format: "%.2f", totalDuration))s")
        } else {
            logger.warning("⚠️ [CleanupCoordinator] \(successful)/\(total) phases completed successfully in \(String(format: "%.2f", totalDuration))s")
            for result in results where !result.success {
                logger.warning("  - \(result.phase.rawValue): failed after \(String(format: "%.2f", result.duration))s")
            }
        }
    }
}
