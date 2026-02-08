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
import Containerization

// MARK: - Output Collector Helper

/// A thread-safe helper class to collect output from container processes.
///
/// Implements the `Writer` protocol to be used as stdout/stderr handlers
/// for container exec operations.
///
/// Example:
/// ```swift
/// let collector = OutputCollector()
/// try await pod.execInContainer("main", ..., stdout: collector)
/// let output = collector.getString()
/// ```
public final class OutputCollector: Writer, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    
    public init() {}
    
    /// Appends data to the internal buffer.
    public func write(_ data: Data) throws {
        lock.withLock {
            buffer.append(data)
        }
    }
    
    /// No-op close implementation.
    public func close() throws {
        // No-op - buffer is kept for retrieval
    }
    
    /// Returns the collected output as raw Data.
    public func getOutput() -> Data {
        lock.withLock {
            return buffer
        }
    }
    
    /// Returns the collected output as a UTF-8 string.
    public func getString() -> String {
        let data = getOutput()
        return String(data: data, encoding: .utf8) ?? ""
    }
    
    /// Returns the collected output as a trimmed UTF-8 string.
    public func getTrimmedString() -> String {
        getString().trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Clears the internal buffer.
    public func clear() {
        lock.withLock {
            buffer.removeAll()
        }
    }
    
    /// Returns the current size of the buffer in bytes.
    public var count: Int {
        lock.withLock {
            buffer.count
        }
    }
}
