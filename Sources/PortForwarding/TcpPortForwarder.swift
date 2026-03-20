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
class TcpPortForwarder: ObservableObject {
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

    @Published private(set) var status: ForwardingStatus = .inactive
    private var listener: NWListener?
    private var activeConnections: [UUID: ConnectionRelay] = [:]
    private var guestBridge: GuestBridge?
    private var connectionTasks: [UUID: Task<Void, Never>] = [:]

    /// Background task that periodically warms the vsock connection when idle.
    ///
    /// Without this keepalive, the first request after ~1-2 minutes of idle
    /// triggers a cold-start in VZVirtioSocketDevice.connect(toPort:) which
    /// can take long enough for clients to time out before data flows.
    private var keepaliveTask: Task<Void, Never>?

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
            // Step 1: Set up the guest-side bridge (direct mode with auto-bridge).
            guestBridge = GuestBridge(pod: pod, logger: logger)
            logger.info("📡 [TcpPortForwarder] Step 1: Setting up guest bridge (direct mode with auto-bridge)")
            try await guestBridge?.startDirectMode(socketPath: guestSocketPath, containerPort: containerPort)

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

            // Step 4: Start vsock keepalive to prevent cold-start timeouts after idle.
            startVsockKeepalive()

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
        // Phase 1: Cancel keepalive and all connection tasks (immediate, non-blocking)
        keepaliveTask?.cancel()
        keepaliveTask = nil

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

    /// Create and start the NWListener with retry logic.
    ///
    /// Retries up to 5 times with increasing delays to handle EADDRINUSE
    /// from stale listeners or TIME_WAIT state after unclean shutdowns.
    private func startListener() async throws {
        let maxAttempts = 5
        var lastError: Error?

        for attempt in 1...maxAttempts {
            if attempt > 1 {
                logger.info("[TcpPortForwarder] Retry \(attempt)/\(maxAttempts): releasing stale port \(hostPort)...")
                await releaseStalePort()
                try await Task.sleep(for: .seconds(attempt - 1))
            }

            do {
                try await attemptStartListener()
                return
            } catch {
                lastError = error
                logger.warning("[TcpPortForwarder] Listener attempt \(attempt)/\(maxAttempts) failed: \(error)")
                listener?.cancel()
                listener = nil
            }
        }

        throw ContainerizationError(
            .internalError,
            message: "Failed to bind port \(hostPort) after \(maxAttempts) attempts. "
                + "Last error: \(lastError?.localizedDescription ?? "unknown"). "
                + "Check if another process is using port \(hostPort)."
        )
    }

    /// Single attempt to create and start the NWListener.
    private func attemptStartListener() async throws {
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
                    self.logger.info("[TcpPortForwarder] Listener ready on port \(self.hostPort)")
                case .failed(let error):
                    self.logger.error("[TcpPortForwarder] Listener failed: \(error)")
                    self.status = .error("Listener failed: \(error.localizedDescription)")
                case .cancelled:
                    self.logger.info("[TcpPortForwarder] Listener cancelled")
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

    /// Attempt to release a stale port by killing processes that hold it.
    ///
    /// Uses `lsof` to find PIDs listening on the port, then sends SIGTERM
    /// (and SIGKILL if needed) to release the port for rebinding.
    private func releaseStalePort() async {
        let currentPID = ProcessInfo.processInfo.processIdentifier

        // Find PIDs holding the port
        let lsof = Process()
        let pipe = Pipe()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-ti", ":\(hostPort)"]
        lsof.standardOutput = pipe
        lsof.standardError = FileHandle.nullDevice

        do {
            try lsof.run()
            lsof.waitUntilExit()
        } catch {
            logger.debug("[TcpPortForwarder] lsof failed: \(error)")
            return
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8), !output.isEmpty else {
            logger.debug("[TcpPortForwarder] No process found on port \(hostPort) (likely TIME_WAIT)")
            return
        }

        let pids = output.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }

        for pid in pids {
            if pid == currentPID {
                logger.debug("[TcpPortForwarder] Skipping own PID \(pid)")
                continue
            }

            logger.warning("[TcpPortForwarder] Killing stale process PID \(pid) holding port \(hostPort)")
            kill(pid, SIGTERM)

            // Brief wait for graceful exit
            try? await Task.sleep(for: .milliseconds(500))

            // Force kill if still alive
            if kill(pid, 0) == 0 {
                logger.warning("[TcpPortForwarder] PID \(pid) still alive, sending SIGKILL")
                kill(pid, SIGKILL)
                try? await Task.sleep(for: .milliseconds(200))
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
        let activeCount = activeConnections.count
        logger.info("📥 [TcpPortForwarder] New connection: \(connectionID) (active: \(activeCount), hostSocket exists: \(FileManager.default.fileExists(atPath: hostSocketPath)))")

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
        let relayStart = ContinuousClock.now

        defer {
            let elapsed = ContinuousClock.now - relayStart
            incoming.cancel()
            try? socketHandle?.close()
            // Clean up synchronously — this function is @MainActor-isolated,
            // so we can access actor state directly without a fire-and-forget Task.
            activeConnections.removeValue(forKey: connectionID)
            connectionTasks.removeValue(forKey: connectionID)
            updateConnectionCount()
            logger.info("[TcpPortForwarder] Connection closed: \(connectionID) (lifetime: \(elapsed))")
        }

        // Wait for incoming connection to be ready
        do {
            try await waitForConnectionReady(incoming)
            logger.debug("✅ [TcpPortForwarder] Incoming connection ready: \(connectionID)")
        } catch {
            logger.warning("⚠️ [TcpPortForwarder] Incoming connection failed to become ready: \(connectionID) — \(error)")
            return
        }

        // Verify host socket file exists before attempting POSIX connect
        let socketExists = FileManager.default.fileExists(atPath: hostSocketPath)
        logger.info("🔗 [TcpPortForwarder] Connecting to host Unix socket: \(hostSocketPath) (exists:\(socketExists)) for connection: \(connectionID)")

        if !socketExists {
            logger.error("❌ [TcpPortForwarder] Host Unix socket file is MISSING at \(hostSocketPath) — the framework relay may have died. Connection \(connectionID) will fail.")
        }

        // Connect to the host-side Unix socket (framework relay endpoint)
        do {
            socketHandle = try connectToUnixSocket(path: hostSocketPath)
            logger.info("✅ [TcpPortForwarder] Unix socket connected (fd:\(socketHandle!.fileDescriptor)) for connection: \(connectionID)")
        } catch {
            logger.warning("⚠️ [TcpPortForwarder] Failed to connect to Unix socket \(hostSocketPath) for \(connectionID): \(error) (hostSocket exists:\(FileManager.default.fileExists(atPath: hostSocketPath)))")
            return
        }

        guard let unixSocket = socketHandle else {
            logger.warning("⚠️ [TcpPortForwarder] Unix socket handle is nil for \(connectionID)")
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

        logger.info("🔗 [TcpPortForwarder] Relay established for \(connectionID) (unixSocketFd:\(unixSocket.fileDescriptor))")

        // Start bidirectional relay
        await relay.startRelay()
    }
    
    private func waitForConnectionReady(_ connection: NWConnection, timeout: TimeInterval = 10.0) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
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

            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw ContainerizationError(.timeout, message: "Connection timed out after \(timeout)s")
            }

            // First task to complete wins; cancel the other.
            try await group.next()
            group.cancelAll()
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

    // MARK: - Vsock Keepalive

    /// Start a background timer that periodically warms the vsock connection when idle.
    ///
    /// After ~1-2 minutes of inactivity, `VZVirtioSocketDevice.connect(toPort:)` undergoes
    /// a cold-start that can take long enough for clients to time out before data flows.
    /// This timer connects to the host Unix socket every 45 seconds (well under the
    /// cold-start threshold) when no real connections are active, triggering a `vm.dial()`
    /// inside the framework's `SocketRelay` and keeping vsock warm.
    ///
    /// The keepalive connection is opened and immediately closed — no data is transferred.
    private func startVsockKeepalive() {
        keepaliveTask = Task { @MainActor [weak self] in
            let interval: Duration = .seconds(45)
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { break }

                // Safety net: audit activeConnections for stale entries
                // whose relay has already closed but wasn't cleaned up.
                self.auditStaleConnections()

                // Only warm when idle — skip if real connections are active.
                guard self.activeConnections.isEmpty else {
                    self.logger.debug("[TcpPortForwarder] Keepalive: skipped (active: \(self.activeConnections.count) connections)")
                    continue
                }

                guard FileManager.default.fileExists(atPath: self.hostSocketPath) else {
                    self.logger.warning("[TcpPortForwarder] Keepalive: host socket missing at \(self.hostSocketPath), skipping warm-up")
                    continue
                }

                // Connect and immediately close to trigger vm.dial() in SocketRelay.
                self.logger.debug("[TcpPortForwarder] Keepalive: warming vsock via \(self.hostSocketPath)")
                do {
                    let fd = try self.connectToUnixSocket(path: self.hostSocketPath)
                    try? fd.close()
                    self.logger.info("[TcpPortForwarder] Keepalive: vsock warmed successfully")
                } catch {
                    self.logger.warning("[TcpPortForwarder] Keepalive: warm-up attempt failed (non-fatal): \(error)")
                }
            }
            self?.logger.debug("[TcpPortForwarder] Keepalive: timer stopped")
        }
    }

    /// Remove entries from activeConnections where the relay has already closed.
    ///
    /// This is a safety net for edge cases where the normal cleanup path
    /// (defer block in relayConnectionViaUnixSocket) didn't execute — e.g.,
    /// due to a hung DispatchSource or cancelled task.
    private func auditStaleConnections() {
        var staleIDs: [UUID] = []
        for (id, relay) in activeConnections {
            if relay.isClosed {
                staleIDs.append(id)
            }
        }

        if !staleIDs.isEmpty {
            for id in staleIDs {
                activeConnections.removeValue(forKey: id)
                connectionTasks.removeValue(forKey: id)
            }
            updateConnectionCount()
            logger.warning("[TcpPortForwarder] Audit: removed \(staleIDs.count) stale connection(s)")
        }
    }

    // MARK: - Unix Socket Connection

    /// Connect to a Unix domain socket at the given path and return a FileHandle.
    ///
    /// Uses POSIX socket APIs to create an AF_UNIX connection. The returned
    /// FileHandle is compatible with ConnectionRelay (same interface as vsock).
    private nonisolated func connectToUnixSocket(path: String) throws -> FileHandle {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            let errNo = errno
            throw ContainerizationError(
                .internalError,
                message: "Failed to create Unix socket: \(posixErrnoName(errNo))"
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
                message: "Failed to connect to Unix socket at \(path): \(posixErrnoName(errNo))"
            )
        }

        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Return a readable POSIX name for an errno value.
    private nonisolated func posixErrnoName(_ code: Int32) -> String {
        switch code {
        case ENOENT:       return "ENOENT(2) — no such file or directory (socket file missing)"
        case ECONNREFUSED: return "ECONNREFUSED(61) — connection refused (nothing listening)"
        case EPIPE:        return "EPIPE(32)"
        case EBADF:        return "EBADF(9)"
        case EACCES:       return "EACCES(13) — permission denied"
        case EADDRINUSE:   return "EADDRINUSE(48)"
        case ETIMEDOUT:    return "ETIMEDOUT(60)"
        case ENOTSOCK:     return "ENOTSOCK(38)"
        default:           return "errno(\(code))"
        }
    }
}
