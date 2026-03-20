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

// MARK: - Bridge Tool

/// Bridge tools that can create a TCP-to-Unix-socket proxy inside the container.
/// Ordered by preference: most reliable first.
private enum BridgeTool: String, CaseIterable {
    case socat
    case python3
    case python
    case node
    case busyboxNc

    /// Shell command to check if this tool exists inside the container.
    var detectCommand: [String] {
        switch self {
        case .socat:
            return ["which", "socat"]
        case .python3:
            return ["which", "python3"]
        case .python:
            return ["which", "python"]
        case .node:
            return ["which", "node"]
        case .busyboxNc:
            return ["sh", "-c", "which nc 2>/dev/null && nc --help 2>&1 | grep -qi busybox"]
        }
    }

    /// The command to launch a TCP-to-Unix-socket bridge in the foreground.
    /// The caller is responsible for running this in the background (via exec without waiting).
    func bridgeCommand(socketPath: String, tcpPort: UInt16) -> [String] {
        switch self {
        case .socat:
            return [
                "socat",
                "UNIX-LISTEN:\(socketPath),fork,unlink-early,mode=777",
                "TCP:127.0.0.1:\(tcpPort)"
            ]
        case .python3:
            return ["python3", "-c", Self.pythonBridgeScript(socketPath: socketPath, tcpPort: tcpPort)]
        case .python:
            return ["python", "-c", Self.pythonBridgeScript(socketPath: socketPath, tcpPort: tcpPort)]
        case .node:
            return ["node", "-e", Self.nodeBridgeScript(socketPath: socketPath, tcpPort: tcpPort)]
        case .busyboxNc:
            return [
                "sh", "-c",
                "rm -f \(socketPath) && mkfifo /tmp/.bridge-fifo-\(tcpPort) 2>/dev/null; "
                    + "while true; do nc -lU \(socketPath) < /tmp/.bridge-fifo-\(tcpPort) "
                    + "| nc 127.0.0.1 \(tcpPort) > /tmp/.bridge-fifo-\(tcpPort); done"
            ]
        }
    }

    // MARK: - Bridge Scripts

    private static func pythonBridgeScript(socketPath: String, tcpPort: UInt16) -> String {
        // Compact Python script: Unix socket server that relays each connection to TCP.
        """
        import socket,os,threading
        p='\(socketPath)'
        try:os.unlink(p)
        except:pass
        s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
        s.bind(p)
        os.chmod(p,0o777)
        s.listen(128)
        def relay(a,b):
         try:
          while True:
           d=a.recv(65536)
           if not d:break
           b.sendall(d)
         except:pass
         finally:
          try:a.close()
          except:pass
          try:b.close()
          except:pass
        while True:
         c,_=s.accept()
         t=socket.socket(socket.AF_INET,socket.SOCK_STREAM)
         try:
          t.connect(('127.0.0.1',\(tcpPort)))
          threading.Thread(target=relay,args=(c,t),daemon=True).start()
          threading.Thread(target=relay,args=(t,c),daemon=True).start()
         except:
          c.close()
          t.close()
        """
    }

    private static func nodeBridgeScript(socketPath: String, tcpPort: UInt16) -> String {
        """
        const net=require('net'),fs=require('fs');try{fs.unlinkSync('\(socketPath)')}catch{}net.createServer(c=>{const t=net.connect(\(tcpPort),'127.0.0.1',()=>{c.pipe(t);t.pipe(c)});t.on('error',()=>c.destroy());c.on('error',()=>t.destroy())}).listen('\(socketPath)',()=>{try{fs.chmodSync('\(socketPath)',0o777)}catch{}});
        """
    }
}

// MARK: - Guest Bridge

/// Manages the guest-side bridge for forwarding connections to services
/// inside the container.
///
/// In direct mode, the bridge orchestrates a TCP-to-Unix-socket proxy
/// inside the container so that standard TCP-listening applications work
/// transparently with the framework's `relayUnixSocket` API.
///
/// If the container app already creates the Unix socket natively (by
/// reading the `UNIX_SOCKET` environment variable), the bridge detects
/// this and skips proxy setup entirely.
///
/// Architecture:
/// ```
/// Host (macOS)                       Guest (Linux Container)
/// ─────────────                      ─────────────────────────
/// relayUnixSocket → vminitd  ──────► [Bridge proxy on /tmp/bridge.sock]
///                                           ↓
///                                    [Container app on TCP port]
/// ```
actor GuestBridge {
    private let pod: LinuxPod
    private let logger: Logger
    private var isRunning = false

    /// The processID of the background bridge process, for tracking.
    private var bridgeProcessID: String?

    init(pod: LinuxPod, logger: Logger) {
        self.pod = pod
        self.logger = logger
    }

    /// Whether the bridge is currently active.
    var isBridgeRunning: Bool {
        isRunning
    }

    // MARK: - Direct Mode Setup

    /// Set up the guest-side bridge for port forwarding.
    ///
    /// Orchestrates the TCP-to-Unix-socket bridge inside the container:
    /// 1. Check if the app already created the Unix socket (UNIX_SOCKET-aware apps)
    /// 2. Wait for the container's TCP port to be listening
    /// 3. Detect available bridging tools (socat, python3, python, node, nc)
    /// 4. Launch a background bridge process
    /// 5. Poll until the Unix socket appears
    ///
    /// - Parameters:
    ///   - socketPath: The Unix socket path inside the container.
    ///   - containerPort: The TCP port the container app listens on.
    ///   - pollTimeout: Maximum time for the entire bridge setup.
    func startDirectMode(
        socketPath: String,
        containerPort: UInt16,
        pollTimeout: Duration = .seconds(30)
    ) async throws {
        guard !isRunning else {
            logger.warning("[GuestBridge] Bridge already running")
            return
        }

        logger.info("[GuestBridge] Direct mode: setting up bridge for port \(containerPort) -> \(socketPath)")

        // Phase 0: Quick check — maybe the app already created the socket
        if await checkSocketExists(socketPath: socketPath) {
            logger.info("[GuestBridge] App already created \(socketPath) — no bridge needed")
            isRunning = true
            return
        }

        let deadline = ContinuousClock.now + pollTimeout

        // Phase 1: Wait for TCP port to be listening inside the container
        logger.info("[GuestBridge] Phase 1: Waiting for container TCP port \(containerPort)...")
        try await waitForTcpPort(port: containerPort, deadline: deadline)

        // Phase 2: Detect available bridge tool
        logger.info("[GuestBridge] Phase 2: Detecting bridge tools...")
        let tool = try await detectBridgeTool(deadline: deadline)
        logger.info("[GuestBridge] Using bridge tool: \(tool.rawValue)")

        // Phase 3: Launch bridge process in background
        logger.info("[GuestBridge] Phase 3: Launching \(tool.rawValue) bridge...")
        if tool == .busyboxNc {
            logger.warning("[GuestBridge] busybox nc only handles one connection at a time. Consider installing socat for better performance.")
        }
        try await launchBridgeProcess(tool: tool, socketPath: socketPath, containerPort: containerPort)

        // Phase 4: Poll for Unix socket creation
        logger.info("[GuestBridge] Phase 4: Waiting for Unix socket \(socketPath)...")
        try await pollForSocket(socketPath: socketPath, deadline: deadline)

        isRunning = true
        logger.info("[GuestBridge] Direct mode active via \(tool.rawValue) bridge")
    }

    // MARK: - Lifecycle

    /// Stop the bridge (resets state).
    func stopBridge() async {
        guard isRunning else { return }
        bridgeProcessID = nil
        isRunning = false
        logger.info("[GuestBridge] Bridge stopped")
    }

    // MARK: - Health Check

    /// Check if the Unix socket still exists inside the container.
    func checkBridgeHealth(socketPath: String) async -> Bool {
        guard isRunning else { return false }

        return await checkSocketExists(socketPath: socketPath)
    }

    // MARK: - Phase 1: TCP Port Waiting

    /// Poll until the container's TCP port is listening, or the deadline is reached.
    private func waitForTcpPort(port: UInt16, deadline: ContinuousClock.Instant) async throws {
        while ContinuousClock.now < deadline {
            if await checkPortListening(port: port) {
                logger.info("[GuestBridge] TCP port \(port) is listening")
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw ContainerizationError(
            .timeout,
            message: "Container TCP port \(port) did not start listening within the timeout. "
                + "The container application may have failed to start."
        )
    }

    /// Single check: is the given TCP port listening inside the container?
    private func checkPortListening(port: UInt16) async -> Bool {
        do {
            let process = try await pod.execInContainer(
                "main",
                processID: "port-check-\(UUID().uuidString.prefix(8))",
                configuration: { config in
                    config.arguments = [
                        "sh", "-c",
                        "ss -tln 2>/dev/null | grep -q ':\(port)' || "
                            + "netstat -tln 2>/dev/null | grep -q ':\(port)'"
                    ]
                    config.workingDirectory = "/"
                }
            )
            try await process.start()
            let status = try await process.wait(timeoutInSeconds: 5)
            return status.exitCode == 0
        } catch {
            return false
        }
    }

    // MARK: - Phase 2: Tool Detection

    /// Detect which bridging tool is available inside the container.
    private func detectBridgeTool(deadline: ContinuousClock.Instant) async throws -> BridgeTool {
        for tool in BridgeTool.allCases {
            guard ContinuousClock.now < deadline else { break }

            do {
                let process = try await pod.execInContainer(
                    "main",
                    processID: "tool-\(tool.rawValue)-\(UUID().uuidString.prefix(8))",
                    configuration: { config in
                        config.arguments = tool.detectCommand
                        config.workingDirectory = "/"
                    }
                )
                try await process.start()
                let status = try await process.wait(timeoutInSeconds: 3)
                if status.exitCode == 0 {
                    return tool
                }
            } catch {
                // Tool not found, try next
            }
        }

        throw ContainerizationError(
            .notFound,
            message: "No bridge tool found inside the container. "
                + "Checked: \(BridgeTool.allCases.map(\.rawValue).joined(separator: ", ")). "
                + "Install at least one (e.g., 'apk add socat' or 'apt-get install socat') in your container image."
        )
    }

    // MARK: - Phase 3: Bridge Process Launch

    /// Launch the bridge process as a background exec inside the container.
    private func launchBridgeProcess(
        tool: BridgeTool,
        socketPath: String,
        containerPort: UInt16
    ) async throws {
        let processID = "bridge-\(tool.rawValue)-\(UUID().uuidString.prefix(8))"
        let args = tool.bridgeCommand(socketPath: socketPath, tcpPort: containerPort)

        let process = try await pod.execInContainer(
            "main",
            processID: processID,
            configuration: { config in
                config.arguments = args
                config.workingDirectory = "/"
            }
        )
        try await process.start()
        bridgeProcessID = processID

        // Give the bridge a moment to start and potentially fail fast
        try await Task.sleep(for: .milliseconds(500))

        // Check for immediate failure (command not found, permission error, etc.)
        // We do NOT await the full process — it should run forever.
        // If wait() times out, the process is still running — that's the success case.
        var exitedImmediately = false
        var exitCode: Int32 = 0

        do {
            let status = try await process.wait(timeoutInSeconds: 1)
            exitedImmediately = true
            exitCode = status.exitCode
        } catch {
            // Timeout means the process is still running — good!
            logger.debug("[GuestBridge] Bridge process \(processID) is running")
        }

        if exitedImmediately {
            throw ContainerizationError(
                .internalError,
                message: "Bridge process (\(tool.rawValue)) exited immediately with code \(exitCode). "
                    + "The bridge tool may not support the required options."
            )
        }
    }

    // MARK: - Phase 4: Socket Polling

    /// Poll until the Unix socket file appears inside the container.
    private func pollForSocket(socketPath: String, deadline: ContinuousClock.Instant) async throws {
        while ContinuousClock.now < deadline {
            if await checkSocketExists(socketPath: socketPath) {
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw ContainerizationError(
            .timeout,
            message: "Bridge process started but Unix socket \(socketPath) was not created within the timeout. "
                + "The bridge tool may have failed silently."
        )
    }

    // MARK: - Helpers

    /// Check if a Unix socket exists at the given path inside the container.
    private func checkSocketExists(socketPath: String) async -> Bool {
        do {
            let process = try await pod.execInContainer(
                "main",
                processID: "check-sock-\(UUID().uuidString.prefix(8))",
                configuration: { config in
                    config.arguments = ["sh", "-c", "test -S \(socketPath)"]
                    config.workingDirectory = "/"
                }
            )
            try await process.start()
            let status = try await process.wait(timeoutInSeconds: 3)
            return status.exitCode == 0
        } catch {
            return false
        }
    }
}
