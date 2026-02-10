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

// MARK: - Vsock-based Communication

/// Communicator that uses vsock for direct host-guest communication.
///
/// Vsock provides a direct communication channel between the host and guest
/// without going through the network stack.
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
