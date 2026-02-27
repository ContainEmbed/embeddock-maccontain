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
import Logging
import os.log

// MARK: - Debug Log Handler

/// Custom log handler that outputs to both stderr (for VS Code debug console)
/// and os_log (for Xcode/Console.app).
///
/// This handler ensures logs are visible in all development environments:
/// - VS Code: Uses `fputs` to stderr which is captured by the debug console
/// - Xcode: Uses `os_log` which integrates with the system logging
/// - Console.app: Also visible via `os_log`
///
/// Usage:
/// ```swift
/// LoggingBootstrap.initialize()
/// let logger = Logger(label: "com.example.myapp")
/// logger.info("Hello, world!")
/// ```
public struct DebugLogHandler: LogHandler {
    public let label: String
    private let osLog: OSLog
    
    public var metadata: Logging.Logger.Metadata = [:]
    public var logLevel: Logging.Logger.Level = .debug
    
    public init(label: String) {
        self.label = label
        self.osLog = OSLog(subsystem: label, category: "app")
    }
    
    public subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }
    
    public func log(
        level: Logging.Logger.Level,
        message: Logging.Logger.Message,
        metadata: Logging.Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logMessage = "\(timestamp) [\(level)] [\(label)] \(message)"
        
        // Print to stderr - this shows in VS Code debug console
        fputs(logMessage + "\n", stderr)
        fflush(stderr)
        
        // Also log to os_log for Xcode/Console.app
        let osLogType: OSLogType
        switch level {
        case .trace, .debug: osLogType = .debug
        case .info, .notice: osLogType = .info
        case .warning: osLogType = .default
        case .error: osLogType = .error
        case .critical: osLogType = .fault
        }
        os_log("%{public}@", log: osLog, type: osLogType, "[\(level)] \(message)")
    }
}

// MARK: - Logging Bootstrap

/// Centralized logging initialization.
///
/// Call `LoggingBootstrap.initialize()` at app startup before creating any loggers.
public enum LoggingBootstrap {
    nonisolated(unsafe) private static var isInitialized = false
    
    /// Initializes the logging system with `DebugLogHandler`.
    /// Safe to call multiple times - only the first call has effect.
    public static func initialize() {
        guard !isInitialized else { return }
        isInitialized = true
        
        LoggingSystem.bootstrap { label in
            return DebugLogHandler(label: label)
        }
    }
}

// MARK: - File-scope Bootstrap (Legacy Support)

/// Bootstrap logging at file scope to ensure it runs before @StateObject initialization.
/// This is accessed by main.swift to trigger early initialization.
public let bootstrapLogging: Void = {
    LoggingBootstrap.initialize()
}()
