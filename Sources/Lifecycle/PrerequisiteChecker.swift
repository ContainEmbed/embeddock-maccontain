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
import ContainerizationError
import Logging
#if os(macOS)
import Virtualization
#endif

// MARK: - Prerequisite Checker

/// Service responsible for checking and validating prerequisites for container operations.
///
/// This service verifies that all required binaries and resources are available
/// before attempting to start containers.
///
/// Prerequisites checked:
/// - vminitd binary (guest init system)
/// - vmexec binary (guest exec helper)
/// - Linux kernel (vmlinux)
/// - Init filesystem (optional, can be created)
public struct PrerequisiteChecker: Sendable {
    private let workDir: URL
    private let logger: Logger
    
    public init(workDir: URL, logger: Logger) {
        self.workDir = workDir
        self.logger = logger
    }
    
    // MARK: - Full Check
    
    /// Check all prerequisites for container operation.
    ///
    /// - Throws: `ContainerizationError` if any required prerequisite is missing.
    public func checkAll() throws {
        logger.info("🔍 [PrerequisiteChecker] Checking prerequisites...")
        
        // Check 1: vminitd
        do {
            let vminitdPath = try getVminitdPath()
            logger.info("✅ [PrerequisiteChecker] vminitd found at: \(vminitdPath.path)")
        } catch {
            logger.error("❌ [PrerequisiteChecker] vminitd NOT FOUND")
            logger.error("📝 [PrerequisiteChecker] Required: Build guest binaries with 'make guest-binaries' in vminitd/")
            logger.error("💡 [PrerequisiteChecker] See BINARY_BUILD_GUIDE.md for instructions")
            throw error
        }
        
        // Check 2: vmexec
        do {
            let vmexecPath = try getVmexecPath()
            logger.info("✅ [PrerequisiteChecker] vmexec found at: \(vmexecPath.path)")
        } catch {
            logger.error("❌ [PrerequisiteChecker] vmexec NOT FOUND")
            logger.error("📝 [PrerequisiteChecker] Required: Build guest binaries with 'make guest-binaries'")
            throw error
        }
        
        // Check 3: Kernel
        do {
            let kernelPath = try getKernelPath()
            logger.info("✅ [PrerequisiteChecker] Kernel found at: \(kernelPath.path)")

            // Check kernel size (should be > 10MB)
            let attrs = try FileManager.default.attributesOfItem(atPath: kernelPath.path)
            if let size = attrs[.size] as? Int64 {
                logger.info("📊 [PrerequisiteChecker] Kernel size: \(size / 1024 / 1024) MB")
            }
        } catch {
            logger.error("❌ [PrerequisiteChecker] Kernel (vmlinux) NOT FOUND")
            logger.error("📝 [PrerequisiteChecker] Expected in Bundle.module Resources/ or:")
            logger.error("   - \(workDir.path)/vmlinux")
            logger.error("   - ~/.local/share/containerization/vmlinux")
            throw error
        }

        #if os(macOS)
        // Check 4: Virtualization framework support
        try checkVirtualizationSupport()

        // Check 5: Basic memory availability (uses default VM allocation as baseline)
        try checkMemoryAvailability(requiredBytes: 512 * 1024 * 1024)
        #endif

        logger.info("✅ [PrerequisiteChecker] All prerequisites checked")
    }
    
    // MARK: - Resource Path Helpers
    
    /// Find a resource file by name.
    ///
    /// Searches in the SPM module bundle (populated by the CopyResourcesPlugin
    /// from the artifact bundle downloaded via the binary target).
    public func getResourcePath(_ name: String) -> URL? {
        // Plugin-generated resources appear at top level in Bundle.module
        if let url = Bundle.module.url(forResource: name, withExtension: nil) {
            logger.info("✅ [PrerequisiteChecker] Found in module bundle: \(url.path)")
            return url
        }

        // Fallback: try with "Resources" subdirectory for backward compatibility
        if let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources") {
            logger.info("✅ [PrerequisiteChecker] Found in module bundle (Resources/): \(url.path)")
            return url
        }

        logger.error("❌ [PrerequisiteChecker] Could not find resource: \(name)")
        return nil
    }
    
    /// Get the path to the pre-init shim binary.
    public func getPreInitPath() throws -> URL {
        guard let path = getResourcePath("pre-init") else {
            throw ContainerizationError(.notFound, message: "pre-init binary not found in Resources/. Please ensure pre-init is cross-compiled for aarch64-linux.")
        }
        return path
    }

    /// Get the path to the vminitd binary.
    public func getVminitdPath() throws -> URL {
        guard let path = getResourcePath("vminitd") else {
            throw ContainerizationError(.notFound, message: "vminitd binary not found in Resources/. Please build guest binaries first. See BINARY_BUILD_GUIDE.md")
        }
        return path
    }
    
    /// Get the path to the vmexec binary.
    public func getVmexecPath() throws -> URL {
        guard let path = getResourcePath("vmexec") else {
            throw ContainerizationError(.notFound, message: "vmexec binary not found in Resources/. Please build guest binaries first.")
        }
        return path
    }
    
    /// Get the path to the Linux kernel.
    ///
    /// Searches in order:
    /// 1. Bundled resource (Bundle.module / source tree)
    /// 2. Working directory
    /// 3. Homebrew installation
    /// 4. User home directory
    public func getKernelPath() throws -> URL {
        // Check Bundle.module first (bundled vmlinux in Resources/)
        if let bundledKernel = getResourcePath("vmlinux") {
            return bundledKernel
        }

        // Fallback to common filesystem locations
        let possiblePaths = [
            workDir.appendingPathComponent("vmlinux"),
            URL(fileURLWithPath: "/opt/homebrew/share/containerization/vmlinux"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/share/containerization/vmlinux")
        ]

        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path.path) {
                return path
            }
        }

        throw ContainerizationError(.notFound, message: "Linux kernel (vmlinux) not found. Ensure vmlinux is in src/EmbedDock/Resources/ or download from kata-containers.")
    }
    
    /// Get the path to the init block file.
    public func getInitBlockPath() -> URL {
        workDir.appendingPathComponent("init.block")
    }
    
    /// Check if init block exists.
    public func initBlockExists() -> Bool {
        FileManager.default.fileExists(atPath: getInitBlockPath().path)
    }

    // MARK: - Host Directory Access

    /// Verify that the host can access TCC-protected directories needed for VirtioFS mounts.
    ///
    /// On macOS, ~/Desktop is TCC-protected. This method triggers the system permission
    /// prompt early and fails fast if access is denied, instead of hanging during
    /// guest VirtioFS mount setup.
    ///
    /// - Parameter directoryName: The home subdirectory to check (default: "Desktop").
    /// - Throws: `ContainerizationError(.invalidArgument)` if access is denied.
    public func checkHostDirectoryAccess(directoryName: String = "Desktop") throws {
        let hostSharePath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(directoryName).path
        let hostShareURL = URL(fileURLWithPath: hostSharePath)

        do {
            _ = try FileManager.default.contentsOfDirectory(
                at: hostShareURL, includingPropertiesForKeys: nil
            )
            logger.debug("[PrerequisiteChecker] Host directory access verified: \(hostSharePath)")
        } catch {
            logger.error("[PrerequisiteChecker] Cannot access host directory: \(hostSharePath) — \(error.localizedDescription)")
            throw ContainerizationError(
                .invalidArgument,
                message: "Cannot access \(hostSharePath). Grant Desktop access in System Settings > Privacy & Security > Files and Folders."
            )
        }
    }

    #if os(macOS)
    // MARK: - Virtualization Readiness Checks

    /// Query available system memory using Mach host_statistics64 API.
    ///
    /// Returns the sum of free + inactive pages as available memory.
    /// Falls back to half of physical memory if the Mach call fails.
    private func getAvailableMemoryBytes() -> UInt64 {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            logger.warning("⚠️ [PrerequisiteChecker] host_statistics64 failed, using fallback memory estimate")
            return ProcessInfo.processInfo.physicalMemory / 2
        }
        let pageSize = UInt64(sysconf(_SC_PAGESIZE))
        let free = UInt64(stats.free_count) * pageSize
        let inactive = UInt64(stats.inactive_count) * pageSize
        return free + inactive
    }

    /// Run all VM-specific pre-flight readiness checks.
    ///
    /// Checks are run in order of cost/severity:
    /// 1. Virtualization framework support (fatal if unsupported)
    /// 2. CPU/memory within hardware limits (fatal if out of range)
    /// 3. Available system memory (fatal if insufficient)
    /// 4. init.block file access (fatal if locked)
    /// 5. Stale process detection (warning only)
    ///
    /// - Parameters:
    ///   - cpus: Number of virtual CPUs to allocate.
    ///   - memoryInBytes: VM memory allocation in bytes.
    ///   - initBlockPath: Path to the init.block file.
    ///   - pidFilePath: Path to the PID file from a previous run.
    /// - Throws: `ContainerizationError` for fatal readiness failures.
    public func checkVirtualizationReadiness(
        cpus: Int,
        memoryInBytes: UInt64,
        initBlockPath: URL,
        pidFilePath: URL
    ) throws {
        logger.info("🔍 [PrerequisiteChecker] Running virtualization readiness checks...")

        // 1. Can this Mac run VMs at all?
        try checkVirtualizationSupport()

        // 2. Are requested resources within hardware limits?
        try checkResourceLimits(cpus: cpus, memoryInBytes: memoryInBytes)

        // 3. Is there enough free memory right now?
        try checkMemoryAvailability(requiredBytes: memoryInBytes)

        // 4. Is the init.block file usable?
        try checkInitBlockAccess(path: initBlockPath)

        // 5. Is a previous instance still running? (warning only, does not throw)
        checkForStaleProcess(pidFilePath: pidFilePath)

        logger.info("✅ [PrerequisiteChecker] All virtualization readiness checks passed")
    }

    /// Check that the host supports Apple's Virtualization framework.
    ///
    /// Verifies hardware capability and entitlement availability via
    /// `VZVirtualMachine.isSupported`.
    ///
    /// - Throws: `ContainerizationError(.unsupported)` if virtualization is not available.
    public func checkVirtualizationSupport() throws {
        logger.info("🔍 [PrerequisiteChecker] Checking virtualization support...")

        guard VZVirtualMachine.isSupported else {
            logger.error("❌ [PrerequisiteChecker] Virtualization is NOT supported on this Mac")
            logger.error("   Possible causes:")
            logger.error("   - Running on unsupported hardware")
            logger.error("   - Virtual machine software blocking Hypervisor.framework")
            logger.error("   - Missing com.apple.security.virtualization entitlement")
            throw ContainerizationError(
                .unsupported,
                message: "Virtualization is not supported on this Mac. "
                    + "Ensure you are running on Apple Silicon or compatible Intel hardware, "
                    + "and that no other hypervisor is blocking access."
            )
        }

        logger.info("✅ [PrerequisiteChecker] Virtualization is supported")
    }

    /// Validate that requested CPU and memory fall within the hardware's virtualization limits.
    ///
    /// Compares against `VZVirtualMachineConfiguration` static boundary properties.
    ///
    /// - Parameters:
    ///   - cpus: Number of virtual CPUs requested.
    ///   - memoryInBytes: Amount of VM memory requested in bytes.
    /// - Throws: `ContainerizationError(.invalidArgument)` if below minimum,
    ///           `ContainerizationError(.unsupported)` if exceeding hardware maximum.
    public func checkResourceLimits(cpus: Int, memoryInBytes: UInt64) throws {
        let minCPU = VZVirtualMachineConfiguration.minimumAllowedCPUCount
        let maxCPU = VZVirtualMachineConfiguration.maximumAllowedCPUCount
        let minMem = VZVirtualMachineConfiguration.minimumAllowedMemorySize
        let maxMem = VZVirtualMachineConfiguration.maximumAllowedMemorySize

        logger.info("🔍 [PrerequisiteChecker] Checking resource limits (requested: \(cpus) CPUs, \(memoryInBytes / 1024 / 1024) MB)")
        logger.debug("   CPU range: \(minCPU)...\(maxCPU), Memory range: \(minMem / 1024 / 1024) MB...\(maxMem / 1024 / 1024) MB")

        if cpus < minCPU {
            throw ContainerizationError(
                .invalidArgument,
                message: "Requested \(cpus) CPUs is below the minimum (\(minCPU)). "
                    + "Increase the CPU count in PodConfiguration."
            )
        }

        if cpus > maxCPU {
            throw ContainerizationError(
                .unsupported,
                message: "Requested \(cpus) CPUs exceeds the maximum allowed (\(maxCPU)) on this hardware. "
                    + "Reduce the CPU count in PodConfiguration."
            )
        }

        if memoryInBytes < minMem {
            throw ContainerizationError(
                .invalidArgument,
                message: "Requested \(memoryInBytes / 1024 / 1024) MB memory is below the minimum "
                    + "(\(minMem / 1024 / 1024) MB). Increase memoryInBytes in PodConfiguration."
            )
        }

        if memoryInBytes > maxMem {
            throw ContainerizationError(
                .unsupported,
                message: "Requested \(memoryInBytes / 1024 / 1024) MB memory exceeds the maximum allowed "
                    + "(\(maxMem / 1024 / 1024) MB) on this hardware. "
                    + "Reduce memoryInBytes in PodConfiguration."
            )
        }

        logger.info("✅ [PrerequisiteChecker] Resource limits OK (cpus: \(cpus)/\(maxCPU), memory: \(memoryInBytes / 1024 / 1024)/\(maxMem / 1024 / 1024) MB)")
    }

    /// Check that the system has enough free memory to allocate the VM.
    ///
    /// Uses `os_proc_available_memory()` to query the amount of memory
    /// available before macOS applies memory pressure. Requires
    /// `requiredBytes + 256 MB headroom`.
    ///
    /// - Parameter requiredBytes: VM memory allocation in bytes (e.g., 512 MiB).
    /// - Throws: `ContainerizationError(.unsupported)` if insufficient memory.
    public func checkMemoryAvailability(requiredBytes: UInt64) throws {
        let headroomBytes: UInt64 = 256 * 1024 * 1024  // 256 MB headroom
        let totalRequired = requiredBytes + headroomBytes

        let availableBytes = getAvailableMemoryBytes()

        logger.info("🔍 [PrerequisiteChecker] Memory check: available = \(availableBytes / 1024 / 1024) MB, required = \(requiredBytes / 1024 / 1024) MB + \(headroomBytes / 1024 / 1024) MB headroom = \(totalRequired / 1024 / 1024) MB total")

        guard availableBytes >= totalRequired else {
            let deficit = totalRequired - availableBytes
            logger.error("❌ [PrerequisiteChecker] Insufficient memory for VM allocation")
            logger.error("   Available: \(availableBytes / 1024 / 1024) MB, Required: \(totalRequired / 1024 / 1024) MB (deficit: \(deficit / 1024 / 1024) MB)")
            logger.error("   Close other applications or reduce VM memory to free up resources")
            throw ContainerizationError(
                .unsupported,
                message: "Insufficient memory to start VM. "
                    + "Available: \(availableBytes / 1024 / 1024) MB, "
                    + "Required: \(totalRequired / 1024 / 1024) MB "
                    + "(\(requiredBytes / 1024 / 1024) MB for VM + \(headroomBytes / 1024 / 1024) MB headroom). "
                    + "Close other applications or reduce the VM memory allocation."
            )
        }

        logger.info("✅ [PrerequisiteChecker] Memory availability OK (\(availableBytes / 1024 / 1024) MB available)")
    }

    /// Verify that the init.block file is accessible and not locked.
    ///
    /// Attempts to open the file with `O_RDONLY | O_NONBLOCK` to detect
    /// file locks or permission issues from crashed previous runs.
    /// Also performs a basic size sanity check (file should be > 1 MB).
    ///
    /// - Parameter path: URL to the init.block file.
    /// - Throws: `ContainerizationError(.internalError)` if the file is locked or inaccessible.
    public func checkInitBlockAccess(path: URL) throws {
        logger.info("🔍 [PrerequisiteChecker] Checking init.block access: \(path.path)")

        // Skip check if init.block doesn't exist yet (it will be created during startup)
        guard FileManager.default.fileExists(atPath: path.path) else {
            logger.info("   init.block does not exist yet (will be created during startup)")
            return
        }

        // Try to open the file to check for locks / permission issues
        let fd = open(path.path, O_RDONLY | O_NONBLOCK)
        if fd == -1 {
            let errCode = errno
            let errString = String(cString: strerror(errCode))
            logger.error("❌ [PrerequisiteChecker] Cannot open init.block: \(errString) (errno: \(errCode))")

            if errCode == EACCES {
                throw ContainerizationError(
                    .internalError,
                    message: "init.block is not readable (\(errString)). "
                        + "Check file permissions at \(path.path), or delete and recreate the file."
                )
            } else {
                throw ContainerizationError(
                    .internalError,
                    message: "Cannot access init.block: \(errString) (errno: \(errCode)). "
                        + "The file may be locked by a previous instance. "
                        + "Try deleting \(path.path) and restarting."
                )
            }
        }

        // File opened successfully -- close it immediately
        close(fd)

        // Size sanity check (init.block should be a valid ext4 image, > 1 MB)
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
            if let size = attrs[.size] as? Int64 {
                logger.debug("   init.block size: \(size / 1024 / 1024) MB")
                if size < 1_048_576 {  // 1 MB
                    logger.warning("⚠️ [PrerequisiteChecker] init.block is suspiciously small (\(size) bytes). It may be corrupted.")
                    logger.warning("   Consider deleting \(path.path) to regenerate it.")
                }
            }
        } catch {
            logger.warning("⚠️ [PrerequisiteChecker] Could not read init.block attributes: \(error.localizedDescription)")
        }

        logger.info("✅ [PrerequisiteChecker] init.block is accessible")
    }

    /// Check if a PID file from a previous run indicates a stale process.
    ///
    /// Reads the PID file, then uses `kill(pid, 0)` to probe whether the process
    /// is still alive. This is informational only -- it logs a warning but does
    /// not throw, because we cannot safely kill another process from sandbox.
    ///
    /// - Parameter pidFilePath: URL to the PID file (e.g., `workDir/embeddock.pid`).
    public func checkForStaleProcess(pidFilePath: URL) {
        logger.info("🔍 [PrerequisiteChecker] Checking for stale process: \(pidFilePath.path)")

        guard FileManager.default.fileExists(atPath: pidFilePath.path) else {
            logger.debug("   No PID file found (clean state)")
            return
        }

        do {
            let pidString = try String(contentsOfFile: pidFilePath.path, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard let pid = Int32(pidString) else {
                logger.warning("⚠️ [PrerequisiteChecker] PID file contains invalid content: '\(pidString)'. Ignoring.")
                return
            }

            let currentPid = ProcessInfo.processInfo.processIdentifier
            if pid == currentPid {
                logger.debug("   PID file contains current process PID (\(pid)). OK.")
                return
            }

            // kill(pid, 0) sends no signal but checks if the process exists.
            // Returns 0 if process exists; -1 with ESRCH if it does not.
            let result = kill(pid, 0)

            if result == 0 {
                logger.warning("⚠️ [PrerequisiteChecker] A previous instance (PID \(pid)) appears to still be running.")
                logger.warning("   This may cause resource conflicts with the hypervisor or vmnet.")
                logger.warning("   If the previous instance is stuck, terminate it with: kill \(pid)")
            } else if errno == ESRCH {
                logger.info("   Previous process (PID \(pid)) is no longer running (stale PID file)")
            } else {
                logger.warning("⚠️ [PrerequisiteChecker] Cannot determine status of PID \(pid) (errno: \(errno)). A previous instance may still be running.")
            }
        } catch {
            logger.warning("⚠️ [PrerequisiteChecker] Could not read PID file: \(error.localizedDescription)")
        }
    }
    #endif
}
