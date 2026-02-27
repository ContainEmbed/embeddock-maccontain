//===----------------------------------------------------------------------===//
//
// Container Image Managing Protocol
//
//===----------------------------------------------------------------------===//

import Foundation
import Containerization
import ContainerizationOCI

// MARK: - Shared Type Aliases

/// An OCI container image from the Containerization framework.
public typealias ContainerImage = Containerization.Image

// MARK: - Container Image Managing

/// Pull images from registries and prepare root file-systems.
@MainActor
public protocol ContainerImageManaging {

    /// Pull a container image by reference (e.g. `node:20-alpine`).
    func pullImage(reference: String, platform: Platform?) async throws -> ContainerImage

    /// Unpack an image into an EXT4 root filesystem ready for a VM.
    func prepareRootfs(from image: ContainerImage, platform: Platform) async throws -> URL
}
