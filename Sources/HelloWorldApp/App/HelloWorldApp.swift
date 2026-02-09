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
    
    @StateObject private var viewModel: ContainerViewModel = {
        // Ensure logging is bootstrapped before ContainerManager is created
        LoggingBootstrap.initialize()
        return ContainerViewModel()
    }()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
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
                    viewModel.openImageFilePicker()
                }
                .keyboardShortcut("o", modifiers: .command)
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
                appDelegate.openJavaScriptFile(pendingURL, viewModel: viewModel)
                
            case "tar", "tgz", "gz":
                // OCI image file - start container
                do {
                    try await viewModel.startContainerFromImage(imageFile: pendingURL)
                    
                    try await Task.sleep(for: .seconds(2))
                    if let url = URL(string: "http://localhost:\(viewModel.port)") {
                        NSWorkspace.shared.open(url)
                    }
                } catch {
                    viewModel.showError(error)
                }
                
            default:
                print("⚠️ [App] Unsupported file type: \(ext)")
            }
        }
    }
}
