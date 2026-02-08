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
import ContainerizationExtras
import Logging
import Network

// MARK: - TCP Port Forwarder

/// A TCP port forwarder that bridges host TCP connections to container via vsock.
///
/// The TcpPortForwarder creates a network listener on the host that accepts
/// incoming TCP connections and forwards them to a service running inside
/// the container via vsock.
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
///
/// Usage:
/// ```swift
/// let forwarder = TcpPortForwarder(
///     hostPort: 3000,
///     containerPort: 3000,
///     bridgePort: 5000,
///     pod: pod,
///     logger: logger
/// )
/// try await forwarder.start()
/// // ... forwarder is active
/// await forwarder.stop()
/// ```
@MainActor
public class TcpPortForwarder: ObservableObject {
    // MARK: - Configuration
    
    private let hostPort: UInt16
    private let containerPort: UInt16
    private let vsockPort: UInt32
    private let pod: LinuxPod
    private let logger: Logger
    
    // MARK: - State
    
    @Published private(set) public var status: ForwardingStatus = .inactive
    private var listener: NWListener?
    private var activeConnections: [UUID: ConnectionRelay] = [:]
    private var guestBridge: GuestBridge?
    private var connectionTasks: [UUID: Task<Void, Never>] = [:]
    
    // MARK: - Retry Configuration
    
    private let maxRetries = 5
    private let baseRetryDelay: TimeInterval = 1.0
    private let maxRetryDelay: TimeInterval = 30.0
    
    // MARK: - Initialization
    
    /// Create a new TCP port forwarder.
    ///
    /// - Parameters:
    ///   - hostPort: The port to listen on the host machine.
    ///   - containerPort: The port the service is running on inside the container.
    ///   - bridgePort: The vsock port used for host-VM communication.
    ///   - pod: The LinuxPod containing the container.
    ///   - logger: Logger for diagnostics.
    public init(
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
    
    // MARK: - Lifecycle
    
    /// Start port forwarding.
    public func start() async throws {
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
    
    /// Stop port forwarding with robust timeout handling.
    public func stop() async {
        logger.info("🛑 [TcpPortForwarder] Stopping port forwarding")
        
        // Immediately mark as inactive to prevent new connections
        status = .inactive
        
        await cleanup()
        
        logger.info("✅ [TcpPortForwarder] Port forwarding stopped")
    }
    
    // MARK: - Cleanup
    
    private func cleanup() async {
        // Phase 1: Cancel all connection tasks (immediate, non-blocking)
        for (_, task) in connectionTasks {
            task.cancel()
        }
        connectionTasks.removeAll()
        
        // Phase 2: Close all active connections (immediate, synchronous)
        for (_, relay) in activeConnections {
            relay.close()
        }
        activeConnections.removeAll()
        
        // Phase 3: Stop listener (immediate)
        listener?.cancel()
        listener = nil
        
        // Phase 4: Stop guest bridge with 3 second timeout
        if let bridge = guestBridge {
            do {
                try await Timeout.run(seconds: 3) {
                    await bridge.stopBridge()
                }
                logger.debug("✅ [TcpPortForwarder] Guest bridge stopped")
            } catch {
                logger.warning("⚠️ [TcpPortForwarder] Guest bridge stop timed out")
            }
        }
        guestBridge = nil
    }
    
    // MARK: - Listener Management
    
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
    
    // MARK: - Connection Handling
    
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
