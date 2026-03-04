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
import ContainerizationError
import Logging

// MARK: - Image Loader

/// Service for loading OCI images from tar files.
///
/// Handles the extraction and import of OCI-format container images,
/// separating this concern from the orchestrator.
actor ImageLoader {
    private let imageStore: ImageStore
    private let workDir: URL
    private let logger: Logger
    
    init(imageStore: ImageStore, workDir: URL, logger: Logger) {
        self.imageStore = imageStore
        self.workDir = workDir
        self.logger = logger
    }
    
    // MARK: - Load from File
    
    /// Load an OCI image from a tar file.
    ///
    /// Extracts the tar file and imports it into the image store.
    ///
    /// - Parameters:
    ///   - imageFile: Path to the tar/tar.gz file.
    ///   - onProgress: Progress callback for UI updates.
    /// - Returns: The loaded container image.
    func loadFromFile(
        _ imageFile: URL,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> Containerization.Image {
        logger.info("📦 [ImageLoader] Loading image from: \(imageFile.lastPathComponent)")
        
        // Create temp directory for extraction
        let tempExtractDir = workDir.appendingPathComponent("temp-\(UUID().uuidString)")
        logger.debug("📂 [ImageLoader] Creating temp directory: \(tempExtractDir.path)")
        
        try FileManager.default.createDirectory(at: tempExtractDir, withIntermediateDirectories: true)
        
        defer {
            logger.debug("🧹 [ImageLoader] Cleaning up temp directory")
            try? FileManager.default.removeItem(at: tempExtractDir)
        }
        
        // Extract tar file
        onProgress?("Extracting OCI image...")
        try await extractTar(imageFile, to: tempExtractDir)
        
        // Import into image store
        onProgress?("Importing container image...")
        let image = try await importFromDirectory(tempExtractDir)
        
        logger.info("✅ [ImageLoader] Image loaded: \(image.reference)")
        return image
    }
    
    /// Load multiple OCI images from a directory.
    ///
    /// - Parameter directory: Directory containing OCI layout.
    /// - Returns: Array of loaded images.
    func loadFromDirectory(_ directory: URL) async throws -> [Containerization.Image] {
        logger.info("📦 [ImageLoader] Loading images from directory: \(directory.path)")
        
        let images = try await imageStore.load(from: directory)
        
        logger.info("✅ [ImageLoader] Loaded \(images.count) image(s)")
        return images
    }
    
    // MARK: - Private Helpers
    
    /// Extract a tar file to a directory.
    private func extractTar(_ tarFile: URL, to directory: URL) async throws {
        logger.info("📦 [ImageLoader] Extracting tar file using /usr/bin/tar")
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        
        // Detect compression based on file extension
        let isCompressed = tarFile.pathExtension == "gz" || tarFile.pathExtension == "tgz"
        process.arguments = isCompressed ?
            ["-xzf", tarFile.path, "-C", directory.path] :
            ["-xf", tarFile.path, "-C", directory.path]
        
        logger.debug("🔧 [ImageLoader] Running: tar \(process.arguments!.joined(separator: " "))")
        
        try process.run()
        process.waitUntilExit()
        
        logger.debug("📊 [ImageLoader] Tar process exit code: \(process.terminationStatus)")
        
        guard process.terminationStatus == 0 else {
            logger.error("❌ [ImageLoader] Tar extraction failed with code \(process.terminationStatus)")
            throw ContainerizationError(.internalError, message: "Failed to extract OCI image tar file")
        }
        
        logger.info("✅ [ImageLoader] Tar extraction complete")
    }
    
    /// Import an image from an extracted OCI layout directory.
    private func importFromDirectory(_ directory: URL) async throws -> Containerization.Image {
        let images = try await imageStore.load(from: directory)
        
        logger.debug("📋 [ImageLoader] Loaded \(images.count) image(s)")
        
        guard let image = images.first else {
            logger.error("❌ [ImageLoader] No valid OCI image found in tar file")
            throw ContainerizationError(.notFound, message: "No valid OCI image found in tar file")
        }
        
        return image
    }
}

// MARK: - Image Configuration Extractor

/// Extracts configuration from a container image.
struct ImageConfigExtractor {
    private let image: Containerization.Image
    private let platform: Platform
    
    init(image: Containerization.Image, platform: Platform) {
        self.image = image
        self.platform = platform
    }
    
    /// Extract the container configuration from the image.
    func extract() async throws -> ExtractedImageConfig {
        let config = try await image.config(for: platform)
        
        return ExtractedImageConfig(
            command: (config.config?.entrypoint ?? []) + (config.config?.cmd ?? ["/bin/sh"]),
            environment: config.config?.env ?? ["PATH=/usr/local/bin:/usr/bin:/bin"],
            workingDirectory: config.config?.workingDir ?? "/",
            labels: config.config?.labels ?? [:]
        )
    }
}

/// Extracted configuration from a container image.
struct ExtractedImageConfig {
    let command: [String]
    let environment: [String]
    let workingDirectory: String
    let labels: [String: String]
    
    /// Create environment with additional variables.
    func environmentWith(additional: [String]) -> [String] {
        environment + additional
    }
    
    /// Get a specific label value.
    func label(_ key: String) -> String? {
        labels[key]
    }
}
