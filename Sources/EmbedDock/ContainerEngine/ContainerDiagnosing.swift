//===----------------------------------------------------------------------===//
//
// Container Diagnosing Protocol
//
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - Container Diagnosing

/// Health diagnostics, system information, and log access.
@MainActor
public protocol ContainerDiagnosing {

    /// The last captured diagnostic report, if any.
    var lastDiagnosticReport: DiagnosticReport? { get }

    /// Host system information (macOS version, memory, CPU count).
    func systemInfo() -> [String: String]

    /// Read the tail of a log file from the container work directory.
    func readLogFile(name: String, lastLines: Int) -> String?

    /// Re-print the last diagnostic report to the logger.
    func reprintLastDiagnosticReport()
}
