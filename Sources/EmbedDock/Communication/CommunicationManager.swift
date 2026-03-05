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
import Logging
import System

// MARK: - Communication Channel Types

/// The type of communication channel to use.
public enum CommunicationType: String, Codable, CaseIterable, Sendable {
    case vsock      = "Vsock"
    case http       = "HTTP"
    case unixSocket = "Unix Socket"

    public var description: String {
        switch self {
        case .vsock:
            return "Direct vsock communication between host and guest"
        case .http:
            return "HTTP-based communication via curl"
        case .unixSocket:
            return "Unix socket communication for local services"
        }
    }
}

// MARK: - Communication Manager

/// Central manager for container communication.
///
/// The CommunicationManager provides a unified interface for different
/// communication channels. It handles channel lifecycle, routing, and
/// provides convenient methods for common operations.
///
/// Usage:
/// ```swift
/// let manager = CommunicationManager(pod: pod, logger: logger)
/// try await manager.addChannel(.http, port: 8080)
/// let response = try await manager.http.get(path: "/health")
/// ```
actor CommunicationManager {
    private var channels: [CommunicationType: any ContainerCommunicator] = [:]
    private let pod: LinuxPod
    private let logger: Logger

    init(pod: LinuxPod, logger: Logger) {
        self.pod = pod
        self.logger = logger
    }

    // MARK: - Channel Management

    /// Add a vsock communication channel.
    func addVsockChannel(port: UInt32) async throws {
        let communicator = VsockCommunicator(pod: pod, port: port, logger: logger)
        try await communicator.start()
        channels[.vsock] = communicator
        logger.info("✅ Added vsock channel on port \(port)")
    }

    /// Add an HTTP communication channel.
    func addHTTPChannel(containerIP: String = "192.168.127.2", port: Int) async throws {
        let communicator = HTTPContainerCommunicator(
            pod: pod,
            containerIP: containerIP,
            containerPort: port,
            logger: logger
        )
        try await communicator.start()
        channels[.http] = communicator
        logger.info("✅ Added HTTP channel to \(containerIP):\(port)")
    }

    /// Add a Unix socket communication channel.
    func addUnixSocketChannel(socketPath: FilePath) async throws {
        let communicator = UnixSocketCommunicator(
            pod: pod,
            socketPath: socketPath,
            logger: logger
        )
        try await communicator.start()
        channels[.unixSocket] = communicator
        logger.info("✅ Added Unix socket channel at \(socketPath)")
    }

    /// Remove a communication channel.
    func removeChannel(_ type: CommunicationType) async throws {
        guard let channel = channels[type] else {
            return
        }
        try await channel.stop()
        channels[type] = nil
        logger.info("🗑️ Removed \(type.rawValue) channel")
    }

    /// Remove all communication channels.
    func removeAllChannels() async throws {
        for (type, channel) in channels {
            try await channel.stop()
            logger.info("🗑️ Stopped \(type.rawValue) channel")
        }
        channels.removeAll()
    }

    // MARK: - Channel Access

    /// Get a channel by type.
    func channel(_ type: CommunicationType) -> (any ContainerCommunicator)? {
        channels[type]
    }

    /// Get the HTTP communicator for convenience.
    var http: HTTPContainerCommunicator? {
        channels[.http] as? HTTPContainerCommunicator
    }

    /// Get the vsock communicator for convenience.
    var vsock: VsockCommunicator? {
        channels[.vsock] as? VsockCommunicator
    }

    /// Get the Unix socket communicator for convenience.
    var unixSocket: UnixSocketCommunicator? {
        channels[.unixSocket] as? UnixSocketCommunicator
    }

    /// Check if a channel type is available.
    func hasChannel(_ type: CommunicationType) -> Bool {
        channels[type] != nil
    }

    /// Get all active channel types.
    var activeChannelTypes: [CommunicationType] {
        Array(channels.keys)
    }

    // MARK: - Convenience Methods

    /// Execute a command in the container using the best available channel.
    func exec(command: [String], workingDirectory: String? = nil) async throws -> ExecResult {
        // Prefer vsock for exec operations, then fallback to others
        let preferredOrder: [CommunicationType] = [.vsock, .unixSocket, .http]

        for type in preferredOrder {
            if let channel = channels[type] {
                return try await channel.exec(command: command, workingDirectory: workingDirectory)
            }
        }

        throw CommunicationError.noAvailableChannel
    }

    /// Send raw data using the best available channel.
    func send(_ data: Data) async throws -> Data {
        let preferredOrder: [CommunicationType] = [.vsock, .unixSocket, .http]

        for type in preferredOrder {
            if let channel = channels[type] {
                return try await channel.send(data)
            }
        }

        throw CommunicationError.noAvailableChannel
    }

    // MARK: - ContainerEngine Compatibility

    /// Setup HTTP communication channel (compatibility method for ContainerEngine).
    /// - Parameter port: The container port to connect to.
    /// - Returns: The configured HTTPContainerCommunicator.
    func setupHTTPCommunication(port: Int) async throws -> HTTPContainerCommunicator {
        try await addHTTPChannel(port: port)
        guard let httpComm = http else {
            throw CommunicationError.setupFailed("Failed to create HTTP channel")
        }
        return httpComm
    }

    /// Disconnect all communication channels.
    func disconnect() async {
        do {
            try await removeAllChannels()
        } catch {
            logger.warning("⚠️ Error during disconnect: \(error)")
        }
    }

    /// Make an HTTP request (convenience method for ContainerEngine).
    /// - Parameters:
    ///   - method: HTTP method (GET, POST, etc.)
    ///   - path: Request path.
    ///   - body: Optional request body.
    ///   - headers: Optional headers.
    /// - Returns: HTTPResponse with status, body, and headers.
    func httpRequest(
        method: String,
        path: String,
        body: Data? = nil,
        headers: [String: String]? = nil
    ) async throws -> HTTPResponse {
        guard let httpComm = http else {
            throw CommunicationError.notConnected
        }
        return try await httpComm.httpRequest(method: method, path: path, headers: headers ?? [:], body: body)
    }
}

// MARK: - Extension for Error

extension CommunicationError {
    /// Error when no communication channel is available.
    static let noAvailableChannel = CommunicationError.setupFailed("No communication channel available")
}
