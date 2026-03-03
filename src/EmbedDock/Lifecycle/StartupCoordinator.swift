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

/// Coordinates the multi-step container startup process.
///
/// Delegates to extracted modules (ImageLoader, ImageService, PodFactory,
/// DiagnosticsHelper) instead of reimplementing their logic, following the
/// Single Responsibility Principle.
@MainActor
final class StartupCoordinator {
    
    // MARK: - Dependencies (Injected)
    
    private let imageLoader: ImageLoader
    private let imageService: ImageService
    private let podFactory: PodFactory
    private let diagnosticsHelper: DiagnosticsHelper
    private let imageStore: ImageStore
    private let logger: Logger
    
    /// Progress callback for UI updates.
    var onProgress: ((String) -> Void)?
    
    // MARK: - Initialization
    
    init(
        imageLoader: ImageLoader,
        imageService: ImageService,
        podFactory: PodFactory,
        imageStore: ImageStore,
        diagnosticsHelper: DiagnosticsHelper,
        logger: Logger
    ) {
        self.imageLoader = imageLoader
        self.imageService = imageService
        self.podFactory = podFactory
        self.imageStore = imageStore
        self.diagnosticsHelper = diagnosticsHelper
        self.logger = logger
    }
    
    // MARK: - Public API
    
    /// Start a container from an OCI image tar file.
    ///
    /// - Parameters:
    ///   - imageFile: Path to the OCI image tar file.
    ///   - port: Port the container application listens on.
    /// - Returns: The started LinuxPod instance.
    func startFromImage(imageFile: URL, port: Int) async throws -> LinuxPod {
        logger.info("🚀 [StartupCoordinator] Starting container from: \(imageFile.lastPathComponent)")
        let platform = Platform(arch: "arm64", os: "linux", variant: "v8")
        
        // Step 1-2: Extract and import OCI image (delegates to ImageLoader)
        updateProgress("Step 1/10: Extracting OCI image...")
        let image = try await imageLoader.loadFromFile(imageFile)
        updateProgress("Step 2/10: Importing container image...")
        logger.info("✅ [StartupCoordinator] Loaded OCI image: \(image.reference)")
        
        // Step 3: Prepare rootfs (delegates to ImageService)
        updateProgress("Step 3/10: Unpacking container image...")
        let rootfsURL = try await imageService.prepareRootfs(from: image, platform: platform)
        let rootfs = podFactory.createRootfsMount(from: rootfsURL)
        
        // Step 4: Prepare init filesystem (delegates to PodFactory)
        updateProgress("Step 4/10: Preparing init filesystem...")
        let initfs = try await podFactory.prepareInitFilesystem(imageStore: imageStore)
        
        // Step 5-7: Load kernel, create VM manager, create pod (delegates to PodFactory)
        updateProgress("Step 5/10: Loading Linux kernel...")
        updateProgress("Step 6/10: Starting virtual machine...")
        updateProgress("Step 7/10: Creating container pod...")
        let podID = "container-\(UUID().uuidString.prefix(8))"
        let pod = try await podFactory.createPod(podID: podID, initfs: initfs)
        
        // Step 8: Configure container (uses ImageConfigExtractor)
        updateProgress("Step 8/10: Configuring container...")
        let extractor = ImageConfigExtractor(image: image, platform: platform)
        let imageConfig = try await extractor.extract()
        
        // Step 9: Add container to pod (delegates to PodFactory)
        updateProgress("Step 9/10: Adding container to pod...")

        // Verify host directory access before creating VirtioFS mount.
        // ~/Desktop is TCC-protected on macOS; this triggers the permission
        // prompt and fails fast if access is denied, instead of hanging
        // during the guest VirtioFS mount.
        let hostSharePath = "/Users/babithbabyvarghese/Desktop"
        let hostShareURL = URL(fileURLWithPath: hostSharePath)
        do {
            _ = try FileManager.default.contentsOfDirectory(at: hostShareURL, includingPropertiesForKeys: nil)
            logger.info("✅ [StartupCoordinator] Host directory access verified: \(hostSharePath)")
        } catch {
            logger.error("❌ [StartupCoordinator] Cannot access host directory: \(hostSharePath) — \(error.localizedDescription)")
            logger.error("   Grant Desktop access in System Settings > Privacy & Security > Files and Folders")
            throw ContainerizationError(
                .invalidArgument,
                message: "Cannot access \(hostSharePath). Grant Desktop access in System Settings > Privacy & Security > Files and Folders."
            )
        }

        let containerConfig = ContainerConfiguration(
            containerID: "main",
            hostname: "container",
            command: imageConfig.command,
            workingDirectory: imageConfig.workingDirectory,
            environment: imageConfig.environmentWith(additional: [
                "PORT=\(port)",
                "UNIX_SOCKET=/tmp/bridge-\(port).sock"
            ]),
            rootfs: rootfs,
            additionalMounts: [
                Containerization.Mount.share(
                    source: hostSharePath,
                    destination: "/host-files",
                    options: ["ro"]
                )
            ]
        )
        try await podFactory.addContainer(to: pod, config: containerConfig)
        
        // Step 10: Start container with timeout
        updateProgress("Step 10/10: Starting container...")
        try await startPodWithTimeout(pod: pod, port: port)
        
        logger.info("✅✅✅ [StartupCoordinator] Container started successfully!")
        return pod
    }
    
    // MARK: - Private Helpers
    
    private func startPodWithTimeout(pod: LinuxPod, port: Int) async throws {
        let timeoutSeconds: Double = 90.0
        let startTime = Date()
        var timedOut = false

        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            timedOut = true
        }

        defer { timeoutTask.cancel() }

        // Phase A: Create pod (VM boot + vminitd + standardSetup + rootfs mount + network)
        logger.info("[Step10] Phase A: pod.create() starting...")
        let createStart = Date()
        do {
            try await pod.create()
            let createElapsed = Date().timeIntervalSince(createStart)
            logger.info("[Step10] Phase A: pod.create() completed in \(String(format: "%.2f", createElapsed))s")
            if timedOut {
                throw ContainerizationError(.timeout, message: "Pod creation timed out")
            }
        } catch {
            let createElapsed = Date().timeIntervalSince(createStart)
            logger.error("[Step10] Phase A: pod.create() FAILED after \(String(format: "%.2f", createElapsed))s — \(error)")
            dumpBootLog(pod: pod)
            if timedOut {
                throw ContainerizationError(.timeout, message: "Step 10 timed out after \(timeoutSeconds) seconds")
            }
            await diagnosticsHelper.printDiagnostics(pod: pod, phase: "pod.create()", error: error)
            throw error
        }

        // Phase B: Start the container process
        logger.info("[Step10] Phase B: pod.startContainer(\"main\") starting...")
        let startContainerStart = Date()
        do {
            try await pod.startContainer("main")
            let startElapsed = Date().timeIntervalSince(startContainerStart)
            logger.info("[Step10] Phase B: pod.startContainer(\"main\") completed in \(String(format: "%.2f", startElapsed))s")
            if timedOut {
                throw ContainerizationError(.timeout, message: "Container start timed out")
            }
        } catch {
            let startElapsed = Date().timeIntervalSince(startContainerStart)
            logger.error("[Step10] Phase B: pod.startContainer(\"main\") FAILED after \(String(format: "%.2f", startElapsed))s — \(error)")
            dumpBootLog(pod: pod)
            if timedOut {
                throw ContainerizationError(.timeout, message: "Step 10 timed out after \(timeoutSeconds) seconds")
            }
            await diagnosticsHelper.printDiagnostics(pod: pod, phase: "startContainer()", error: error)
            throw error
        }

        // Phase C: Immediate crash detection
        logger.info("[Step10] Phase C: checking for immediate crash...")
        let crashCheck = await diagnosticsHelper.checkForImmediateCrash(pod: pod, containerID: "main")
        if crashCheck.crashed {
            let exitInfo = crashCheck.exitStatus.map { diagnosticsHelper.formatExitStatus($0) } ?? "Unknown"
            logger.error("[Step10] Phase C: Container crashed immediately — \(exitInfo)")
            dumpBootLog(pod: pod)
            await diagnosticsHelper.printDiagnostics(pod: pod, phase: "crash detection", error: nil)
            throw ContainerizationError(.internalError, message: "Container crashed: \(exitInfo)")
        }

        let elapsed = Date().timeIntervalSince(startTime)
        logger.info("⏱️ [StartupCoordinator] Started in \(String(format: "%.1f", elapsed))s")
    }

    /// Read the boot log file and dump its contents to the logger for debugging.
    private func dumpBootLog(pod: LinuxPod) {
        guard let bootlogURL = pod.config.bootlog else {
            logger.warning("[Step10] No boot log path configured — cannot dump kernel output")
            return
        }
        logger.info("[Step10] --- BEGIN BOOT LOG (\(bootlogURL.path)) ---")
        do {
            let content = try String(contentsOf: bootlogURL, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)
            // Log last 40 lines (or all if shorter)
            let tail = lines.suffix(40)
            for line in tail {
                logger.info("[bootlog] \(line)")
            }
        } catch {
            logger.warning("[Step10] Could not read boot log: \(error.localizedDescription)")
        }
        logger.info("[Step10] --- END BOOT LOG ---")
    }
    
    private func updateProgress(_ message: String) {
        logger.info("📊 [StartupCoordinator] \(message)")
        onProgress?(message)
    }
}
