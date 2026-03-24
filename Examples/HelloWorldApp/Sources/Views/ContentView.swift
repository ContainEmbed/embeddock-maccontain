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
    @EnvironmentObject var viewModel: ContainerViewModel
    
    var body: some View {
        ZStack {
            // Background gradient
            backgroundGradient
            
            ScrollView {
                VStack(spacing: 20) {
                    // Header
                    headerSection
                    
                    // Status Section
                    StatusSection(viewModel: viewModel)
                    
                    // Tab View for different features
                    if viewModel.isRunning {
                        tabPicker
                        
                        switch viewModel.selectedTab {
                        case 0:
                            ControlSection(viewModel: viewModel)
                        case 1:
                            TerminalSection(viewModel: viewModel)
                        case 2:
                            FilesSection(viewModel: viewModel)
                        case 3:
                            ResourceMonitoringSection(viewModel: viewModel)
                        default:
                            ControlSection(viewModel: viewModel)
                        }
                    } else {
                        ControlSection(viewModel: viewModel)
                    }
                    
                    Spacer(minLength: 20)
                    
                    // Footer
                    footerSection
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $viewModel.showSettings) {
            SettingsView(
                imageName: $viewModel.imageName,
                port: $viewModel.port,
                cpuCores: $viewModel.configuredCpuCores,
                memoryMB: $viewModel.configuredMemoryMB
            )
        }
        .task {
            await viewModel.initialize()
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
            Text("Resources").tag(3)
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
            .environmentObject(ContainerViewModel())
    }
}
#endif
