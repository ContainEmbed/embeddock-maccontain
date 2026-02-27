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
import Logging

// MARK: - Stale Cleanup Report

/// Summary of what StaleResourceCleaner found and removed.
public struct StaleCleanupReport: CustomStringConvertible, Sendable {
    public let foundStaleManifest: Bool
    public let stalePIDKilled: Bool
    public let socketFilesRemoved: [String]
    public let bootlogFilesRemoved: [String]
    public let portWasBlocked: Bool

    public var description: String {
        var parts: [String] = []
        if stalePIDKilled { parts.append("killed stale PID") }
        if !socketFilesRemoved.isEmpty { parts.append("removed \(socketFilesRemoved.count) socket file(s)") }
        if !bootlogFilesRemoved.isEmpty { parts.append("removed \(bootlogFilesRemoved.count) bootlog(s)") }
        if portWasBlocked { parts.append("port still in use") }
        return parts.isEmpty ? "nothing to clean" : parts.joined(separator: ", ")
    }
}

// MARK: - Stale Resource Cleaner

/// Inspects the on-disk run manifest written by a previous app process and removes
/// any resources it left behind.
///
/// Called once, early in `DefaultContainerEngine.initialize()`, so that stale sockets
/// and occupied ports are freed **before** any new container startup is attempted.
///
/// ## Resources cleaned
/// - Previous process (SIGTERM → wait → SIGKILL)
/// - Host Unix socket files (`/tmp/embeddock-bridge-*.sock`) — full glob sweep plus
///   manifest-listed paths
/// - Bootlog files (keeps the 2 most-recent for diagnostics)
/// - Port occupancy check (logs a warning — the OS will release TIME_WAIT sockets
///   on its own, but an explicit warning helps the user diagnose failures)
public struct StaleResourceCleaner: Sendable {

    private let logger: Logger

    public init(logger: Logger) {
        self.logger = logger
    }

    // MARK: - Entry Point

    /// Inspect the manifest and clean any stale resources.
    ///
    /// - Returns: A report of what was found and cleaned.
    public func cleanIfNeeded() async -> StaleCleanupReport {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let manifestURL = home.appendingPathComponent(".embeddock/run-manifest.json")

        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            logger.debug("🧹 [StaleResourceCleaner] No stale manifest found — nothing to clean")
            return StaleCleanupReport(
                foundStaleManifest: false,
                stalePIDKilled: false,
                socketFilesRemoved: [],
                bootlogFilesRemoved: [],
                portWasBlocked: false
            )
        }

        logger.info("🧹 [StaleResourceCleaner] Stale manifest found at \(manifestURL.path) — cleaning up")

        // Decode manifest (delete and bail if corrupt)
        guard let entry = decodeManifest(at: manifestURL) else {
            try? FileManager.default.removeItem(at: manifestURL)
            logger.warning("⚠️ [StaleResourceCleaner] Manifest was corrupt — deleted")
            return StaleCleanupReport(
                foundStaleManifest: true,
                stalePIDKilled: false,
                socketFilesRemoved: [],
                bootlogFilesRemoved: [],
                portWasBlocked: false
            )
        }

        // Skip manifest that belongs to the current process (shouldn't happen, but be safe)
        let currentPID = ProcessInfo.processInfo.processIdentifier
        if entry.pid == currentPID {
            try? FileManager.default.removeItem(at: manifestURL)
            logger.debug("🧹 [StaleResourceCleaner] Manifest belongs to current process — cleared")
            return StaleCleanupReport(
                foundStaleManifest: false,
                stalePIDKilled: false,
                socketFilesRemoved: [],
                bootlogFilesRemoved: [],
                portWasBlocked: false
            )
        }

        // Phase 1: Terminate stale process
        let pidKilled = await terminateStalePID(entry.pid)

        // Phase 2: Remove socket files (manifest-listed + full glob sweep)
        let socketsRemoved = removeSocketFiles(manifestPaths: entry.socketPaths)

        // Phase 3: Prune bootlog files — keep only 2 most-recent
        let bootlogsRemoved = pruneBootlogs(manifestPaths: entry.bootlogPaths)

        // Phase 4: Check port occupancy (informational)
        let portBlocked = checkPort(entry.hostPort)

        // Delete manifest file
        try? FileManager.default.removeItem(at: manifestURL)

        let report = StaleCleanupReport(
            foundStaleManifest: true,
            stalePIDKilled: pidKilled,
            socketFilesRemoved: socketsRemoved,
            bootlogFilesRemoved: bootlogsRemoved,
            portWasBlocked: portBlocked
        )
        logger.info("✅ [StaleResourceCleaner] Cleanup complete: \(report)")
        return report
    }

    // MARK: - Phase 1: Kill Stale PID

    private func terminateStalePID(_ pid: Int32) async -> Bool {
        // kill(pid, 0) → checks existence without sending a signal
        guard kill(pid, 0) == 0 else {
            let code = errno
            if code == ESRCH {
                logger.info("🧹 [StaleResourceCleaner] Stale PID \(pid) is no longer running")
            } else {
                logger.warning("⚠️ [StaleResourceCleaner] Cannot probe PID \(pid) (errno \(code))")
            }
            return false
        }

        logger.warning("⚠️ [StaleResourceCleaner] Stale process PID \(pid) is still alive — sending SIGTERM")
        kill(pid, SIGTERM)

        // Wait up to 3 seconds for graceful exit
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
            if kill(pid, 0) != 0 {
                logger.info("✅ [StaleResourceCleaner] PID \(pid) exited after SIGTERM")
                return true
            }
        }

        // Force-kill if still alive
        if kill(pid, 0) == 0 {
            logger.warning("⚠️ [StaleResourceCleaner] PID \(pid) did not exit — sending SIGKILL")
            kill(pid, SIGKILL)
            try? await Task.sleep(for: .milliseconds(500))
        }

        let gone = kill(pid, 0) != 0
        logger.info(gone
            ? "✅ [StaleResourceCleaner] PID \(pid) terminated via SIGKILL"
            : "⚠️ [StaleResourceCleaner] PID \(pid) may still be running after SIGKILL"
        )
        return gone
    }

    // MARK: - Phase 2: Remove Socket Files

    private func removeSocketFiles(manifestPaths: [String]) -> [String] {
        var removed: [String] = []

        // Collect all targets: manifest-listed + glob sweep of /tmp
        var targets = Set(manifestPaths)
        let tmpDir = NSTemporaryDirectory()
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: tmpDir) {
            for name in entries where name.hasPrefix("embeddock-bridge-") && name.hasSuffix(".sock") {
                targets.insert(tmpDir + name)
            }
        }

        for path in targets {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            do {
                try FileManager.default.removeItem(atPath: path)
                removed.append(path)
                logger.info("🧹 [StaleResourceCleaner] Removed socket: \(path)")
            } catch {
                logger.warning("⚠️ [StaleResourceCleaner] Could not remove socket \(path): \(error.localizedDescription)")
            }
        }
        return removed
    }

    // MARK: - Phase 3: Prune Bootlogs

    private func pruneBootlogs(manifestPaths: [String]) -> [String] {
        var removed: [String] = []
        let tmpDir = NSTemporaryDirectory()

        // Also gather any bootlog-*.txt files from /tmp not in manifest
        var allBootlogs = Set(manifestPaths)
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: tmpDir) {
            for name in entries where name.hasPrefix("bootlog-") && name.hasSuffix(".txt") {
                allBootlogs.insert(tmpDir + name)
            }
        }

        // Sort by modification date descending to keep 2 most-recent
        let sorted = allBootlogs
            .compactMap { path -> (String, Date)? in
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                      let mod = attrs[.modificationDate] as? Date else { return nil }
                return (path, mod)
            }
            .sorted { $0.1 > $1.1 }  // newest first

        // Keep at most 2 most-recent bootlogs for diagnostics; delete the rest
        let toDelete = sorted.dropFirst(2)
        for (path, _) in toDelete {
            do {
                try FileManager.default.removeItem(atPath: path)
                removed.append(path)
                logger.info("🧹 [StaleResourceCleaner] Removed bootlog: \(path)")
            } catch {
                logger.warning("⚠️ [StaleResourceCleaner] Could not remove bootlog \(path): \(error.localizedDescription)")
            }
        }
        return removed
    }

    // MARK: - Phase 4: Port Check

    /// Attempts a non-blocking bind on the previously used port to detect TIME_WAIT.
    /// Returns `true` if the port appears to be in use (log a warning; the OS will clear it).
    private func checkPort(_ port: Int?) -> Bool {
        guard let port, port > 0 else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if result == 0 {
            logger.debug("🧹 [StaleResourceCleaner] Port \(port) is free")
            return false
        } else {
            logger.warning("⚠️ [StaleResourceCleaner] Port \(port) is still in use (TIME_WAIT or other process). It will be released by the OS shortly.")
            return true
        }
    }

    // MARK: - Helpers

    private func decodeManifest(at url: URL) -> ManifestEntry? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ManifestEntry.self, from: data)
    }
}
