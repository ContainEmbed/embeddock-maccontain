//===----------------------------------------------------------------------===//
//
// ContainerImageRef — Opaque wrapper hiding Containerization.Image
//
//===----------------------------------------------------------------------===//

import Containerization

/// An opaque reference to a pulled OCI container image.
///
/// Returned by `ContainerImageManaging.pullImage(reference:platform:)` and
/// consumed by `ContainerImageManaging.prepareRootfs(from:platform:)`.
/// Consumers of EmbedDock treat this as an opaque handle — no Containerization
/// import is required.
public struct ContainerImageRef: Sendable {
    internal let image: Containerization.Image

    internal init(_ image: Containerization.Image) {
        self.image = image
    }
}
