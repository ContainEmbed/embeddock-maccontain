//===----------------------------------------------------------------------===//
//
// Container File Operations Protocol
//
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - Container File Operations

/// Read, write, and inspect files and processes inside a running container.
@MainActor
public protocol ContainerFileOperations {

    /// Read the contents of a file inside the container.
    func readFile(_ path: String) async throws -> String

    /// Write content to a file inside the container.
    func writeFile(_ path: String, content: String) async throws

    /// List entries in a container directory.
    func listDirectory(_ path: String) async throws -> [String]

    /// Return the container's environment variables.
    func environment() async throws -> [String: String]

    /// Return a `ps`-style listing of running processes.
    func processes() async throws -> String

    /// Check whether a TCP port is listening inside the container.
    func isPortListening(_ port: Int) async throws -> Bool
}
