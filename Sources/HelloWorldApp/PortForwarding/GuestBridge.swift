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

/// Manages the guest-side vsock to TCP bridge.
///
/// The GuestBridge handles setting up a bridge inside the container that
/// listens for vsock connections from the host and forwards them to
/// TCP services running inside the container.
///
/// Architecture:
/// ```
/// Host (macOS)                 Guest (Linux Container)
/// ─────────────                ─────────────────────────
/// pod.dialVsock(port)  ───────► [socat VSOCK-LISTEN:port]
///                                        │
///                                        ▼
///                              [TCP:localhost:containerPort]
///                                        │
///                                        ▼
///                              Container Service (e.g., Node.js)
/// ```
actor GuestBridge {
    private let pod: LinuxPod
    private let logger: Logger
    private var bridgeProcessID: String?
    private var isRunning = false
    
    init(pod: LinuxPod, logger: Logger) {
        self.pod = pod
        self.logger = logger
    }
    
    // MARK: - Tool Detection
    
    /// Check if socat is available in the container.
    func isSocatAvailable() async -> Bool {
        logger.debug("🔍 [GuestBridge] Checking if socat is available")
        
        do {
            let process = try await pod.execInContainer(
                "main",
                processID: "check-socat-\(UUID().uuidString.prefix(8))",
                configuration: { config in
                    config.arguments = ["which", "socat"]
                    config.workingDirectory = "/"
                }
            )
            try await process.start()
            let status = try await process.wait(timeoutInSeconds: 5)
            let available = status.exitCode == 0
            logger.info("📦 [GuestBridge] socat available: \(available)")
            return available
        } catch {
            logger.warning("⚠️ [GuestBridge] Failed to check socat: \(error)")
            return false
        }
    }
    
    /// Detect the package manager in the container.
    func detectPackageManager() async -> String? {
        logger.debug("🔍 [GuestBridge] Detecting package manager")
        
        // Try apk first (Alpine)
        if await commandExists("apk") {
            logger.info("📦 [GuestBridge] Detected Alpine (apk)")
            return "apk"
        }
        
        // Try apt-get (Debian/Ubuntu)
        if await commandExists("apt-get") {
            logger.info("📦 [GuestBridge] Detected Debian/Ubuntu (apt-get)")
            return "apt-get"
        }
        
        // Try yum (CentOS/RHEL)
        if await commandExists("yum") {
            logger.info("📦 [GuestBridge] Detected CentOS/RHEL (yum)")
            return "yum"
        }
        
        logger.warning("⚠️ [GuestBridge] No supported package manager found")
        return nil
    }
    
    private func commandExists(_ command: String) async -> Bool {
        do {
            let process = try await pod.execInContainer(
                "main",
                processID: "check-cmd-\(UUID().uuidString.prefix(8))",
                configuration: { config in
                    config.arguments = ["which", command]
                    config.workingDirectory = "/"
                }
            )
            try await process.start()
            let status = try await process.wait(timeoutInSeconds: 5)
            return status.exitCode == 0
        } catch {
            return false
        }
    }
    
    // MARK: - Installation
    
    /// Try to install socat using the available package manager.
    func installSocat() async -> Bool {
        guard let packageManager = await detectPackageManager() else {
            logger.warning("⚠️ [GuestBridge] Cannot install socat: no package manager")
            return false
        }
        
        logger.info("📥 [GuestBridge] Installing socat using \(packageManager)")
        
        let installCommand: [String]
        switch packageManager {
        case "apk":
            installCommand = ["apk", "add", "--no-cache", "socat"]
        case "apt-get":
            installCommand = ["sh", "-c", "apt-get update && apt-get install -y socat"]
        case "yum":
            installCommand = ["yum", "install", "-y", "socat"]
        default:
            return false
        }
        
        do {
            let process = try await pod.execInContainer(
                "main",
                processID: "install-socat-\(UUID().uuidString.prefix(8))",
                configuration: { config in
                    config.arguments = installCommand
                    config.workingDirectory = "/"
                }
            )
            try await process.start()
            let status = try await process.wait(timeoutInSeconds: 60)
            
            if status.exitCode == 0 {
                logger.info("✅ [GuestBridge] socat installed successfully")
                return true
            } else {
                logger.warning("⚠️ [GuestBridge] socat installation failed with exit code \(status.exitCode)")
                return false
            }
        } catch {
            logger.error("❌ [GuestBridge] Failed to install socat: \(error)")
            return false
        }
    }
    
    /// Ensure socat is available, installing it if necessary.
    func ensureSocatAvailable() async -> Bool {
        if await isSocatAvailable() {
            return true
        }
        
        logger.info("📦 [GuestBridge] socat not found, attempting installation...")
        return await installSocat()
    }
    
    // MARK: - Bridge Lifecycle
    
    /// Start a vsock bridge that listens on vsock and forwards to TCP inside the container.
    ///
    /// This is the recommended method for host-to-container communication.
    func startVsockBridge(vsockPort: UInt32, tcpPort: Int) async throws {
        guard !isRunning else {
            logger.warning("⚠️ [GuestBridge] Bridge already running")
            return
        }
        
        let processID = "vsock-bridge-\(UUID().uuidString.prefix(8))"
        
        // Try socat first - it has native vsock support
        if await ensureSocatAvailable() {
            logger.info("🚀 [GuestBridge] Starting socat vsock bridge: vsock:\(vsockPort) -> tcp:localhost:\(tcpPort)")
            
            // socat VSOCK-LISTEN listens for vsock connections from the host
            // CID 2 is the host, CID 3+ are guests
            // We use VSOCK-LISTEN:port,fork to accept connections from host
            let socatCommand = """
            while true; do
                socat VSOCK-LISTEN:\(vsockPort),reuseaddr,fork TCP:localhost:\(tcpPort) 2>&1 || sleep 1
            done
            """
            
            do {
                let process = try await pod.execInContainer(
                    "main",
                    processID: processID,
                    configuration: { config in
                        config.arguments = ["sh", "-c", socatCommand]
                        config.workingDirectory = "/"
                    }
                )
                
                try await process.start()
                bridgeProcessID = processID
                isRunning = true
                logger.info("✅ [GuestBridge] socat vsock bridge started")
                return
            } catch {
                logger.warning("⚠️ [GuestBridge] Failed to start socat vsock bridge: \(error)")
            }
        }
        
        // Fallback: Use a simple shell-based approach
        // Note: BusyBox nc doesn't support vsock, so we need a workaround
        logger.info("🔄 [GuestBridge] Falling back to TCP bridge (vsock handled by vminitd)")
        
        // The vminitd agent already handles vsock routing
        // We just need to ensure something listens on the expected port
        // The host will use pod.dialVsock() which connects to vminitd
        // vminitd can route to TCP ports inside the guest
        
        // For now, we'll start a simple nc listener that forwards to the app
        let hasNc = await commandExists("nc")
        
        if hasNc {
            // Start a TCP relay using named pipes
            let ncCommand = """
            rm -f /tmp/vsock_pipe_\(vsockPort) 2>/dev/null
            mkfifo /tmp/vsock_pipe_\(vsockPort) 2>/dev/null || true
            while true; do
                nc -l -p \(vsockPort) < /tmp/vsock_pipe_\(vsockPort) | nc localhost \(tcpPort) > /tmp/vsock_pipe_\(vsockPort) 2>/dev/null
                sleep 0.1
            done
            """
            
            do {
                let process = try await pod.execInContainer(
                    "main",
                    processID: processID,
                    configuration: { config in
                        config.arguments = ["sh", "-c", ncCommand]
                        config.workingDirectory = "/"
                    }
                )
                
                try await process.start()
                bridgeProcessID = processID
                isRunning = true
                logger.info("✅ [GuestBridge] nc TCP bridge started on port \(vsockPort)")
                return
            } catch {
                logger.warning("⚠️ [GuestBridge] Failed to start nc bridge: \(error)")
            }
        }
        
        throw ContainerizationError(.notFound, message: "No suitable bridge tool available in container")
    }
    
    /// Start the guest-side bridge using socat or shell fallback (legacy TCP-only method).
    func startBridge(vsockPort: UInt32, tcpPort: Int) async throws {
        guard !isRunning else {
            logger.warning("⚠️ [GuestBridge] Bridge already running")
            return
        }
        
        let processID = "vsock-bridge-\(UUID().uuidString.prefix(8))"
        
        // Try socat first
        if await ensureSocatAvailable() {
            logger.info("🚀 [GuestBridge] Starting socat bridge: port \(vsockPort) -> tcp:localhost:\(tcpPort)")
            
            // socat listens on a TCP port and forwards to the container's service
            let socatCommand = """
            while true; do
                socat TCP-LISTEN:\(vsockPort),reuseaddr,fork TCP:localhost:\(tcpPort) 2>/dev/null || sleep 1
            done
            """
            
            do {
                let process = try await pod.execInContainer(
                    "main",
                    processID: processID,
                    configuration: { config in
                        config.arguments = ["sh", "-c", socatCommand]
                        config.workingDirectory = "/"
                    }
                )
                
                // Start the process (runs in background)
                try await process.start()
                bridgeProcessID = processID
                isRunning = true
                logger.info("✅ [GuestBridge] socat bridge started with PID: \(processID)")
                return
            } catch {
                logger.warning("⚠️ [GuestBridge] Failed to start socat bridge: \(error)")
            }
        }
        
        // Fallback: Use a shell-based TCP proxy with named pipes
        // This works on BusyBox/Alpine where nc -e is not available
        logger.info("🔄 [GuestBridge] Falling back to shell-based bridge")
        
        // Check if nc exists
        let hasNc = await commandExists("nc")
        
        if hasNc {
            // Use a mkfifo-based bidirectional proxy that works with BusyBox nc
            // This creates a named pipe to enable bidirectional communication
            let ncCommand = """
            rm -f /tmp/backpipe 2>/dev/null
            mkfifo /tmp/backpipe 2>/dev/null || true
            while true; do
                nc -l -p \(vsockPort) < /tmp/backpipe | nc localhost \(tcpPort) > /tmp/backpipe 2>/dev/null
                sleep 0.1
            done
            """
            
            do {
                let process = try await pod.execInContainer(
                    "main",
                    processID: processID,
                    configuration: { config in
                        config.arguments = ["sh", "-c", ncCommand]
                        config.workingDirectory = "/"
                    }
                )
                
                try await process.start()
                bridgeProcessID = processID
                isRunning = true
                logger.info("✅ [GuestBridge] nc pipe bridge started with PID: \(processID)")
                return
            } catch {
                logger.warning("⚠️ [GuestBridge] Failed to start nc bridge: \(error)")
            }
        }
        
        // Last resort: Use built-in shell features if available
        logger.warning("⚠️ [GuestBridge] No suitable bridge tool available")
        throw ContainerizationError(.notFound, message: "No suitable bridge tool (socat or nc) available in container")
    }
    
    /// Stop the guest-side bridge.
    func stopBridge() async {
        guard isRunning, let processID = bridgeProcessID else {
            return
        }
        
        logger.info("🛑 [GuestBridge] Stopping bridge process: \(processID)")
        
        // Kill any socat/nc processes
        do {
            let process = try await pod.execInContainer(
                "main",
                processID: "kill-bridge-\(UUID().uuidString.prefix(8))",
                configuration: { config in
                    config.arguments = ["sh", "-c", "pkill -f 'socat.*\(processID)' 2>/dev/null; pkill -f 'nc.*\(processID)' 2>/dev/null; true"]
                    config.workingDirectory = "/"
                }
            )
            try await process.start()
            _ = try? await process.wait(timeoutInSeconds: 5)
        } catch {
            logger.warning("⚠️ [GuestBridge] Error stopping bridge: \(error)")
        }
        
        bridgeProcessID = nil
        isRunning = false
        logger.info("✅ [GuestBridge] Bridge stopped")
    }
}
