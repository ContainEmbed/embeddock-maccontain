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
import ContainerizationError
import Logging

// MARK: - Container File System

/// Service for file operations inside the container.
///
/// Provides a clean interface for reading, writing, and managing files
/// inside the running container, abstracting away the exec-based implementation.
actor ContainerFileSystem {
    private let communicationManager: CommunicationManager
    private let logger: Logger
    
    init(communicationManager: CommunicationManager, logger: Logger) {
        self.communicationManager = communicationManager
        self.logger = logger
    }
    
    // MARK: - File Operations
    
    /// Read the contents of a file from the container.
    ///
    /// - Parameter path: Absolute path to the file inside the container.
    /// - Returns: The file contents as a string.
    /// - Throws: ContainerizationError if the file doesn't exist or can't be read.
    func readFile(_ path: String) async throws -> String {
        logger.debug("📖 [ContainerFileSystem] Reading file: \(path)")
        
        let result = try await communicationManager.exec(command: ["cat", path])
        
        guard result.isSuccess else {
            logger.error("❌ [ContainerFileSystem] Failed to read file: \(path)")
            throw ContainerizationError(.notFound, message: "File not found: \(path)")
        }
        
        return result.stdoutString
    }
    
    /// Write content to a file in the container.
    ///
    /// Creates parent directories if they don't exist.
    ///
    /// - Parameters:
    ///   - path: Absolute path to the file inside the container.
    ///   - content: The content to write.
    /// - Throws: ContainerizationError if the file can't be written.
    func writeFile(_ path: String, content: String) async throws {
        logger.debug("✏️ [ContainerFileSystem] Writing file: \(path)")
        
        // Escape single quotes in content
        let escapedContent = content.replacingOccurrences(of: "'", with: "'\\''")
        
        let result = try await communicationManager.exec(command: [
            "sh", "-c",
            "mkdir -p $(dirname '\(path)') && echo '\(escapedContent)' > '\(path)'"
        ])
        
        guard result.isSuccess else {
            logger.error("❌ [ContainerFileSystem] Failed to write file: \(result.stderrString)")
            throw ContainerizationError(.internalError, message: "Failed to write file: \(result.stderrString)")
        }
        
        logger.debug("✅ [ContainerFileSystem] File written: \(path)")
    }
    
    /// Append content to a file in the container.
    ///
    /// Creates the file if it doesn't exist.
    ///
    /// - Parameters:
    ///   - path: Absolute path to the file inside the container.
    ///   - content: The content to append.
    func appendFile(_ path: String, content: String) async throws {
        logger.debug("📝 [ContainerFileSystem] Appending to file: \(path)")
        
        let escapedContent = content.replacingOccurrences(of: "'", with: "'\\''")
        
        let result = try await communicationManager.exec(command: [
            "sh", "-c",
            "mkdir -p $(dirname '\(path)') && echo '\(escapedContent)' >> '\(path)'"
        ])
        
        guard result.isSuccess else {
            throw ContainerizationError(.internalError, message: "Failed to append to file: \(result.stderrString)")
        }
    }
    
    /// Delete a file from the container.
    ///
    /// - Parameter path: Absolute path to the file inside the container.
    /// - Throws: ContainerizationError if the file can't be deleted.
    func deleteFile(_ path: String) async throws {
        logger.debug("🗑️ [ContainerFileSystem] Deleting file: \(path)")
        
        let result = try await communicationManager.exec(command: ["rm", "-f", path])
        
        guard result.isSuccess else {
            throw ContainerizationError(.internalError, message: "Failed to delete file: \(result.stderrString)")
        }
    }
    
    /// Check if a file exists in the container.
    ///
    /// - Parameter path: Absolute path to the file inside the container.
    /// - Returns: True if the file exists.
    func fileExists(_ path: String) async throws -> Bool {
        let result = try await communicationManager.exec(command: ["test", "-f", path])
        return result.isSuccess
    }
    
    // MARK: - Directory Operations
    
    /// List files in a directory inside the container.
    ///
    /// - Parameter path: Absolute path to the directory.
    /// - Returns: Array of file entries (output of ls -la).
    func listDirectory(_ path: String) async throws -> [String] {
        logger.debug("📁 [ContainerFileSystem] Listing directory: \(path)")
        
        let result = try await communicationManager.exec(command: ["ls", "-la", path])
        
        guard result.isSuccess else {
            throw ContainerizationError(.notFound, message: "Directory not found: \(path)")
        }
        
        return result.stdoutString
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
    }
    
    /// List only file names in a directory (simple format).
    ///
    /// - Parameter path: Absolute path to the directory.
    /// - Returns: Array of file/directory names.
    func listFileNames(_ path: String) async throws -> [String] {
        let result = try await communicationManager.exec(command: ["ls", path])
        
        guard result.isSuccess else {
            throw ContainerizationError(.notFound, message: "Directory not found: \(path)")
        }
        
        return result.stdoutString
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
    }
    
    /// Create a directory in the container.
    ///
    /// Creates parent directories if needed.
    ///
    /// - Parameter path: Absolute path to the directory to create.
    func createDirectory(_ path: String) async throws {
        logger.debug("📂 [ContainerFileSystem] Creating directory: \(path)")
        
        let result = try await communicationManager.exec(command: ["mkdir", "-p", path])
        
        guard result.isSuccess else {
            throw ContainerizationError(.internalError, message: "Failed to create directory: \(result.stderrString)")
        }
    }
    
    /// Delete a directory from the container.
    ///
    /// - Parameters:
    ///   - path: Absolute path to the directory.
    ///   - recursive: If true, delete contents recursively.
    func deleteDirectory(_ path: String, recursive: Bool = false) async throws {
        logger.debug("🗑️ [ContainerFileSystem] Deleting directory: \(path)")
        
        let command = recursive ? ["rm", "-rf", path] : ["rmdir", path]
        let result = try await communicationManager.exec(command: command)
        
        guard result.isSuccess else {
            throw ContainerizationError(.internalError, message: "Failed to delete directory: \(result.stderrString)")
        }
    }
    
    /// Check if a directory exists in the container.
    ///
    /// - Parameter path: Absolute path to the directory.
    /// - Returns: True if the directory exists.
    func directoryExists(_ path: String) async throws -> Bool {
        let result = try await communicationManager.exec(command: ["test", "-d", path])
        return result.isSuccess
    }
    
    // MARK: - File Information
    
    /// Get file size in bytes.
    ///
    /// - Parameter path: Absolute path to the file.
    /// - Returns: File size in bytes.
    func fileSize(_ path: String) async throws -> Int64 {
        let result = try await communicationManager.exec(command: ["stat", "-c", "%s", path])
        
        guard result.isSuccess,
              let size = Int64(result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ContainerizationError(.notFound, message: "Cannot get file size: \(path)")
        }
        
        return size
    }
    
    /// Get file permissions (octal string).
    ///
    /// - Parameter path: Absolute path to the file.
    /// - Returns: Permissions as octal string (e.g., "755").
    func filePermissions(_ path: String) async throws -> String {
        let result = try await communicationManager.exec(command: ["stat", "-c", "%a", path])
        
        guard result.isSuccess else {
            throw ContainerizationError(.notFound, message: "Cannot get file permissions: \(path)")
        }
        
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Change file permissions.
    ///
    /// - Parameters:
    ///   - path: Absolute path to the file.
    ///   - mode: Permission mode (e.g., "755", "644").
    func chmod(_ path: String, mode: String) async throws {
        let result = try await communicationManager.exec(command: ["chmod", mode, path])
        
        guard result.isSuccess else {
            throw ContainerizationError(.internalError, message: "Failed to chmod: \(result.stderrString)")
        }
    }
}
