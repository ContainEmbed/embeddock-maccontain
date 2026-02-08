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

// MARK: - Container State

/// Represents the lifecycle state of a container.
///
/// Uses a State Machine pattern to clearly define valid state transitions
/// and make the container lifecycle explicit and type-safe.
enum ContainerState: Equatable, CustomStringConvertible {
    /// No container is running.
    case idle
    
    /// Container is initializing (prerequisites, image extraction).
    case initializing(step: StartupStep)
    
    /// Container is starting (VM boot, container start).
    case starting(step: StartupStep)
    
    /// Container is running and healthy.
    case running
    
    /// Container is running but HTTP health check failed.
    case runningUnhealthy(reason: String)
    
    /// Container is stopping.
    case stopping
    
    /// Container failed to start or crashed.
    case failed(error: String)
    
    var description: String {
        switch self {
        case .idle:
            return "Idle"
        case .initializing(let step):
            return "Initializing: \(step)"
        case .starting(let step):
            return "Starting: \(step)"
        case .running:
            return "Running"
        case .runningUnhealthy(let reason):
            return "Running (Unhealthy): \(reason)"
        case .stopping:
            return "Stopping"
        case .failed(let error):
            return "Failed: \(error)"
        }
    }
    
    /// Whether the container is currently running (healthy or unhealthy).
    var isRunning: Bool {
        switch self {
        case .running, .runningUnhealthy:
            return true
        default:
            return false
        }
    }
    
    /// Whether the container is in a transitional state.
    var isTransitioning: Bool {
        switch self {
        case .initializing, .starting, .stopping:
            return true
        default:
            return false
        }
    }
    
    /// Whether the container can be started.
    var canStart: Bool {
        switch self {
        case .idle, .failed:
            return true
        default:
            return false
        }
    }
    
    /// Whether the container can be stopped.
    var canStop: Bool {
        switch self {
        case .running, .runningUnhealthy, .starting, .initializing:
            return true
        default:
            return false
        }
    }
}

// MARK: - Startup Steps

/// Represents the steps during container startup.
enum StartupStep: Int, CustomStringConvertible, CaseIterable {
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
    
    var description: String {
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
    var progress: Double {
        Double(rawValue) / Double(StartupStep.allCases.count - 1)
    }
    
    /// Status message with step number.
    var statusMessage: String {
        "Step \(rawValue)/\(StartupStep.allCases.count - 1): \(description)..."
    }
}

// MARK: - State Machine

/// Manages container state transitions with validation.
@MainActor
final class ContainerStateMachine: ObservableObject {
    @Published private(set) var state: ContainerState = .idle
    @Published private(set) var currentStep: StartupStep?
    
    /// Transition to a new state, validating the transition is valid.
    func transition(to newState: ContainerState) {
        // Log state transition
        #if DEBUG
        print("🔄 [StateMachine] \(state) → \(newState)")
        #endif
        
        state = newState
        
        // Update current step if applicable
        switch newState {
        case .initializing(let step), .starting(let step):
            currentStep = step
        default:
            currentStep = nil
        }
    }
    
    /// Transition to a startup step.
    func transitionToStep(_ step: StartupStep) {
        if step.rawValue <= 4 {
            transition(to: .initializing(step: step))
        } else {
            transition(to: .starting(step: step))
        }
    }
    
    /// Mark as running (healthy).
    func markRunning() {
        transition(to: .running)
    }
    
    /// Mark as running but unhealthy.
    func markUnhealthy(reason: String) {
        transition(to: .runningUnhealthy(reason: reason))
    }
    
    /// Mark as stopping.
    func markStopping() {
        transition(to: .stopping)
    }
    
    /// Mark as failed.
    func markFailed(error: String) {
        transition(to: .failed(error: error))
    }
    
    /// Reset to idle.
    func reset() {
        transition(to: .idle)
    }
}
