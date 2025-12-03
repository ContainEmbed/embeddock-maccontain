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
import ContainerizationOS
import Logging
import Network

// MARK: - Communication Protocol

/// Protocol defining the communication interface with the container
public protocol ContainerCommunicator: Sendable {
    /// Send a message to the container and receive a response
    func send(_ message: Data) async throws -> Data
    
    /// Execute a command inside the container
    func exec(command: [String], workingDirectory: String?) async throws -> ExecResult
    
    /// Start the communication channel
    func start() async throws
    
    /// Stop the communication channel
    func stop() async throws
}

/// Result of executing a command in the container
public struct ExecResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data
    
    public var stdoutString: String {
        String(decoding: stdout, as: UTF8.self)
    }
    
    public var stderrString: String {
        String(decoding: stderr, as: UTF8.self)
    }
    
    public var isSuccess: Bool {
        exitCode == 0
    }
}

// MARK: - Vsock-based Communication

/// Communicator that uses vsock for direct host-guest communication
public actor VsockCommunicator: ContainerCommunicator {
    private let pod: LinuxPod
    private let port: UInt32
    private let logger: Logger
    private var isRunning = false
    
    public init(pod: LinuxPod, port: UInt32, logger: Logger) {
        self.pod = pod
        self.port = port
        self.logger = logger
    }
    
    public func start() async throws {
        logger.info("🔌 [VsockCommunicator] Starting vsock communication on port \(port)")
        isRunning = true
    }
    
    public func stop() async throws {
        logger.info("🔌 [VsockCommunicator] Stopping vsock communication")
        isRunning = false
    }
    
    public func send(_ message: Data) async throws -> Data {
        guard isRunning else {
            throw CommunicationError.notConnected
        }
        
        logger.debug("📤 [VsockCommunicator] Sending \(message.count) bytes via vsock port \(port)")
        
        // Dial the vsock port in the guest
        let handle = try await pod.dialVsock(port: port)
        defer { try? handle.close() }
        
        // Write the message
        try handle.write(contentsOf: message)
        
        // Read response
        let response = try handle.readToEnd() ?? Data()
        
        logger.debug("📥 [VsockCommunicator] Received \(response.count) bytes")
        return response
    }
    
    public func exec(command: [String], workingDirectory: String?) async throws -> ExecResult {
        logger.info("🖥️ [VsockCommunicator] Executing command: \(command.joined(separator: " "))")
        
        let stdoutCollector = OutputCollector()
        let stderrCollector = OutputCollector()
        
        let process = try await pod.execInContainer(
            "main",
            processID: "exec-\(UUID().uuidString.prefix(8))",
            configuration: { config in
                config.arguments = command
                config.workingDirectory = workingDirectory ?? "/"
                config.stdout = stdoutCollector
                config.stderr = stderrCollector
            }
        )
        
        try await process.start()
        let exitStatus = try await process.wait(timeoutInSeconds: 30)
        
        return ExecResult(
            exitCode: exitStatus.exitCode,
            stdout: stdoutCollector.getOutput(),
            stderr: stderrCollector.getOutput()
        )
    }
}

// MARK: - HTTP-based Communication

/// Communicator that uses HTTP to communicate with services in the container
public actor HTTPContainerCommunicator: ContainerCommunicator {
    private let pod: LinuxPod
    private let containerIP: String
    private let containerPort: Int
    private let logger: Logger
    private var isRunning = false
    
    public init(pod: LinuxPod, containerIP: String = "192.168.127.2", containerPort: Int, logger: Logger) {
        self.pod = pod
        self.containerIP = containerIP
        self.containerPort = containerPort
        self.logger = logger
    }
    
    public func start() async throws {
        logger.info("🌐 [HTTPCommunicator] Starting HTTP communication to \(containerIP):\(containerPort)")
        isRunning = true
    }
    
    public func stop() async throws {
        logger.info("🌐 [HTTPCommunicator] Stopping HTTP communication")
        isRunning = false
    }
    
    public func send(_ message: Data) async throws -> Data {
        guard isRunning else {
            throw CommunicationError.notConnected
        }
        
        // Use curl inside the container to make HTTP requests
        // This is necessary because the container is in a NAT network
        let result = try await httpRequest(
            method: "POST",
            path: "/",
            body: message
        )
        
        return result.body
    }
    
    /// Make an HTTP GET request to the container
    public func get(path: String, headers: [String: String] = [:]) async throws -> HTTPResponse {
        try await httpRequest(method: "GET", path: path, headers: headers, body: nil)
    }
    
    /// Make an HTTP POST request to the container
    public func post(path: String, body: Data?, headers: [String: String] = [:]) async throws -> HTTPResponse {
        try await httpRequest(method: "POST", path: path, headers: headers, body: body)
    }
    
    /// Make an HTTP PUT request to the container
    public func put(path: String, body: Data?, headers: [String: String] = [:]) async throws -> HTTPResponse {
        try await httpRequest(method: "PUT", path: path, headers: headers, body: body)
    }
    
    /// Make an HTTP DELETE request to the container
    public func delete(path: String, headers: [String: String] = [:]) async throws -> HTTPResponse {
        try await httpRequest(method: "DELETE", path: path, headers: headers, body: nil)
    }
    
    private func httpRequest(
        method: String,
        path: String,
        headers: [String: String] = [:],
        body: Data?
    ) async throws -> HTTPResponse {
        logger.debug("📤 [HTTPCommunicator] \(method) http://\(containerIP):\(containerPort)\(path)")
        
        var curlArgs = [
            "curl",
            "-s",                                    // Silent mode
            "-w", "\n---STATUS:%{http_code}---",    // Append status code
            "-X", method,
            "-m", "30"                              // 30 second timeout
        ]
        
        // Add headers
        for (key, value) in headers {
            curlArgs.append("-H")
            curlArgs.append("\(key): \(value)")
        }
        
        // Add body if present
        if let body = body, !body.isEmpty {
            curlArgs.append("-d")
            curlArgs.append(String(decoding: body, as: UTF8.self))
            
            // Add content-type if not specified
            if !headers.keys.contains(where: { $0.lowercased() == "content-type" }) {
                curlArgs.append("-H")
                curlArgs.append("Content-Type: application/json")
            }
        }
        
        curlArgs.append("http://\(containerIP):\(containerPort)\(path)")
        
        let result = try await exec(command: curlArgs, workingDirectory: nil)
        
        // Parse the response
        let outputString = result.stdoutString
        
        // Extract status code from the output
        var statusCode = 0
        var responseBody = outputString
        
        if let statusRange = outputString.range(of: "---STATUS:") {
            let statusStart = outputString.index(statusRange.upperBound, offsetBy: 0)
            if let statusEnd = outputString.range(of: "---", range: statusStart..<outputString.endIndex) {
                let statusString = String(outputString[statusStart..<statusEnd.lowerBound])
                statusCode = Int(statusString) ?? 0
                responseBody = String(outputString[..<statusRange.lowerBound])
            }
        }
        
        logger.debug("📥 [HTTPCommunicator] Response status: \(statusCode)")
        
        return HTTPResponse(
            statusCode: statusCode,
            body: Data(responseBody.utf8),
            headers: [:]  // Headers would need additional curl flags to capture
        )
    }
    
    public func exec(command: [String], workingDirectory: String?) async throws -> ExecResult {
        let stdoutCollector = OutputCollector()
        let stderrCollector = OutputCollector()
        
        let process = try await pod.execInContainer(
            "main",
            processID: "http-\(UUID().uuidString.prefix(8))",
            configuration: { config in
                config.arguments = command
                config.workingDirectory = workingDirectory ?? "/"
                config.stdout = stdoutCollector
                config.stderr = stderrCollector
            }
        )
        
        try await process.start()
        let exitStatus = try await process.wait(timeoutInSeconds: 35)
        
        return ExecResult(
            exitCode: exitStatus.exitCode,
            stdout: stdoutCollector.getOutput(),
            stderr: stderrCollector.getOutput()
        )
    }
}

/// HTTP Response from the container
public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let body: Data
    public let headers: [String: String]
    
    public var bodyString: String {
        String(decoding: body, as: UTF8.self)
    }
    
    public var isSuccess: Bool {
        statusCode >= 200 && statusCode < 300
    }
}

// MARK: - Unix Socket Communication

/// Communicator that uses Unix socket relay for communication
public actor UnixSocketCommunicator: ContainerCommunicator {
    private let pod: LinuxPod
    private let hostSocketPath: URL
    private let guestSocketPath: URL
    private let logger: Logger
    private var isRunning = false
    
    public init(
        pod: LinuxPod,
        hostSocketPath: URL,
        guestSocketPath: URL,
        logger: Logger
    ) {
        self.pod = pod
        self.hostSocketPath = hostSocketPath
        self.guestSocketPath = guestSocketPath
        self.logger = logger
    }
    
    public func start() async throws {
        logger.info("🔗 [UnixSocketCommunicator] Setting up Unix socket relay")
        logger.info("   Host: \(hostSocketPath.path)")
        logger.info("   Guest: \(guestSocketPath.path)")
        
        // Set up the socket relay
        let socketConfig = UnixSocketConfiguration(
            source: guestSocketPath,
            destination: hostSocketPath,
            permissions: nil,
            direction: .outOf  // Share guest socket to host
        )
        
        try await pod.relayUnixSocket("main", socket: socketConfig)
        isRunning = true
        
        logger.info("✅ [UnixSocketCommunicator] Unix socket relay established")
    }
    
    public func stop() async throws {
        logger.info("🔗 [UnixSocketCommunicator] Stopping Unix socket relay")
        isRunning = false
        
        // Clean up host socket file
        try? FileManager.default.removeItem(at: hostSocketPath)
    }
    
    public func send(_ message: Data) async throws -> Data {
        guard isRunning else {
            throw CommunicationError.notConnected
        }
        
        logger.debug("📤 [UnixSocketCommunicator] Sending \(message.count) bytes")
        
        // Connect to the host socket
        let socketType = try UnixType(path: hostSocketPath.path)
        let socket = try Socket(type: socketType, closeOnDeinit: true)
        try socket.connect()
        
        // Write the message
        try message.withUnsafeBytes { buffer in
            let written = write(socket.fileDescriptor, buffer.baseAddress, buffer.count)
            if written != buffer.count {
                throw CommunicationError.sendFailed
            }
        }
        
        // Read response
        var responseData = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        
        while true {
            let bytesRead = read(socket.fileDescriptor, buffer, bufferSize)
            if bytesRead <= 0 {
                break
            }
            responseData.append(buffer, count: bytesRead)
        }
        
        try socket.close()
        
        logger.debug("📥 [UnixSocketCommunicator] Received \(responseData.count) bytes")
        return responseData
    }
    
    public func exec(command: [String], workingDirectory: String?) async throws -> ExecResult {
        let stdoutCollector = OutputCollector()
        let stderrCollector = OutputCollector()
        
        let process = try await pod.execInContainer(
            "main",
            processID: "socket-exec-\(UUID().uuidString.prefix(8))",
            configuration: { config in
                config.arguments = command
                config.workingDirectory = workingDirectory ?? "/"
                config.stdout = stdoutCollector
                config.stderr = stderrCollector
            }
        )
        
        try await process.start()
        let exitStatus = try await process.wait(timeoutInSeconds: 30)
        
        return ExecResult(
            exitCode: exitStatus.exitCode,
            stdout: stdoutCollector.getOutput(),
            stderr: stderrCollector.getOutput()
        )
    }
}

// MARK: - Message Queue Communication

/// A simple message-based communication channel using file-based messaging
public actor MessageQueueCommunicator: ContainerCommunicator {
    private let pod: LinuxPod
    private let queuePath: String
    private let logger: Logger
    private var isRunning = false
    private var messageCounter: UInt64 = 0
    
    public init(pod: LinuxPod, queuePath: String = "/tmp/app-messages", logger: Logger) {
        self.pod = pod
        self.queuePath = queuePath
        self.logger = logger
    }
    
    public func start() async throws {
        logger.info("📬 [MessageQueueCommunicator] Starting message queue at \(queuePath)")
        
        // Create the message queue directory in the container
        let result = try await exec(
            command: ["mkdir", "-p", queuePath],
            workingDirectory: nil
        )
        
        guard result.isSuccess else {
            throw CommunicationError.setupFailed(result.stderrString)
        }
        
        isRunning = true
        logger.info("✅ [MessageQueueCommunicator] Message queue ready")
    }
    
    public func stop() async throws {
        logger.info("📬 [MessageQueueCommunicator] Stopping message queue")
        isRunning = false
    }
    
    public func send(_ message: Data) async throws -> Data {
        guard isRunning else {
            throw CommunicationError.notConnected
        }
        
        messageCounter += 1
        let messageId = messageCounter
        let requestFile = "\(queuePath)/request-\(messageId)"
        let responseFile = "\(queuePath)/response-\(messageId)"
        
        logger.debug("📤 [MessageQueueCommunicator] Sending message \(messageId)")
        
        // Write message to request file
        let messageString = String(decoding: message, as: UTF8.self)
        let writeResult = try await exec(
            command: ["sh", "-c", "echo '\(messageString)' > \(requestFile)"],
            workingDirectory: nil
        )
        
        guard writeResult.isSuccess else {
            throw CommunicationError.sendFailed
        }
        
        // Wait for response (poll with timeout)
        var attempts = 0
        let maxAttempts = 30  // 30 second timeout
        
        while attempts < maxAttempts {
            let checkResult = try await exec(
                command: ["cat", responseFile],
                workingDirectory: nil
            )
            
            if checkResult.isSuccess && !checkResult.stdout.isEmpty {
                // Clean up
                _ = try? await exec(
                    command: ["rm", "-f", requestFile, responseFile],
                    workingDirectory: nil
                )
                
                logger.debug("📥 [MessageQueueCommunicator] Received response for message \(messageId)")
                return checkResult.stdout
            }
            
            try await Task.sleep(for: .seconds(1))
            attempts += 1
        }
        
        throw CommunicationError.timeout
    }
    
    public func exec(command: [String], workingDirectory: String?) async throws -> ExecResult {
        let stdoutCollector = OutputCollector()
        let stderrCollector = OutputCollector()
        
        let process = try await pod.execInContainer(
            "main",
            processID: "mq-\(UUID().uuidString.prefix(8))",
            configuration: { config in
                config.arguments = command
                config.workingDirectory = workingDirectory ?? "/"
                config.stdout = stdoutCollector
                config.stderr = stderrCollector
            }
        )
        
        try await process.start()
        let exitStatus = try await process.wait(timeoutInSeconds: 35)
        
        return ExecResult(
            exitCode: exitStatus.exitCode,
            stdout: stdoutCollector.getOutput(),
            stderr: stderrCollector.getOutput()
        )
    }
}

// MARK: - Communication Errors

public enum CommunicationError: Error, LocalizedError {
    case notConnected
    case sendFailed
    case receiveFailed
    case timeout
    case setupFailed(String)
    case invalidResponse
    
    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Communication channel is not connected"
        case .sendFailed:
            return "Failed to send message to container"
        case .receiveFailed:
            return "Failed to receive response from container"
        case .timeout:
            return "Communication timed out"
        case .setupFailed(let reason):
            return "Failed to setup communication: \(reason)"
        case .invalidResponse:
            return "Invalid response from container"
        }
    }
}

// MARK: - Output Collector Helper

/// Helper class to collect output from container processes
final class OutputCollector: Writer, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    
    func write(_ data: Data) throws {
        lock.withLock {
            buffer.append(data)
        }
    }
    
    func close() throws {
        // No-op
    }
    
    func getOutput() -> Data {
        lock.withLock {
            return buffer
        }
    }
}

// MARK: - Container Communication Manager

/// Unified manager for all communication methods with the container
@MainActor
public class ContainerCommunicationManager: ObservableObject {
    private let pod: LinuxPod
    private let logger: Logger
    
    @Published public var isConnected = false
    @Published public var lastError: String?
    
    private var httpCommunicator: HTTPContainerCommunicator?
    private var vsockCommunicator: VsockCommunicator?
    
    public init(pod: LinuxPod, logger: Logger) {
        self.pod = pod
        self.logger = logger
    }
    
    /// Initialize HTTP communication with the container
    public func setupHTTPCommunication(port: Int) async throws -> HTTPContainerCommunicator {
        logger.info("🌐 Setting up HTTP communication on port \(port)")
        
        let communicator = HTTPContainerCommunicator(
            pod: pod,
            containerPort: port,
            logger: logger
        )
        
        try await communicator.start()
        httpCommunicator = communicator
        isConnected = true
        
        return communicator
    }
    
    /// Initialize vsock communication with the container
    public func setupVsockCommunication(port: UInt32) async throws -> VsockCommunicator {
        logger.info("🔌 Setting up vsock communication on port \(port)")
        
        let communicator = VsockCommunicator(
            pod: pod,
            port: port,
            logger: logger
        )
        
        try await communicator.start()
        vsockCommunicator = communicator
        isConnected = true
        
        return communicator
    }
    
    /// Execute a command directly in the container
    public func exec(command: [String], workingDirectory: String? = nil) async throws -> ExecResult {
        logger.info("🖥️ Executing: \(command.joined(separator: " "))")
        
        let stdoutCollector = OutputCollector()
        let stderrCollector = OutputCollector()
        
        let process = try await pod.execInContainer(
            "main",
            processID: "direct-exec-\(UUID().uuidString.prefix(8))",
            configuration: { config in
                config.arguments = command
                config.workingDirectory = workingDirectory ?? "/"
                config.stdout = stdoutCollector
                config.stderr = stderrCollector
            }
        )
        
        try await process.start()
        let exitStatus = try await process.wait(timeoutInSeconds: 30)
        
        let result = ExecResult(
            exitCode: exitStatus.exitCode,
            stdout: stdoutCollector.getOutput(),
            stderr: stderrCollector.getOutput()
        )
        
        logger.info("📋 Exit code: \(result.exitCode)")
        if !result.isSuccess {
            logger.warning("⚠️ stderr: \(result.stderrString)")
        }
        
        return result
    }
    
    /// Make an HTTP request to the container service
    public func httpRequest(
        method: String = "GET",
        path: String = "/",
        body: Data? = nil,
        headers: [String: String] = [:]
    ) async throws -> HTTPResponse {
        guard let http = httpCommunicator else {
            throw CommunicationError.notConnected
        }
        
        switch method.uppercased() {
        case "GET":
            return try await http.get(path: path, headers: headers)
        case "POST":
            return try await http.post(path: path, body: body, headers: headers)
        case "PUT":
            return try await http.put(path: path, body: body, headers: headers)
        case "DELETE":
            return try await http.delete(path: path, headers: headers)
        default:
            throw CommunicationError.invalidResponse
        }
    }
    
    /// Stop all communication channels
    public func disconnect() async {
        logger.info("🔌 Disconnecting all communication channels")
        
        if let http = httpCommunicator {
            try? await http.stop()
        }
        if let vsock = vsockCommunicator {
            try? await vsock.stop()
        }
        
        httpCommunicator = nil
        vsockCommunicator = nil
        isConnected = false
    }
}
