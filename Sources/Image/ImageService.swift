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
import ContainerizationError
import Logging

// MARK: - Image Service

/// Service responsible for pulling and preparing container images.
///
/// Handles:
/// - Pulling images from registries
/// - Unpacking images to EXT4 rootfs
/// - Caching and managing local images
actor ImageService {
    private let imageStore: ImageStore
    private let workDir: URL
    private let logger: Logger
    
    init(imageStore: ImageStore, workDir: URL, logger: Logger) {
        self.imageStore = imageStore
        self.workDir = workDir
        self.logger = logger
    }
    
    // MARK: - Image Pull
    
    /// Pull a container image from a registry.
    ///
    /// - Parameters:
    ///   - reference: The image reference (e.g., "docker.io/library/node:20-alpine")
    ///   - platform: Target platform (defaults to arm64/linux)
    ///   - onProgress: Progress callback for UI updates
    /// - Returns: The pulled image.
    func pullImage(
        reference: String,
        platform: Platform? = nil,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> Containerization.Image {
        onProgress?("Parsing reference: \(reference)")
        let ref = try Reference.parse(reference)
        ref.normalize()
        
        let normalizedReference = ref.description
        onProgress?("Pulling image: \(normalizedReference)")
        
        // Determine platform - default to current architecture
        let targetPlatform = platform ?? Platform(
            arch: "arm64",
            os: "linux"
        )
        
        // Check if image already exists
        if let existing = try? await imageStore.get(reference: normalizedReference) {
            onProgress?("Image already exists locally")
            return existing
        }
        
        // Pull from registry
        onProgress?("Downloading from registry...")
        let image = try await withAuthentication(ref: normalizedReference) { [imageStore] auth in
            return try await imageStore.pull(
                reference: normalizedReference,
                platform: targetPlatform,
                insecure: false,
                auth: auth
            )
        }
        
        guard let image = image else {
            throw ContainerizationError(.notFound, message: "Failed to pull image")
        }
        
        onProgress?("Image pulled successfully")
        return image
    }
    
    // MARK: - Rootfs Preparation
    
    /// Prepare an EXT4 rootfs from a container image.
    ///
    /// - Parameters:
    ///   - image: The container image to unpack.
    ///   - platform: Target platform.
    ///   - onProgress: Progress callback for UI updates.
    /// - Returns: URL to the EXT4 rootfs file.
    func prepareRootfs(
        from image: Containerization.Image,
        platform: Platform,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> URL {
        logger.debug("🏗️ [ImageService] Starting rootfs preparation")
        onProgress?("Preparing container rootfs...")
        
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HelloWorldApp-containers")
            .appendingPathComponent(UUID().uuidString)
        
        logger.debug("📂 [ImageService] Creating temp directory: \(tempDir.path)")
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )
        logger.debug("✅ [ImageService] Temp directory created")
        
        onProgress?("Unpacking image layers...")
        logger.debug("🔧 [ImageService] Creating EXT4 unpacker with 2 GiB block size")
        let unpacker = EXT4Unpacker(blockSizeInBytes: 2.gib())
        
        // Get manifest to determine image name
        logger.debug("📋 [ImageService] Getting image index")
        _ = try await image.index()
        let name = image.reference.split(separator: "/").last.map(String.init) ?? "container"
        logger.debug("🏷️ [ImageService] Image name: \(name)")
        
        let rootfsURL = tempDir.appendingPathComponent("\(name).ext4")
        logger.debug("📍 [ImageService] Rootfs will be created at: \(rootfsURL.path)")
        
        onProgress?("Creating EXT4 filesystem...")
        logger.info("📦 [ImageService] Unpacking image layers to EXT4...")
        let _ = try await unpacker.unpack(image, for: platform, at: rootfsURL)
        logger.info("✅ [ImageService] EXT4 filesystem created")
        
        onProgress?("Rootfs ready at: \(rootfsURL.path)")
        logger.info("✅ [ImageService] Rootfs preparation complete: \(rootfsURL.path)")
        return rootfsURL
    }
    
    // MARK: - Image Loading
    
    /// Load images from a directory (e.g., extracted OCI tar).
    func loadImages(from directory: URL) async throws -> [Containerization.Image] {
        try await imageStore.load(from: directory)
    }
    
    /// Get an image by reference.
    func getImage(reference: String) async throws -> Containerization.Image? {
        try await imageStore.get(reference: reference)
    }
    
    /// Get the init image for a given reference.
    func getInitImage(reference: String) async throws -> InitImage {
        try await imageStore.getInitImage(reference: reference)
    }
    
    // MARK: - Authentication
    
    private func withAuthentication<T>(
        ref: String,
        _ body: @Sendable @escaping (Authentication?) async throws -> T?
    ) async throws -> T? {
        let parsedRef = try Reference.parse(ref)
        guard let host = parsedRef.resolvedDomain else {
            return try await body(nil)
        }
        
        // Check environment variables first
        if let auth = authenticationFromEnv(host: host) {
            return try await body(auth)
        }
        
        // Check keychain
        let keychain = KeychainHelper(securityDomain: "com.example.HelloWorldApp")
        if let auth = try? keychain.lookup(hostname: host) {
            return try await body(auth)
        }
        
        return try await body(nil)
    }
    
    private func authenticationFromEnv(host: String) -> Authentication? {
        let env = ProcessInfo.processInfo.environment
        guard env["REGISTRY_HOST"] == host else { return nil }
        guard let user = env["REGISTRY_USERNAME"],
              let password = env["REGISTRY_TOKEN"] else { return nil }
        return BasicAuthentication(username: user, password: password)
    }
}
