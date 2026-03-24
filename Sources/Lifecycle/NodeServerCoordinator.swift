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
    private let prerequisiteChecker: PrerequisiteChecker
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
        prerequisiteChecker: PrerequisiteChecker,
        workDir: URL,
        logger: Logger
    ) {
        self.imageService = imageService
        self.podFactory = podFactory
        self.imageStore = imageStore
        self.diagnosticsHelper = diagnosticsHelper
        self.prerequisiteChecker = prerequisiteChecker
        self.workDir = workDir
        self.logger = logger
    }

    // MARK: - Public API

    /// Start a Node.js container by pulling an image and mounting a JS file.
    ///
    /// Execution strategy (parallel tracks via `async let`):
    /// - Track A (Image): Pull image → Prepare rootfs
    /// - Track B (VM):    Init filesystem → Pod creation (kernel + VMM)
    /// - TCC:             Host directory check runs synchronously first for fail-fast
    ///
    /// - Parameters:
    ///   - jsFile: Local path to the JavaScript entry-point file.
    ///   - imageName: OCI image reference to pull (e.g. "docker.io/library/node:20").
    ///   - port: Port the Node.js server listens on.
    /// - Returns: The started LinuxPod instance.
    func start(jsFile: URL, imageName: String, port: Int, podConfig: PodConfiguration = .default) async throws -> LinuxPod {
        let startTime = ContinuousClock.now
        logger.info("[NodeServerCoordinator] Starting Node.js server from: \(imageName)")
        let platform = Platform(arch: "arm64", os: "linux", variant: "v8")

        // ── Fail-fast checks (Optimization D) ───────────────────────────
        try prerequisiteChecker.checkHostDirectoryAccess()
        let appDir = try prepareAppDirectory(jsFile: jsFile)

        // ── Phase 1: Launch two independent parallel tracks ─────────────
        updateProgress("Pulling image and preparing VM infrastructure...")

        async let imageTrackResult = performNodeImageTrack(
            imageName: imageName, platform: platform
        )
        async let vmTrackResult = performVMTrack(podConfig: podConfig)

        // Await VM track first. If it succeeds and image track later fails,
        // we must clean up the orphaned pod.
        let pod: LinuxPod
        do {
            pod = try await vmTrackResult
        } catch {
            logger.error("[NodeServerCoordinator] VM track failed: \(error.localizedDescription)")
            throw error
        }

        let rootfsURL: URL
        do {
            updateProgress("Finalizing image preparation...")
            rootfsURL = try await imageTrackResult
        } catch {
            logger.error("[NodeServerCoordinator] Image track failed, stopping orphaned pod: \(error.localizedDescription)")
            try? await pod.stop()
            throw error
        }

        let phase1Elapsed = ContinuousClock.now - startTime
        logger.info("[NodeServerCoordinator] Phase 1 (parallel prep) completed in \(phase1Elapsed)")

        // ── Phase 2: Add container (needs pod + rootfs) ─────────────────
        updateProgress("Adding container to pod...")
        let rootfs = podFactory.createRootfsMount(from: rootfsURL)
        let hostSharePath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop").path

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

        // ── Phase 3: Start container ────────────────────────────────────
        updateProgress("Starting container...")
        try await startPodWithCrashDetection(pod: pod, containerID: "nodejs")

        let totalElapsed = ContinuousClock.now - startTime
        logger.info("[NodeServerCoordinator] Node.js server started successfully in \(totalElapsed)")
        return pod
    }

    // MARK: - Parallel Execution Tracks

    /// Node Image Track: Pull image from registry, then prepare rootfs.
    private func performNodeImageTrack(
        imageName: String,
        platform: Platform
    ) async throws -> URL {
        let trackStart = ContinuousClock.now

        let image = try await imageService.pullImage(reference: imageName)
        logger.debug("[NodeServerCoordinator:ImageTrack] Pulled image, preparing rootfs...")
        let url = try await imageService.prepareRootfs(from: image, platform: platform)

        logger.info("[NodeServerCoordinator:ImageTrack] Completed in \(ContinuousClock.now - trackStart)")
        return url
    }

    /// VM Track: Prepare init filesystem, then create pod with kernel and VMM.
    private func performVMTrack(podConfig: PodConfiguration) async throws -> LinuxPod {
        let trackStart = ContinuousClock.now

        let initfs = try await podFactory.prepareInitFilesystem()
        let podID = "nodejs-server-\(UUID().uuidString.prefix(8))"
        let pod = try await podFactory.createPod(podID: podID, initfs: initfs, config: podConfig)

        logger.info("[NodeServerCoordinator:VMTrack] Completed in \(ContinuousClock.now - trackStart)")
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
        logger.debug("[NodeServerCoordinator] Copied \(jsFile.lastPathComponent) to app directory")
        return appDir
    }

    /// Creates the pod and starts the container, then checks for immediate crash.
    private func startPodWithCrashDetection(pod: LinuxPod, containerID: String) async throws {
        let timeoutSeconds: UInt32 = 90

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
                    try await pod.startContainer(containerID)
                } catch {
                    await self.diagnosticsHelper.printDiagnostics(
                        pod: pod, phase: "startContainer(\(containerID))", error: error
                    )
                    throw error
                }
            }
        } catch is CancellationError {
            await diagnosticsHelper.printDiagnostics(
                pod: pod, phase: "startPodWithCrashDetection", error: nil
            )
            throw ContainerizationError(
                .timeout,
                message: "Pod startup timed out after \(timeoutSeconds) seconds"
            )
        }

        // Crash detection (outside the timeout scope)
        let crashCheck = await diagnosticsHelper.checkForImmediateCrash(
            pod: pod, containerID: containerID
        )
        if crashCheck.crashed {
            let exitInfo = crashCheck.exitStatus.map {
                diagnosticsHelper.formatExitStatus($0)
            } ?? "Unknown"
            await diagnosticsHelper.printDiagnostics(
                pod: pod, phase: "\(containerID) crash detection", error: nil
            )
            throw ContainerizationError(
                .internalError, message: "Container crashed: \(exitInfo)"
            )
        }
    }

    private func updateProgress(_ message: String) {
        onProgress?(message)
    }
}
