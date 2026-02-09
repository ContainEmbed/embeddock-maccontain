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

import AppKit
import SwiftUI

/// Application delegate for handling system-level events.
///
/// Handles file opening events (drag-drop, double-click) and application lifecycle.
/// Connected to SwiftUI via `@NSApplicationDelegateAdaptor` in `HelloWorldApp`.
class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    
    /// URL of a file that was opened before the app was fully ready.
    /// This is processed by `HelloWorldApp.handlePendingFile()` once the main view appears.
    var pendingFileURL: URL?
    
    /// Supported file extensions for container operations.
    private static let supportedExtensions: Set<String> = ["js", "tar", "tgz", "gz"]
    
    // MARK: - File Opening
    
    /// Handle file opened via Finder (double-click or drag-drop to dock icon).
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        let ext = url.pathExtension.lowercased()
        
        guard Self.supportedExtensions.contains(ext) else {
            print("⚠️ [AppDelegate] Unsupported file type: \(ext)")
            return false
        }
        
        print("📂 [AppDelegate] File opened: \(filename)")
        
        // Store for later processing once the SwiftUI view is ready
        pendingFileURL = url
        return true
    }
    
    /// Handle multiple files opened at once.
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        // Only process the first file
        if let first = filenames.first {
            _ = application(sender, openFile: first)
        }
        sender.reply(toOpenOrPrint: .success)
    }
    
    // MARK: - JavaScript File Handler
    
    /// Start a Node.js container with the given JavaScript file.
    /// - Parameters:
    ///   - url: The JavaScript file URL to run.
    ///   - containerManager: The container manager to use.
    func openJavaScriptFile(_ url: URL, viewModel: ContainerViewModel) {
        Task { @MainActor in
            do {
                print("🟢 [AppDelegate] Starting Node.js container with: \(url.lastPathComponent)")
                
                try await viewModel.startNodeServer(jsFile: url)
                
                // Open browser after a short delay to let server start
                try await Task.sleep(for: .seconds(2))
                if let urlToOpen = URL(string: "http://localhost:3000") {
                    NSWorkspace.shared.open(urlToOpen)
                }
                
                print("✅ [AppDelegate] Node.js container started successfully")
            } catch {
                print("❌ [AppDelegate] Failed to start container: \(error)")
                
                let alert = NSAlert()
                alert.messageText = "Failed to start Node.js container"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .critical
                alert.runModal()
            }
        }
    }
    
    // MARK: - Application Lifecycle
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 [AppDelegate] Application did finish launching")
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        print("👋 [AppDelegate] Application will terminate")
        // Container cleanup is handled by ContainerOrchestrator's deinit/cleanup
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep app running even when window is closed (can reopen via dock)
        return false
    }
}
