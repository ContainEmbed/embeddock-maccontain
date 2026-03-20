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

// MARK: - Manifest Entry

/// Snapshot of all live resources owned by this process.
///
/// Written atomically to disk so that a subsequent app launch can discover and clean
/// up anything that survived a crash or force-kill.
public struct ManifestEntry: Codable, Sendable {
    /// PID of the process that created this manifest.
    public var pid: Int32
    /// Host-side Unix socket files created by TcpPortForwarder.
    public var socketPaths: [String]
    /// TCP port bound on the host by NWListener.
    public var hostPort: Int?
    /// Identifier of the active LinuxPod.
    public var podID: String?
    /// Paths to bootlog files created for diagnostic purposes.
    public var bootlogPaths: [String]
    /// ISO-8601 timestamp of the last write.
    public var timestamp: Date

    public init(pid: Int32) {
        self.pid = pid
        self.socketPaths = []
        self.hostPort = nil
        self.podID = nil
        self.bootlogPaths = []
        self.timestamp = Date()
    }
}

// MARK: - Run Manifest Actor

/// In-memory registry of all live container resources, persisted atomically to disk.
///
/// ## Lifecycle
/// - `initialize()` must be called once from `DefaultContainerEngine.initialize()`.
///   It writes a seed manifest containing only the current PID so that even a crash
///   before any container is started leaves a manifest for the next launch to clean up.
/// - Every `record(...)` call updates the in-memory state **and** flushes to disk.
/// - `clear()` is called on a clean shutdown; it nils the in-memory entry and deletes
///   the manifest file, signalling to the next launch that no cleanup is needed.
///
/// ## Thread Safety
/// This is a Swift `actor`; all mutations are serialised automatically.
public actor RunManifest {

    // MARK: - Shared Instance

    /// Singleton shared across the process.  Inject via `RunManifest.shared`.
    public static let shared = RunManifest()

    // MARK: - State

    /// In-memory cache — read without touching disk.
    private(set) public var current: ManifestEntry?

    /// Path to the on-disk manifest file.
    private let manifestURL: URL

    // MARK: - Init

    private init() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let dir = home.appendingPathComponent(".embeddock")
        self.manifestURL = dir.appendingPathComponent("run-manifest.json")
    }

    // MARK: - Setup

    /// Bootstrap the manifest with a seed entry containing the current PID.
    ///
    /// Creates `~/.embeddock/` if it does not already exist.
    /// Fails silently if the directory cannot be created (permission denied in unusual
    /// sandbox configurations) — the feature degrades gracefully.
    public func initialize(logger: Logger) {
        let dir = manifestURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            logger.warning("⚠️ [RunManifest] Cannot create ~/.embeddock directory: \(error.localizedDescription). Manifest disabled.")
            return
        }
        var entry = ManifestEntry(pid: ProcessInfo.processInfo.processIdentifier)
        entry.timestamp = Date()
        current = entry
        persist(logger: logger)
        logger.info("📋 [RunManifest] Manifest initialised (PID \(entry.pid)) at \(manifestURL.path)")
    }

    // MARK: - Recording Resource Handles

    /// Record a host-side Unix socket file path.
    public func record(socketPath: String, logger: Logger) {
        guard current != nil else { return }
        if !current!.socketPaths.contains(socketPath) {
            current!.socketPaths.append(socketPath)
        }
        current!.timestamp = Date()
        persist(logger: logger)
        logger.debug("📋 [RunManifest] Recorded socket: \(socketPath)")
    }

    /// Record the TCP port bound on the host.
    public func record(port: Int, logger: Logger) {
        guard current != nil else { return }
        current!.hostPort = port
        current!.timestamp = Date()
        persist(logger: logger)
        logger.debug("📋 [RunManifest] Recorded port: \(port)")
    }

    /// Record the active pod identifier.
    public func record(podID: String, logger: Logger) {
        guard current != nil else { return }
        current!.podID = podID
        current!.timestamp = Date()
        persist(logger: logger)
        logger.debug("📋 [RunManifest] Recorded podID: \(podID)")
    }

    /// Record a bootlog file path.
    public func record(bootlogPath: String, logger: Logger) {
        guard current != nil else { return }
        if !current!.bootlogPaths.contains(bootlogPath) {
            current!.bootlogPaths.append(bootlogPath)
        }
        current!.timestamp = Date()
        persist(logger: logger)
        logger.debug("📋 [RunManifest] Recorded bootlog: \(bootlogPath)")
    }

    // MARK: - Clean Shutdown

    /// Remove the manifest, indicating a clean shutdown with no dangling resources.
    ///
    /// Called at the end of `DefaultContainerEngine.stop()` after all resources have
    /// been successfully released.
    public func clear(logger: Logger) {
        current = nil
        try? FileManager.default.removeItem(at: manifestURL)
        logger.info("📋 [RunManifest] Manifest cleared (clean shutdown)")
    }

    // MARK: - Private Persistence

    /// Write the current entry to disk atomically via a temp-file + rename.
    private func persist(logger: Logger) {
        guard let entry = current else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(entry)

            // Write to a temp file first, then rename for atomicity.
            let tmp = manifestURL.appendingPathExtension("tmp")
            try data.write(to: tmp)
            _ = try FileManager.default.replaceItemAt(manifestURL, withItemAt: tmp)
        } catch {
            logger.warning("⚠️ [RunManifest] Failed to persist manifest: \(error.localizedDescription)")
        }
    }
}
