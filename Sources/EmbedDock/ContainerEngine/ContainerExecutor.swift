//===----------------------------------------------------------------------===//
//
// Container Executor Protocol
//
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - Container Executor

/// Executes commands and HTTP requests inside a running container.
@MainActor
public protocol ContainerExecutor {

    /// Execute an arbitrary command inside the container.
    func execute(_ command: [String], workingDirectory: String?) async throws -> ExecResult

    /// Quick health-check: `curl`/`wget` inside the container on the given port.
    func checkAPI(port: Int) async throws -> (statusCode: Int, body: String)

    /// Send an HTTP request routed through the container communication layer.
    func httpRequest(
        method: String,
        path: String,
        body: Data?,
        headers: [String: String]
    ) async throws -> HTTPResponse
}
