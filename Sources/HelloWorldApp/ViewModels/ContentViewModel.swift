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

// MARK: - Content View Model

/// ViewModel for the ContentView, managing UI state and user interactions.
@MainActor
class ContentViewModel: ObservableObject {
    // MARK: - Published State
    
    @Published var showSettings = false
    @Published var imageName = "node:20-alpine"
    @Published var port = "3000"
    @Published var apiResponse = ""
    @Published var isCheckingAPI = false
    @Published var commandInput = ""
    @Published var commandOutput = ""
    @Published var isExecutingCommand = false
    @Published var selectedTab = 0
    
    // MARK: - Initialization
    
    /// Initialize the container manager.
    func initializeContainerManager(_ containerManager: ContainerManager) async {
        do {
            print("🔧 [ContentViewModel] Initializing container manager...")
            try await containerManager.initialize()
            print("✅ [ContentViewModel] Container manager initialized successfully")
        } catch {
            print("❌ [ContentViewModel] Failed to initialize container manager: \(error)")
        }
    }
    
    // MARK: - Container Operations
    
    /// Open an OCI image file and start a container.
    func openAndStartContainer(_ containerManager: ContainerManager) {
        print("📂 [ContentViewModel] Open file action triggered")
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        
        // Create content types safely
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
            guard let self = self else { return }
            
            Task { @MainActor in
                print("📥 [ContentViewModel] File picker response: \(response == .OK ? "OK" : "Cancel")")
                if response == .OK, let url = panel.url {
                    print("✅ [ContentViewModel] File selected: \(url.path)")
                    do {
                        print("🚀 [ContentViewModel] Starting container from image file...")
                        try await containerManager.startContainerFromImage(
                            imageFile: url,
                            port: Int(self.port) ?? 3000
                        )
                        
                        print("⏳ [ContentViewModel] Waiting 2 seconds before opening browser...")
                        try await Task.sleep(for: .seconds(2))
                        if let urlToOpen = URL(string: "http://localhost:\(self.port)") {
                            print("🌐 [ContentViewModel] Opening browser: \(urlToOpen.absoluteString)")
                            NSWorkspace.shared.open(urlToOpen)
                        }
                        print("✅ [ContentViewModel] Container startup complete")
                    } catch {
                        print("❌ [ContentViewModel] Error: \(error)")
                        self.showError(error)
                    }
                }
            }
        }
    }
    
    /// Check the container's API endpoint.
    func checkContainerAPI(_ containerManager: ContainerManager) async {
        print("🌐 [ContentViewModel] Check API button clicked")
        isCheckingAPI = true
        apiResponse = ""
        
        do {
            let targetPort = Int(port) ?? 3000
            print("📡 [ContentViewModel] Checking API inside container on port \(targetPort)")
            
            let result = try await containerManager.checkContainerAPI(port: targetPort)
            
            let responseText = """
            ✅ Status: \(result.statusCode)
            📦 Response Body:
            \(result.body)
            """
            
            print("✅ [ContentViewModel] API Response: \(result.statusCode)")
            apiResponse = responseText
            
        } catch {
            print("❌ [ContentViewModel] API Error: \(error)")
            apiResponse = """
            ❌ Error:
            \(error.localizedDescription)
            
            Details: \(String(describing: error))
            """
        }
        
        isCheckingAPI = false
    }
    
    /// Stop the running container.
    func stopContainer(_ containerManager: ContainerManager) async {
        print("🛑 [ContentViewModel] Stop container button clicked")
        do {
            print("⏹️ [ContentViewModel] Stopping container...")
            try await containerManager.stopContainer()
            print("✅ [ContentViewModel] Container stopped successfully")
        } catch {
            print("❌ [ContentViewModel] Error stopping container: \(error)")
            showError(error)
        }
    }
    
    // MARK: - Command Execution
    
    /// Execute a command in the container.
    func executeCommand(_ containerManager: ContainerManager) async {
        guard !commandInput.isEmpty else { return }
        
        print("🖥️ [ContentViewModel] Executing command: \(commandInput)")
        isExecutingCommand = true
        
        do {
            // Parse the command into arguments
            let args = commandInput.components(separatedBy: " ").filter { !$0.isEmpty }
            let result = try await containerManager.executeCommand(args)
            
            let output = """
            $ \(commandInput)
            
            \(result.isSuccess ? result.stdoutString : "Error (exit code \(result.exitCode)):\n\(result.stderrString)")
            """
            
            commandOutput = output
            print("✅ [ContentViewModel] Command completed with exit code: \(result.exitCode)")
        } catch {
            commandOutput = "❌ Error: \(error.localizedDescription)"
            print("❌ [ContentViewModel] Command failed: \(error)")
        }
        
        isExecutingCommand = false
    }
    
    /// Browse a directory in the container.
    func browseDirectory(_ path: String, containerManager: ContainerManager) async {
        print("📂 [ContentViewModel] Browsing directory: \(path)")
        isExecutingCommand = true
        
        do {
            let files = try await containerManager.listContainerDirectory(path)
            commandOutput = """
            📁 Directory: \(path)
            
            \(files.joined(separator: "\n"))
            """
        } catch {
            commandOutput = "❌ Error browsing \(path): \(error.localizedDescription)"
        }
        
        isExecutingCommand = false
    }
    
    /// Show running processes in the container.
    func showProcesses(_ containerManager: ContainerManager) async {
        print("🔄 [ContentViewModel] Getting container processes")
        isExecutingCommand = true
        
        do {
            let processes = try await containerManager.getContainerProcesses()
            commandOutput = """
            🔄 Running Processes:
            
            \(processes)
            """
        } catch {
            commandOutput = "❌ Error: \(error.localizedDescription)"
        }
        
        isExecutingCommand = false
    }
    
    /// Retry port forwarding.
    func retryPortForwarding(_ containerManager: ContainerManager) async {
        do {
            let targetPort = UInt16(Int(port) ?? 3000)
            try await containerManager.startPortForwarding(hostPort: targetPort, containerPort: targetPort)
        } catch {
            print("❌ [ContentViewModel] Retry port forwarding failed: \(error)")
        }
    }
    
    // MARK: - Helpers
    
    private func showError(_ error: Error) {
        print("⚠️ [ContentViewModel] Showing error alert: \(error.localizedDescription)")
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.runModal()
    }
}
