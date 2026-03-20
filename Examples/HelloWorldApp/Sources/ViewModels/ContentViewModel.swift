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

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Content View Model (Deprecated)

/// Deprecated: This ViewModel has been replaced by `ContainerViewModel`.
///
/// All UI state and container operations are now managed by `ContainerViewModel`,
/// which owns the `ContainerManager` privately and receives state updates via
/// the `ContainerManagerDelegate` protocol.
///
/// This file is retained for reference only and can be safely deleted.
@available(*, deprecated, message: "Use ContainerViewModel instead")
@MainActor
class ContentViewModel: ObservableObject {}
