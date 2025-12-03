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

#if os(macOS)
import Foundation
import Logging
import Virtualization
import ContainerizationError

extension VZVirtualMachine {
    nonisolated func connect(queue: DispatchQueue, port: UInt32) async throws -> VZVirtioSocketConnection {
        try await withCheckedThrowingContinuation { cont in
            queue.sync {
                guard let vsock = self.socketDevices[0] as? VZVirtioSocketDevice else {
                    let error = ContainerizationError(.invalidArgument, message: "no vsock device")
                    cont.resume(throwing: error)
                    return
                }
                vsock.connect(toPort: port) { result in
                    switch result {
                    case .success(let conn):
                        // `conn` isn't used concurrently.
                        nonisolated(unsafe) let conn = conn
                        cont.resume(returning: conn)
                    case .failure(let error):
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    func listen(queue: DispatchQueue, port: UInt32, listener: VZVirtioSocketListener) throws {
        try queue.sync {
            guard let vsock = self.socketDevices[0] as? VZVirtioSocketDevice else {
                throw ContainerizationError(.invalidArgument, message: "no vsock device")
            }
            vsock.setSocketListener(listener, forPort: port)
        }
    }

    func removeListener(queue: DispatchQueue, port: UInt32) throws {
        try queue.sync {
            guard let vsock = self.socketDevices[0] as? VZVirtioSocketDevice else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "no vsock device to remove"
                )
            }
            vsock.removeSocketListener(forPort: port)
        }
    }

    func start(queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.sync {
                self.start { result in
                    if case .failure(let error) = result {
                        cont.resume(throwing: error)
                        return
                    }
                    cont.resume()
                }
            }
        }
    }

    func stop(queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.sync {
                self.stop { error in
                    if let error {
                        cont.resume(throwing: error)
                        return
                    }
                    cont.resume()
                }
            }
        }
    }

    func pause(queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.sync {
                self.pause { result in
                    if case .failure(let error) = result {
                        cont.resume(throwing: error)
                        return
                    }
                    cont.resume()
                }
            }
        }
    }

    func resume(queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.sync {
                self.resume { result in
                    if case .failure(let error) = result {
                        cont.resume(throwing: error)
                        return
                    }
                    cont.resume()
                }
            }
        }
    }
}

extension VZVirtualMachine {
    func waitForAgent(queue: DispatchQueue) async throws -> FileHandle {
        // Increase timeout significantly for VM boot + vminitd startup
        // VM boot can take 10-30 seconds, vminitd needs additional time
        let agentConnectionRetryCount: Int = 3000  // Was 150
        let agentConnectionSleepDuration: Duration = .milliseconds(20)
        let timeoutSeconds = Double(agentConnectionRetryCount) * 0.02  // Calculate total timeout

        print("[DEBUG] Waiting for vminitd agent on vsock port \(Vminitd.port) (timeout: \(timeoutSeconds)s)")
        
        for attempt in 0...agentConnectionRetryCount {
            do {
                let connection = try await self.connect(queue: queue, port: Vminitd.port).dupHandle()
                print("[DEBUG] ✅ Connected to vminitd after \(attempt) attempts (~\(Double(attempt) * 0.02)s)")
                return connection
            } catch {
                if attempt % 50 == 0 && attempt > 0 {
                    // Log progress every second
                    print("[DEBUG] Still waiting for vminitd... (\(Double(attempt) * 0.02)s elapsed)")
                }
                try await Task.sleep(for: agentConnectionSleepDuration)
                continue
            }
        }
        
        let errorMsg = """
        ❌ Failed to connect to vminitd agent after \(timeoutSeconds)s
        
        Possible causes:
        1. Linux kernel failed to boot (check bootlog if configured)
        2. vminitd binary not starting or crashing
        3. init.block filesystem corrupted or missing vminitd
        4. Vsock communication issue
        
        Troubleshooting steps:
        - Check bootlog file for kernel panic messages
        - Verify init.block contains vminitd and vmexec binaries
        - Try rebuilding vminitd with: ./setup-prerequisites.sh
        - Ensure vmlinux kernel is compatible with your system
        """
        throw ContainerizationError(.invalidArgument, message: errorMsg)
    }
}

extension VZVirtioSocketConnection {
    func dupHandle() throws -> FileHandle {
        let fd = dup(self.fileDescriptor)
        if fd == -1 {
            throw POSIXError.fromErrno()
        }
        self.close()
        return FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    }
}

#endif
