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
import os.log

// Custom log handler that prints to stderr (visible in VS Code debug console)
// and also uses os_log for Xcode/Console.app visibility
struct DebugLogHandler: LogHandler {
    let label: String
    let osLog: OSLog
    
    var metadata: Logging.Logger.Metadata = [:]
    var logLevel: Logging.Logger.Level = .debug
    
    init(label: String) {
        self.label = label
        self.osLog = OSLog(subsystem: label, category: "app")
    }
    
    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }
    
    func log(level: Logging.Logger.Level, message: Logging.Logger.Message, metadata: Logging.Logger.Metadata?, source: String, file: String, function: String, line: UInt) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logMessage = "\(timestamp) [\(level)] [\(label)] \(message)"
        
        // Print to stderr - this shows in VS Code debug console
        fputs(logMessage + "\n", stderr)
        fflush(stderr)
        
        // Also log to os_log for Xcode/Console.app
        let osLogType: OSLogType
        switch level {
        case .trace, .debug: osLogType = .debug
        case .info, .notice: osLogType = .info
        case .warning: osLogType = .default
        case .error: osLogType = .error
        case .critical: osLogType = .fault
        }
        os_log("%{public}@", log: osLog, type: osLogType, "[\(level)] \(message)")
    }
}

// Bootstrap logging BEFORE any loggers are created
// This must happen at file scope to ensure it runs before @StateObject initialization
private let _bootstrapLogging: Void = {
    LoggingSystem.bootstrap { label in
        return DebugLogHandler(label: label)
    }
}()

@main
struct HelloWorldApp: App {
    @StateObject private var containerManager: ContainerManager = {
        // Ensure logging is bootstrapped before ContainerManager is created
        _ = _bootstrapLogging
        return ContainerManager()
    }()
    
    init() {
        // Logging already bootstrapped at file scope
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(containerManager)
                .onAppear {
                    print("🚀 [App] HelloWorldApp launched")
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
}

struct ContentView: View {
    @EnvironmentObject var containerManager: ContainerManager
    @State private var showSettings = false
    @State private var imageName = "node:20-alpine"
    @State private var port = "3000"
    @State private var apiResponse = ""
    @State private var isCheckingAPI = false
    @State private var commandInput = ""
    @State private var commandOutput = ""
    @State private var isExecutingCommand = false
    @State private var selectedTab = 0
    @FocusState private var isCommandFieldFocused: Bool
    
    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [Color.blue.opacity(0.1), Color.purple.opacity(0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: 20) {
                    // Header
                    VStack(spacing: 10) {
                        Image(systemName: "cube.box.fill")
                            .font(.system(size: 50))
                            .foregroundStyle(.blue)
                        
                        Text("Container Runtime")
                            .font(.system(size: 32, weight: .bold))
                        
                        Text("Run OCI-compliant containers on macOS")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 20)
                    
                    // Status Section
                    statusSection
                    
                    // Tab View for different features
                    if containerManager.isRunning {
                        Picker("", selection: $selectedTab) {
                            Text("Control").tag(0)
                            Text("Terminal").tag(1)
                            Text("Files").tag(2)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 40)
                        
                        switch selectedTab {
                        case 0:
                            controlSection
                        case 1:
                            terminalSection
                        case 2:
                            filesSection
                        default:
                            controlSection
                        }
                    } else {
                        controlSection
                    }
                    
                    Spacer(minLength: 20)
                    
                    // Footer
                    Text("Powered by Apple Containerization")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .padding(.bottom, 20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showSettings) {
            SettingsView(imageName: $imageName, port: $port)
        }
        .task {
            do {
                print("🔧 [ContentView] Initializing container manager...")
                try await containerManager.initialize()
                print("✅ [ContentView] Container manager initialized successfully")
            } catch {
                print("❌ [ContentView] Failed to initialize container manager: \(error)")
            }
        }
    }
    
    // MARK: - Status Section
    
    private var statusSection: some View {
        VStack(spacing: 15) {
            HStack {
                Circle()
                    .fill(containerManager.isRunning ? Color.green : Color.gray)
                    .frame(width: 12, height: 12)
                
                Text(containerManager.statusMessage)
                    .font(.system(size: 14, weight: .medium))
                
                Spacer()
                
                if containerManager.isCommunicationReady {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 8, height: 8)
                        Text("Connected")
                            .font(.system(size: 12))
                            .foregroundColor(.blue)
                    }
                }
            }
            .padding()
            .background(Color.white.opacity(0.8))
            .cornerRadius(10)
            
            // Port forwarding status
            if containerManager.isRunning {
                HStack {
                    portForwardingStatusView
                    Spacer()
                }
                .padding()
                .background(Color.white.opacity(0.8))
                .cornerRadius(10)
            }
            
            if let url = containerManager.containerURL {
                HStack {
                    Text("Container:")
                        .font(.system(size: 14, weight: .semibold))
                    
                    Text(url)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.blue)
                    
                    Spacer()
                    
                    if containerManager.portForwardingStatus.isActive {
                        Button(action: {
                            if let urlToOpen = URL(string: url) {
                                NSWorkspace.shared.open(urlToOpen)
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "globe")
                                Text("Open")
                            }
                            .font(.system(size: 12))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
                .background(Color.white.opacity(0.8))
                .cornerRadius(10)
            }
        }
        .padding(.horizontal, 40)
    }
    
    // MARK: - Port Forwarding Status View
    
    @ViewBuilder
    private var portForwardingStatusView: some View {
        HStack(spacing: 8) {
            // Status indicator
            Circle()
                .fill(portForwardingStatusColor)
                .frame(width: 10, height: 10)
            
            Text("Port Forwarding:")
                .font(.system(size: 12, weight: .semibold))
            
            Text(containerManager.portForwardingStatus.description)
                .font(.system(size: 12))
                .foregroundColor(portForwardingStatusColor)
            
            // Show retry button if there's an error
            if case .error = containerManager.portForwardingStatus {
                Button(action: retryPortForwarding) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(.blue)
            }
        }
    }
    
    private var portForwardingStatusColor: Color {
        switch containerManager.portForwardingStatus {
        case .inactive:
            return .gray
        case .starting:
            return .yellow
        case .active:
            return .green
        case .error:
            return .red
        }
    }
    
    private func retryPortForwarding() {
        Task { @MainActor in
            do {
                let targetPort = UInt16(Int(port) ?? 3000)
                try await containerManager.startPortForwarding(hostPort: targetPort, containerPort: targetPort)
            } catch {
                print("❌ [ContentView] Retry port forwarding failed: \(error)")
            }
        }
    }
    
    // MARK: - Control Section
    
    private var controlSection: some View {
        VStack(spacing: 15) {
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
            
            Button(action: startQuickDemo) {
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
                VStack(alignment: .leading, spacing: 8) {
                    Text("API Response:")
                        .font(.system(size: 14, weight: .semibold))
                    
                    ScrollView {
                        Text(apiResponse)
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
    
    // MARK: - Terminal Section
    
    private var terminalSection: some View {
        VStack(spacing: 15) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Execute Command in Container")
                    .font(.system(size: 14, weight: .semibold))
                
                HStack {
                    NSTextFieldWrapper(text: $commandInput, placeholder: "Enter command (e.g., ls -la, ps aux, env)", onSubmit: executeContainerCommand)
                        .frame(height: 28)
                    
                    Button(action: executeContainerCommand) {
                        Image(systemName: "play.fill")
                            .foregroundColor(.white)
                            .padding(8)
                            .background(isExecutingCommand ? Color.gray : Color.green)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isExecutingCommand || commandInput.isEmpty)
                }
                
                // Quick command buttons
                HStack(spacing: 8) {
                    quickCommandButton("ls -la", icon: "folder")
                    quickCommandButton("ps aux", icon: "list.bullet")
                    quickCommandButton("env", icon: "gearshape")
                    quickCommandButton("whoami", icon: "person")
                    quickCommandButton("df -h", icon: "internaldrive")
                }
                .font(.system(size: 11))
            }
            .padding()
            .background(Color.white.opacity(0.8))
            .cornerRadius(10)
            
            // Command output
            if !commandOutput.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Output:")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Button(action: { commandOutput = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.gray)
                        }
                        .buttonStyle(.plain)
                    }
                    
                    ScrollView {
                        Text(commandOutput)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                    .padding(8)
                    .background(Color.black.opacity(0.9))
                    .foregroundColor(.green)
                    .cornerRadius(8)
                }
                .padding()
                .background(Color.white.opacity(0.8))
                .cornerRadius(10)
            }
        }
        .padding(.horizontal, 40)
    }
    
    private func quickCommandButton(_ command: String, icon: String) -> some View {
        Button(action: {
            commandInput = command
            executeContainerCommand()
        }) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(command)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.blue.opacity(0.1))
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .disabled(isExecutingCommand)
    }
    
    // MARK: - Files Section
    
    private var filesSection: some View {
        VStack(spacing: 15) {
            // File operations
            VStack(alignment: .leading, spacing: 8) {
                Text("Container File System")
                    .font(.system(size: 14, weight: .semibold))
                
                HStack(spacing: 10) {
                    Button(action: { browseDirectory("/") }) {
                        HStack {
                            Image(systemName: "folder")
                            Text("Browse /")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: { browseDirectory("/app") }) {
                        HStack {
                            Image(systemName: "folder.badge.gearshape")
                            Text("Browse /app")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.purple)
                        .foregroundColor(.white)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: { browseDirectory("/tmp") }) {
                        HStack {
                            Image(systemName: "folder.badge.questionmark")
                            Text("Browse /tmp")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
                
                Button(action: showProcesses) {
                    HStack {
                        Image(systemName: "cpu")
                        Text("Show Running Processes")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.indigo)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .disabled(isExecutingCommand)
            }
            .padding()
            .background(Color.white.opacity(0.8))
            .cornerRadius(10)
            
            // Output display (reuse commandOutput)
            if !commandOutput.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Result:")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Button(action: { commandOutput = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.gray)
                        }
                        .buttonStyle(.plain)
                    }
                    
                    ScrollView {
                        Text(commandOutput)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                    .padding(8)
                    .background(Color.black.opacity(0.9))
                    .foregroundColor(.green)
                    .cornerRadius(8)
                }
                .padding()
                .background(Color.white.opacity(0.8))
                .cornerRadius(10)
            }
        }
        .padding(.horizontal, 40)
    }
    
    // MARK: - Actions
    
    private func executeContainerCommand() {
        guard !commandInput.isEmpty else { return }
        
        print("🖥️ [ContentView] Executing command: \(commandInput)")
        isExecutingCommand = true
        
        Task { @MainActor in
            do {
                // Parse the command into arguments
                let args = commandInput.components(separatedBy: " ").filter { !$0.isEmpty }
                let result = try await containerManager.executeCommand(args)
                
                let output = """
                $ \(commandInput)
                
                \(result.isSuccess ? result.stdoutString : "Error (exit code \(result.exitCode)):\n\(result.stderrString)")
                """
                
                commandOutput = output
                print("✅ [ContentView] Command completed with exit code: \(result.exitCode)")
            } catch {
                commandOutput = "❌ Error: \(error.localizedDescription)"
                print("❌ [ContentView] Command failed: \(error)")
            }
            
            isExecutingCommand = false
        }
    }
    
    private func browseDirectory(_ path: String) {
        print("📂 [ContentView] Browsing directory: \(path)")
        isExecutingCommand = true
        
        Task { @MainActor in
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
    }
    
    private func showProcesses() {
        print("🔄 [ContentView] Getting container processes")
        isExecutingCommand = true
        
        Task { @MainActor in
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
    }
    
    private func openFile() {
        print("📂 [ContentView] Open file action triggered")
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
        
        panel.begin { response in
            Task { @MainActor in
                print("📥 [ContentView] File picker response: \(response == .OK ? "OK" : "Cancel")")
                if response == .OK, let url = panel.url {
                    print("✅ [ContentView] File selected: \(url.path)")
                    do {
                        print("🚀 [ContentView] Starting container from image file...")
                        try await containerManager.startContainerFromImage(
                            imageFile: url,
                            port: Int(port) ?? 3000
                        )
                        
                        print("⏳ [ContentView] Waiting 2 seconds before opening browser...")
                        try await Task.sleep(for: .seconds(2))
                        if let urlToOpen = URL(string: "http://localhost:\(port)") {
                            print("🌐 [ContentView] Opening browser: \(urlToOpen.absoluteString)")
                            NSWorkspace.shared.open(urlToOpen)
                        }
                        print("✅ [ContentView] Container startup complete")
                    } catch {
                        print("❌ [ContentView] Error: \(error)")
                        showError(error)
                    }
                }
            }
        }
    }
    
    private func startQuickDemo() {
        print("🌐 [ContentView] Check API button clicked")
        isCheckingAPI = true
        apiResponse = ""
        
        Task { @MainActor in
            do {
                let targetPort = Int(port) ?? 3000
                
                print("📡 [ContentView] Checking API inside container on port \(targetPort)")
                
                // Use ContainerManager to execute curl inside the VM
                let result = try await containerManager.checkContainerAPI(port: targetPort)
                
                let responseText = """
                ✅ Status: \(result.statusCode)
                📦 Response Body:
                \(result.body)
                """
                
                print("✅ [ContentView] API Response: \(result.statusCode)")
                apiResponse = responseText
                
            } catch {
                print("❌ [ContentView] API Error: \(error)")
                print("❌ [ContentView] Error type: \(type(of: error))")
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
        print("🛑 [ContentView] Stop container button clicked")
        Task { @MainActor in
            do {
                print("⏹️ [ContentView] Stopping container...")
                try await containerManager.stopContainer()
                print("✅ [ContentView] Container stopped successfully")
            } catch {
                print("❌ [ContentView] Error stopping container: \(error)")
                showError(error)
            }
        }
    }
    
    private func showError(_ error: Error) {
        print("⚠️ [ContentView] Showing error alert: \(error.localizedDescription)")
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.runModal()
    }
}

struct SettingsView: View {
    @Binding var imageName: String
    @Binding var port: String
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Settings")
                .font(.title)
                .padding(.top)
            
            Form {
                TextField("Container Image", text: $imageName)
                    .textFieldStyle(.roundedBorder)
                
                TextField("Port", text: $port)
                    .textFieldStyle(.roundedBorder)
            }
            .padding()
            
            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .padding(.bottom)
        }
        .frame(width: 400, height: 250)
    }
}

// MARK: - NSTextField Wrapper for proper macOS text input

struct NSTextFieldWrapper: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void
    
    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.placeholderString = placeholder
        textField.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        textField.delegate = context.coordinator
        textField.bezelStyle = .roundedBezel
        textField.focusRingType = .exterior
        return textField
    }
    
    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NSTextFieldWrapper
        
        init(_ parent: NSTextFieldWrapper) {
            self.parent = parent
        }
        
        func controlTextDidChange(_ obj: Notification) {
            if let textField = obj.object as? NSTextField {
                parent.text = textField.stringValue
            }
        }
        
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}
