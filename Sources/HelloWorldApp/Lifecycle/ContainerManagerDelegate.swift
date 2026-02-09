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

// MARK: - Container Manager Delegate

/// Protocol for receiving state change notifications from ContainerManager.
///
/// Cleanly separates the business logic (ContainerManager) from the
/// presentation layer (ContainerViewModel). The manager calls these methods
/// when its observable state changes, and the ViewModel updates its
/// `@Published` properties accordingly.
@MainActor
protocol ContainerManagerDelegate: AnyObject {
    /// Called whenever the container's observable state changes
    /// (status, container URL, communication readiness).
    ///
    /// The delegate should read the manager's current properties
    /// (`status`, `containerURL`, `isCommunicationReady`) to update the UI.
    func containerManagerDidUpdate(_ manager: ContainerManager)

    /// Called with ephemeral progress messages during startup
    /// (e.g., "Step 3/10: Unpacking container image...").
    func containerManager(_ manager: ContainerManager, didUpdateProgress message: String)

    /// Called when a diagnostic report is produced after a failure.
    func containerManager(_ manager: ContainerManager, didProduceDiagnosticReport report: DiagnosticReport)
}
