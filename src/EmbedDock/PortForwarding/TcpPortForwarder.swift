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

/// A TCP port forwarder that bridges host TCP connections to a container service
/// via the framework's Unix socket relay mechanism.
///
/// The TcpPortForwarder creates a network listener on the host that accepts
/// incoming TCP connections and forwards them to a service running inside
/// the container. It uses `pod.relayUnixSocket()` to tunnel through vminitd
/// via vsock. The container app listens directly on a Unix socket (direct mode),
/// eliminating the need for socat or any guest-side bridge process.
///
/// Architecture:
/// ```
/// External Request (localhost:hostPort)
///        ↓
/// [NWListener on macOS host]
///        ↓
/// [connect to host Unix socket → framework SocketRelay → vsock → vminitd]
///        ↓
/// [vminitd connects to guest Unix socket]
///        ↓
/// [Container app listening natively on guest Unix socket]
/// ```
///
/// Usage:
/// ```swift
/// let forwarder = TcpPortForwarder(
///     hostPort: 3000,
///     containerPort: 3000,
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
    private let pod: LinuxPod
    private let logger: Logger

    // MARK: - Unix Socket Relay Paths

    /// Path inside the container where the app listens on a Unix socket.
    private let guestSocketPath: String

    /// Path on the host where the framework creates the relay Unix socket.
    private let hostSocketPath: String

    // MARK: - State

    @Published private(set) public var status: ForwardingStatus = .inactive
    private var listener: NWListener?
    private var activeConnections: [UUID: ConnectionRelay] = [:]
    private var guestBridge: GuestBridge?
    private var connectionTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: - Initialization

    /// Create a new TCP port forwarder.
    ///
    /// - Parameters:
    ///   - hostPort: The port to listen on the host machine.
    ///   - containerPort: The port the service is running on inside the container.
    ///   - pod: The LinuxPod containing the container.
    ///   - logger: Logger for diagnostics.
    public init(
        hostPort: UInt16 = 3000,
        containerPort: UInt16 = 3000,
        pod: LinuxPod,
        logger: Logger
    ) {
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.pod = pod
        self.logger = logger
        self.guestSocketPath = "/tmp/bridge-\(containerPort).sock"
        self.hostSocketPath = NSTemporaryDirectory() + "embeddock-bridge-\(containerPort).sock"
    }
    
    // MARK: - Lifecycle
    
    /// Start port forwarding.
    public func start() async throws {
        guard case .inactive = status else {
            logger.warning("⚠️ [TcpPortForwarder] Already running or starting")
            return
        }

        status = .starting
        logger.info("🚀 [TcpPortForwarder] Starting port forwarding: localhost:\(hostPort) -> container:\(containerPort) via Unix socket relay")

        do {
            // Step 1: Set up the guest-side bridge (direct mode — app listens on Unix socket natively).
            guestBridge = GuestBridge(pod: pod, logger: logger)
            logger.info("📡 [TcpPortForwarder] Step 1: Direct mode — polling for guest Unix socket")
            try await guestBridge?.startDirectMode(socketPath: guestSocketPath)

            // Step 2: Set up the framework's Unix socket relay.
            // This tells vminitd to listen on a vsock port and connect to the
            // guest Unix socket when connections arrive. It also creates a host-side
            // Unix socket that the framework relays through vsock.
            logger.info("📡 [TcpPortForwarder] Step 2: Setting up Unix socket relay via framework")

            // Clean up any stale host socket file
            try? FileManager.default.removeItem(atPath: hostSocketPath)

            let socketConfig = UnixSocketConfiguration(
                source: URL(filePath: guestSocketPath),
                destination: URL(filePath: hostSocketPath),
                direction: .outOf
            )
            try await pod.relayUnixSocket("main", socket: socketConfig)

            // Poll for host socket instead of hardcoded sleep
            try await pollForHostSocket(timeout: .seconds(5))

            // Record host socket in manifest so a crash leaves a traceable artefact
            await RunManifest.shared.record(socketPath: hostSocketPath, logger: logger)

            // Step 3: Create NWListener on host
            logger.info("📡 [TcpPortForwarder] Step 3: Creating TCP listener on port \(hostPort)")
            try await startListener()

            // Record bound port in manifest
            await RunManifest.shared.record(port: Int(hostPort), logger: logger)

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

        // Phase 5: Clean up host socket file
        try? FileManager.default.removeItem(atPath: hostSocketPath)
    }
    
    // MARK: - Listener Management
    
    private func startListener() async throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        // Enable TCP_NODELAY to disable Nagle's algorithm for lower latency
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        
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

        // Create a task to handle this connection via the Unix socket relay
        let task = Task { [weak self] in
            guard let self = self else { return }
            await self.relayConnectionViaUnixSocket(connectionID: connectionID, incoming: incomingConnection)
        }

        connectionTasks[connectionID] = task
    }

    private func relayConnectionViaUnixSocket(connectionID: UUID, incoming: NWConnection) async {
        var socketHandle: FileHandle? = nil

        defer {
            incoming.cancel()
            try? socketHandle?.close()
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

        // Connect to the host-side Unix socket (framework relay endpoint)
        logger.debug("🔗 [TcpPortForwarder] Connecting to host Unix socket: \(hostSocketPath)")
        do {
            socketHandle = try connectToUnixSocket(path: hostSocketPath)
            logger.debug("✅ [TcpPortForwarder] Unix socket connection established")
        } catch {
            logger.warning("⚠️ [TcpPortForwarder] Failed to connect to Unix socket \(hostSocketPath): \(error)")
            return
        }

        guard let unixSocket = socketHandle else {
            logger.warning("⚠️ [TcpPortForwarder] Unix socket handle is nil")
            return
        }

        // Create a relay wrapper — ConnectionRelay works with any FileHandle
        let relay = ConnectionRelay(
            connectionID: connectionID,
            tcpConnection: incoming,
            vsockHandle: unixSocket,
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

    // MARK: - Host Socket Polling

    /// Poll until the host-side Unix socket file appears, replacing hardcoded sleeps.
    private func pollForHostSocket(timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if FileManager.default.fileExists(atPath: hostSocketPath) {
                logger.debug("✅ [TcpPortForwarder] Host socket ready: \(hostSocketPath)")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ContainerizationError(
            .timeout,
            message: "Host Unix socket not created within \(timeout) at \(hostSocketPath)"
        )
    }

    // MARK: - Unix Socket Connection

    /// Connect to a Unix domain socket at the given path and return a FileHandle.
    ///
    /// Uses POSIX socket APIs to create an AF_UNIX connection. The returned
    /// FileHandle is compatible with ConnectionRelay (same interface as vsock).
    private nonisolated func connectToUnixSocket(path: String) throws -> FileHandle {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ContainerizationError(
                .internalError,
                message: "Failed to create Unix socket: errno \(errno)"
            )
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let maxPathLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard path.utf8.count <= maxPathLen else {
            close(fd)
            throw ContainerizationError(
                .internalError,
                message: "Unix socket path too long (\(path.utf8.count) > \(maxPathLen))"
            )
        }

        withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            path.withCString { cstr in
                _ = strcpy(ptr, cstr)
            }
        }

        let addrLen = socklen_t(
            MemoryLayout<sockaddr_un>.offset(of: \.sun_path)! + path.utf8.count + 1
        )

        let connectResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Foundation.connect(fd, sockaddrPtr, addrLen)
            }
        }

        guard connectResult == 0 else {
            let errNo = errno
            close(fd)
            throw ContainerizationError(
                .internalError,
                message: "Failed to connect to Unix socket at \(path): errno \(errNo)"
            )
        }

        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
}
