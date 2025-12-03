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

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        guard url.pathExtension == "js" else { return false }
        
        // We need the container manager from the scene, but this is called before it's available
        // Store the URL and handle it later
        pendingFileURL = url
        return true
    }
    
    var pendingFileURL: URL?
    
    func openJavaScriptFile(_ url: URL, containerManager: ContainerManager) {
        Task { @MainActor in
            do {
                try await containerManager.startNodeServer(
                    jsFile: url,
                    imageName: "node:20-alpine",
                    port: 3000
                )
                
                // Open browser after a short delay to let server start
                try await Task.sleep(for: .seconds(2))
                if let urlToOpen = URL(string: "http://localhost:3000") {
                    NSWorkspace.shared.open(urlToOpen)
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = "Failed to start container"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .critical
                alert.runModal()
            }
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Container cleanup handled by the manager's deinit
    }
}
