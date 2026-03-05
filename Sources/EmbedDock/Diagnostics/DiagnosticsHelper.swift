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

/// Provides diagnostic utilities for container health checks and debugging.
///
/// This class centralizes crash detection, health probes, diagnostic
/// report generation, and system info collection for troubleshooting.
/// Consolidates functionality from the former DiagnosticService and
/// HealthCheckService into a single source of truth.
final class DiagnosticsHelper: @unchecked Sendable {
    
    // MARK: - Dependencies
    
    private let workDir: URL
    private let logger: Logger
    
    // MARK: - Initialization
    
    init(workDir: URL, logger: Logger) {
        self.workDir = workDir
        self.logger = logger
    }
    
    // MARK: - Crash Detection
    
    /// Check if container process exited immediately after start (crash detection).
    ///
    /// Uses a 1 second timeout - if container exits within 1s, it likely crashed.
    func checkForImmediateCrash(pod: LinuxPod, containerID: String) async -> (crashed: Bool, exitStatus: ExitStatus?) {
        logger.debug("🔍 [DiagnosticsHelper] Checking if container '\(containerID)' exited immediately...")
        
        do {
            let exitStatus = try await pod.waitContainer(containerID, timeoutInSeconds: 1)
            logger.error("❌ [DiagnosticsHelper] Container '\(containerID)' exited immediately!")
            logger.error("❌ [DiagnosticsHelper] \(formatExitStatus(exitStatus))")
            return (crashed: true, exitStatus: exitStatus)
        } catch {
            logger.debug("✅ [DiagnosticsHelper] Container '\(containerID)' is still running")
            return (crashed: false, exitStatus: nil)
        }
    }
    
    // MARK: - Health Checks
    
    /// Test container HTTP response with retry and exponential backoff.
    ///
    /// Test container HTTP response with retry, exponential backoff, and tool fallback.
    ///
    /// Strategy:
    /// 1. Wait for the port to become listening (up to ~10s) so we don't waste HTTP
    ///    attempts while the server is still booting.
    /// 2. Probe with `curl`; if curl is not available fall back to `wget`.
    /// 3. Six retries with increasing delays (total wait ≈ 15s).
    func testHTTPResponseWithRetry(pod: LinuxPod, port: Int, maxRetries: Int = 6) async -> Bool {
        logger.info("🧪 [DiagnosticsHelper] Testing HTTP response on port \(port) with \(maxRetries) retries...")

        // Phase 0: Wait for the port to be listening before wasting HTTP probes.
        let portReady = await waitForPortListening(pod: pod, containerID: "main", port: port, timeout: 10)
        if !portReady {
            logger.warning("⚠️ [DiagnosticsHelper] Port \(port) never started listening — server may not have launched")
            // Fall through and still attempt HTTP probes in case ss/netstat gave a false negative.
        }

        // Phase 1: Detect available HTTP tool (curl preferred, wget fallback).
        let httpTool = await detectHTTPTool(pod: pod)
        logger.info("🔧 [DiagnosticsHelper] Using HTTP tool: \(httpTool.rawValue)")

        // Phase 2: Retry loop with increasing delays.
        //                              0.5s  1s    2s    3s    4s    5s     → total ≈ 15.5s
        let delays: [UInt64] = [500_000_000, 1_000_000_000, 2_000_000_000, 3_000_000_000, 4_000_000_000, 5_000_000_000]

        for attempt in 1...maxRetries {
            if attempt > 1 {
                let delayNs = delays[min(attempt - 1, delays.count - 1)]
                let delayMs = delayNs / UInt64(1_000_000)
                logger.debug("🔄 [DiagnosticsHelper] Retry \(attempt)/\(maxRetries), waiting \(delayMs)ms...")
                try? await Task.sleep(nanoseconds: delayNs)
            }

            let success = await probeHTTP(pod: pod, port: port, tool: httpTool, attempt: attempt)
            if success {
                logger.info("✅ [DiagnosticsHelper] HTTP responding on attempt \(attempt)")
                return true
            }
        }

        logger.warning("⚠️ [DiagnosticsHelper] HTTP not responding after \(maxRetries) attempts")
        return false
    }

    // MARK: - HTTP Tool Detection

    /// HTTP tools we can use for health probes.
    enum HTTPTool: String {
        case curl
        case wget
        case shell // last-resort /dev/tcp probe via bash
    }

    /// Detect which HTTP tool is available inside the container.
    private func detectHTTPTool(pod: LinuxPod) async -> HTTPTool {
        // Try curl
        if await execCheck(pod: pod, args: ["which", "curl"]) { return .curl }
        // Try wget
        if await execCheck(pod: pod, args: ["which", "wget"]) { return .wget }
        // Fall back to bash /dev/tcp
        return .shell
    }

    /// Run a quick command inside the container and return true if exit code == 0.
    private func execCheck(pod: LinuxPod, args: [String]) async -> Bool {
        do {
            let proc = try await pod.execInContainer(
                "main",
                processID: "tool-check-\(UUID().uuidString.prefix(8))",
                configuration: { config in
                    config.arguments = args
                    config.workingDirectory = "/"
                }
            )
            try await proc.start()
            let status = try await proc.wait(timeoutInSeconds: 5)
            return status.exitCode == 0
        } catch {
            return false
        }
    }

    /// Perform a single HTTP probe using the chosen tool.
    private func probeHTTP(pod: LinuxPod, port: Int, tool: HTTPTool, attempt: Int) async -> Bool {
        let probeArgs: [String]
        switch tool {
        case .curl:
            probeArgs = ["curl", "-s", "-m", "3", "-o", "/dev/null", "-w", "%{http_code}", "http://127.0.0.1:\(port)/"]
        case .wget:
            probeArgs = ["wget", "-q", "-O", "/dev/null", "--timeout=3", "--spider", "http://127.0.0.1:\(port)/"]
        case .shell:
            // Bash /dev/tcp probe — only checks connectivity, not HTTP.
            probeArgs = ["bash", "-c", "echo -e \"GET / HTTP/1.0\\r\\n\\r\\n\" > /dev/tcp/127.0.0.1/\(port)"]
        }

        do {
            let proc = try await pod.execInContainer(
                "main",
                processID: "health-check-\(attempt)-\(UUID().uuidString.prefix(8))",
                configuration: { config in
                    config.arguments = probeArgs
                    config.workingDirectory = "/"
                }
            )
            try await proc.start()
            let exitStatus = try await proc.wait(timeoutInSeconds: 5)
            return exitStatus.exitCode == 0
        } catch {
            logger.debug("⚠️ [DiagnosticsHelper] Probe attempt \(attempt) failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Port Listening Wait

    /// Poll until the given port is listening inside the container, or timeout.
    ///
    /// - Parameters:
    ///   - pod: The Linux pod.
    ///   - containerID: The container to check.
    ///   - port: The TCP port.
    ///   - timeout: Maximum seconds to wait.
    /// - Returns: `true` if the port became available before the timeout.
    func waitForPortListening(pod: LinuxPod, containerID: String, port: Int, timeout: Int = 10) async -> Bool {
        let pollInterval: UInt64 = 1_000_000_000 // 1 second
        let maxPolls = timeout

        for poll in 1...maxPolls {
            if await isPortListening(pod: pod, containerID: containerID, port: port) {
                logger.info("✅ [DiagnosticsHelper] Port \(port) is listening (poll \(poll)/\(maxPolls))")
                return true
            }
            logger.debug("⏳ [DiagnosticsHelper] Waiting for port \(port)... (poll \(poll)/\(maxPolls))")
            try? await Task.sleep(nanoseconds: pollInterval)
        }

        logger.warning("⚠️ [DiagnosticsHelper] Port \(port) not listening after \(timeout)s")
        return false
    }
    
    /// Perform a simple health probe via exec.
    func performHealthProbe(pod: LinuxPod, containerID: String) async -> Bool {
        do {
            let healthProcess = try await pod.execInContainer(
                containerID,
                processID: "health-probe-\(UUID().uuidString.prefix(8))",
                configuration: { config in
                    config.arguments = ["echo", "health-check-ok"]
                    config.workingDirectory = "/"
                }
            )
            try await healthProcess.start()
            let exitStatus = try await healthProcess.wait(timeoutInSeconds: 3)
            return exitStatus.exitCode == 0
        } catch {
            return false
        }
    }
    
    /// Check if a port is listening inside the container.
    func isPortListening(pod: LinuxPod, containerID: String, port: Int) async -> Bool {
        do {
            let stdoutCollector = OutputCollector()
            
            let process = try await pod.execInContainer(
                containerID,
                processID: "port-check-\(UUID().uuidString.prefix(8))",
                configuration: { config in
                    config.arguments = [
                        "sh", "-c",
                        "netstat -tlnp 2>/dev/null | grep ':\(port)' || ss -tlnp 2>/dev/null | grep ':\(port)' || echo 'not found'"
                    ]
                    config.workingDirectory = "/"
                    config.stdout = stdoutCollector
                }
            )
            try await process.start()
            let exitStatus = try await process.wait(timeoutInSeconds: 5)
            
            let output = stdoutCollector.getString()
            return exitStatus.exitCode == 0 && !output.contains("not found")
        } catch {
            logger.warning("⚠️ [DiagnosticsHelper] Port check failed: \(error.localizedDescription)")
            return false
        }
    }
    
    // MARK: - Diagnostic Reports
    
    /// Collect a comprehensive diagnostic report.
    ///
    /// - Parameters:
    ///   - pod: The Linux pod to diagnose.
    ///   - phase: The phase where the issue occurred.
    ///   - error: The error that triggered diagnostics.
    /// - Returns: A structured DiagnosticReport.
    func collectDiagnostics(pod: LinuxPod, phase: String, error: Error?) async -> DiagnosticReport {
        logger.error("🔍 [Diagnostics] ========== DIAGNOSTIC REPORT ==========")
        logger.error("🔍 [Diagnostics] Failed Phase: \(phase)")
        
        if let error = error {
            logger.error("🔍 [Diagnostics] Error: \(error.localizedDescription)")
            logger.error("🔍 [Diagnostics] Full Error: \(String(describing: error))")
        }
        
        // Collect system info
        let systemInfo = getSystemInfo()
        for (key, value) in systemInfo.sorted(by: { $0.key < $1.key }) {
            logger.error("🔍 [Diagnostics] System \(key): \(value)")
        }
        
        let containers = await pod.listContainers()
        logger.error("🔍 [Diagnostics] Registered Containers: \(containers.isEmpty ? "NONE" : containers.joined(separator: ", "))")
        
        var statsResult: [(id: String, cpuUsec: UInt64, memoryBytes: UInt64)] = []
        do {
            let stats = try await pod.statistics()
            for stat in stats {
                logger.error("🔍 [Diagnostics] Container '\(stat.id)' - CPU: \(stat.cpu?.usageUsec ?? 0)us, Memory: \(stat.memory?.usageBytes ?? 0) bytes")
                statsResult.append((id: stat.id, cpuUsec: stat.cpu?.usageUsec ?? 0, memoryBytes: stat.memory?.usageBytes ?? 0))
            }
        } catch {
            logger.error("🔍 [Diagnostics] Could not get statistics: \(error.localizedDescription)")
        }
        
        let healthProbeResult = await performHealthProbe(pod: pod, containerID: "main")
        logger.error("🔍 [Diagnostics] Health probe: \(healthProbeResult ? "✅ Responsive" : "❌ Not responding")")
        
        // Use readLogFile() instead of inline file reading
        let bootlogPath = workDir.appendingPathComponent("bootlog.txt").path
        logger.error("🔍 [Diagnostics] Boot log may be at: \(bootlogPath)")
        
        let bootlogTail = readLogFile(name: "bootlog.txt", lastLines: 20)
        if let tail = bootlogTail {
            logger.error("🔍 [Diagnostics] Boot log (last 20 lines):\n\(tail)")
        }
        
        logger.error("🔍 [Diagnostics] ========== END DIAGNOSTIC REPORT ==========")
        
        return DiagnosticReport(
            phase: phase,
            error: error,
            registeredContainers: containers,
            containerStats: statsResult,
            healthProbeResult: healthProbeResult,
            bootlogPath: bootlogPath,
            bootlogTail: bootlogTail,
            systemInfo: systemInfo
        )
    }
    
    /// Print comprehensive diagnostics when container operations fail.
    /// Returns the collected report for storage/display.
    @discardableResult
    func printDiagnostics(pod: LinuxPod, phase: String, error: Error?) async -> DiagnosticReport {
        await collectDiagnostics(pod: pod, phase: phase, error: error)
    }
    
    /// Re-print a previously collected diagnostic report to the log.
    func printReport(_ report: DiagnosticReport) {
        logger.error("🔍 [Diagnostics] ========== CACHED DIAGNOSTIC REPORT ==========")
        logger.error("🔍 [Diagnostics] Phase: \(report.phase)")
        if let error = report.error {
            logger.error("🔍 [Diagnostics] Error: \(error.localizedDescription)")
        }
        for (key, value) in report.systemInfo.sorted(by: { $0.key < $1.key }) {
            logger.error("🔍 [Diagnostics] System \(key): \(value)")
        }
        logger.error("🔍 [Diagnostics] Containers: \(report.registeredContainers.isEmpty ? "NONE" : report.registeredContainers.joined(separator: ", "))")
        for stat in report.containerStats {
            logger.error("🔍 [Diagnostics] Container '\(stat.id)' - CPU: \(stat.cpuUsec)us, Memory: \(stat.memoryBytes) bytes")
        }
        logger.error("🔍 [Diagnostics] Health probe: \(report.healthProbeResult ? "✅ OK" : "❌ Failed")")
        if let tail = report.bootlogTail {
            logger.error("🔍 [Diagnostics] Boot log:\n\(tail)")
        }
        logger.error("🔍 [Diagnostics] Timestamp: \(report.timestamp)")
        logger.error("🔍 [Diagnostics] ========== END CACHED REPORT ==========")
    }
    
    // MARK: - System Information
    
    /// Get system virtualization information.
    func getSystemInfo() -> [String: String] {
        var info: [String: String] = [:]
        
        let processInfo = ProcessInfo.processInfo
        info["macOS"] = processInfo.operatingSystemVersionString
        info["physicalMemory"] = "\(processInfo.physicalMemory / 1024 / 1024 / 1024) GB"
        info["processorCount"] = "\(processInfo.processorCount)"
        info["activeProcessorCount"] = "\(processInfo.activeProcessorCount)"
        info["hostname"] = processInfo.hostName
        
        return info
    }
    
    // MARK: - Log Collection
    
    /// Read the last N lines from a log file in the work directory.
    func readLogFile(name: String, lastLines: Int = 100) -> String? {
        let logPath = workDir.appendingPathComponent(name)
        
        guard FileManager.default.fileExists(atPath: logPath.path) else {
            return nil
        }
        
        do {
            let content = try String(contentsOfFile: logPath.path, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)
            return lines.suffix(lastLines).joined(separator: "\n")
        } catch {
            logger.warning("⚠️ [DiagnosticsHelper] Could not read log file \(name): \(error)")
            return nil
        }
    }
    
    // MARK: - Exit Status Formatting
    
    /// Format exit status for display.
    func formatExitStatus(_ exitStatus: ExitStatus) -> String {
        let exitCode = exitStatus.exitCode
        var result = "Exit code: \(exitCode)"
        
        if exitCode > 128 {
            let signal = exitCode - 128
            let signalName = signalToName(signal)
            result += " (killed by signal \(signal): \(signalName))"
        } else if exitCode == 127 {
            result += " (command not found)"
        } else if exitCode == 126 {
            result += " (permission denied)"
        } else if exitCode == 1 {
            result += " (general error)"
        }
        
        return result
    }
    
    /// Convert signal number to human-readable name.
    private func signalToName(_ signal: Int32) -> String {
        switch signal {
        case 1: return "SIGHUP"
        case 2: return "SIGINT"
        case 3: return "SIGQUIT"
        case 6: return "SIGABRT"
        case 9: return "SIGKILL"
        case 11: return "SIGSEGV"
        case 13: return "SIGPIPE"
        case 14: return "SIGALRM"
        case 15: return "SIGTERM"
        default: return "UNKNOWN"
        }
    }

    // MARK: - Forwarding Chain Health (FM #13)

    /// Result of a forwarding chain health check.
    struct ForwardingChainHealth {
        let hostSocketExists: Bool
        let hostSocketConnectable: Bool
        let guestBridgeHealthy: Bool
        let containerPortListening: Bool

        var overallHealthy: Bool {
            hostSocketExists && hostSocketConnectable && guestBridgeHealthy && containerPortListening
        }

        var summary: String {
            var parts: [String] = []
            parts.append("Host socket: \(hostSocketExists ? "exists" : "MISSING")")
            parts.append("Host connectable: \(hostSocketConnectable ? "yes" : "NO")")
            parts.append("Guest bridge: \(guestBridgeHealthy ? "healthy" : "UNHEALTHY")")
            parts.append("Container port: \(containerPortListening ? "listening" : "NOT LISTENING")")
            return parts.joined(separator: ", ")
        }
    }

    /// Check each segment of the port forwarding chain.
    ///
    /// Tests: host socket file exists, host socket connectable (AF_UNIX),
    /// guest bridge alive, container port listening.
    func checkForwardingChainHealth(
        hostSocketPath: String,
        guestBridge: GuestBridge?,
        guestSocketPath: String,
        pod: LinuxPod?,
        containerPort: Int
    ) async -> ForwardingChainHealth {
        // 1. Host socket file exists
        let hostSocketExists = FileManager.default.fileExists(atPath: hostSocketPath)

        // 2. Host socket is connectable
        var hostSocketConnectable = false
        if hostSocketExists {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            if fd >= 0 {
                var addr = sockaddr_un()
                addr.sun_family = sa_family_t(AF_UNIX)
                withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
                    hostSocketPath.withCString { cstr in
                        _ = strcpy(ptr, cstr)
                    }
                }
                let addrLen = socklen_t(
                    MemoryLayout<sockaddr_un>.offset(of: \.sun_path)! + hostSocketPath.utf8.count + 1
                )
                let result = withUnsafePointer(to: &addr) { addrPtr in
                    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        Foundation.connect(fd, sockaddrPtr, addrLen)
                    }
                }
                hostSocketConnectable = (result == 0)
                close(fd)
            }
        }

        // 3. Guest bridge healthy
        var guestBridgeHealthy = false
        if let bridge = guestBridge {
            guestBridgeHealthy = await bridge.checkBridgeHealth(socketPath: guestSocketPath)
        }

        // 4. Container port listening
        var containerPortListening = false
        if let pod = pod {
            do {
                let process = try await pod.execInContainer(
                    "main",
                    processID: "check-port-\(UUID().uuidString.prefix(8))",
                    configuration: { config in
                        config.arguments = ["sh", "-c", "ss -tln 2>/dev/null | grep -q ':\\(containerPort)' || netstat -tln 2>/dev/null | grep -q ':\\(containerPort)'"]
                        config.workingDirectory = "/"
                    }
                )
                try await process.start()
                let status = try await process.wait(timeoutInSeconds: 5)
                containerPortListening = status.exitCode == 0
            } catch {
                logger.debug("⚠️ [DiagnosticsHelper] Port check failed: \(error)")
            }
        }

        let health = ForwardingChainHealth(
            hostSocketExists: hostSocketExists,
            hostSocketConnectable: hostSocketConnectable,
            guestBridgeHealthy: guestBridgeHealthy,
            containerPortListening: containerPortListening
        )

        logger.info("🏥 [DiagnosticsHelper] Forwarding chain health: \(health.summary)")
        return health
    }
}

// MARK: - Diagnostic Report

/// A comprehensive diagnostic report for container issues.
public struct DiagnosticReport: Sendable {
    public let phase: String
    public let error: Error?
    public let registeredContainers: [String]
    public let containerStats: [(id: String, cpuUsec: UInt64, memoryBytes: UInt64)]
    public let healthProbeResult: Bool
    public let bootlogPath: String?
    public let bootlogTail: String?
    public let systemInfo: [String: String]
    public let timestamp: Date
    
    public init(
        phase: String,
        error: Error?,
        registeredContainers: [String],
        containerStats: [(id: String, cpuUsec: UInt64, memoryBytes: UInt64)],
        healthProbeResult: Bool,
        bootlogPath: String?,
        bootlogTail: String?,
        systemInfo: [String: String] = [:],
        timestamp: Date = Date()
    ) {
        self.phase = phase
        self.error = error
        self.registeredContainers = registeredContainers
        self.containerStats = containerStats
        self.healthProbeResult = healthProbeResult
        self.bootlogPath = bootlogPath
        self.bootlogTail = bootlogTail
        self.systemInfo = systemInfo
        self.timestamp = timestamp
    }
}
