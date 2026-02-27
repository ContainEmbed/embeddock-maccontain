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

// MARK: - Forwarding Status

/// Status of the port forwarding system.
///
/// Represents the current state of a port forwarding operation,
/// including active connection counts.
enum ForwardingStatus: Equatable, Sendable {
    /// Port forwarding is not active.
    case inactive

    /// Port forwarding is in the process of starting.
    case starting

    /// Port forwarding is active with the specified number of connections.
    case active(connections: Int)

    /// Port forwarding detected a failure and is recovering.
    case recovering(attempt: Int)

    /// An error occurred during port forwarding.
    case error(String)

    /// Whether port forwarding is currently active.
    var isActive: Bool {
        if case .active = self { return true }
        return false
    }

    /// A human-readable description of the status.
    var description: String {
        switch self {
        case .inactive:
            return "Inactive"
        case .starting:
            return "Starting..."
        case .active(let count):
            return "Active (\(count) connection\(count == 1 ? "" : "s"))"
        case .recovering(let attempt):
            return "Recovering (attempt \(attempt))..."
        case .error(let message):
            return "Error: \(message)"
        }
    }
}
