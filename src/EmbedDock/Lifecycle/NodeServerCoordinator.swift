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
import ContainerizationOCI
import ContainerizationEXT4
import ContainerizationExtras
import ContainerizationError
import Logging
import NIO

/// Coordinates the multi-step Node.js container startup process.
///
/// Mirrors `StartupCoordinator` but handles the pull-from-registry → Node.js
/// workflow instead of the load-from-OCI-tar workflow. Delegates to extracted
/// modules (ImageService, PodFactory, DiagnosticsHelper) for each step.
@MainActor
final class NodeServerCoordinator {

    // MARK: - Dependencies (Injected)

    private let imageService: ImageService
    private let podFactory: PodFactory
    private let imageStore: ImageStore
    private let diagnosticsHelper: DiagnosticsHelper
    private let workDir: URL
    private let logger: Logger

    /// Progress callback for UI updates.
    var onProgress: ((String) -> Void)?

    // MARK: - Initialization

    init(
        imageService: ImageService,
        podFactory: PodFactory,
        imageStore: ImageStore,
        diagnosticsHelper: DiagnosticsHelper,
        workDir: URL,
        logger: Logger
    ) {
        self.imageService = imageService
        self.podFactory = podFactory
        self.imageStore = imageStore
        self.diagnosticsHelper = diagnosticsHelper
        self.workDir = workDir
        self.logger = logger
    }

    // MARK: - Public API

    /// Start a Node.js container by pulling an image and mounting a JS file.
    ///
    /// - Parameters:
    ///   - jsFile: Local path to the JavaScript entry-point file.
    ///   - imageName: OCI image reference to pull (e.g. "docker.io/library/node:20").
    ///   - port: Port the Node.js server listens on.
    /// - Returns: The started LinuxPod instance.
    func start(jsFile: URL, imageName: String, port: Int) async throws -> LinuxPod {
        logger.info("🚀 [NodeServerCoordinator] Starting Node.js server from: \(imageName)")
        let platform = Platform(arch: "arm64", os: "linux", variant: "v8")

        // Step 1: Pull container image
        updateProgress("Step 1/10: Pulling container image: \(imageName)...")
        let image = try await imageService.pullImage(reference: imageName)

        // Step 2-3: Unpack rootfs
        updateProgress("Step 2/10: Unpacking container image...")
        let rootfsURL = try await imageService.prepareRootfs(from: image, platform: platform)
        let rootfs = podFactory.createRootfsMount(from: rootfsURL)

        // Step 4: Prepare init filesystem
        updateProgress("Step 4/10: Preparing init filesystem...")
        let initfs = try await podFactory.prepareInitFilesystem(imageStore: imageStore)

        // Step 5-7: Create pod
        updateProgress("Step 5/10: Loading Linux kernel...")
        updateProgress("Step 6/10: Starting virtual machine...")
        updateProgress("Step 7/10: Creating container pod...")
        let podID = "nodejs-server-\(UUID().uuidString.prefix(8))"
        let pod = try await podFactory.createPod(podID: podID, initfs: initfs)

        // Step 8: Copy JavaScript file and configure container
        updateProgress("Step 8/10: Configuring Node.js container...")
        let appDir = try prepareAppDirectory(jsFile: jsFile)

        // Step 9: Add container to pod
        updateProgress("Step 9/10: Adding container to pod...")

        // Verify host directory access before creating VirtioFS mount.
        // ~/Desktop is TCC-protected on macOS; this triggers the permission
        // prompt and fails fast if access is denied, instead of hanging
        // during the guest VirtioFS mount.
        let hostSharePath = "/Users/babithbabyvarghese/Desktop"
        let hostShareURL = URL(fileURLWithPath: hostSharePath)
        do {
            _ = try FileManager.default.contentsOfDirectory(at: hostShareURL, includingPropertiesForKeys: nil)
            logger.info("✅ [NodeServerCoordinator] Host directory access verified: \(hostSharePath)")
        } catch {
            logger.error("❌ [NodeServerCoordinator] Cannot access host directory: \(hostSharePath) — \(error.localizedDescription)")
            logger.error("   Grant Desktop access in System Settings > Privacy & Security > Files and Folders")
            throw ContainerizationError(
                .invalidArgument,
                message: "Cannot access \(hostSharePath). Grant Desktop access in System Settings > Privacy & Security > Files and Folders."
            )
        }

        let containerConfig = ContainerConfiguration(
            containerID: "nodejs",
            hostname: "nodejs-container",
            command: ["node", "/app/\(jsFile.lastPathComponent)"],
            workingDirectory: "/app",
            environment: [
                "PATH=/usr/local/bin:/usr/bin:/bin",
                "NODE_ENV=production",
                "PORT=\(port)",
                "UNIX_SOCKET=/tmp/bridge-\(port).sock"
            ],
            rootfs: rootfs,
            additionalMounts: [
                Containerization.Mount.share(
                    source: appDir.path,
                    destination: "/app",
                    options: ["ro"]
                ),
                Containerization.Mount.share(
                    source: hostSharePath,
                    destination: "/host-files",
                    options: ["ro"]
                )
            ]
        )
        try await podFactory.addContainer(to: pod, config: containerConfig)

        // Step 10: Start container with crash detection
        updateProgress("Step 10/10: Starting container...")
        try await startPodWithCrashDetection(pod: pod, containerID: "nodejs")

        logger.info("✅✅✅ [NodeServerCoordinator] Node.js server started successfully!")
        return pod
    }

    // MARK: - Private Helpers

    /// Copies the JS entry-point into a shared app directory that will be mounted.
    private func prepareAppDirectory(jsFile: URL) throws -> URL {
        let appDir = workDir.appendingPathComponent("app")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        let destFile = appDir.appendingPathComponent(jsFile.lastPathComponent)
        try? FileManager.default.removeItem(at: destFile)
        try FileManager.default.copyItem(at: jsFile, to: destFile)
        logger.info("📁 [NodeServerCoordinator] Copied \(jsFile.lastPathComponent) to app directory")
        return appDir
    }

    /// Creates the pod and starts the container, then checks for immediate crash.
    private func startPodWithCrashDetection(pod: LinuxPod, containerID: String) async throws {
        let timeoutSeconds: Double = 90.0
        var timedOut = false

        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            timedOut = true
        }

        defer { timeoutTask.cancel() }

        do {
            try await pod.create()
            if timedOut {
                throw ContainerizationError(.timeout, message: "Pod creation timed out")
            }
        } catch {
            if timedOut {
                throw ContainerizationError(.timeout, message: "Step 10 timed out after \(timeoutSeconds) seconds")
            }
            await diagnosticsHelper.printDiagnostics(pod: pod, phase: "pod.create()", error: error)
            throw error
        }

        do {
            try await pod.startContainer(containerID)
            if timedOut {
                throw ContainerizationError(.timeout, message: "Container start timed out")
            }
        } catch {
            if timedOut {
                throw ContainerizationError(.timeout, message: "Step 10 timed out after \(timeoutSeconds) seconds")
            }
            await diagnosticsHelper.printDiagnostics(pod: pod, phase: "startContainer(\(containerID))", error: error)
            throw error
        }

        // Crash detection
        let crashCheck = await diagnosticsHelper.checkForImmediateCrash(pod: pod, containerID: containerID)
        if crashCheck.crashed {
            let exitInfo = crashCheck.exitStatus.map { diagnosticsHelper.formatExitStatus($0) } ?? "Unknown"
            await diagnosticsHelper.printDiagnostics(pod: pod, phase: "\(containerID) crash detection", error: nil)
            throw ContainerizationError(.internalError, message: "Container crashed: \(exitInfo)")
        }
    }

    private func updateProgress(_ message: String) {
        logger.info("📊 [NodeServerCoordinator] \(message)")
        onProgress?(message)
    }
}
