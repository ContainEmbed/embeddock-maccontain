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
import Logging

// Import logging bootstrap from Logging module
// Note: LoggingBootstrap.setup() is called in the App init

@main
struct HelloWorldApp: App {
    /// Connect AppDelegate to handle application lifecycle events.
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    @StateObject private var containerManager: ContainerManager = {
        // Ensure logging is bootstrapped before ContainerManager is created
        LoggingBootstrap.initialize()
        return ContainerManager()
    }()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(containerManager)
                .onAppear {
                    print("🚀 [App] HelloWorldApp launched")
                    // Handle pending file opened before app was ready
                    handlePendingFile()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open OCI Image...") {
                    print("📂 [App] Open OCI Image button clicked")
                    openFile()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
    
    private func openFile() {
        print("🔍 [App] Opening file picker dialog")
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        
        // Create content types safely - some may not exist
        var allowedTypes: [UTType] = []
        if let tarType = UTType(filenameExtension: "tar") {
            allowedTypes.append(tarType)
        }
        if let tgzType = UTType(filenameExtension: "tgz") {
            allowedTypes.append(tgzType)
        }
        // Add gzip type which covers .gz files
        allowedTypes.append(.gzip)
        
        panel.allowedContentTypes = allowedTypes
        panel.message = "Select an OCI container image (tar, tar.gz, or tgz)"
        
        print("📋 [App] File picker configured with types: \(allowedTypes.map { $0.identifier })")
        
        panel.begin { response in
            Task { @MainActor in
                print("📥 [App] File picker response: \(response == .OK ? "OK" : "Cancel")")
                if response == .OK, let url = panel.url {
                    print("✅ [App] File selected: \(url.path)")
                    let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                    print("📊 [App] File size: \(fileSize) bytes")
                    do {
                        print("🚀 [App] Starting container from image...")
                        try await containerManager.startContainerFromImage(
                            imageFile: url,
                            port: 3000
                        )
                        
                        print("⏳ [App] Waiting 2 seconds before opening browser...")
                        try await Task.sleep(for: .seconds(2))
                        if let urlToOpen = URL(string: "http://localhost:3000") {
                            print("🌐 [App] Opening browser: \(urlToOpen.absoluteString)")
                            NSWorkspace.shared.open(urlToOpen)
                        }
                        print("✅ [App] Container startup sequence complete")
                    } catch {
                        print("❌ [App] Error starting container: \(error)")
                        let alert = NSAlert()
                        alert.messageText = "Failed to start container"
                        alert.informativeText = error.localizedDescription
                        alert.alertStyle = .critical
                        alert.runModal()
                    }
                }
            }
        }
    }
    
    /// Handle pending file that was opened before the app was fully ready.
    private func handlePendingFile() {
        guard let pendingURL = appDelegate.pendingFileURL else { return }
        
        print("📂 [App] Handling pending file: \(pendingURL.path)")
        appDelegate.pendingFileURL = nil // Clear so we don't process again
        
        Task { @MainActor in
            // Handle based on file extension
            let ext = pendingURL.pathExtension.lowercased()
            
            switch ext {
            case "js":
                // JavaScript file - start Node.js container
                appDelegate.openJavaScriptFile(pendingURL, containerManager: containerManager)
                
            case "tar", "tgz", "gz":
                // OCI image file - start container
                do {
                    try await containerManager.startContainerFromImage(
                        imageFile: pendingURL,
                        port: 3000
                    )
                    
                    try await Task.sleep(for: .seconds(2))
                    if let url = URL(string: "http://localhost:3000") {
                        NSWorkspace.shared.open(url)
                    }
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "Failed to start container"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .critical
                    alert.runModal()
                }
                
            default:
                print("⚠️ [App] Unsupported file type: \(ext)")
            }
        }
    }
}
