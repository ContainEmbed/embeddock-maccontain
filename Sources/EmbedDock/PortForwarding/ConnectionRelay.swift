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
    /// This method runs until either side closes or an error occurs.
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
    
    // MARK: - Relay Directions
    
    /// Relay data from TCP to Vsock.
    private func relayTcpToVsock() async {
        let shortID = connectionID.uuidString.prefix(8)
        
        while !Task.isCancelled {
            do {
                let data = try await receiveTcpData()
                
                guard let data = data, !data.isEmpty else {
                    logger.debug("📤 [Relay:\(shortID)] TCP->Vsock EOF")
                    break
                }
                
                try vsockHandle.write(contentsOf: data)
                logger.debug("📤 [Relay:\(shortID)] TCP->Vsock \(data.count) bytes")
                
            } catch {
                logger.debug("⚠️ [Relay:\(shortID)] TCP->Vsock error: \(error)")
                break
            }
        }
    }
    
    /// Relay data from Vsock to TCP.
    private func relayVsockToTcp() async {
        let shortID = connectionID.uuidString.prefix(8)
        
        while !Task.isCancelled {
            do {
                // Read from vsock (FileHandle)
                let data: Data? = try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async { [self] in
                        do {
                            let data = try self.vsockHandle.read(upToCount: self.bufferSize)
                            continuation.resume(returning: data)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
                
                guard let data = data, !data.isEmpty else {
                    logger.debug("📤 [Relay:\(shortID)] Vsock->TCP EOF")
                    break
                }
                
                try await sendTcpData(data)
                logger.debug("📤 [Relay:\(shortID)] Vsock->TCP \(data.count) bytes")
                
            } catch {
                logger.debug("⚠️ [Relay:\(shortID)] Vsock->TCP error: \(error)")
                break
            }
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
    
    /// Send data over the TCP connection.
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
