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
import EmbedDock

// MARK: - Resource Monitoring Section

/// Main container view for the Resources tab. Displays live container metrics.
struct ResourceMonitoringSection: View {
    @ObservedObject var viewModel: ContainerViewModel

    var body: some View {
        VStack(spacing: 15) {
            if let snapshot = viewModel.latestSnapshot, viewModel.isMonitoringResources {
                // Quality badge
                HStack {
                    Text("Container Resources")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    SnapshotQualityBadge(quality: snapshot.quality)
                }

                CPUMetricsCard(cpu: snapshot.cpu, history: viewModel.cpuHistory)
                MemoryMetricsCard(memory: snapshot.memory, history: viewModel.memoryHistory)
                NetworkMetricsCard(network: snapshot.network)
                DiskIOMetricsCard(diskIO: snapshot.diskIO)
                GPUMetricsCard(gpu: snapshot.gpu)
            } else {
                monitoringInactivePlaceholder
            }
        }
        .padding(.horizontal, 40)
    }

    private var monitoringInactivePlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "gauge.with.dots.needle.0percent")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text("Resource Monitoring Inactive")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
            Text("Start a container to view live resource metrics")
                .font(.system(size: 12))
                .foregroundColor(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(30)
        .background(Color.white.opacity(0.8))
        .cornerRadius(10)
    }
}

// MARK: - CPU Metrics Card

struct CPUMetricsCard: View {
    let cpu: CPUMetrics
    let history: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "cpu")
                    .foregroundColor(.blue)
                Text("CPU")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(cpu.coreCount) cores")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            MetricProgressBar(
                value: cpu.usagePercent,
                label: "Usage",
                maxValue: Double(cpu.coreCount) * 100.0
            )

            if !history.isEmpty {
                SparklineView(
                    data: history,
                    lineColor: progressColor(for: cpu.usagePercent / Double(max(cpu.coreCount, 1))),
                    height: 40
                )
            }

            // Per-core breakdown
            if let perCore = cpu.perCoreUsagePercent, !perCore.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Per-Core")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    ForEach(Array(perCore.enumerated()), id: \.offset) { index, usage in
                        MetricProgressBar(
                            value: usage,
                            label: "Core \(index)",
                            maxValue: 100.0,
                            height: 6,
                            showPercentage: false
                        )
                    }
                }
            }

            // User / System / Idle
            if let user = cpu.userPercent, let system = cpu.systemPercent, let idle = cpu.idlePercent {
                HStack(spacing: 16) {
                    MetricLabel(title: "User", value: String(format: "%.1f%%", user))
                    MetricLabel(title: "System", value: String(format: "%.1f%%", system))
                    MetricLabel(title: "Idle", value: String(format: "%.1f%%", idle))
                }
            }
        }
        .padding()
        .background(Color.white.opacity(0.8))
        .cornerRadius(10)
    }
}

// MARK: - Memory Metrics Card

struct MemoryMetricsCard: View {
    let memory: MemoryMetrics
    let history: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "memorychip")
                    .foregroundColor(.purple)
                Text("Memory")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(formatBytes(memory.usageBytes)) / \(formatBytes(memory.totalBytes))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            MetricProgressBar(
                value: memory.usagePercent,
                label: "Usage",
                maxValue: 100.0
            )

            if !history.isEmpty {
                SparklineView(data: history, lineColor: progressColor(for: memory.usagePercent), height: 40)
            }

            // Detailed breakdown
            HStack(spacing: 12) {
                if let free = memory.freeBytes {
                    MetricLabel(title: "Free", value: formatBytes(free))
                }
                if let available = memory.availableBytes {
                    MetricLabel(title: "Available", value: formatBytes(available))
                }
                if let buffers = memory.buffersBytes {
                    MetricLabel(title: "Buffers", value: formatBytes(buffers))
                }
                if let cached = memory.cachedBytes {
                    MetricLabel(title: "Cached", value: formatBytes(cached))
                }
            }

            // Swap
            if let swapUsed = memory.swapUsedBytes, let swapTotal = memory.swapTotalBytes, swapTotal > 0 {
                HStack {
                    Text("Swap:")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text("\(formatBytes(swapUsed)) / \(formatBytes(swapTotal))")
                        .font(.system(size: 10, design: .monospaced))
                }
            }
        }
        .padding()
        .background(Color.white.opacity(0.8))
        .cornerRadius(10)
    }
}

// MARK: - Network Metrics Card

struct NetworkMetricsCard: View {
    let network: NetworkMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "network")
                    .foregroundColor(.green)
                Text("Network")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
            }

            // Aggregate rates
            HStack(spacing: 20) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                    Text("RX: \(formatRate(network.totalRxBytesPerSec))")
                        .font(.system(size: 12, design: .monospaced))
                }
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 10))
                        .foregroundColor(.blue)
                    Text("TX: \(formatRate(network.totalTxBytesPerSec))")
                        .font(.system(size: 12, design: .monospaced))
                }
            }

            // Cumulative totals
            HStack(spacing: 16) {
                MetricLabel(title: "Total RX", value: formatBytes(network.totalRxBytes))
                MetricLabel(title: "Total TX", value: formatBytes(network.totalTxBytes))
            }

            // Per-interface breakdown
            if !network.interfaces.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Interfaces")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    ForEach(network.interfaces, id: \.name) { iface in
                        HStack {
                            Text(iface.name)
                                .font(.system(size: 10, design: .monospaced))
                                .frame(width: 50, alignment: .leading)
                            Text("RX: \(formatRate(iface.rxBytesPerSec))")
                                .font(.system(size: 10, design: .monospaced))
                            Text("TX: \(formatRate(iface.txBytesPerSec))")
                                .font(.system(size: 10, design: .monospaced))
                            if iface.rxErrors > 0 || iface.txErrors > 0 {
                                Text("Err: \(iface.rxErrors + iface.txErrors)")
                                    .font(.system(size: 10))
                                    .foregroundColor(.red)
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color.white.opacity(0.8))
        .cornerRadius(10)
    }
}

// MARK: - Disk IO Metrics Card

struct DiskIOMetricsCard: View {
    let diskIO: DiskIOMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "internaldrive")
                    .foregroundColor(.orange)
                Text("Disk I/O")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
            }

            // Throughput rates
            HStack(spacing: 20) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                    Text("Read: \(formatRate(diskIO.readBytesPerSec))")
                        .font(.system(size: 12, design: .monospaced))
                }
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.doc")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Text("Write: \(formatRate(diskIO.writeBytesPerSec))")
                        .font(.system(size: 12, design: .monospaced))
                }
            }

            // Operation rates
            HStack(spacing: 16) {
                MetricLabel(title: "Read Ops", value: String(format: "%.0f ops/s", diskIO.readOpsPerSec))
                MetricLabel(title: "Write Ops", value: String(format: "%.0f ops/s", diskIO.writeOpsPerSec))
            }

            // Cumulative totals
            HStack(spacing: 16) {
                MetricLabel(title: "Total Read", value: formatBytes(diskIO.readBytes))
                MetricLabel(title: "Total Written", value: formatBytes(diskIO.writeBytes))
            }
        }
        .padding()
        .background(Color.white.opacity(0.8))
        .cornerRadius(10)
    }
}

// MARK: - GPU Metrics Card

struct GPUMetricsCard: View {
    let gpu: GPUMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "gpu")
                    .foregroundColor(.pink)
                Text("GPU")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
            }

            if gpu.isAvailable {
                MetricProgressBar(
                    value: gpu.utilizationPercent,
                    label: "Utilization",
                    maxValue: 100.0
                )

                HStack(spacing: 16) {
                    MetricLabel(
                        title: "VRAM",
                        value: "\(formatBytes(gpu.memoryUsageBytes)) / \(formatBytes(gpu.memoryTotalBytes))"
                    )
                    if let temp = gpu.temperatureCelsius {
                        MetricLabel(title: "Temp", value: String(format: "%.0f °C", temp))
                    }
                    if let power = gpu.powerWatts {
                        MetricLabel(title: "Power", value: String(format: "%.1f W", power))
                    }
                }
            } else {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("GPU monitoring not available")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color.white.opacity(0.8))
        .cornerRadius(10)
    }
}

// MARK: - Snapshot Quality Badge

struct SnapshotQualityBadge: View {
    let quality: SnapshotQuality

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(badgeColor)
                .frame(width: 8, height: 8)
            Text(badgeText)
                .font(.system(size: 10))
                .foregroundColor(badgeColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(badgeColor.opacity(0.12))
        .cornerRadius(6)
    }

    private var badgeColor: Color {
        switch quality {
        case .complete:
            return .green
        case .degraded:
            return .orange
        case .failed:
            return .red
        }
    }

    private var badgeText: String {
        switch quality {
        case .complete:
            return "Complete"
        case .degraded(let missing):
            let names = missing.map(\.rawValue).joined(separator: ", ")
            return "Degraded: \(names)"
        case .failed(let reason):
            return "Failed: \(reason)"
        }
    }
}

// MARK: - Sparkline View

struct SparklineView: View {
    let data: [Double]
    let lineColor: Color
    let height: CGFloat

    var body: some View {
        GeometryReader { geo in
            if data.count > 1 {
                let maxVal = max(data.max() ?? 1.0, 1.0)
                Path { path in
                    let stepX = geo.size.width / CGFloat(data.count - 1)
                    for (index, value) in data.enumerated() {
                        let x = CGFloat(index) * stepX
                        let y = geo.size.height - (CGFloat(value / maxVal) * geo.size.height)
                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(lineColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(height: height)
        .background(Color.black.opacity(0.03))
        .cornerRadius(4)
    }
}

// MARK: - Reusable Helpers

struct MetricProgressBar: View {
    let value: Double
    let label: String
    var maxValue: Double = 100.0
    var height: CGFloat = 10
    var showPercentage: Bool = true

    private var normalizedPercent: Double {
        guard maxValue > 0 else { return 0 }
        return min(max(value / maxValue, 0), 1.0)
    }

    private var displayPercent: Double {
        normalizedPercent * 100.0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if showPercentage {
                HStack {
                    Text(label)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.1f%%", displayPercent))
                        .font(.system(size: 10, design: .monospaced))
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: height / 2)
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: height)
                    RoundedRectangle(cornerRadius: height / 2)
                        .fill(progressColor(for: displayPercent))
                        .frame(width: geo.size.width * normalizedPercent, height: height)
                }
            }
            .frame(height: height)
        }
    }
}

struct MetricLabel: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
        }
    }
}

// MARK: - Formatting Helpers

func formatBytes(_ bytes: UInt64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(bytes)
    var unitIndex = 0
    while value >= 1024 && unitIndex < units.count - 1 {
        value /= 1024
        unitIndex += 1
    }
    if unitIndex == 0 {
        return String(format: "%.0f %@", value, units[unitIndex])
    }
    return String(format: "%.1f %@", value, units[unitIndex])
}

func formatRate(_ bytesPerSec: Double) -> String {
    let units = ["B/s", "KB/s", "MB/s", "GB/s"]
    var value = bytesPerSec
    var unitIndex = 0
    while value >= 1024 && unitIndex < units.count - 1 {
        value /= 1024
        unitIndex += 1
    }
    if unitIndex == 0 {
        return String(format: "%.0f %@", value, units[unitIndex])
    }
    return String(format: "%.1f %@", value, units[unitIndex])
}

func progressColor(for percent: Double) -> Color {
    if percent < 60 {
        return .green
    } else if percent < 85 {
        return .orange
    } else {
        return .red
    }
}
