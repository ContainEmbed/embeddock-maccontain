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

// MARK: - Control Section

/// Main control section with buttons for container operations.
struct ControlSection: View {
    @ObservedObject var containerManager: ContainerManager
    @Binding var port: String
    @Binding var apiResponse: String
    @Binding var isCheckingAPI: Bool
    @Binding var showSettings: Bool
    
    var body: some View {
        VStack(spacing: 15) {
            // Open OCI Image button
            Button(action: openFile) {
                HStack {
                    Image(systemName: "cube.box")
                    Text("Open OCI Image")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .disabled(containerManager.isRunning)
            
            // Check API button
            Button(action: checkAPI) {
                HStack {
                    Image(systemName: "network")
                    Text("Check API")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(containerManager.isRunning ? Color.green : Color.gray)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .disabled(!containerManager.isRunning || isCheckingAPI)
            
            // API Response Display
            if !apiResponse.isEmpty {
                APIResponseView(response: apiResponse)
            }
            
            // Stop Container button
            if containerManager.isRunning {
                Button(action: stopContainer) {
                    HStack {
                        Image(systemName: "stop.fill")
                        Text("Stop Container")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.red)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
            }
            
            // Settings button
            Button(action: { showSettings.toggle() }) {
                HStack {
                    Image(systemName: "gear")
                    Text("Settings")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.gray.opacity(0.3))
                .foregroundColor(.primary)
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 40)
    }
    
    // MARK: - Actions
    
    private func openFile() {
        print("📂 [ControlSection] Open file action triggered")
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
        
        panel.begin { response in
            Task { @MainActor in
                if response == .OK, let url = panel.url {
                    do {
                        try await containerManager.startContainerFromImage(
                            imageFile: url,
                            port: Int(port) ?? 3000
                        )
                        
                        try await Task.sleep(for: .seconds(2))
                        if let urlToOpen = URL(string: "http://localhost:\(port)") {
                            NSWorkspace.shared.open(urlToOpen)
                        }
                    } catch {
                        showError(error)
                    }
                }
            }
        }
    }
    
    private func checkAPI() {
        print("🌐 [ControlSection] Check API button clicked")
        isCheckingAPI = true
        apiResponse = ""
        
        Task { @MainActor in
            do {
                let targetPort = Int(port) ?? 3000
                let result = try await containerManager.checkContainerAPI(port: targetPort)
                
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
    }
    
    private func stopContainer() {
        print("🛑 [ControlSection] Stop container button clicked")
        Task { @MainActor in
            do {
                try await containerManager.stopContainer()
            } catch {
                showError(error)
            }
        }
    }
    
    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.runModal()
    }
}

// MARK: - API Response View

/// Displays the API response in a scrollable text area.
struct APIResponseView: View {
    let response: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("API Response:")
                .font(.system(size: 14, weight: .semibold))
            
            ScrollView {
                Text(response)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
            .padding(8)
            .background(Color.black.opacity(0.05))
            .cornerRadius(8)
        }
        .padding()
        .background(Color.white.opacity(0.8))
        .cornerRadius(10)
    }
}
