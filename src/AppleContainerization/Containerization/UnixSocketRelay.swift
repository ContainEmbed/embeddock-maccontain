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

import ContainerizationError
import ContainerizationIO
import ContainerizationOS
import Foundation
import Logging
import Synchronization

package actor UnixSocketRelayManager {
    private let vm: any VirtualMachineInstance
    private var relays: [String: SocketRelay]
    private let q: DispatchQueue
    private let log: Logger?

    init(vm: any VirtualMachineInstance, log: Logger? = nil) {
        self.vm = vm
        self.relays = [:]
        self.q = DispatchQueue(label: "com.apple.containerization.socket-relay")
        self.log = log
    }
}

extension UnixSocketRelayManager {
    func start(port: UInt32, socket: UnixSocketConfiguration) async throws {
        guard self.relays[socket.id] == nil else {
            throw ContainerizationError(
                .invalidState,
                message: "socket relay \(socket.id) already started"
            )
        }

        let socketRelay = try SocketRelay(
            port: port,
            socket: socket,
            vm: self.vm,
            queue: self.q,
            log: self.log
        )

        do {
            self.relays[socket.id] = socketRelay
            try await socketRelay.start()
        } catch {
            self.relays.removeValue(forKey: socket.id)
            throw error
        }
    }

    func stop(socket: UnixSocketConfiguration) async throws {
        guard let storedRelay = self.relays.removeValue(forKey: socket.id) else {
            throw ContainerizationError(
                .notFound,
                message: "failed to stop socket relay"
            )
        }
        try storedRelay.stop()
    }

    func stopAll() async throws {
        for (_, relay) in self.relays {
            try relay.stop()
        }
    }
}

package final class SocketRelay: Sendable {
    private let port: UInt32
    private let configuration: UnixSocketConfiguration
    private let log: Logger?
    private let vm: any VirtualMachineInstance
    private let q: DispatchQueue
    private let state: Mutex<State>

    private struct State {
        var relaySources: [String: ConnectionSources] = [:]
        var t: Task<(), Never>? = nil
    }

    // `DispatchSourceRead` is thread-safe.
    private struct ConnectionSources: @unchecked Sendable {
        let hostSource: DispatchSourceRead
        let guestSource: DispatchSourceRead
    }

    init(
        port: UInt32,
        socket: UnixSocketConfiguration,
        vm: any VirtualMachineInstance,
        queue: DispatchQueue,
        log: Logger? = nil
    ) throws {
        self.port = port
        self.configuration = socket
        self.state = Mutex<State>(.init())
        self.vm = vm
        self.log = log
        self.q = queue
    }

    deinit {
        self.state.withLock { $0.t?.cancel() }
    }
}

extension SocketRelay {
    func start() async throws {
        switch configuration.direction {
        case .outOf:
            try await setupHostVsockDial()
        case .into:
            try setupHostVsockListener()
        }
    }

    func stop() throws {
        try self.state.withLock {
            guard let t = $0.t else {
                throw ContainerizationError(
                    .invalidState,
                    message: "failed to stop socket relay: relay has not been started"
                )
            }
            t.cancel()
            $0.t = nil
            $0.relaySources.removeAll()
        }

        switch configuration.direction {
        case .outOf:
            // If we created the host conn, lets unlink it also. It's possible it was
            // already unlinked if the relay failed earlier.
            try? FileManager.default.removeItem(at: self.configuration.destination)
        case .into:
            try self.vm.stopListen(self.port)
        }
    }

    private func setupHostVsockDial() async throws {
        let hostConn = self.configuration.destination

        let socketType = try UnixType(
            path: hostConn.path,
            unlinkExisting: true
        )
        let hostSocket = try Socket(type: socketType)
        try hostSocket.listen()

        log?.info(
            "listening on host UDS",
            metadata: [
                "path": "\(hostConn.path)",
                "vport": "\(self.port)",
            ])
        let connectionStream = try hostSocket.acceptStream(closeOnDeinit: false)
        self.state.withLock {
            $0.t = Task {
                defer {
                    try? FileManager.default.removeItem(at: hostConn)
                }
                do {
                    var acceptCount = 0
                    for try await connection in connectionStream {
                        acceptCount += 1
                        let connIndex = acceptCount
                        log?.info(
                            "accept loop: accepted connection, spawning handler",
                            metadata: [
                                "connIndex": "\(connIndex)",
                                "vport": "\(self.port)",
                            ])

                        // FIX: Spawn handleHostUnixConn as a concurrent Task so the
                        // accept loop is NEVER blocked by vm.dial() or relay setup.
                        //
                        // Root cause of idle-then-slow-first-request:
                        //   Previously `await handleHostUnixConn(...)` serialised the
                        //   loop. After ~1-2 min idle, VZVirtioSocketDevice.connect()
                        //   is slow to warm up. The loop was blocked during that dial,
                        //   so subsequent connections piled up in the kernel backlog
                        //   and the first client timed out waiting for a response.
                        //   Spawning here makes the accept loop immediately ready for
                        //   the next connection regardless of vsock dial latency.
                        Task {
                            let dialStart = ContinuousClock.now
                            log?.info(
                                "accept loop: starting vsock dial",
                                metadata: [
                                    "connIndex": "\(connIndex)",
                                    "vport": "\(self.port)",
                                ])
                            do {
                                try await self.handleHostUnixConn(
                                    hostConn: connection,
                                    port: self.port,
                                    vm: self.vm,
                                    log: self.log
                                )
                                let elapsed = ContinuousClock.now - dialStart
                                log?.info(
                                    "accept loop: handler completed",
                                    metadata: [
                                        "connIndex": "\(connIndex)",
                                        "elapsed": "\(elapsed)",
                                        "vport": "\(self.port)",
                                    ])
                            } catch {
                                let elapsed = ContinuousClock.now - dialStart
                                // Per-connection error: log and continue.
                                // Do NOT rethrow — the accept loop must survive
                                // individual connection failures (e.g. vsock dial
                                // errors, guest overload, transient network issues).
                                log?.warning(
                                    "relay connection handling failed",
                                    metadata: [
                                        "connIndex": "\(connIndex)",
                                        "elapsed": "\(elapsed)",
                                        "error": "\(error)",
                                        "vport": "\(self.port)",
                                    ])
                                // Safety net: ensure the accepted host Socket fd is
                                // closed even if handleHostUnixConn missed it.
                                // Socket.close() is idempotent if already closed.
                                try? connection.close()
                            }
                        }
                    }
                } catch {
                    log?.error("relay accept stream failed: \(error)")
                }
            }
        }
    }

    private func setupHostVsockListener() throws {
        let hostPath = self.configuration.source
        let port = self.port
        let log = self.log

        let connectionStream = try self.vm.listen(self.port)
        log?.info(
            "listening on guest vsock",
            metadata: [
                "path": "\(hostPath)",
                "vport": "\(port)",
            ])
        self.state.withLock {
            $0.t = Task {
                do {
                    defer { connectionStream.finish() }
                    for await connection in connectionStream {
                        do {
                            try await self.handleGuestVsockConn(
                                vsockConn: connection,
                                hostConnectionPath: hostPath,
                                port: port,
                                log: log
                            )
                        } catch {
                            log?.warning("guest vsock connection handling failed, continuing: \(error)")
                        }
                    }
                } catch {
                    log?.error("failed to setup relay between vsock \(port) and \(hostPath.path): \(error)")
                }
            }
        }
    }

    private func handleHostUnixConn(
        hostConn: ContainerizationOS.Socket,
        port: UInt32,
        vm: any VirtualMachineInstance,
        log: Logger?
    ) async throws {
        // Retry vm.dial() to handle transient VZ framework cold-start failures
        // after idle. Similar to waitForAgent() which retries during boot, but
        // with a smaller budget since the VM is already running.
        let maxDialAttempts = 3
        let retryDelay: Duration = .milliseconds(250)

        var guestConn: FileHandle?
        var lastDialError: Error?

        for attempt in 1...maxDialAttempts {
            let dialStart = ContinuousClock.now
            log?.info(
                "vsock dial starting",
                metadata: [
                    "vport": "\(port)",
                    "hostFd": "\(hostConn.fileDescriptor)",
                    "attempt": "\(attempt)/\(maxDialAttempts)",
                ])

            do {
                guestConn = try await vm.dial(port)
                lastDialError = nil

                let dialElapsed = ContinuousClock.now - dialStart
                log?.info(
                    "vsock dial completed",
                    metadata: [
                        "vport": "\(port)",
                        "guestFd": "\(guestConn!.fileDescriptor)",
                        "hostFd": "\(hostConn.fileDescriptor)",
                        "dialDuration": "\(dialElapsed)",
                        "attempt": "\(attempt)/\(maxDialAttempts)",
                    ])

                if dialElapsed > .milliseconds(500) {
                    log?.warning(
                        "SLOW vsock dial detected",
                        metadata: [
                            "dialDuration": "\(dialElapsed)",
                            "vport": "\(port)",
                            "attempt": "\(attempt)/\(maxDialAttempts)",
                        ])
                }
                break
            } catch {
                let dialElapsed = ContinuousClock.now - dialStart
                lastDialError = error
                log?.warning(
                    "vsock dial failed",
                    metadata: [
                        "vport": "\(port)",
                        "hostFd": "\(hostConn.fileDescriptor)",
                        "attempt": "\(attempt)/\(maxDialAttempts)",
                        "dialDuration": "\(dialElapsed)",
                        "error": "\(error)",
                    ])
                if attempt < maxDialAttempts {
                    try? await Task.sleep(for: retryDelay)
                }
            }
        }

        guard let guestConn else {
            log?.error(
                "all vsock dial attempts exhausted, closing host connection to unblock peer",
                metadata: [
                    "vport": "\(port)",
                    "hostFd": "\(hostConn.fileDescriptor)",
                    "attempts": "\(maxDialAttempts)",
                ])
            // FIX: Close hostConn to prevent fd leak and send EOF to the
            // ConnectionRelay on the other end of the Unix socket. Without this
            // close, the accepted Socket (closeOnDeinit=false) stays open but
            // orphaned — nobody reads from it, nobody writes to it, nobody
            // closes it — so the TCP client hangs until the 300s idle timeout.
            try? hostConn.close()
            throw lastDialError!
        }

        let guestFd = guestConn.fileDescriptor

        // NOTE: relay() returns IMMEDIATELY — it activates DispatchSources and
        // exits. After this, the DispatchSource cancel handlers own both fds.
        do {
            try await self.relay(
                hostConn: hostConn,
                guestFd: guestFd
            )
        } catch {
            log?.error(
                "relay setup failed, closing both fds",
                metadata: [
                    "vport": "\(port)",
                    "hostFd": "\(hostConn.fileDescriptor)",
                    "guestFd": "\(guestFd)",
                    "error": "\(error)",
                ])
            try? hostConn.close()
            close(guestFd)
            throw error
        }
    }

    private func handleGuestVsockConn(
        vsockConn: FileHandle,
        hostConnectionPath: URL,
        port: UInt32,
        log: Logger?
    ) async throws {
        let hostPath = hostConnectionPath.path
        let socketType = try UnixType(path: hostPath)
        let hostSocket = try Socket(
            type: socketType,
            closeOnDeinit: false
        )
        log?.info(
            "initiating connection from host to guest",
            metadata: [
                "vport": "\(port)",
                "hostFd": "\(hostSocket.fileDescriptor)",
                "guestFd": "\(vsockConn.fileDescriptor)",
            ])
        try hostSocket.connect()

        do {
            try await self.relay(
                hostConn: hostSocket,
                guestFd: vsockConn.fileDescriptor
            )
        } catch {
            log?.error("failed to relay between vsock \(port) and \(hostPath)")
        }
    }

    private func relay(
        hostConn: Socket,
        guestFd: Int32
    ) async throws {
        // set up the source for host to guest transfers
        let connSource = DispatchSource.makeReadSource(
            fileDescriptor: hostConn.fileDescriptor,
            queue: self.q
        )

        // set up the source for guest to host transfers
        let vsockConnectionSource = DispatchSource.makeReadSource(
            fileDescriptor: guestFd,
            queue: self.q
        )

        // add the sources to the connection map
        let pairID = UUID().uuidString
        self.state.withLock {
            $0.relaySources[pairID] = ConnectionSources(
                hostSource: connSource,
                guestSource: vsockConnectionSource
            )
        }

        // 64KB buffer aligned with ConnectionRelay.bufferSize to prevent syscall amplification.
        // Previously used getpagesize() (4KB) which caused 16x fragmentation.
        let relayBufferSize = 65536
        nonisolated(unsafe) let buf1 = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: relayBufferSize)
        connSource.setEventHandler {
            Self.fdCopyHandler(
                buffer: buf1,
                source: connSource,
                from: hostConn.fileDescriptor,
                to: guestFd,
                log: self.log
            )
        }

        nonisolated(unsafe) let buf2 = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: relayBufferSize)
        vsockConnectionSource.setEventHandler {
            Self.fdCopyHandler(
                buffer: buf2,
                source: vsockConnectionSource,
                from: guestFd,
                to: hostConn.fileDescriptor,
                log: self.log
            )
        }

        connSource.setCancelHandler {
            self.log?.info(
                "host cancel received",
                metadata: [
                    "hostFd": "\(hostConn.fileDescriptor)",
                    "guestFd": "\(guestFd)",
                ])

            // only close underlying fds when both sources are at EOF
            // ensure that one of the cancel handlers will see both sources cancelled
            self.state.withLock { state in
                if vsockConnectionSource.isCancelled {
                    try? hostConn.close()
                    close(guestFd)
                    // FM #12: Free page-sized buffers and remove relay sources entry
                    buf1.deallocate()
                    buf2.deallocate()
                    state.relaySources.removeValue(forKey: pairID)
                }
            }
        }

        vsockConnectionSource.setCancelHandler {
            self.log?.info(
                "guest cancel received",
                metadata: [
                    "hostFd": "\(hostConn.fileDescriptor)",
                    "guestFd": "\(guestFd)",
                ])

            // only close underlying fds when both sources are at EOF
            // ensure that one of the cancel handlers will see both sources cancelled
            self.state.withLock { state in
                if connSource.isCancelled {
                    self.log?.info(
                        "close file descriptors",
                        metadata: [
                            "hostFd": "\(hostConn.fileDescriptor)",
                            "guestFd": "\(guestFd)",
                        ])
                    try? hostConn.close()
                    close(guestFd)
                    // FM #12: Free page-sized buffers and remove relay sources entry
                    buf1.deallocate()
                    buf2.deallocate()
                    state.relaySources.removeValue(forKey: pairID)
                }
            }
        }

        connSource.activate()
        vsockConnectionSource.activate()
    }

    private static func fdCopyHandler(
        buffer: UnsafeMutableBufferPointer<UInt8>,
        source: DispatchSourceRead,
        from sourceFd: Int32,
        to destinationFd: Int32,
        log: Logger? = nil
    ) {
        if source.data == 0 {
            log?.info(
                "source EOF",
                metadata: [
                    "sourceFd": "\(sourceFd)",
                    "dstFd": "\(destinationFd)",
                ])
            if !source.isCancelled {
                log?.info(
                    "canceling DispatchSourceRead",
                    metadata: [
                        "sourceFd": "\(sourceFd)",
                        "dstFd": "\(destinationFd)",
                    ])
                source.cancel()
                if shutdown(destinationFd, SHUT_WR) != 0 {
                    log?.info(
                        "failed to shut down reads",
                        metadata: [
                            "errno": "\(errno)",
                            "sourceFd": "\(sourceFd)",
                            "dstFd": "\(destinationFd)",
                        ]
                    )
                }
            }
            return
        }

        do {
            log?.debug(
                "source copy",
                metadata: [
                    "sourceFd": "\(sourceFd)",
                    "dstFd": "\(destinationFd)",
                    "size": "\(source.data)",
                ])
            try self.fileDescriptorCopy(
                buffer: buffer,
                size: source.data,
                from: sourceFd,
                to: destinationFd
            )
        } catch {
            log?.error("file descriptor copy failed \(error)")
            if !source.isCancelled {
                source.cancel()
                if shutdown(destinationFd, SHUT_RDWR) != 0 {
                    log?.info(
                        "failed to shut down destination",
                        metadata: [
                            "errno": "\(errno)",
                            "sourceFd": "\(sourceFd)",
                            "dstFd": "\(destinationFd)",
                        ]
                    )
                }
            }
        }
    }

    private static func fileDescriptorCopy(
        buffer: UnsafeMutableBufferPointer<UInt8>,
        size: UInt,
        from sourceFd: Int32,
        to destinationFd: Int32
    ) throws {
        let bufferSize = buffer.count
        var readBytesRemaining = min(Int(size), bufferSize)

        guard let baseAddr = buffer.baseAddress else {
            throw ContainerizationError(
                .invalidState,
                message: "buffer has no base address"
            )
        }

        while readBytesRemaining > 0 {
            let readResult = read(sourceFd, baseAddr, min(bufferSize, readBytesRemaining))
            if readResult <= 0 {
                throw ContainerizationError(
                    .internalError,
                    message: "failed to read from source fd \(sourceFd): result \(readResult), errno \(errno)"
                )
            }
            readBytesRemaining -= readResult

            var writeBytesRemaining = readResult
            var writeOffset = 0
            while writeBytesRemaining > 0 {
                let writeResult = write(destinationFd, baseAddr + writeOffset, writeBytesRemaining)
                if writeResult <= 0 {
                    throw ContainerizationError(
                        .internalError,
                        message: "zero byte write or error in socket relay: fd \(destinationFd), result \(writeResult)"
                    )
                }
                writeBytesRemaining -= writeResult
                writeOffset += writeResult
            }
        }
    }
}
