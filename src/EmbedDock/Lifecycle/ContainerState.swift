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

// MARK: - Container Status

/// Unified status enum representing the complete container lifecycle state,
/// including health and port forwarding sub-states.
///
/// Replaces the previous `ContainerState` + `ForwardingStatus` combination
/// with a single source of truth for all container state.
public enum ContainerStatus: Equatable, CustomStringConvertible {
    /// No container is running.
    case idle

    /// Container is being prepared (prerequisites, image extraction, VM boot).
    case initializing(step: StartupStep)

    /// Container is running with health and port-forwarding sub-states.
    case running(health: HealthState, forwarding: ForwardingState)

    /// Container is shutting down.
    case stopping

    /// Container failed to start or crashed.
    case failed(error: String)

    // MARK: Nested State Enums

    /// Health state of a running container.
    public enum HealthState: Equatable, CustomStringConvertible {
        case healthy
        case unhealthy(reason: String)

        public var description: String {
            switch self {
            case .healthy: return "Healthy"
            case .unhealthy(let reason): return "Unhealthy: \(reason)"
            }
        }
    }

    /// Port forwarding state of a running container.
    public enum ForwardingState: Equatable, CustomStringConvertible {
        case inactive
        case starting
        case active(connections: Int)
        case recovering(attempt: Int)
        case error(String)

        public var isActive: Bool {
            if case .active = self { return true }
            return false
        }

        public var description: String {
            switch self {
            case .inactive: return "Inactive"
            case .starting: return "Starting..."
            case .active(let count): return "Active (\(count) connection\(count == 1 ? "" : "s"))"
            case .recovering(let attempt): return "Recovering (attempt \(attempt))..."
            case .error(let msg): return "Error: \(msg)"
            }
        }
    }

    // MARK: Description

    public var description: String {
        switch self {
        case .idle: return "Idle"
        case .initializing(let step): return "Initializing: \(step)"
        case .running(let health, let forwarding): return "Running (\(health), forwarding: \(forwarding))"
        case .stopping: return "Stopping"
        case .failed(let error): return "Failed: \(error)"
        }
    }

    // MARK: Computed Properties

    /// Whether the container is in a running state (healthy or unhealthy).
    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    /// Whether the container is in a transitional state.
    public var isTransitioning: Bool {
        switch self {
        case .initializing, .stopping: return true
        default: return false
        }
    }

    /// Whether a new container can be started.
    public var canStart: Bool {
        switch self {
        case .idle, .failed: return true
        default: return false
        }
    }

    /// Whether the container can be stopped.
    public var canStop: Bool {
        switch self {
        case .running, .initializing: return true
        default: return false
        }
    }

    /// Whether the container is in an active state (can't start another).
    public var isActive: Bool { !canStart }

    /// The forwarding state, if running.
    public var forwardingState: ForwardingState? {
        if case .running(_, let forwarding) = self { return forwarding }
        return nil
    }

    /// The health state, if running.
    public var healthState: HealthState? {
        if case .running(let health, _) = self { return health }
        return nil
    }
}

// MARK: - Startup Steps

/// Represents the steps during container startup.
public enum StartupStep: Int, CustomStringConvertible, CaseIterable {
    case checkingPrerequisites = 0
    case extractingImage = 1
    case importingImage = 2
    case unpackingRootfs = 3
    case preparingInitfs = 4
    case loadingKernel = 5
    case creatingVMManager = 6
    case creatingPod = 7
    case configuringContainer = 8
    case addingContainer = 9
    case startingContainer = 10
    
    public var description: String {
        switch self {
        case .checkingPrerequisites: return "Checking prerequisites"
        case .extractingImage: return "Extracting OCI image"
        case .importingImage: return "Importing container image"
        case .unpackingRootfs: return "Unpacking container image"
        case .preparingInitfs: return "Preparing init filesystem"
        case .loadingKernel: return "Loading Linux kernel"
        case .creatingVMManager: return "Starting virtual machine"
        case .creatingPod: return "Creating container pod"
        case .configuringContainer: return "Configuring container"
        case .addingContainer: return "Adding container to pod"
        case .startingContainer: return "Starting container"
        }
    }
    
    /// Progress percentage (0.0 to 1.0).
    public var progress: Double {
        Double(rawValue) / Double(StartupStep.allCases.count - 1)
    }
    
    /// Status message with step number.
    public var statusMessage: String {
        "Step \(rawValue)/\(StartupStep.allCases.count - 1): \(description)..."
    }
}


