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
import ContainerizationArchive
import ContainerizationOCI
import ContainerizationError
import Logging
import NIO

// MARK: - Pod Configuration

/// Configuration for creating a Linux Pod.
struct PodConfiguration {
    let cpus: Int
    let memoryInBytes: UInt64
    let networkAddress: String
    let networkGateway: String
    let bootlogPath: URL?
    
    static let `default` = PodConfiguration(
        cpus: 2,
        memoryInBytes: 512.mib(),
        networkAddress: "192.168.127.2/24",
        networkGateway: "192.168.127.1",
        bootlogPath: nil
    )
    
    func withBootlog(_ path: URL) -> PodConfiguration {
        PodConfiguration(
            cpus: cpus,
            memoryInBytes: memoryInBytes,
            networkAddress: networkAddress,
            networkGateway: networkGateway,
            bootlogPath: path
        )
    }
}

// MARK: - Container Configuration

/// Configuration for adding a container to a pod.
struct ContainerConfiguration {
    let containerID: String
    let hostname: String
    let command: [String]
    let workingDirectory: String
    let environment: [String]
    let rootfs: Containerization.Mount
    let additionalMounts: [Containerization.Mount]
    
    init(
        containerID: String = "main",
        hostname: String = "container",
        command: [String],
        workingDirectory: String = "/",
        environment: [String],
        rootfs: Containerization.Mount,
        additionalMounts: [Containerization.Mount] = []
    ) {
        self.containerID = containerID
        self.hostname = hostname
        self.command = command
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.rootfs = rootfs
        self.additionalMounts = additionalMounts
    }
}

// MARK: - Pod Factory

/// Factory for creating and configuring Linux Pods.
///
/// Separates the complexity of VM/Pod creation from the orchestrator,
/// following the Factory pattern and Single Responsibility Principle.
actor PodFactory {
    private let workDir: URL
    private let logger: Logger
    private let eventLoopGroup: MultiThreadedEventLoopGroup
    private let prerequisiteChecker: PrerequisiteChecker
    
    init(
        workDir: URL,
        logger: Logger,
        eventLoopGroup: MultiThreadedEventLoopGroup,
        prerequisiteChecker: PrerequisiteChecker
    ) {
        self.workDir = workDir
        self.logger = logger
        self.eventLoopGroup = eventLoopGroup
        self.prerequisiteChecker = prerequisiteChecker
    }
    
    // MARK: - Pod Creation
    
    /// Create a fully configured Linux Pod with VM, kernel, and init filesystem.
    ///
    /// - Parameters:
    ///   - podID: Unique identifier for the pod.
    ///   - initfs: The init filesystem mount.
    ///   - config: Pod configuration (CPU, memory, network).
    /// - Returns: A configured LinuxPod ready for container addition.
    func createPod(
        podID: String,
        initfs: Containerization.Mount,
        config: PodConfiguration = .default
    ) async throws -> LinuxPod {
        logger.info("🏗️ [PodFactory] Creating pod: \(podID)")
        
        // Load kernel
        let kernel = try await loadKernel()
        
        // Create VM Manager
        let vmm = createVMManager(kernel: kernel, initfs: initfs)
        
        // Create Linux Pod with configuration
        let bootlogPath = config.bootlogPath ?? createBootlogPath(podID: podID)
        
        let pod = try LinuxPod(podID, vmm: vmm, logger: logger) { podConfig in
            podConfig.cpus = config.cpus
            podConfig.memoryInBytes = config.memoryInBytes
            podConfig.interfaces = [
                NATInterface(address: config.networkAddress, gateway: config.networkGateway)
            ]
            podConfig.bootlog = bootlogPath
        }
        
        logger.info("✅ [PodFactory] Pod created: \(podID)")

        // Record pod and its bootlog in the run manifest for crash-time cleanup
        await RunManifest.shared.record(podID: podID, logger: logger)
        await RunManifest.shared.record(bootlogPath: bootlogPath.path, logger: logger)

        return pod
    }
    
    /// Add a container to an existing pod.
    ///
    /// - Parameters:
    ///   - pod: The pod to add the container to.
    ///   - config: Container configuration.
    func addContainer(to pod: LinuxPod, config: ContainerConfiguration) async throws {
        logger.info("➕ [PodFactory] Adding container '\(config.containerID)' to pod")

        let stdoutWriter = LoggingWriter(logger: logger, label: "container:stdout")
        let stderrWriter = LoggingWriter(logger: logger, label: "container:stderr")

        try await pod.addContainer(config.containerID, rootfs: config.rootfs) { containerConfig in
            containerConfig.hostname = config.hostname
            containerConfig.process.arguments = config.command
            containerConfig.process.workingDirectory = config.workingDirectory
            containerConfig.process.environmentVariables = config.environment
            containerConfig.process.stdout = stdoutWriter
            containerConfig.process.stderr = stderrWriter

            // Add additional mounts (e.g., virtiofs shares)
            for mount in config.additionalMounts {
                containerConfig.mounts.append(mount)
            }
        }
        
        logger.info("✅ [PodFactory] Container '\(config.containerID)' added")
    }
    
    // MARK: - Init Filesystem

    /// Prepare the init filesystem mount from the pre-built `init.block`.
    ///
    /// The init.block is generated by `make init-block` (see Makefile) and must
    /// be present in the Resources directory.  It contains:
    ///   - `/init`           — pre-init shim (mounts /proc, then execs vminitd)
    ///   - `/sbin/vminitd`   — guest init (Swift binary, PID 1)
    ///   - `/usr/bin/vmexec` — guest exec helper
    ///   - Mount-point directories for standardSetup()
    ///
    /// Resolution order:
    ///   1. Bundled `init.block` in Resources (produced by `make init-block`)
    ///   2. Cached copy in workDir from a previous run
    ///
    /// - Parameter imageStore: The image store (unused, kept for API compatibility).
    /// - Returns: The init filesystem mount.
    func prepareInitFilesystem(imageStore: ImageStore) async throws -> Containerization.Mount {
        // 1. Try Resources bundle first (preferred — built via `make init-block`).
        if let bundledURL = prerequisiteChecker.getBundledInitBlockPath() {
            let cachedURL = workDir.appendingPathComponent("init.block")

            // Copy to workDir if not already there (avoid re-copying on every launch).
            if !FileManager.default.fileExists(atPath: cachedURL.path) {
                logger.info("[PodFactory] Copying bundled init.block to workDir")
                try FileManager.default.copyItem(at: bundledURL, to: cachedURL)
            }

            logger.info("[PodFactory] Using init.block from Resources: \(bundledURL.path)")
            return .block(format: "ext4", source: cachedURL.path, destination: "/", options: ["ro"])
        }

        // 2. Fall back to a cached init.block in workDir (from a previous run).
        let cachedURL = workDir.appendingPathComponent("init.block")
        if FileManager.default.fileExists(atPath: cachedURL.path) {
            logger.info("[PodFactory] Using cached init.block from workDir: \(cachedURL.path)")
            return .block(format: "ext4", source: cachedURL.path, destination: "/", options: ["ro"])
        }

        // No init.block anywhere — fatal.
        throw ContainerizationError(
            .notFound,
            message: "init.block not found. Run 'make init-block' in the project root to generate it."
        )
    }
    
    // MARK: - Rootfs Creation
    
    /// Create a rootfs mount from a URL path.
    ///
    /// - Parameter rootfsURL: Path to the EXT4 rootfs file.
    /// - Returns: A block mount for the rootfs.
    nonisolated func createRootfsMount(from rootfsURL: URL) -> Containerization.Mount {
        .block(
            format: "ext4",
            source: rootfsURL.path,
            destination: "/",
            options: []
        )
    }
    
    // MARK: - Private Helpers
    
    private func loadKernel() async throws -> Kernel {
        logger.debug("🐧 [PodFactory] Loading Linux kernel")
        let kernelPath = try prerequisiteChecker.getKernelPath()
        
        var kernel = Kernel(path: .init(filePath: kernelPath.path), platform: .linuxArm)
        kernel.commandLine.addDebug()
        
        logger.info("✅ [PodFactory] Kernel configured: \(kernelPath.path)")
        return kernel
    }
    
    private func createVMManager(kernel: Kernel, initfs: Containerization.Mount) -> VZVirtualMachineManager {
        logger.debug("🖥️ [PodFactory] Creating VZVirtualMachineManager")
        return VZVirtualMachineManager(
            kernel: kernel,
            initialFilesystem: initfs,
            group: eventLoopGroup
        )
    }
    
    private func createBootlogPath(podID: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bootlog-\(podID).txt")
    }
}
