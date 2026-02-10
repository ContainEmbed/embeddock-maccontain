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

// MARK: - HTTP-based Communication

/// Communicator that uses HTTP to communicate with services in the container.
///
/// Since the container runs in a NAT network, this communicator uses curl
/// inside the container to make HTTP requests to local services.
public actor HTTPContainerCommunicator: ContainerCommunicator {
    private let pod: LinuxPod
    private let containerIP: String
    private let containerPort: Int
    private let logger: Logger
    private var isRunning = false
    
    public init(
        pod: LinuxPod,
        containerIP: String = "192.168.127.2",
        containerPort: Int,
        logger: Logger
    ) {
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
        let result = try await httpRequest(
            method: "POST",
            path: "/",
            body: message
        )
        
        return result.body
    }
    
    /// Make an HTTP GET request to the container.
    public func get(path: String, headers: [String: String] = [:]) async throws -> HTTPResponse {
        try await httpRequest(method: "GET", path: path, headers: headers, body: nil)
    }
    
    /// Make an HTTP POST request to the container.
    public func post(path: String, body: Data?, headers: [String: String] = [:]) async throws -> HTTPResponse {
        try await httpRequest(method: "POST", path: path, headers: headers, body: body)
    }
    
    /// Make an HTTP PUT request to the container.
    public func put(path: String, body: Data?, headers: [String: String] = [:]) async throws -> HTTPResponse {
        try await httpRequest(method: "PUT", path: path, headers: headers, body: body)
    }
    
    /// Make an HTTP DELETE request to the container.
    public func delete(path: String, headers: [String: String] = [:]) async throws -> HTTPResponse {
        try await httpRequest(method: "DELETE", path: path, headers: headers, body: nil)
    }
    
    /// Make an HTTP request to the container.
    public func httpRequest(
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
