//===----------------------------------------------------------------------===//
//
// Container Engine Delegate
//
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - Container Engine Delegate

/// Protocol for receiving state-change notifications from a `ContainerEngine`.
///
/// The presentation layer (e.g. `ContainerViewModel`) implements this
/// protocol to translate engine state into `@Published` UI properties.
@MainActor
public protocol ContainerEngineDelegate: AnyObject {

    /// Called whenever the engine's observable state changes
    /// (status, container URL, communication readiness).
    func engineDidUpdateState(_ engine: any ContainerEngine)

    /// Called with ephemeral progress messages during startup
    /// (e.g. "Step 3/10: Unpacking container image…").
    func engine(_ engine: any ContainerEngine, didUpdateProgress message: String)

    /// Called when a diagnostic report is produced after a failure.
    func engine(_ engine: any ContainerEngine, didProduceDiagnosticReport report: DiagnosticReport)

    /// Called on each resource monitoring collection cycle with the latest snapshot.
    func engine(_ engine: any ContainerEngine, didUpdateResourceSnapshot snapshot: ResourceSnapshot)

    /// Called when the active resource limits change (e.g., after start or restart with new limits).
    func engine(_ engine: any ContainerEngine, didUpdateResourceLimits limits: ContainerResourceLimits)
}

// MARK: - Default Implementations

public extension ContainerEngineDelegate {

    /// Default no-op so existing delegates are not broken.
    func engine(_ engine: any ContainerEngine, didUpdateResourceSnapshot snapshot: ResourceSnapshot) {}

    /// Default no-op so existing delegates are not broken.
    func engine(_ engine: any ContainerEngine, didUpdateResourceLimits limits: ContainerResourceLimits) {}
}
