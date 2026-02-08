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
            logger.error("📝 [PrerequisiteChecker] Expected locations:")
            logger.error("   - \(workDir.path)/vmlinux")
            logger.error("   - ~/.local/share/containerization/vmlinux")
            logger.error("💡 [PrerequisiteChecker] Download from: https://github.com/kata-containers/kata-containers/releases")
            logger.error("💡 [PrerequisiteChecker] Or build with 'make kernel' in kernel/")
            throw error
        }
        
        // Check 4: Init filesystem (optional - can be created)
        let initBlockURL = workDir.appendingPathComponent("init.block")
        if FileManager.default.fileExists(atPath: initBlockURL.path) {
            logger.info("✅ [PrerequisiteChecker] init.block found at: \(initBlockURL.path)")
        } else {
            logger.warning("⚠️ [PrerequisiteChecker] init.block NOT FOUND (will attempt to create)")
            logger.info("📝 [PrerequisiteChecker] Will be created at: \(initBlockURL.path)")
        }
        
        logger.info("✅ [PrerequisiteChecker] All prerequisites checked")
    }
    
    // MARK: - Resource Path Helpers
    
    /// Find a resource file by name.
    ///
    /// Searches in:
    /// 1. Application bundle resources
    /// 2. Source tree Resources directory (for development)
    public func getResourcePath(_ name: String) -> URL? {
        // Try to find in Bundle's Resources
        if let resourcePath = Bundle.main.resourcePath {
            let url = URL(fileURLWithPath: resourcePath).appendingPathComponent(name)
            logger.debug("🔍 [PrerequisiteChecker] Checking bundle resources: \(url.path)")
            if FileManager.default.fileExists(atPath: url.path) {
                logger.info("✅ [PrerequisiteChecker] Found in bundle: \(url.path)")
                return url
            }
        }
        
        // Try in source tree Resources directory for development
        if let executablePath = Bundle.main.executablePath {
            let execURL = URL(fileURLWithPath: executablePath)
            logger.debug("🔍 [PrerequisiteChecker] Executable path: \(executablePath)")
            // When running from .build/arm64-apple-macosx/debug, need to go up 4 levels
            let projectRoot = execURL.deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            logger.debug("🔍 [PrerequisiteChecker] Project root: \(projectRoot.path)")
            let sourceResourcesURL = projectRoot
                .appendingPathComponent("Sources/HelloWorldApp/Resources/\(name)")
            logger.debug("🔍 [PrerequisiteChecker] Checking source tree: \(sourceResourcesURL.path)")
            logger.debug("🔍 [PrerequisiteChecker] File exists: \(FileManager.default.fileExists(atPath: sourceResourcesURL.path))")
            if FileManager.default.fileExists(atPath: sourceResourcesURL.path) {
                logger.info("✅ [PrerequisiteChecker] Found in source tree: \(sourceResourcesURL.path)")
                return sourceResourcesURL
            }
        }
        
        logger.error("❌ [PrerequisiteChecker] Could not find resource: \(name)")
        return nil
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
    public func getKernelPath() throws -> URL {
        // Check common locations
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
        
        throw ContainerizationError(.notFound, message: "Linux kernel (vmlinux) not found. Please download from kata-containers or build one.")
    }
    
    /// Get the path to the init block file.
    public func getInitBlockPath() -> URL {
        workDir.appendingPathComponent("init.block")
    }
    
    /// Check if init block exists.
    public func initBlockExists() -> Bool {
        FileManager.default.fileExists(atPath: getInitBlockPath().path)
    }
}
