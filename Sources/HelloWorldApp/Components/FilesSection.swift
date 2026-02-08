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

// MARK: - Files Section

/// Provides file system browsing and process viewing for the container.
struct FilesSection: View {
    @ObservedObject var containerManager: ContainerManager
    @Binding var commandOutput: String
    @Binding var isExecutingCommand: Bool
    
    var body: some View {
        VStack(spacing: 15) {
            // File operations
            VStack(alignment: .leading, spacing: 8) {
                Text("Container File System")
                    .font(.system(size: 14, weight: .semibold))
                
                HStack(spacing: 10) {
                    DirectoryButton(
                        path: "/",
                        icon: "folder",
                        color: .blue,
                        action: { browseDirectory("/") }
                    )
                    
                    DirectoryButton(
                        path: "/app",
                        icon: "folder.badge.gearshape",
                        color: .purple,
                        action: { browseDirectory("/app") }
                    )
                    
                    DirectoryButton(
                        path: "/tmp",
                        icon: "folder.badge.questionmark",
                        color: .orange,
                        action: { browseDirectory("/tmp") }
                    )
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
                
                HStack(spacing: 10) {
                    Button(action: viewBootLog) {
                        HStack {
                            Image(systemName: "doc.text.magnifyingglass")
                            Text("Boot Log")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.teal)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: showLastDiagnostics) {
                        HStack {
                            Image(systemName: "stethoscope")
                            Text("Diagnostics")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(containerManager.lastDiagnosticReport != nil ? Color.orange : Color.gray)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                    .disabled(containerManager.lastDiagnosticReport == nil)
                }
            }
            .padding()
            .background(Color.white.opacity(0.8))
            .cornerRadius(10)
            
            // Output display
            if !commandOutput.isEmpty {
                CommandOutputView(
                    output: commandOutput,
                    onClear: { commandOutput = "" }
                )
            }
        }
        .padding(.horizontal, 40)
    }
    
    // MARK: - Actions
    
    private func browseDirectory(_ path: String) {
        print("📂 [FilesSection] Browsing directory: \(path)")
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
        print("🔄 [FilesSection] Getting container processes")
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
    
    private func viewBootLog() {
        print("📋 [FilesSection] Viewing boot log")
        if let logContent = containerManager.readLogFile(name: "bootlog.txt", lastLines: 50) {
            commandOutput = """
            📋 Boot Log (last 50 lines):
            
            \(logContent)
            """
        } else {
            commandOutput = "ℹ️ No boot log available yet."
        }
    }
    
    private func showLastDiagnostics() {
        print("🔍 [FilesSection] Showing last diagnostic report")
        guard let report = containerManager.lastDiagnosticReport else {
            commandOutput = "ℹ️ No diagnostic report available."
            return
        }
        
        var output = """
        🔍 Diagnostic Report
        ━━━━━━━━━━━━━━━━━━━━━
        Phase: \(report.phase)
        Time:  \(report.timestamp)
        
        """
        
        if let error = report.error {
            output += "Error: \(error.localizedDescription)\n\n"
        }
        
        if !report.systemInfo.isEmpty {
            output += "System Info:\n"
            for (key, value) in report.systemInfo.sorted(by: { $0.key < $1.key }) {
                output += "  \(key): \(value)\n"
            }
            output += "\n"
        }
        
        output += "Containers: \(report.registeredContainers.isEmpty ? "NONE" : report.registeredContainers.joined(separator: ", "))\n"
        
        for stat in report.containerStats {
            output += "  \(stat.id) — CPU: \(stat.cpuUsec)µs, Mem: \(stat.memoryBytes) bytes\n"
        }
        
        output += "\nHealth Probe: \(report.healthProbeResult ? "✅ OK" : "❌ Failed")\n"
        
        if let tail = report.bootlogTail {
            output += "\nBoot Log (tail):\n\(tail)\n"
        }
        
        commandOutput = output
        
        // Also re-print to log for debugging
        containerManager.reprintLastDiagnosticReport()
    }
}

// MARK: - Directory Button

/// A styled button for browsing directories.
struct DirectoryButton: View {
    let path: String
    let icon: String
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                Text("Browse \(path)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(color)
            .foregroundColor(.white)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}
