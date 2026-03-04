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
import EmbedDock

/// Displays the current container status, port forwarding status, and container URL.
struct StatusSection: View {
    @ObservedObject var viewModel: ContainerViewModel
    @State private var activeChannels: [CommunicationType] = []
    
    var body: some View {
        VStack(spacing: 15) {
            // Main status row
            HStack {
                Circle()
                    .fill(viewModel.isRunning ? Color.green : Color.gray)
                    .frame(width: 12, height: 12)
                
                Text(viewModel.statusMessage)
                    .font(.system(size: 14, weight: .medium))
                
                Spacer()
                
                if viewModel.isCommunicationReady {
                    CommunicationChannelsIndicator(channels: viewModel.activeChannels)
                }
            }
            .padding()
            .background(Color.white.opacity(0.8))
            .cornerRadius(10)
            
            // Port forwarding status
            if viewModel.isRunning {
                HStack {
                    PortForwardingStatusView(
                        status: viewModel.forwardingState,
                        onRetry: { /* Retry handled by parent */ }
                    )
                    Spacer()
                }
                .padding()
                .background(Color.white.opacity(0.8))
                .cornerRadius(10)
            }
            
            // System info (from DiagnosticsHelper.getSystemInfo)
            if viewModel.isRunning {
                SystemInfoRow(systemInfo: viewModel.getSystemInfo())
            }

            // Container URL
            if let url = viewModel.containerURL {
                ContainerURLRow(
                    url: url,
                    isActive: viewModel.isPortForwardingActive
                )
            }
        }
        .padding(.horizontal, 40)
    }
}

// MARK: - Communication Channels Indicator

/// Shows the active communication channels as small icons.
struct CommunicationChannelsIndicator: View {
    let channels: [CommunicationType]
    
    var body: some View {
        HStack(spacing: 4) {
            ForEach(channels, id: \.self) { channel in
                ChannelBadge(type: channel)
            }
            
            if channels.isEmpty {
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
    }
}

/// A small badge showing a communication channel type.
struct ChannelBadge: View {
    let type: CommunicationType
    
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: iconName)
                .font(.system(size: 10))
            Text(type.rawValue)
                .font(.system(size: 10))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.blue.opacity(0.15))
        .foregroundColor(.blue)
        .cornerRadius(4)
    }
    
    private var iconName: String {
        switch type {
        case .http:
            return "globe"
        case .vsock:
            return "bolt.horizontal"
        case .unixSocket:
            return "cable.connector"
        }
    }
}

// MARK: - System Info Row

/// Displays host system information (macOS version, memory, CPUs).
struct SystemInfoRow: View {
    let systemInfo: [String: String]
    
    var body: some View {
        if !systemInfo.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Host System")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                
                HStack(spacing: 16) {
                    if let macOS = systemInfo["macOS"] {
                        Label(macOS, systemImage: "desktopcomputer")
                            .font(.system(size: 11))
                    }
                    if let memory = systemInfo["physicalMemory"] {
                        Label(memory, systemImage: "memorychip")
                            .font(.system(size: 11))
                    }
                    if let cpus = systemInfo["activeProcessorCount"] {
                        Label("\(cpus) CPUs", systemImage: "cpu")
                            .font(.system(size: 11))
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.8))
            .cornerRadius(10)
        }
    }
}

// MARK: - Port Forwarding Status View

/// Displays the port forwarding status with an indicator and optional retry button.
struct PortForwardingStatusView: View {
    let status: ContainerStatus.ForwardingState
    let onRetry: () -> Void
    
    var body: some View {
        HStack(spacing: 8) {
            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            
            Text("Port Forwarding:")
                .font(.system(size: 12, weight: .semibold))
            
            Text(status.description)
                .font(.system(size: 12))
                .foregroundColor(statusColor)
            
            // Show retry button if there's an error
            if case .error = status {
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(.blue)
            }
        }
    }
    
    private var statusColor: Color {
        switch status {
        case .inactive:
            return .gray
        case .starting:
            return .yellow
        case .active:
            return .green
        case .recovering:
            return .orange
        case .error:
            return .red
        }
    }
}

// MARK: - Container URL Row

/// Displays the container URL with an "Open" button when available.
struct ContainerURLRow: View {
    let url: String
    let isActive: Bool
    
    var body: some View {
        HStack {
            Text("Container:")
                .font(.system(size: 14, weight: .semibold))
            
            Text(url)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.blue)
            
            Spacer()
            
            if isActive {
                Button(action: openURL) {
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
    
    private func openURL() {
        if let urlToOpen = URL(string: url) {
            NSWorkspace.shared.open(urlToOpen)
        }
    }
}
