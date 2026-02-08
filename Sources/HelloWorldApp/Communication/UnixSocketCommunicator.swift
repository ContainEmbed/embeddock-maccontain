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

// MARK: - Unix Socket Communication

/// Communicator that uses Unix sockets for inter-process communication.
///
/// Unix sockets provide high-performance local communication, commonly used
/// for Docker-style APIs and other local services.
public actor UnixSocketCommunicator: ContainerCommunicator {
    private let pod: LinuxPod
    private let socketPath: FilePath
    private let logger: Logger
    private var isRunning = false
    
    public init(
        pod: LinuxPod,
        socketPath: FilePath,
        logger: Logger
    ) {
        self.pod = pod
        self.socketPath = socketPath
        self.logger = logger
    }
    
    public func start() async throws {
        logger.info("🔗 [UnixSocketCommunicator] Starting communication on socket: \(socketPath)")
        isRunning = true
    }
    
    public func stop() async throws {
        logger.info("🔗 [UnixSocketCommunicator] Stopping communication")
        isRunning = false
    }
    
    public func send(_ message: Data) async throws -> Data {
        guard isRunning else {
            throw CommunicationError.notConnected
        }
        
        logger.debug("📤 [UnixSocketCommunicator] Sending \(message.count) bytes to \(socketPath)")
        
        // Use socat or curl to communicate via unix socket
        let result = try await exec(
            command: [
                "curl",
                "--unix-socket", socketPath.string,
                "-s",
                "-X", "POST",
                "-d", String(decoding: message, as: UTF8.self),
                "http://localhost/"
            ],
            workingDirectory: nil
        )
        
        if result.exitCode != 0 {
            throw CommunicationError.unexpectedResponse(result.stderrString)
        }
        
        return result.stdout
    }
    
    /// Make an HTTP request through a Unix socket.
    public func httpRequest(
        method: String,
        path: String,
        body: Data? = nil,
        headers: [String: String] = [:]
    ) async throws -> HTTPResponse {
        var curlArgs = [
            "curl",
            "--unix-socket", socketPath.string,
            "-s",
            "-w", "\n---STATUS:%{http_code}---",
            "-X", method
        ]
        
        for (key, value) in headers {
            curlArgs.append("-H")
            curlArgs.append("\(key): \(value)")
        }
        
        if let body = body, !body.isEmpty {
            curlArgs.append("-d")
            curlArgs.append(String(decoding: body, as: UTF8.self))
        }
        
        curlArgs.append("http://localhost\(path)")
        
        let result = try await exec(command: curlArgs, workingDirectory: nil)
        
        // Parse the response
        let outputString = result.stdoutString
        var statusCode = 0
        var responseBody = outputString
        
        if let statusRange = outputString.range(of: "---STATUS:") {
            let statusStart = statusRange.upperBound
            if let statusEnd = outputString.range(of: "---", range: statusStart..<outputString.endIndex) {
                let statusString = String(outputString[statusStart..<statusEnd.lowerBound])
                statusCode = Int(statusString) ?? 0
                responseBody = String(outputString[..<statusRange.lowerBound])
            }
        }
        
        return HTTPResponse(
            statusCode: statusCode,
            body: Data(responseBody.utf8),
            headers: [:]
        )
    }
    
    public func exec(command: [String], workingDirectory: String?) async throws -> ExecResult {
        let stdoutCollector = OutputCollector()
        let stderrCollector = OutputCollector()
        
        let process = try await pod.execInContainer(
            "main",
            processID: "unix-\(UUID().uuidString.prefix(8))",
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
