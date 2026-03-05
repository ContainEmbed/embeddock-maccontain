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

// MARK: - Resumable Once Helper

/// A thread-safe helper to ensure a continuation is only resumed once.
/// 
/// This is useful when working with async continuations where multiple
/// code paths might attempt to resume the same continuation.
///
/// Example:
/// ```swift
/// let once = ResumableOnce()
/// if once.tryResume() {
///     continuation.resume(returning: value)
/// }
/// ```
public final class ResumableOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var _hasResumed = false
    
    public init() {}
    
    /// Whether this instance has already been resumed.
    public var hasResumed: Bool {
        lock.withLock { _hasResumed }
    }
    
    /// Attempts to mark as resumed.
    /// - Returns: `true` if this was the first call, `false` if already resumed.
    public func tryResume() -> Bool {
        lock.withLock {
            if _hasResumed {
                return false
            }
            _hasResumed = true
            return true
        }
    }
    
    /// Resets the resumed state. Use with caution.
    public func reset() {
        lock.withLock {
            _hasResumed = false
        }
    }
}
