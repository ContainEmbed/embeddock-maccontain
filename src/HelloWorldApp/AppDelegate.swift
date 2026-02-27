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

    /// Cleanup closure set by `HelloWorldApp` once the SwiftUI view is ready.
    ///
    /// When called, the closure should stop any running container and then invoke
    /// its `completion` block.  `AppDelegate` uses this from both
    /// `applicationShouldTerminate(_:)` and the SIGTERM/SIGINT signal handlers so
    /// that cleanup runs regardless of *how* the app exits.
    var cleanupHandler: ((@escaping @Sendable () -> Void) -> Void)?

    // Active Dispatch signal sources — kept alive for the process lifetime.
    private var sigtermSource: DispatchSourceSignal?
    private var sigintSource: DispatchSourceSignal?

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
    ///   - viewModel: The container view model to use.
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
        registerSignalHandlers()
    }

    /// Ask macOS to wait while we perform container cleanup before quitting.
    ///
    /// Returns `.terminateNow` immediately if no container is running (or if
    /// no cleanup handler has been wired yet).  Otherwise returns `.terminateLater`
    /// and calls `NSApp.reply(toApplicationShouldTerminate: true)` once cleanup
    /// finishes, allowing macOS to proceed with the quit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let handler = cleanupHandler else {
            print("👋 [AppDelegate] No cleanup handler — terminating now")
            return .terminateNow
        }

        print("👋 [AppDelegate] Container cleanup requested before quit — deferring termination")
        handler {
            print("✅ [AppDelegate] Cleanup complete — replying to system")
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep app running even when window is closed (can reopen via dock)
        return false
    }

    // MARK: - Signal Handlers

    /// Register DispatchSource-based handlers for SIGTERM and SIGINT.
    ///
    /// These cover termination paths that bypass `applicationShouldTerminate`:
    /// - `kill -15 <pid>` from the terminal
    /// - System shutdown / logout
    /// - Ctrl+C when launched from a terminal
    ///
    /// SIGKILL cannot be caught — the run manifest on disk handles that case
    /// by letting the next app launch detect and clean up leftover resources.
    private func registerSignalHandlers() {
        // Prevent the default C-level handlers from firing (required before makeSignalSource)
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        let queue = DispatchQueue(label: "com.embeddock.signalhandler", qos: .userInitiated)

        sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        sigtermSource?.setEventHandler { [weak self] in
            print("🛑 [AppDelegate] Received SIGTERM — running cleanup")
            self?.handleSignalTermination(signalName: "SIGTERM")
        }
        sigtermSource?.resume()

        sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
        sigintSource?.setEventHandler { [weak self] in
            print("🛑 [AppDelegate] Received SIGINT — running cleanup")
            self?.handleSignalTermination(signalName: "SIGINT")
        }
        sigintSource?.resume()

        print("🔒 [AppDelegate] SIGTERM/SIGINT handlers registered")
    }

    /// Called from a DispatchSource signal handler.
    ///
    /// Invokes the cleanup closure and then calls `NSApp.terminate(nil)` so the
    /// normal macOS quit flow (and `applicationShouldTerminate`) takes over.
    /// If no cleanup handler is registered, terminates immediately.
    private func handleSignalTermination(signalName: String) {
        guard let handler = cleanupHandler else {
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        }

        handler {
            print("✅ [AppDelegate] \(signalName) cleanup complete — terminating")
            // terminateLater reply has likely already been sent; just force-exit
            // to be safe in case applicationShouldTerminate wasn't triggered.
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
