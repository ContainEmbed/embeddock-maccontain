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
import ContainerizationEXT4
import ContainerizationOS
import ContainerizationError
import Logging
import SystemPackage

/// Generates the init.block EXT4 filesystem image from bundled pre-init, vminitd, and vmexec binaries.
///
/// The init.block serves as the root filesystem for the Linux VM. It contains:
/// - `/init`           — pre-init shim (PID 1): mounts /proc, /sys, /dev then exec's vminitd
/// - `/sbin/vminitd`   — guest init system (exec'd by pre-init)
/// - `/sbin/vmexec`     — guest exec helper (must be at /sbin/vmexec — hardcoded in vminitd)
/// - Mount-point directories required by vminitd's `standardSetup()`:
///   `/sys`, `/tmp`, `/dev`, `/dev/pts`, `/proc`, `/run`, `/run/container`, `/etc`
///
/// The pre-init shim is required because vminitd is a Swift binary whose runtime
/// needs `/proc/self/exe` to be readable. As PID 1, `/proc` is not yet mounted,
/// so pre-init mounts it first before exec'ing vminitd.
///
/// The EXT4 image is created using `EXT4.Formatter`, which produces the same
/// minimal feature set expected by the VM kernel (sparse_super2, extents,
/// flex_bg, inline_data — no journal, no metadata_csum, no 64bit).
struct InitBlockGenerator {
    private let prerequisiteChecker: PrerequisiteChecker
    private let logger: Logger

    /// Image size in bytes (600 MiB). Must exceed vminitd (~255 MB) + vmexec (~257 MB) + overhead.
    private static let imageSizeBytes: UInt64 = 600.mib()

    init(prerequisiteChecker: PrerequisiteChecker, logger: Logger) {
        self.prerequisiteChecker = prerequisiteChecker
        self.logger = logger
    }

    /// Generate the init.block EXT4 filesystem at the given path.
    ///
    /// - Parameter outputPath: Destination URL for the init.block file.
    /// - Throws: `ContainerizationError` if bundled binaries are not found or EXT4 creation fails.
    func generateInitBlock(at outputPath: URL) throws {
        logger.info("🔨 [InitBlockGenerator] Generating init.block at: \(outputPath.path)")

        // Resolve bundled binaries
        let preInitURL = try prerequisiteChecker.getPreInitPath()
        let vminitdURL = try prerequisiteChecker.getVminitdPath()
        let vmexecURL = try prerequisiteChecker.getVmexecPath()
        logger.info("📦 [InitBlockGenerator] pre-init: \(preInitURL.path)")
        logger.info("📦 [InitBlockGenerator] vminitd: \(vminitdURL.path)")
        logger.info("📦 [InitBlockGenerator] vmexec: \(vmexecURL.path)")

        // Create EXT4 filesystem
        let formatter = try EXT4.Formatter(
            FilePath(outputPath.path),
            minDiskSize: Self.imageSizeBytes
        )

        do {
            // Create directory structure for mount points
            let directories: [(String, UInt16)] = [
                ("/sbin",          0o755),
                ("/sys",           0o755),
                ("/tmp",           0o1777),
                ("/dev",           0o755),
                ("/dev/pts",       0o755),
                ("/proc",          0o555),
                ("/run",           0o755),
                ("/run/container", 0o755),
                ("/etc",           0o755),
            ]

            for (path, permissions) in directories {
                logger.debug("📁 [InitBlockGenerator] Creating directory: \(path)")
                try formatter.create(
                    path: FilePath(path),
                    mode: EXT4.Inode.Mode(.S_IFDIR, permissions),
                    uid: 0,
                    gid: 0
                )
            }

            // Write pre-init shim (PID 1 bootstrap — mounts /proc, /sys, /dev then exec's vminitd)
            logger.info("📝 [InitBlockGenerator] Writing /init (pre-init shim)...")
            try writeBinary(formatter: formatter, sourceURL: preInitURL, destPath: "/init")

            // Write vminitd binary
            logger.info("📝 [InitBlockGenerator] Writing /sbin/vminitd...")
            try writeBinary(formatter: formatter, sourceURL: vminitdURL, destPath: "/sbin/vminitd")

            // Write vmexec binary (must be at /sbin/vmexec — path is hardcoded in vminitd)
            logger.info("📝 [InitBlockGenerator] Writing /sbin/vmexec...")
            try writeBinary(formatter: formatter, sourceURL: vmexecURL, destPath: "/sbin/vmexec")

            // Finalize the EXT4 filesystem
            try formatter.close()
            logger.info("✅ [InitBlockGenerator] init.block created successfully")

            // Log final size
            if let attrs = try? FileManager.default.attributesOfItem(atPath: outputPath.path),
               let size = attrs[.size] as? Int64 {
                logger.info("📊 [InitBlockGenerator] init.block size: \(size / 1024 / 1024) MB")
            }
        } catch {
            // Clean up partial file on failure
            try? FileManager.default.removeItem(at: outputPath)
            try? formatter.close()
            logger.error("❌ [InitBlockGenerator] Failed to generate init.block: \(error.localizedDescription)")
            throw ContainerizationError(
                .internalError,
                message: "Failed to generate init.block: \(error.localizedDescription)"
            )
        }
    }

    /// Write a binary file into the EXT4 filesystem.
    private func writeBinary(formatter: EXT4.Formatter, sourceURL: URL, destPath: String) throws {
        guard let inputStream = InputStream(url: sourceURL) else {
            throw ContainerizationError(
                .notFound,
                message: "Cannot open binary at \(sourceURL.path)"
            )
        }
        inputStream.open()
        defer { inputStream.close() }

        try formatter.create(
            path: FilePath(destPath),
            mode: EXT4.Inode.Mode(.S_IFREG, 0o755),
            buf: inputStream,
            uid: 0,
            gid: 0
        )
    }
}
