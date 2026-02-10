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
import ContainerizationOCI
import Containerization
import EmbedDock

// MARK: - Container View Model

/// The primary ViewModel for all container-related UI.
///
/// Owns a `ContainerEngine` instance (via protocol) and exposes all
/// container state as `@Published` properties for SwiftUI views.
/// Implements `ContainerEngineDelegate` to receive state updates
/// from the engine and translate them into UI-appropriate values.
///
/// Views should interact exclusively with this ViewModel — never
/// with the concrete engine implementation directly.
@MainActor
final class ContainerViewModel: ObservableObject {

    // MARK: - Container State (from delegate)

    @Published private(set) var status: ContainerStatus = .idle
    @Published private(set) var statusMessage: String = "Ready"
    @Published private(set) var containerURL: String?
    @Published private(set) var isCommunicationReady: Bool = false
    @Published private(set) var lastDiagnosticReport: DiagnosticReport?
    @Published private(set) var activeChannels: [CommunicationType] = []

    // MARK: - UI State

    @Published var showSettings = false
    @Published var imageName = "node:20-alpine"
    @Published var port = "3000"
    @Published var apiResponse = ""
    @Published var isCheckingAPI = false
    @Published var commandInput = ""
    @Published var commandOutput = ""
    @Published var isExecutingCommand = false
    @Published var selectedTab = 0

    // MARK: - Computed Properties

    /// True for any active state (initializing, running, stopping).
    var isRunning: Bool { status.isActive }
    var canStart: Bool { status.canStart }
    var canStop: Bool { status.canStop }

    var portForwardingDescription: String {
        status.forwardingState?.description ?? "Inactive"
    }

    var isPortForwardingActive: Bool {
        status.forwardingState?.isActive ?? false
    }

    /// The forwarding sub-state for status views.
    var forwardingState: ContainerStatus.ForwardingState {
        status.forwardingState ?? .inactive
    }

    var statusColor: Color {
        switch status {
        case .idle: return .gray
        case .initializing: return .yellow
        case .running(let health, _):
            return health == .healthy ? .green : .orange
        case .stopping: return .yellow
        case .failed: return .red
        }
    }

    var forwardingStatusColor: Color {
        guard let forwarding = status.forwardingState else { return .gray }
        switch forwarding {
        case .inactive: return .gray
        case .starting: return .yellow
        case .active: return .green
        case .error: return .red
        }
    }

    // MARK: - Private

    let engine: any ContainerEngine

    // MARK: - Initialization

    init(engine: (any ContainerEngine)? = nil) {
        self.engine = engine ?? ContainerEngineFactory.makeEngine()
        self.engine.delegate = self
    }

    // MARK: - Lifecycle

    func initialize() async {
        do {
            print("🔧 [ContainerViewModel] Initializing container engine...")
            try await engine.initialize()
            print("✅ [ContainerViewModel] Container engine initialized successfully")
        } catch {
            print("❌ [ContainerViewModel] Failed to initialize: \(error)")
        }
    }

    // MARK: - Container Operations

    func startContainerFromImage(imageFile: URL) async throws {
        let targetPort = Int(port) ?? 3000
        try await engine.startFromImage(imageFile: imageFile, port: targetPort)
    }

    func startNodeServer(jsFile: URL) async throws {
        let targetPort = Int(port) ?? 3000
        try await engine.startNodeServer(jsFile: jsFile, imageName: imageName, port: targetPort)
    }

    func stopContainer() async throws {
        try await engine.stop()
    }

    func executeCommand(_ command: [String], workingDirectory: String? = nil) async throws -> ExecResult {
        try await engine.execute(command, workingDirectory: workingDirectory)
    }

    func checkContainerAPI() async {
        isCheckingAPI = true
        apiResponse = ""

        do {
            let targetPort = Int(port) ?? 3000
            let result = try await engine.checkAPI(port: targetPort)
            apiResponse = """
            ✅ Status: \(result.statusCode)
            📦 Response Body:
            \(result.body)
            """
        } catch {
            apiResponse = """
            ❌ Error:
            \(error.localizedDescription)
            
            Details: \(String(describing: error))
            """
        }

        isCheckingAPI = false
    }

    func httpRequest(
        method: String = "GET",
        path: String = "/",
        body: Data? = nil,
        headers: [String: String] = [:]
    ) async throws -> HTTPResponse {
        try await engine.httpRequest(method: method, path: path, body: body, headers: headers)
    }

    func readContainerFile(_ path: String) async throws -> String {
        try await engine.readFile(path)
    }

    func writeContainerFile(_ path: String, content: String) async throws {
        try await engine.writeFile(path, content: content)
    }

    func listContainerDirectory(_ path: String) async throws -> [String] {
        try await engine.listDirectory(path)
    }

    func getContainerEnvironment() async throws -> [String: String] {
        try await engine.environment()
    }

    func getContainerProcesses() async throws -> String {
        try await engine.processes()
    }

    func isPortListening(_ port: Int) async throws -> Bool {
        try await engine.isPortListening(port)
    }

    // MARK: - Port Forwarding

    func startPortForwarding() async throws {
        let targetPort = UInt16(Int(port) ?? 3000)
        try await engine.startPortForwarding(
            hostPort: targetPort,
            containerPort: targetPort
        )
    }

    func stopPortForwarding() async {
        await engine.stopPortForwarding()
    }

    func retryPortForwarding() async {
        do {
            try await startPortForwarding()
        } catch {
            print("❌ [ContainerViewModel] Retry port forwarding failed: \(error)")
        }
    }

    // MARK: - Diagnostics

    func getSystemInfo() -> [String: String] {
        engine.systemInfo()
    }

    func readLogFile(name: String, lastLines: Int = 100) -> String? {
        engine.readLogFile(name: name, lastLines: lastLines)
    }

    func reprintLastDiagnosticReport() {
        engine.reprintLastDiagnosticReport()
    }

    // MARK: - Image Operations

    func pullNodeImage(reference: String, platform: Platform? = nil) async throws -> ContainerImage {
        try await engine.pullImage(reference: reference, platform: platform)
    }

    func prepareRootfs(from image: ContainerImage, platform: Platform) async throws -> URL {
        try await engine.prepareRootfs(from: image, platform: platform)
    }

    // MARK: - File Picker

    func openImageFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        var allowedTypes: [UTType] = []
        if let tarType = UTType(filenameExtension: "tar") {
            allowedTypes.append(tarType)
        }
        if let tgzType = UTType(filenameExtension: "tgz") {
            allowedTypes.append(tgzType)
        }
        allowedTypes.append(.gzip)

        panel.allowedContentTypes = allowedTypes
        panel.message = "Select an OCI container image (tar, tar.gz, or tgz)"

        panel.begin { [weak self] response in
            guard let self else { return }
            Task { @MainActor in
                if response == .OK, let url = panel.url {
                    do {
                        try await self.startContainerFromImage(imageFile: url)
                        try await Task.sleep(for: .seconds(2))
                        if let urlToOpen = URL(string: "http://localhost:\(self.port)") {
                            NSWorkspace.shared.open(urlToOpen)
                        }
                    } catch {
                        self.showError(error)
                    }
                }
            }
        }
    }

    // MARK: - Command Execution

    func executeCommandFromInput() async {
        guard !commandInput.isEmpty else { return }
        isExecutingCommand = true

        do {
            let args = commandInput.components(separatedBy: " ").filter { !$0.isEmpty }
            let result = try await executeCommand(args)
            commandOutput = """
            $ \(commandInput)
            
            \(result.isSuccess ? result.stdoutString : "Error (exit code \(result.exitCode)):\n\(result.stderrString)")
            """
        } catch {
            commandOutput = "❌ Error: \(error.localizedDescription)"
        }

        isExecutingCommand = false
    }

    func browseDirectory(_ path: String) async {
        isExecutingCommand = true
        do {
            let files = try await listContainerDirectory(path)
            commandOutput = """
            📁 Directory: \(path)
            
            \(files.joined(separator: "\n"))
            """
        } catch {
            commandOutput = "❌ Error browsing \(path): \(error.localizedDescription)"
        }
        isExecutingCommand = false
    }

    func showProcesses() async {
        isExecutingCommand = true
        do {
            let processes = try await getContainerProcesses()
            commandOutput = """
            🔄 Running Processes:
            
            \(processes)
            """
        } catch {
            commandOutput = "❌ Error: \(error.localizedDescription)"
        }
        isExecutingCommand = false
    }

    // MARK: - Helpers

    func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.runModal()
    }

    // MARK: - Status Message Derivation

    private func updateStatusMessage(for status: ContainerStatus) {
        switch status {
        case .idle:
            statusMessage = "Ready"
        case .initializing(let step):
            statusMessage = step.statusMessage
        case .running(let health, _):
            switch health {
            case .healthy:
                if let url = containerURL {
                    statusMessage = "✅ Container running at \(url)"
                } else {
                    statusMessage = "✅ Container running"
                }
            case .unhealthy(let reason):
                statusMessage = "⚠️ Container running but \(reason)"
            }
        case .stopping:
            statusMessage = "Stopping container..."
        case .failed(let error):
            statusMessage = "❌ Failed: \(error)"
        }
    }
}

// MARK: - ContainerEngineDelegate

extension ContainerViewModel: ContainerEngineDelegate {
    func engineDidUpdateState(_ engine: any ContainerEngine) {
        status = engine.status
        containerURL = engine.containerURL
        isCommunicationReady = engine.isCommunicationReady

        // Derive status message from status
        updateStatusMessage(for: engine.status)

        // Refresh communication channels
        if isCommunicationReady {
            Task { activeChannels = await engine.activeChannels() }
        } else {
            activeChannels = []
        }
    }

    func engine(_ engine: any ContainerEngine, didUpdateProgress message: String) {
        statusMessage = message
    }

    func engine(_ engine: any ContainerEngine, didProduceDiagnosticReport report: DiagnosticReport) {
        lastDiagnosticReport = report
    }
}
