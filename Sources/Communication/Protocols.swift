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

// MARK: - Communication Protocol

/// Protocol defining the communication interface with the container.
///
/// Implementations of this protocol provide different communication mechanisms
/// to interact with running containers (vsock, HTTP, Unix socket, etc.)
protocol ContainerCommunicator: Sendable {
    /// Send a message to the container and receive a response.
    /// - Parameter message: The data to send
    /// - Returns: The response data from the container
    func send(_ message: Data) async throws -> Data
    
    /// Execute a command inside the container.
    /// - Parameters:
    ///   - command: The command arguments to execute
    ///   - workingDirectory: Optional working directory for the command
    /// - Returns: The result of the execution
    func exec(command: [String], workingDirectory: String?) async throws -> ExecResult
    
    /// Start the communication channel.
    func start() async throws
    
    /// Stop the communication channel.
    func stop() async throws
}

// MARK: - Exec Result

/// Result of executing a command in the container.
public struct ExecResult: Sendable {
    /// The exit code of the command.
    public let exitCode: Int32
    
    /// The stdout output as raw data.
    public let stdout: Data
    
    /// The stderr output as raw data.
    public let stderr: Data
    
    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
    
    /// The stdout output as a UTF-8 string.
    public var stdoutString: String {
        String(decoding: stdout, as: UTF8.self)
    }
    
    /// The stderr output as a UTF-8 string.
    public var stderrString: String {
        String(decoding: stderr, as: UTF8.self)
    }
    
    /// Whether the command exited successfully (exit code 0).
    public var isSuccess: Bool {
        exitCode == 0
    }
}

// MARK: - HTTP Response

/// HTTP Response from the container.
public struct HTTPResponse: Sendable {
    /// The HTTP status code.
    public let statusCode: Int
    
    /// The response body as raw data.
    public let body: Data
    
    /// The response headers.
    public let headers: [String: String]
    
    public init(statusCode: Int, body: Data, headers: [String: String]) {
        self.statusCode = statusCode
        self.body = body
        self.headers = headers
    }
    
    /// The response body as a UTF-8 string.
    public var bodyString: String {
        String(decoding: body, as: UTF8.self)
    }
    
    /// Whether the response indicates success (2xx status code).
    public var isSuccess: Bool {
        statusCode >= 200 && statusCode < 300
    }
}
