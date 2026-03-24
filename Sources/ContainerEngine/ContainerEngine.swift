//===----------------------------------------------------------------------===//
//
// Container Engine — Composed Protocol
//
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - Container Engine

/// The unified API surface for the container engine.
///
/// Composes all capability protocols into a single type that consumers
/// (such as `ContainerViewModel`) depend on.  The concrete implementation
/// is `DefaultContainerEngine`; consumers never reference it directly.
///
/// When this code is later extracted into a standalone library, this
/// protocol (and its sub-protocols) form the public API.
@MainActor
public protocol ContainerEngine:
    ContainerLifecycle,
    ContainerExecutor,
    ContainerFileOperations,
    ContainerNetworking,
    ContainerImageManaging,
    ContainerDiagnosing,
    ContainerResourceMonitoring,
    AnyObject
{
    /// Delegate for state-change callbacks.
    var delegate: ContainerEngineDelegate? { get set }
}
