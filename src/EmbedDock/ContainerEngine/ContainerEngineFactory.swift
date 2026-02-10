//===----------------------------------------------------------------------===//
//
// Container Engine Factory
//
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - Container Engine Factory

/// Creates `ContainerEngine` instances.
///
/// The app layer uses this factory so it never directly references the
/// concrete `DefaultContainerEngine`.  When the engine moves into a
/// separate library, the factory becomes the library's entry-point.
public enum ContainerEngineFactory {

    /// Create a new container engine with the default configuration.
    @MainActor
    public static func makeEngine() -> any ContainerEngine {
        DefaultContainerEngine()
    }
}
