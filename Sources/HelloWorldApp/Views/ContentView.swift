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

// MARK: - Content View

/// Main content view for the HelloWorldApp container runtime.
struct ContentView: View {
    @EnvironmentObject var containerManager: ContainerManager
    @StateObject private var viewModel = ContentViewModel()
    
    var body: some View {
        ZStack {
            // Background gradient
            backgroundGradient
            
            ScrollView {
                VStack(spacing: 20) {
                    // Header
                    headerSection
                    
                    // Status Section
                    StatusSection(containerManager: containerManager)
                    
                    // Tab View for different features
                    if containerManager.isRunning {
                        tabPicker
                        
                        switch viewModel.selectedTab {
                        case 0:
                            ControlSection(
                                containerManager: containerManager,
                                port: $viewModel.port,
                                apiResponse: $viewModel.apiResponse,
                                isCheckingAPI: $viewModel.isCheckingAPI,
                                showSettings: $viewModel.showSettings
                            )
                        case 1:
                            TerminalSection(
                                containerManager: containerManager,
                                commandInput: $viewModel.commandInput,
                                commandOutput: $viewModel.commandOutput,
                                isExecutingCommand: $viewModel.isExecutingCommand
                            )
                        case 2:
                            FilesSection(
                                containerManager: containerManager,
                                commandOutput: $viewModel.commandOutput,
                                isExecutingCommand: $viewModel.isExecutingCommand
                            )
                        default:
                            ControlSection(
                                containerManager: containerManager,
                                port: $viewModel.port,
                                apiResponse: $viewModel.apiResponse,
                                isCheckingAPI: $viewModel.isCheckingAPI,
                                showSettings: $viewModel.showSettings
                            )
                        }
                    } else {
                        ControlSection(
                            containerManager: containerManager,
                            port: $viewModel.port,
                            apiResponse: $viewModel.apiResponse,
                            isCheckingAPI: $viewModel.isCheckingAPI,
                            showSettings: $viewModel.showSettings
                        )
                    }
                    
                    Spacer(minLength: 20)
                    
                    // Footer
                    footerSection
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $viewModel.showSettings) {
            SettingsView(imageName: $viewModel.imageName, port: $viewModel.port)
        }
        .task {
            await viewModel.initializeContainerManager(containerManager)
        }
    }
    
    // MARK: - View Components
    
    private var backgroundGradient: some View {
        LinearGradient(
            colors: [Color.blue.opacity(0.1), Color.purple.opacity(0.1)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
    
    private var headerSection: some View {
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
    }
    
    private var tabPicker: some View {
        Picker("", selection: $viewModel.selectedTab) {
            Text("Control").tag(0)
            Text("Terminal").tag(1)
            Text("Files").tag(2)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 40)
    }
    
    private var footerSection: some View {
        Text("Powered by Apple Containerization")
            .font(.system(size: 12))
            .foregroundColor(.secondary)
            .padding(.bottom, 20)
    }
}

// MARK: - Preview

#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(ContainerManager())
    }
}
#endif
