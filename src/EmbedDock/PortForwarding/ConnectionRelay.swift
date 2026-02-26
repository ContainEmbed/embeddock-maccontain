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
    private var isClosed = false
    private let lock = NSLock()

    /// Buffer size for data transfers.
    private let bufferSize = 65536

    /// FM #2: Idle timeout — connections with no data transfer for this duration are closed.
    private let idleTimeout: Duration = .seconds(300)

    /// Tracks last data activity for idle timeout detection.
    private let lastActivity = Mutex<ContinuousClock.Instant>(.now)

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
    func close() {
        lock.withLock {
            guard !isClosed else { return }
            isClosed = true
        }
        tcpConnection.cancel()
        try? vsockHandle.close()
    }

    /// Start the bidirectional relay.
    ///
    /// This method runs until either side closes, an error occurs,
    /// or the idle timeout expires (FM #2).
    func startRelay() async {
        // FM #8: Monitor NWConnection state for failures
        tcpConnection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                self.close()
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
                        self.logger.info("⏰ [Relay:\(self.connectionID.uuidString.prefix(8))] Idle timeout (\(self.idleTimeout)) exceeded, closing")
                        self.close()
                        break
                    }
                }
            }
        }

        close()
    }

    // MARK: - Relay Directions

    /// Relay data from TCP to Vsock.
    ///
    /// The write to the vsock FileHandle is dispatched to a GCD queue
    /// to avoid blocking a Swift concurrency cooperative thread.
    private func relayTcpToVsock() async {
        let shortID = connectionID.uuidString.prefix(8)

        while !Task.isCancelled {
            do {
                let data = try await receiveTcpData()

                guard let data = data, !data.isEmpty else {
                    logger.debug("📤 [Relay:\(shortID)] TCP->Vsock EOF")
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
                lastActivity.withLock { $0 = .now }
                logger.debug("📤 [Relay:\(shortID)] TCP->Vsock \(data.count) bytes")

            } catch {
                logger.debug("⚠️ [Relay:\(shortID)] TCP->Vsock error: \(error)")
                break
            }
        }
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

        // Set non-blocking mode (required for DispatchSourceRead)
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
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
                    self.logger.debug("📤 [Relay:\(shortID)] Vsock->TCP EOF")
                    source.cancel()
                    return
                }

                let readSize = min(Int(source.data), self.bufferSize)
                let bytesRead = read(fd, readBuffer, readSize)

                guard bytesRead > 0 else {
                    if bytesRead == 0 {
                        // Clean EOF
                        self.logger.debug("📤 [Relay:\(shortID)] Vsock->TCP EOF (read 0)")
                        source.cancel()
                    } else if errno != EAGAIN && errno != EWOULDBLOCK {
                        // Real error (not just "try again")
                        self.logger.debug("⚠️ [Relay:\(shortID)] Vsock->TCP read error: errno \(errno)")
                        source.cancel()
                    }
                    // EAGAIN/EWOULDBLOCK: source will fire again when data available
                    return
                }

                let data = Data(bytes: readBuffer, count: bytesRead)

                self.lastActivity.withLock { $0 = .now }
                self.logger.debug("📤 [Relay:\(shortID)] Vsock->TCP \(bytesRead) bytes")

                // Suspend the source to apply backpressure: do not read more
                // data until the current TCP send completes. This prevents
                // unbounded memory growth when the TCP client is slow.
                source.suspend()
                self.tcpConnection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        self.logger.debug("⚠️ [Relay:\(shortID)] Vsock->TCP send error: \(error)")
                        source.cancel()
                    } else {
                        source.resume()
                    }
                })
            }

            source.setCancelHandler {
                readBuffer.deallocate()
                continuation.resume()
            }

            source.activate()
        }
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
