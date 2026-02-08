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

// MARK: - Communication Errors

/// Errors that can occur during container communication.
public enum CommunicationError: Error, LocalizedError {
    /// The communication channel is not connected.
    case notConnected
    
    /// Failed to send message to container.
    case sendFailed
    
    /// Failed to receive response from container.
    case receiveFailed
    
    /// Communication timed out.
    case timeout
    
    /// Failed to setup communication channel.
    case setupFailed(String)
    
    /// Invalid response from container.
    case invalidResponse
    
    /// Unexpected response from container.
    case unexpectedResponse(String)
    
    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Communication channel is not connected"
        case .sendFailed:
            return "Failed to send message to container"
        case .receiveFailed:
            return "Failed to receive response from container"
        case .timeout:
            return "Communication timed out"
        case .setupFailed(let reason):
            return "Failed to setup communication: \(reason)"
        case .invalidResponse:
            return "Invalid response from container"
        case .unexpectedResponse(let message):
            return "Unexpected response: \(message)"
        }
    }
}
