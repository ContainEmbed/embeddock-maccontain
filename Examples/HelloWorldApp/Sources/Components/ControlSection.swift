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

// MARK: - Control Section

/// Main control section with buttons for container operations.
struct ControlSection: View {
    @ObservedObject var viewModel: ContainerViewModel
    
    var body: some View {
        VStack(spacing: 15) {
            // Open OCI Image button
            Button(action: { viewModel.openImageFilePicker() }) {
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
            .disabled(viewModel.isRunning)
            
            // Check API button
            Button(action: { Task { await viewModel.checkContainerAPI() } }) {
                HStack {
                    Image(systemName: "network")
                    Text("Check API")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(viewModel.isContainerOperational ? Color.green : Color.gray)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.isContainerOperational || viewModel.isCheckingAPI)
            
            // API Response Display
            if !viewModel.apiResponse.isEmpty {
                APIResponseView(response: viewModel.apiResponse)
            }
            
            // Stop Container button
            if viewModel.isRunning {
                Button(action: { Task { try? await viewModel.stopContainer() } }) {
                    HStack {
                        if viewModel.isStopping {
                            ProgressView()
                                .controlSize(.small)
                                .colorScheme(.dark)
                        } else {
                            Image(systemName: "stop.fill")
                        }
                        Text(viewModel.isStopping ? "Stopping..." : "Stop Container")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(viewModel.isStopping ? Color.red.opacity(0.5) : Color.red)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canStop)
            }
            
            // Settings button
            Button(action: { viewModel.showSettings.toggle() }) {
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
}

// MARK: - API Response View

/// Displays the API response in a scrollable text area.
struct APIResponseView: View {
    let response: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("API Response:")
                .font(.system(size: 14, weight: .semibold))
            
            ScrollView {
                Text(response)
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
}
