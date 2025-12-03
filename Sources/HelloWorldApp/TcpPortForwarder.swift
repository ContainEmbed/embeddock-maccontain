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
import Network

// MARK: - Resumable Once Helper

/// A thread-safe helper to ensure a continuation is only resumed once
final class ResumableOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var _hasResumed = false
    
    var hasResumed: Bool {
        lock.withLock { _hasResumed }
    }
    
    /// Attempts to mark as resumed. Returns true if this was the first call.
    func tryResume() -> Bool {
        lock.withLock {
            if _hasResumed {
                return false
            }
            _hasResumed = true
            return true
        }
    }
}

// MARK: - Forwarding Status

/// Status of the port forwarding system
public enum ForwardingStatus: Equatable, Sendable {
    case inactive
    case starting
    case active(connections: Int)
    case error(String)
    
    public var isActive: Bool {
        if case .active = self { return true }
        return false
    }
    
    public var description: String {
        switch self {
        case .inactive:
            return "Inactive"
        case .starting:
            return "Starting..."
        case .active(let count):
            return "Active (\(count) connection\(count == 1 ? "" : "s"))"
        case .error(let message):
            return "Error: \(message)"
        }
    }
}

// MARK: - Guest Bridge

/// Manages the guest-side vsock to TCP bridge
actor GuestBridge {
    private let pod: LinuxPod
    private let logger: Logger
    private var bridgeProcessID: String?
    private var isRunning = false
    
    init(pod: LinuxPod, logger: Logger) {
        self.pod = pod
        self.logger = logger
    }
    
    /// Check if socat is available in the container
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
    
    /// Detect the package manager in the container
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
    
    /// Try to install socat using the available package manager
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
    
    /// Ensure socat is available, installing it if necessary
    func ensureSocatAvailable() async -> Bool {
        if await isSocatAvailable() {
            return true
        }
        
        logger.info("📦 [GuestBridge] socat not found, attempting installation...")
        return await installSocat()
    }
    
    /// Start a vsock bridge that listens on vsock and forwards to TCP inside the container
    /// This is the recommended method for host-to-container communication
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
    
    /// Start the guest-side bridge using socat or shell fallback (legacy TCP-only method)
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
    
    /// Stop the guest-side bridge
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

// MARK: - TCP Port Forwarder

/// A TCP port forwarder that bridges host TCP connections to container via vsock
/// 
/// Architecture:
/// ```
/// External Request (localhost:hostPort)
///        ↓
/// [NWListener on macOS host]
///        ↓
/// [pod.dialVsock(vsockPort) - connects to VM via vsock]
///        ↓
/// [Guest Bridge (socat/nc): vsockPort → containerPort via TCP inside container]
///        ↓
/// Container Service (localhost:containerPort inside container)
/// ```
/// 
/// Note: The NAT network (192.168.127.0/24) is internal to the VM and not 
/// directly routable from macOS. We must use vsock as the transport.
@MainActor
class TcpPortForwarder: ObservableObject {
    // Configuration
    private let hostPort: UInt16
    private let containerPort: UInt16
    private let vsockPort: UInt32  // Vsock port for host-VM communication
    private let pod: LinuxPod
    private let logger: Logger
    
    // State
    @Published private(set) var status: ForwardingStatus = .inactive
    private var listener: NWListener?
    private var activeConnections: [UUID: ConnectionRelay] = [:]
    private var guestBridge: GuestBridge?
    private var connectionTasks: [UUID: Task<Void, Never>] = [:]
    
    // Retry configuration
    private let maxRetries = 5
    private let baseRetryDelay: TimeInterval = 1.0
    private let maxRetryDelay: TimeInterval = 30.0
    
    init(
        hostPort: UInt16 = 3000,
        containerPort: UInt16 = 3000,
        bridgePort: UInt16 = 5000,
        pod: LinuxPod,
        logger: Logger
    ) {
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.vsockPort = UInt32(bridgePort)
        self.pod = pod
        self.logger = logger
    }
    
    /// Start port forwarding
    func start() async throws {
        guard case .inactive = status else {
            logger.warning("⚠️ [TcpPortForwarder] Already running or starting")
            return
        }
        
        status = .starting
        logger.info("🚀 [TcpPortForwarder] Starting port forwarding: localhost:\(hostPort) -> container:\(containerPort) via vsock:\(vsockPort)")
        
        do {
            // Step 1: Start guest bridge that listens on vsock and forwards to container TCP
            logger.info("📡 [TcpPortForwarder] Step 1: Starting guest vsock bridge")
            guestBridge = GuestBridge(pod: pod, logger: logger)
            try await guestBridge?.startVsockBridge(vsockPort: vsockPort, tcpPort: Int(containerPort))
            
            // Give the bridge a moment to start
            try await Task.sleep(for: .milliseconds(500))
            
            // Step 2: Create NWListener on host
            logger.info("📡 [TcpPortForwarder] Step 2: Creating TCP listener on port \(hostPort)")
            try await startListener()
            
            status = .active(connections: 0)
            logger.info("✅ [TcpPortForwarder] Port forwarding active: localhost:\(hostPort) -> container:\(containerPort)")
            
        } catch {
            logger.error("❌ [TcpPortForwarder] Failed to start: \(error)")
            status = .error(error.localizedDescription)
            await cleanup()
            throw error
        }
    }
    
    /// Stop port forwarding
    func stop() async {
        logger.info("🛑 [TcpPortForwarder] Stopping port forwarding")
        await cleanup()
        status = .inactive
        logger.info("✅ [TcpPortForwarder] Port forwarding stopped")
    }
    
    private func cleanup() async {
        // Cancel all connection tasks
        for (_, task) in connectionTasks {
            task.cancel()
        }
        connectionTasks.removeAll()
        
        // Close all active connections
        for (_, relay) in activeConnections {
            relay.close()
        }
        activeConnections.removeAll()
        
        // Stop listener
        listener?.cancel()
        listener = nil
        
        // Stop guest bridge
        await guestBridge?.stopBridge()
        guestBridge = nil
    }
    
    private func startListener() async throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        
        do {
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: hostPort)!)
        } catch {
            throw ContainerizationError(.internalError, message: "Failed to create listener on port \(hostPort): \(error)")
        }
        
        listener?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            
            Task { @MainActor in
                switch state {
                case .ready:
                    self.logger.info("✅ [TcpPortForwarder] Listener ready on port \(self.hostPort)")
                case .failed(let error):
                    self.logger.error("❌ [TcpPortForwarder] Listener failed: \(error)")
                    self.status = .error("Listener failed: \(error.localizedDescription)")
                case .cancelled:
                    self.logger.info("🛑 [TcpPortForwarder] Listener cancelled")
                default:
                    break
                }
            }
        }
        
        listener?.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            
            Task { @MainActor in
                await self.handleNewConnection(connection)
            }
        }
        
        listener?.start(queue: .global(qos: .userInitiated))
        
        // Wait for listener to be ready using a sendable wrapper
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumeOnce = ResumableOnce()
            
            listener?.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if resumeOnce.tryResume() {
                        continuation.resume()
                    }
                case .failed(let error):
                    if resumeOnce.tryResume() {
                        continuation.resume(throwing: error)
                    }
                case .cancelled:
                    if resumeOnce.tryResume() {
                        continuation.resume(throwing: ContainerizationError(.invalidState, message: "Listener cancelled"))
                    }
                default:
                    break
                }
                
                // Restore the original handler
                if resumeOnce.hasResumed {
                    Task { @MainActor in
                        self?.setupListenerStateHandler()
                    }
                }
            }
        }
    }
    
    private func setupListenerStateHandler() {
        listener?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            
            Task { @MainActor in
                switch state {
                case .failed(let error):
                    self.logger.error("❌ [TcpPortForwarder] Listener failed: \(error)")
                    self.status = .error("Listener failed: \(error.localizedDescription)")
                case .cancelled:
                    self.logger.info("🛑 [TcpPortForwarder] Listener cancelled")
                default:
                    break
                }
            }
        }
    }
    
    private func handleNewConnection(_ incomingConnection: NWConnection) async {
        let connectionID = UUID()
        logger.info("📥 [TcpPortForwarder] New connection: \(connectionID)")
        
        // Start the incoming connection
        incomingConnection.start(queue: .global(qos: .userInitiated))
        
        // Create a task to handle this connection via vsock
        let task = Task { [weak self] in
            guard let self = self else { return }
            await self.relayConnectionViaVsock(connectionID: connectionID, incoming: incomingConnection)
        }
        
        connectionTasks[connectionID] = task
    }
    
    private func relayConnectionViaVsock(connectionID: UUID, incoming: NWConnection) async {
        var vsockHandle: FileHandle? = nil
        
        defer {
            incoming.cancel()
            try? vsockHandle?.close()
            Task { @MainActor in
                self.activeConnections.removeValue(forKey: connectionID)
                self.connectionTasks.removeValue(forKey: connectionID)
                self.updateConnectionCount()
                self.logger.info("🔌 [TcpPortForwarder] Connection closed: \(connectionID)")
            }
        }
        
        // Wait for incoming connection to be ready
        do {
            try await waitForConnectionReady(incoming)
            logger.debug("✅ [TcpPortForwarder] Incoming connection ready: \(connectionID)")
        } catch {
            logger.warning("⚠️ [TcpPortForwarder] Incoming connection failed: \(error)")
            return
        }
        
        // Connect to the VM via vsock
        logger.debug("🔗 [TcpPortForwarder] Dialing vsock port \(vsockPort)")
        do {
            vsockHandle = try await pod.dialVsock(port: vsockPort)
            logger.debug("✅ [TcpPortForwarder] Vsock connection established")
        } catch {
            logger.warning("⚠️ [TcpPortForwarder] Failed to dial vsock:\(vsockPort): \(error)")
            return
        }
        
        guard let vsock = vsockHandle else {
            logger.warning("⚠️ [TcpPortForwarder] Vsock handle is nil")
            return
        }
        
        // Create a relay wrapper
        let relay = ConnectionRelay(
            connectionID: connectionID,
            tcpConnection: incoming,
            vsockHandle: vsock,
            logger: logger
        )
        
        await MainActor.run {
            activeConnections[connectionID] = relay
            updateConnectionCount()
        }
        
        logger.info("🔗 [TcpPortForwarder] Relay established for \(connectionID)")
        
        // Start bidirectional relay
        await relay.startRelay()
    }
    
    private func waitForConnectionReady(_ connection: NWConnection, timeout: TimeInterval = 10.0) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumeOnce = ResumableOnce()
            
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumeOnce.tryResume() {
                        continuation.resume()
                    }
                case .failed(let error):
                    if resumeOnce.tryResume() {
                        continuation.resume(throwing: error)
                    }
                case .cancelled:
                    if resumeOnce.tryResume() {
                        continuation.resume(throwing: ContainerizationError(.invalidState, message: "Connection cancelled"))
                    }
                default:
                    break
                }
            }
        }
    }
    
    private func updateConnectionCount() {
        let count = activeConnections.count
        if case .active = status {
            status = .active(connections: count)
        }
    }
}

// MARK: - Connection Relay

/// Handles bidirectional data relay between a TCP connection and a vsock FileHandle
final class ConnectionRelay: @unchecked Sendable {
    let connectionID: UUID
    private let tcpConnection: NWConnection
    private let vsockHandle: FileHandle
    private let logger: Logger
    private var isClosed = false
    private let lock = NSLock()
    
    init(connectionID: UUID, tcpConnection: NWConnection, vsockHandle: FileHandle, logger: Logger) {
        self.connectionID = connectionID
        self.tcpConnection = tcpConnection
        self.vsockHandle = vsockHandle
        self.logger = logger
    }
    
    func close() {
        lock.withLock {
            guard !isClosed else { return }
            isClosed = true
        }
        tcpConnection.cancel()
        try? vsockHandle.close()
    }
    
    func startRelay() async {
        await withTaskGroup(of: Void.self) { group in
            // TCP -> Vsock
            group.addTask {
                await self.relayTcpToVsock()
            }
            
            // Vsock -> TCP
            group.addTask {
                await self.relayVsockToTcp()
            }
        }
        
        close()
    }
    
    private func relayTcpToVsock() async {
        while !Task.isCancelled {
            do {
                let data = try await receiveTcpData()
                
                guard let data = data, !data.isEmpty else {
                    logger.debug("📤 [Relay:\(connectionID.uuidString.prefix(8))] TCP->Vsock EOF")
                    break
                }
                
                try vsockHandle.write(contentsOf: data)
                logger.debug("📤 [Relay:\(connectionID.uuidString.prefix(8))] TCP->Vsock \(data.count) bytes")
                
            } catch {
                logger.debug("⚠️ [Relay:\(connectionID.uuidString.prefix(8))] TCP->Vsock error: \(error)")
                break
            }
        }
    }
    
    private func relayVsockToTcp() async {
        let bufferSize = 65536
        
        while !Task.isCancelled {
            do {
                // Read from vsock (FileHandle)
                let data: Data? = try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            let data = try self.vsockHandle.read(upToCount: bufferSize)
                            continuation.resume(returning: data)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
                
                guard let data = data, !data.isEmpty else {
                    logger.debug("📤 [Relay:\(connectionID.uuidString.prefix(8))] Vsock->TCP EOF")
                    break
                }
                
                try await sendTcpData(data)
                logger.debug("📤 [Relay:\(connectionID.uuidString.prefix(8))] Vsock->TCP \(data.count) bytes")
                
            } catch {
                logger.debug("⚠️ [Relay:\(connectionID.uuidString.prefix(8))] Vsock->TCP error: \(error)")
                break
            }
        }
    }
    
    private func receiveTcpData() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            tcpConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { content, _, isComplete, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if isComplete && (content == nil || content!.isEmpty) {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: content)
                }
            }
        }
    }
    
    private func sendTcpData(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            tcpConnection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
}
