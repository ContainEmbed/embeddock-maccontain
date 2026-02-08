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

// MARK: - Terminal Section

/// Provides a terminal-like interface for executing commands in the container.
struct TerminalSection: View {
    @ObservedObject var containerManager: ContainerManager
    @Binding var commandInput: String
    @Binding var commandOutput: String
    @Binding var isExecutingCommand: Bool
    
    var body: some View {
        VStack(spacing: 15) {
            // Command input section
            VStack(alignment: .leading, spacing: 8) {
                Text("Execute Command in Container")
                    .font(.system(size: 14, weight: .semibold))
                
                HStack {
                    NSTextFieldWrapper(
                        text: $commandInput,
                        placeholder: "Enter command (e.g., ls -la, ps aux, env)",
                        onSubmit: executeCommand
                    )
                    .frame(height: 28)
                    
                    Button(action: executeCommand) {
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
                CommandOutputView(
                    output: commandOutput,
                    onClear: { commandOutput = "" }
                )
            }
        }
        .padding(.horizontal, 40)
    }
    
    // MARK: - Components
    
    private func quickCommandButton(_ command: String, icon: String) -> some View {
        Button(action: {
            commandInput = command
            executeCommand()
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
    
    // MARK: - Actions
    
    private func executeCommand() {
        guard !commandInput.isEmpty else { return }
        
        print("🖥️ [TerminalSection] Executing command: \(commandInput)")
        isExecutingCommand = true
        
        Task { @MainActor in
            do {
                let args = commandInput.components(separatedBy: " ").filter { !$0.isEmpty }
                let result = try await containerManager.executeCommand(args)
                
                commandOutput = """
                $ \(commandInput)
                
                \(result.isSuccess ? result.stdoutString : "Error (exit code \(result.exitCode)):\n\(result.stderrString)")
                """
            } catch {
                commandOutput = "❌ Error: \(error.localizedDescription)"
            }
            isExecutingCommand = false
        }
    }
}

// MARK: - Command Output View

/// Displays command output in a terminal-style format.
struct CommandOutputView: View {
    let output: String
    let onClear: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Output:")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.gray)
                }
                .buttonStyle(.plain)
            }
            
            ScrollView {
                Text(output)
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
