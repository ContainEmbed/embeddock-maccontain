//===----------------------------------------------------------------------===//
//
// Container Image Managing Protocol
//
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - Container Image Managing

/// Pull images from registries and prepare root file-systems.
@MainActor
public protocol ContainerImageManaging {

    /// Pull a container image by reference (e.g. `node:20-alpine`).
    func pullImage(reference: String, platform: ContainerPlatform?) async throws -> ContainerImageRef

    /// Unpack an image into an EXT4 root filesystem ready for a VM.
    func prepareRootfs(from image: ContainerImageRef, platform: ContainerPlatform) async throws -> URL
}
