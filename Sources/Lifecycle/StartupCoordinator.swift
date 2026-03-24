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
    private let prerequisiteChecker: PrerequisiteChecker
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
        prerequisiteChecker: PrerequisiteChecker,
        logger: Logger
    ) {
        self.imageLoader = imageLoader
        self.imageService = imageService
        self.podFactory = podFactory
        self.imageStore = imageStore
        self.diagnosticsHelper = diagnosticsHelper
        self.prerequisiteChecker = prerequisiteChecker
        self.logger = logger
    }
    
    // MARK: - Public API

    /// Start a container from an OCI image tar file.
    ///
    /// Execution strategy (parallel tracks via `async let`):
    /// - Track A (Image): Load OCI tar → [Rootfs unpacking ‖ Config extraction]
    /// - Track B (VM):    Init filesystem → Pod creation (kernel + VMM)
    /// - TCC:             Host directory check runs synchronously first for fail-fast
    ///
    /// - Parameters:
    ///   - imageFile: Path to the OCI image tar file.
    ///   - port: Port the container application listens on.
    /// - Returns: The started LinuxPod instance.
    func startFromImage(imageFile: URL, port: Int, podConfig: PodConfiguration = .default) async throws -> LinuxPod {
        let startTime = ContinuousClock.now
        logger.info("[StartupCoordinator] Starting container from: \(imageFile.lastPathComponent)")
        let platform = Platform(arch: "arm64", os: "linux", variant: "v8")

        // ── Fail-fast TCC check (Optimization D) ────────────────────────
        // Run before ANY async work so permission denial shows immediately.
        updateProgress("Checking host directory access...")
        try prerequisiteChecker.checkHostDirectoryAccess()

        // ── Phase 1: Launch two independent parallel tracks ─────────────
        // Track A: image load → [rootfs prep ‖ config extraction]
        // Track B: init filesystem → pod creation (kernel + VMM)
        updateProgress("Loading image and preparing VM infrastructure...")

        async let imageTrackResult = performImageTrack(
            imageFile: imageFile, platform: platform
        )
        async let vmTrackResult = performVMTrack(podConfig: podConfig)

        // Await VM track first — typically faster when init.block is cached.
        // If it succeeds and image track later fails, we must clean up the pod.
        let pod: LinuxPod
        do {
            pod = try await vmTrackResult
        } catch {
            // VM track failed; image track is auto-cancelled by structured concurrency.
            logger.error("[StartupCoordinator] VM track failed: \(error.localizedDescription)")
            throw error
        }

        let rootfsURL: URL
        let imageConfig: ExtractedImageConfig
        do {
            updateProgress("Finalizing image preparation...")
            (rootfsURL, imageConfig) = try await imageTrackResult
        } catch {
            // Image track failed after VM track succeeded — clean up the orphaned pod.
            logger.error("[StartupCoordinator] Image track failed, stopping orphaned pod: \(error.localizedDescription)")
            try? await pod.stop()
            throw error
        }

        let phase1Elapsed = ContinuousClock.now - startTime
        logger.info("[StartupCoordinator] Phase 1 (parallel prep) completed in \(phase1Elapsed)")

        // ── Phase 2: Add container (needs pod + rootfs + config) ────────
        updateProgress("Adding container to pod...")
        let rootfs = podFactory.createRootfsMount(from: rootfsURL)
        let hostSharePath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop").path

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

        // ── Phase 3: Start container with timeout ───────────────────────
        updateProgress("Starting container...")
        try await startPodWithTimeout(pod: pod, port: port)

        let totalElapsed = ContinuousClock.now - startTime
        logger.info("[StartupCoordinator] Container started successfully in \(totalElapsed)")
        return pod
    }

    // MARK: - Parallel Execution Tracks

    /// Image Track: Load OCI image, then prepare rootfs and extract config in parallel.
    ///
    /// Implements Optimizations A and B:
    /// - A: This entire track runs in parallel with the VM track
    /// - B: Rootfs preparation and config extraction run in parallel after image loads
    private func performImageTrack(
        imageFile: URL,
        platform: Platform
    ) async throws -> (URL, ExtractedImageConfig) {
        let trackStart = ContinuousClock.now

        let image = try await imageLoader.loadFromFile(imageFile)
        logger.debug("[StartupCoordinator:ImageTrack] Loaded image: \(image.reference)")

        // Rootfs unpacking (heavy) alongside config extraction (light)
        async let rootfsURL = imageService.prepareRootfs(from: image, platform: platform)
        async let imageConfig = ImageConfigExtractor(image: image, platform: platform).extract()

        let result = (try await rootfsURL, try await imageConfig)
        logger.info("[StartupCoordinator:ImageTrack] Completed in \(ContinuousClock.now - trackStart)")
        return result
    }

    /// VM Track: Prepare init filesystem, then create pod with kernel and VMM.
    ///
    /// Implements Optimizations A and C:
    /// - A: Init filesystem preparation starts immediately (no image dependency)
    /// - C: VM creation (kernel + VMM + pod) starts before rootfs is ready
    private func performVMTrack(podConfig: PodConfiguration) async throws -> LinuxPod {
        let trackStart = ContinuousClock.now

        let initfs = try await podFactory.prepareInitFilesystem()
        let podID = "container-\(UUID().uuidString.prefix(8))"
        let pod = try await podFactory.createPod(podID: podID, initfs: initfs, config: podConfig)

        logger.info("[StartupCoordinator:VMTrack] Completed in \(ContinuousClock.now - trackStart)")
        return pod
    }
    
    // MARK: - Private Helpers
    
    private func startPodWithTimeout(pod: LinuxPod, port: Int) async throws {
        let timeoutSeconds: UInt32 = 90
        let startTime = Date()

        // Use Timeout.run to race the actual work against a deadline.
        do {
            try await Timeout.run(seconds: timeoutSeconds) { [self] in
                do {
                    try await pod.create()
                } catch {
                    await self.diagnosticsHelper.printDiagnostics(
                        pod: pod, phase: "pod.create()", error: error
                    )
                    throw error
                }

                do {
                    try await pod.startContainer("main")
                } catch {
                    await self.diagnosticsHelper.printDiagnostics(
                        pod: pod, phase: "startContainer()", error: error
                    )
                    throw error
                }
            }
        } catch is CancellationError {
            await diagnosticsHelper.printDiagnostics(
                pod: pod, phase: "startPodWithTimeout", error: nil
            )
            throw ContainerizationError(
                .timeout,
                message: "Pod startup timed out after \(timeoutSeconds) seconds"
            )
        }

        // Check for immediate crash (outside the timeout scope)
        let crashCheck = await diagnosticsHelper.checkForImmediateCrash(
            pod: pod, containerID: "main"
        )
        if crashCheck.crashed {
            let exitInfo = crashCheck.exitStatus.map {
                diagnosticsHelper.formatExitStatus($0)
            } ?? "Unknown"
            await diagnosticsHelper.printDiagnostics(
                pod: pod, phase: "crash detection", error: nil
            )
            throw ContainerizationError(
                .internalError, message: "Container crashed: \(exitInfo)"
            )
        }

        let elapsed = Date().timeIntervalSince(startTime)
        logger.info("⏱️ [StartupCoordinator] Started in \(String(format: "%.1f", elapsed))s")
    }
    
    private func updateProgress(_ message: String) {
        onProgress?(message)
    }
}
