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
import Logging

/// Provides high-level container operations like exec, file I/O, and API checks.
///
/// Delegates file operations to ContainerFileSystem and uses the shared
/// OutputCollector from Helpers/ for process output collection.
@MainActor
final class ContainerOperations {
    
    // MARK: - Dependencies
    
    private let logger: Logger
    private weak var communicationManager: ContainerCommunicationManager?
    private weak var pod: LinuxPod?
    private var fileSystem: ContainerFileSystem?
    private var diagnosticsHelper: DiagnosticsHelper?
    
    // MARK: - Initialization
    
    init(logger: Logger) {
        self.logger = logger
    }
    
    /// Configure with pod, communication manager, and diagnostics helper.
    func configure(
        pod: LinuxPod?,
        communicationManager: ContainerCommunicationManager?,
        diagnosticsHelper: DiagnosticsHelper? = nil
    ) {
        self.pod = pod
        self.communicationManager = communicationManager
        self.diagnosticsHelper = diagnosticsHelper
        
        // Wire ContainerFileSystem when communication is available
        if let commManager = communicationManager {
            self.fileSystem = ContainerFileSystem(communicationManager: commManager, logger: logger)
        } else {
            self.fileSystem = nil
        }
    }
    
    // MARK: - Command Execution
    
    /// Execute a command inside the container and return the result.
    func executeCommand(_ command: [String], workingDirectory: String? = nil) async throws -> ExecResult {
        guard let commManager = communicationManager else {
            throw ContainerizationError(.invalidState, message: "Communication manager not initialized")
        }
        return try await commManager.exec(command: command, workingDirectory: workingDirectory)
    }
    
    /// Make an HTTP request to the container service.
    func httpRequest(
        method: String = "GET",
        path: String = "/",
        body: Data? = nil,
        headers: [String: String] = [:]
    ) async throws -> HTTPResponse {
        guard let commManager = communicationManager else {
            throw ContainerizationError(.invalidState, message: "Communication manager not initialized")
        }
        return try await commManager.httpRequest(method: method, path: path, body: body, headers: headers)
    }
    
    // MARK: - File Operations (Delegated to ContainerFileSystem)
    
    /// Read a file from the container.
    func readContainerFile(_ path: String) async throws -> String {
        if let fs = fileSystem {
            return try await fs.readFile(path)
        }
        // Fallback to exec-based approach if file system not available
        let result = try await executeCommand(["cat", path])
        if result.isSuccess {
            return result.stdoutString
        } else {
            throw ContainerizationError(.notFound, message: "File not found: \(path)")
        }
    }
    
    /// Write data to a file in the container.
    func writeContainerFile(_ path: String, content: String) async throws {
        if let fs = fileSystem {
            try await fs.writeFile(path, content: content)
            return
        }
        // Fallback to exec-based approach
        let escapedContent = content.replacingOccurrences(of: "'", with: "'\\''")
        let result = try await executeCommand([
            "sh", "-c",
            "mkdir -p $(dirname '\(path)') && echo '\(escapedContent)' > '\(path)'"
        ])
        
        if !result.isSuccess {
            throw ContainerizationError(.internalError, message: "Failed to write file: \(result.stderrString)")
        }
    }
    
    /// List files in a directory in the container.
    func listContainerDirectory(_ path: String) async throws -> [String] {
        if let fs = fileSystem {
            return try await fs.listDirectory(path)
        }
        // Fallback to exec-based approach
        let result = try await executeCommand(["ls", "-la", path])
        if result.isSuccess {
            return result.stdoutString.components(separatedBy: "\n").filter { !$0.isEmpty }
        } else {
            throw ContainerizationError(.notFound, message: "Directory not found: \(path)")
        }
    }
    
    /// Get the ContainerFileSystem instance for advanced file operations.
    func getFileSystem() -> ContainerFileSystem? {
        fileSystem
    }
    
    // MARK: - Environment & Process Info
    
    /// Get environment variables from the container.
    func getContainerEnvironment() async throws -> [String: String] {
        let result = try await executeCommand(["env"])
        var envVars: [String: String] = [:]
        
        for line in result.stdoutString.components(separatedBy: "\n") {
            if let equalIndex = line.firstIndex(of: "=") {
                let key = String(line[..<equalIndex])
                let value = String(line[line.index(after: equalIndex)...])
                envVars[key] = value
            }
        }
        
        return envVars
    }
    
    /// Get running processes in the container.
    func getContainerProcesses() async throws -> String {
        let result = try await executeCommand(["ps", "aux"])
        return result.stdoutString
    }
    
    /// Check if a port is listening in the container.
    /// Delegates to DiagnosticsHelper for the core pod-based implementation.
    func isPortListening(_ port: Int, diagnosticsHelper: DiagnosticsHelper? = nil) async throws -> Bool {
        // Prefer DiagnosticsHelper's pod-based implementation if available
        if let diag = diagnosticsHelper, let pod = self.pod {
            return await diag.isPortListening(pod: pod, containerID: "main", port: port)
        }
        // Fallback to exec-based approach via CommunicationManager
        let result = try await executeCommand([
            "sh", "-c",
            "netstat -tlnp 2>/dev/null | grep ':\(port)' || ss -tlnp 2>/dev/null | grep ':\(port)' || echo 'not found'"
        ])
        return !result.stdoutString.contains("not found") && result.isSuccess
    }
    
    // MARK: - API Check
    
    /// Check container API health using curl/wget inside the container.
    func checkContainerAPI(port: Int) async throws -> (statusCode: Int, body: String) {
        guard let pod = pod else {
            throw ContainerizationError(.invalidState, message: "No container is running")
        }
        
        logger.info("🌐 [ContainerOperations] Checking API at localhost:\(port)/api/filesize")
        
        // Use shared OutputCollector from Helpers/
        let stdoutCollector = OutputCollector()
        let stderrCollector = OutputCollector()
        
        // Check if curl exists
        let checkProcess = try await pod.execInContainer(
            "main",
            processID: "check-curl-\(UUID().uuidString.prefix(8))",
            configuration: { config in
                config.arguments = ["which", "curl"]
                config.workingDirectory = "/"
            }
        )
        try await checkProcess.start()
        let curlExists = try await checkProcess.wait(timeoutInSeconds: 5)
        let useWget = curlExists.exitCode != 0
        
        // Execute curl or wget
        let apiProcess = try await pod.execInContainer(
            "main",
            processID: "api-check-\(UUID().uuidString.prefix(8))",
            configuration: { config in
                if useWget {
                    config.arguments = ["wget", "-q", "-O", "-", "-T", "10", "http://127.0.0.1:\(port)/api/filesize"]
                } else {
                    config.arguments = ["curl", "-X", "GET", "-w", "\n%{http_code}", "-s", "-m", "10", "http://127.0.0.1:\(port)/api/filesize"]
                }
                config.workingDirectory = "/"
                config.stdout = stdoutCollector
                config.stderr = stderrCollector
            }
        )
        
        try await apiProcess.start()
        let exitStatus = try await apiProcess.wait(timeoutInSeconds: 15)
        
        let output = String(decoding: stdoutCollector.getOutput(), as: UTF8.self)
        let errorOutput = String(decoding: stderrCollector.getOutput(), as: UTF8.self)
        
        guard exitStatus.exitCode == 0 else {
            // Check for HTTP error in output
            let combinedOutput = errorOutput + output
            if combinedOutput.contains("HTTP/1.1 4") || combinedOutput.contains("HTTP/1.1 5") {
                if let range = combinedOutput.range(of: "HTTP/1.1 ") {
                    let statusStart = combinedOutput.index(range.upperBound, offsetBy: 0)
                    let statusEnd = combinedOutput.index(statusStart, offsetBy: min(3, combinedOutput.distance(from: statusStart, to: combinedOutput.endIndex)))
                    let statusStr = String(combinedOutput[statusStart..<statusEnd])
                    if let statusCode = Int(statusStr) {
                        return (statusCode: statusCode, body: "Server responded with HTTP \(statusCode)")
                    }
                }
            }
            
            let errorMessage: String
            if errorOutput.contains("curl: command not found") || errorOutput.contains("wget: not found") {
                errorMessage = "Neither curl nor wget found in container"
            } else if errorOutput.contains("Connection refused") {
                errorMessage = "Connection refused on port \(port)"
            } else {
                errorMessage = "API check failed: \(errorOutput.isEmpty ? output : errorOutput)"
            }
            throw ContainerizationError(.invalidState, message: errorMessage)
        }
        
        // Parse status code from curl output
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        var statusCode = 200
        var body = output
        
        if let lastLine = lines.last, let parsedCode = Int(lastLine.trimmingCharacters(in: .whitespaces)) {
            statusCode = parsedCode
            body = lines.dropLast().joined(separator: "\n")
        }
        
        logger.info("✅ [ContainerOperations] API check complete - Status: \(statusCode)")
        return (statusCode: statusCode, body: body)
    }
}
