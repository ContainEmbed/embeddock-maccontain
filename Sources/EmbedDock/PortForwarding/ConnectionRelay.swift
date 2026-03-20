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
import Network
import Logging
import Synchronization

// MARK: - POSIX Errno Helper

/// Return a human-readable POSIX name for a given errno value.
///
/// Makes log lines like "errno EPIPE" immediately actionable vs raw numbers.
private func errnoPOSIXName(_ code: Int32) -> String {
    switch code {
    case EPIPE:        return "EPIPE(\(code))"
    case ECONNRESET:   return "ECONNRESET(\(code))"
    case EBADF:        return "EBADF(\(code))"
    case EAGAIN:       return "EAGAIN(\(code))"
    case EWOULDBLOCK:  return "EWOULDBLOCK(\(code))"
    case ENOBUFS:      return "ENOBUFS(\(code))"
    case ETIMEDOUT:    return "ETIMEDOUT(\(code))"
    case ENOTCONN:     return "ENOTCONN(\(code))"
    case ENETDOWN:     return "ENETDOWN(\(code))"
    case ENETUNREACH:  return "ENETUNREACH(\(code))"
    case ECONNREFUSED: return "ECONNREFUSED(\(code))"
    case EIO:          return "EIO(\(code))"
    case ENOMEM:       return "ENOMEM(\(code))"
    case EFAULT:       return "EFAULT(\(code))"
    case EINVAL:       return "EINVAL(\(code))"
    case ENOSPC:       return "ENOSPC(\(code))"
    default:           return "errno(\(code))"
    }
}

// MARK: - Connection Relay

/// Handles bidirectional data relay between a TCP connection and a vsock FileHandle.
///
/// The ConnectionRelay manages the data flow between incoming TCP connections
/// from the host and the vsock connection to the container. It handles both
/// directions concurrently using task groups.
///
/// Data Flow:
/// ```
/// TCP Connection (NWConnection)
///        ↕ [ConnectionRelay]
/// Vsock Handle (FileHandle)
/// ```
final class ConnectionRelay: @unchecked Sendable {
    let connectionID: UUID
    private let tcpConnection: NWConnection
    private let vsockHandle: FileHandle
    private let logger: Logger
    private var _isClosed = false
    private let lock = NSLock()

    /// Whether this relay has been closed (thread-safe read).
    var isClosed: Bool {
        lock.withLock { _isClosed }
    }

    /// Buffer size for data transfers.
    private let bufferSize = 65536

    /// FM #2: Idle timeout — connections with no data transfer for this duration are closed.
    private let idleTimeout: Duration = .seconds(300)

    /// Tracks last data activity for idle timeout detection.
    private let lastActivity = Mutex<ContinuousClock.Instant>(.now)

    /// Relay creation time — used to measure how long the relay stays alive.
    private let startTime = ContinuousClock.now

    /// Cumulative byte counters for diagnostics.
    private let tcpToVsockBytes = Mutex<Int>(0)
    private let vsockToTcpBytes = Mutex<Int>(0)

    init(
        connectionID: UUID,
        tcpConnection: NWConnection,
        vsockHandle: FileHandle,
        logger: Logger
    ) {
        self.connectionID = connectionID
        self.tcpConnection = tcpConnection
        self.vsockHandle = vsockHandle
        self.logger = logger
    }

    // MARK: - Lifecycle

    /// Close the relay and cleanup resources.
    ///
    /// - Parameter reason: Human-readable description of why the relay is being closed.
    ///   Used to diagnose premature or unexpected closures in logs.
    func close(reason: String = "unspecified") {
        var alreadyClosed = false
        lock.withLock {
            if _isClosed {
                alreadyClosed = true
            } else {
                _isClosed = true
            }
        }

        let shortID = connectionID.uuidString.prefix(8)
        let elapsed = ContinuousClock.now - startTime
        let tx = tcpToVsockBytes.withLock { $0 }
        let rx = vsockToTcpBytes.withLock { $0 }

        if alreadyClosed {
            logger.debug("🔒 [Relay:\(shortID)] close() called again (already closed) — reason: \(reason)")
            return
        }

        logger.info("🔒 [Relay:\(shortID)] Closing relay — reason: \(reason), lifetime: \(elapsed), tcp→vsock: \(tx)B, vsock→tcp: \(rx)B")
        tcpConnection.cancel()
        try? vsockHandle.close()
    }

    /// Start the bidirectional relay.
    ///
    /// This method runs until either side closes, an error occurs,
    /// or the idle timeout expires (FM #2).
    func startRelay() async {
        let shortID = connectionID.uuidString.prefix(8)
        logger.info("▶️ [Relay:\(shortID)] Starting bidirectional relay (vsockFd:\(vsockHandle.fileDescriptor))")

        // FM #8: Monitor NWConnection state for failures
        tcpConnection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let error):
                self.logger.warning("⚠️ [Relay:\(shortID)] TCP connection failed: \(error)")
                self.close(reason: "tcp-failed:\(error)")
            case .cancelled:
                self.logger.info("ℹ️ [Relay:\(shortID)] TCP state: cancelled")
                self.close(reason: "tcp-cancelled")
            case .ready:
                self.logger.debug("✅ [Relay:\(shortID)] TCP state: ready")
            case .waiting(let error):
                self.logger.warning("⏳ [Relay:\(shortID)] TCP state: waiting (\(error))")
            default:
                break
            }
        }

        await withTaskGroup(of: Void.self) { group in
            // TCP -> Vsock
            group.addTask {
                await self.relayTcpToVsock()
            }

            // Vsock -> TCP
            group.addTask {
                await self.relayVsockToTcp()
            }

            // FM #2: Idle timeout watchdog
            group.addTask {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled else { break }
                    let last = self.lastActivity.withLock { $0 }
                    if ContinuousClock.now - last > self.idleTimeout {
                        self.logger.info("⏰ [Relay:\(shortID)] Idle timeout (\(self.idleTimeout)) exceeded, closing")
                        self.close(reason: "idle-timeout")
                        break
                    }
                }
            }
        }

        logger.info("⏹️ [Relay:\(shortID)] Task group finished")
        close(reason: "relay-complete")
    }

    // MARK: - Relay Directions

    /// Relay data from TCP to Vsock.
    ///
    /// The write to the vsock FileHandle is dispatched to a GCD queue
    /// to avoid blocking a Swift concurrency cooperative thread.
    private func relayTcpToVsock() async {
        let shortID = connectionID.uuidString.prefix(8)
        logger.debug("📥 [Relay:\(shortID)] TCP->Vsock relay started (vsockFd:\(vsockHandle.fileDescriptor))")

        while !Task.isCancelled {
            do {
                let data = try await receiveTcpData()

                guard let data = data, !data.isEmpty else {
                    logger.info("📤 [Relay:\(shortID)] TCP->Vsock EOF (connection closed by peer)")
                    close(reason: "tcp-eof")
                    break
                }

                // Dispatch blocking write to GCD to avoid stalling
                // the Swift concurrency cooperative thread pool.
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async { [self] in
                        do {
                            try self.vsockHandle.write(contentsOf: data)
                            cont.resume()
                        } catch {
                            cont.resume(throwing: error)
                        }
                    }
                }
                tcpToVsockBytes.withLock { $0 += data.count }
                lastActivity.withLock { $0 = .now }
                logger.debug("📤 [Relay:\(shortID)] TCP->Vsock \(data.count) bytes")

            } catch {
                logger.warning("⚠️ [Relay:\(shortID)] TCP->Vsock error: \(error)")
                close(reason: "tcp-to-vsock-error:\(error)")
                break
            }
        }

        logger.debug("📥 [Relay:\(shortID)] TCP->Vsock relay loop exited")
    }

    /// Relay data from Vsock to TCP using non-blocking DispatchSourceRead.
    ///
    /// Instead of blocking a GCD thread on `vsockHandle.read()`, this uses
    /// a DispatchSourceRead on the file descriptor. The kernel notifies us
    /// via kqueue when data is available, eliminating one blocked thread
    /// per connection.
    ///
    /// Backpressure: the dispatch source is suspended while a TCP send is
    /// in flight, preventing unbounded memory growth with slow clients.
    private func relayVsockToTcp() async {
        let shortID = connectionID.uuidString.prefix(8)
        let fd = vsockHandle.fileDescriptor
        logger.debug("📥 [Relay:\(shortID)] Vsock->TCP relay started (vsockFd:\(fd))")

        // Set non-blocking mode (required for DispatchSourceRead)
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            logger.debug("📥 [Relay:\(shortID)] vsockFd:\(fd) set to non-blocking")
        } else {
            logger.warning("⚠️ [Relay:\(shortID)] fcntl F_GETFL failed on vsockFd:\(fd) — \(errnoPOSIXName(errno))")
        }

        // Pre-allocate a single read buffer for the lifetime of this relay,
        // avoiding per-event malloc/free overhead.
        let readBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let source = DispatchSource.makeReadSource(
                fileDescriptor: fd,
                queue: .global(qos: .userInitiated)
            )

            source.setEventHandler { [weak self] in
                guard let self else {
                    source.cancel()
                    return
                }

                if source.data == 0 {
                    // kqueue reports data==0 when the fd is closed/EOF
                    self.logger.info("📤 [Relay:\(shortID)] Vsock->TCP EOF (source.data==0, vsockFd:\(fd)) — likely vsock fd was closed")
                    self.close(reason: "vsock-eof-source-data-zero")
                    source.cancel()
                    return
                }

                let readSize = min(Int(source.data), self.bufferSize)
                let bytesRead = read(fd, readBuffer, readSize)

                guard bytesRead > 0 else {
                    if bytesRead == 0 {
                        // Clean EOF from read()
                        self.logger.info("📤 [Relay:\(shortID)] Vsock->TCP EOF (read returned 0, vsockFd:\(fd))")
                        self.close(reason: "vsock-eof-read-zero")
                        source.cancel()
                    } else {
                        let capturedErrno = errno
                        if capturedErrno != EAGAIN && capturedErrno != EWOULDBLOCK {
                            // Real error (not just "try again")
                            self.logger.warning("⚠️ [Relay:\(shortID)] Vsock->TCP read error on fd:\(fd): \(errnoPOSIXName(capturedErrno))")
                            self.close(reason: "vsock-read-error:\(errnoPOSIXName(capturedErrno))")
                            source.cancel()
                        }
                        // EAGAIN/EWOULDBLOCK: source will fire again when data available
                    }
                    return
                }

                let data = Data(bytes: readBuffer, count: bytesRead)

                self.vsockToTcpBytes.withLock { $0 += bytesRead }
                self.lastActivity.withLock { $0 = .now }
                self.logger.debug("📤 [Relay:\(shortID)] Vsock->TCP \(bytesRead) bytes")

                // Suspend the source to apply backpressure: do not read more
                // data until the current TCP send completes. This prevents
                // unbounded memory growth when the TCP client is slow.
                source.suspend()
                self.tcpConnection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        self.logger.warning("⚠️ [Relay:\(shortID)] Vsock->TCP TCP send error: \(error)")
                        self.close(reason: "vsock-to-tcp-send-error:\(error)")
                        // Resume before cancel — a suspended DispatchSource may not
                        // fire its cancel handler, causing the relay to hang forever.
                        source.resume()
                        source.cancel()
                    } else {
                        source.resume()
                    }
                })
            }

            source.setCancelHandler {
                self.logger.debug("📥 [Relay:\(shortID)] Vsock->TCP DispatchSource cancelled (vsockFd:\(fd))")
                readBuffer.deallocate()
                continuation.resume()
            }

            source.activate()
            self.logger.debug("📥 [Relay:\(shortID)] Vsock->TCP DispatchSource activated (vsockFd:\(fd))")
        }

        logger.debug("📥 [Relay:\(shortID)] Vsock->TCP relay finished")
    }

    // MARK: - TCP Operations

    /// Receive data from the TCP connection.
    private func receiveTcpData() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            tcpConnection.receive(minimumIncompleteLength: 1, maximumLength: bufferSize) { content, _, isComplete, error in
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
}
