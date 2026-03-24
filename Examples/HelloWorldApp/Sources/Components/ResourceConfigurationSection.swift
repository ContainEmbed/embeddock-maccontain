//===----------------------------------------------------------------------===//
//
// Resource Configuration Section — UI for Setting Resource Limits
//
//===----------------------------------------------------------------------===//

import SwiftUI
import EmbedDock

// MARK: - Resource Configuration Section

/// Simple UI for configuring container CPU and memory limits.
///
/// Shows configuration controls, active allocation when running,
/// and a restart button when limits are changed on a running container.
struct ResourceConfigurationSection: View {
    @ObservedObject var viewModel: ContainerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Resource Configuration")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.secondary)

            // Active allocation badge (when running)
            if let limits = viewModel.activeResourceLimits {
                activeAllocationBadge(limits)
            }

            HStack(spacing: 12) {
                // CPU Configuration Card
                cpuCard
                // Memory Configuration Card
                memoryCard
            }

            // Apply & Restart button (when running with pending changes)
            if viewModel.isRunning && viewModel.hasUnsavedResourceChanges {
                restartButton
            }
        }
    }

    // MARK: - CPU Card

    private var cpuCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "cpu")
                    .foregroundColor(.blue)
                Text("CPU Cores")
                    .font(.system(size: 12, weight: .semibold))
            }

            HStack {
                Text("\(viewModel.configuredCpuCores)")
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                Text(viewModel.configuredCpuCores == 1 ? "core" : "cores")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Stepper(
                "",
                value: $viewModel.configuredCpuCores,
                in: 1...8
            )
            .labelsHidden()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.8))
        .cornerRadius(10)
    }

    // MARK: - Memory Card

    private var memoryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "memorychip")
                    .foregroundColor(.purple)
                Text("Memory")
                    .font(.system(size: 12, weight: .semibold))
            }

            HStack {
                Text(memoryDisplayValue)
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                Text(memoryDisplayUnit)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Picker("", selection: $viewModel.configuredMemoryMB) {
                Text("256 MB").tag(256)
                Text("512 MB").tag(512)
                Text("1 GB").tag(1024)
                Text("2 GB").tag(2048)
                Text("4 GB").tag(4096)
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.8))
        .cornerRadius(10)
    }

    // MARK: - Active Allocation Badge

    private func activeAllocationBadge(_ limits: ContainerResourceLimits) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
            Text("Active:")
                .font(.system(size: 11, weight: .semibold))
            Text("\(limits.cpuCores) \(limits.cpuCores == 1 ? "core" : "cores")")
                .font(.system(size: 11, design: .monospaced))
            Text("|")
                .foregroundColor(.secondary)
            Text(limits.memoryDescription)
                .font(.system(size: 11, design: .monospaced))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.green.opacity(0.1))
        .cornerRadius(8)
    }

    // MARK: - Restart Button

    private var restartButton: some View {
        Button {
            Task {
                do {
                    try await viewModel.applyResourceLimitsAndRestart()
                } catch {
                    viewModel.showError(error)
                }
            }
        } label: {
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("Apply Changes (Restart Required)")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.orange)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private var memoryDisplayValue: String {
        if viewModel.configuredMemoryMB >= 1024 {
            let gb = Double(viewModel.configuredMemoryMB) / 1024.0
            return gb == gb.rounded() ? String(format: "%.0f", gb) : String(format: "%.1f", gb)
        }
        return "\(viewModel.configuredMemoryMB)"
    }

    private var memoryDisplayUnit: String {
        viewModel.configuredMemoryMB >= 1024 ? "GB" : "MB"
    }
}
