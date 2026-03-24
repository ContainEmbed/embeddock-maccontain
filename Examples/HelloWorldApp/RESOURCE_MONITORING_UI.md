# Resource Monitoring & Configuration UI Components

## Overview

This document describes the SwiftUI UI components added to the HelloWorldApp example for:
1. **Resource Configuration** — Setting CPU and memory limits before starting a container, viewing active allocation, and changing limits (with restart) while running.
2. **Resource Monitoring** — Visualizing real-time container resource metrics from the `ResourceMonitoring` module.

---

## Resource Configuration

### `ContainerResourceLimits` (Public API)

```swift
public struct ContainerResourceLimits: Sendable, Equatable {
    public let cpuCores: Int       // >= 1, default: 2
    public let memoryBytes: UInt64 // >= 128 MiB, default: 512 MiB

    public static let `default`     // 2 cores, 512 MiB
    public static let minimal       // 1 core, 256 MiB
    public static let performance   // 4 cores, 1 GiB
}
```

Set `engine.resourceLimits` before calling `startFromImage()` or `startNodeServer()`. The engine converts this to the internal `PodConfiguration` for VM creation.

### Apple Virtualization Framework Constraint

CPU count and memory are fixed at VM creation time. **Changing resource limits requires stopping the container and restarting with a new VM.** The UI communicates this with an "Apply Changes (Restart Required)" button.

### Configuration Data Flow

```
ResourceConfigurationSection (SwiftUI)
    ├─ CPUConfigurationCard    ──writes──> viewModel.configuredCpuCores
    ├─ MemoryConfigurationCard ──writes──> viewModel.configuredMemoryMB
    └─ RestartButton           ──calls──> viewModel.applyResourceLimitsAndRestart()

ContainerViewModel
    ├─ Converts configuredCpuCores/memoryMB → ContainerResourceLimits
    ├─ Sets engine.resourceLimits before calling engine.startFromImage()
    └─ Receives activeResourceLimits via delegate callback

DefaultContainerEngine
    ├─ Converts ContainerResourceLimits → PodConfiguration (internal)
    ├─ Threads config through StartupCoordinator → PodFactory
    └─ Uses activeResourceLimits for resource monitoring scaling
```

### Configuration State Lifecycle

| Event | ViewModel Action | UI Effect |
|---|---|---|
| App launch | configuredCpuCores=2, configuredMemoryMB=512 | Config cards show defaults |
| User adjusts CPU/Memory | Published properties update | Card reflects new value |
| User starts container | Limits passed to engine via `engine.resourceLimits` | Active allocation badge appears |
| User changes limits while running | `hasUnsavedResourceChanges` becomes true | "Apply (Restart)" button appears |
| User clicks Apply | `applyResourceLimitsAndRestart()` stops/restarts | Brief stop, new allocation shown |
| Container stops | `activeResourceLimits` = nil | Active badge disappears |

### New File: `Sources/Components/ResourceConfigurationSection.swift`

- **CPU card**: Stepper (1–8 cores), large monospaced value display
- **Memory card**: Picker with presets (256 MB, 512 MB, 1 GB, 2 GB, 4 GB)
- **Active allocation badge**: Green dot + "Active: N cores | X MB" when running
- **Restart button**: Orange "Apply Changes (Restart Required)" when limits differ from active

### Settings View Enhancement

`SettingsView` now accepts `cpuCores` and `memoryMB` bindings, providing a pre-start configuration path alongside the Resources tab.

---

## Architecture

### Data Flow

```
ResourceMonitor (actor) ──collects──> ResourceSnapshot
        │
        ├─ AsyncStream<ResourceSnapshot>   (pull model — UI iterates via for-await)
        └─ ContainerEngineDelegate callback (push model — ViewModel receives via delegate)

ContainerViewModel (ViewModel)
        │
        ├─ @Published latestSnapshot: ResourceSnapshot?
        ├─ @Published isMonitoringResources: Bool
        ├─ @Published cpuHistory: [Double]        (rolling window for sparkline)
        ├─ @Published memoryHistory: [Double]      (rolling window for sparkline)
        └─ @Published networkHistory: [(rx, tx)]   (rolling window for sparkline)
                │
                ▼
    ResourceMonitoringSection (SwiftUI View — Tab index 3)
        ├─ CPUMetricsCard
        ├─ MemoryMetricsCard
        ├─ NetworkMetricsCard
        ├─ DiskIOMetricsCard
        └─ SnapshotQualityBadge
```

### Lifecycle Management

1. **Auto-start**: `DefaultContainerEngine` auto-starts resource monitoring after a container launches. No explicit start call is needed from the ViewModel.
2. **Delegate bridge**: `ContainerEngineDelegate.engine(_:didUpdateResourceSnapshot:)` pushes each snapshot to the ViewModel on `@MainActor`.
3. **ViewModel update**: The delegate callback updates `@Published` properties, which automatically triggers SwiftUI view updates.
4. **History tracking**: The ViewModel maintains rolling arrays (capped at 60 entries) for sparkline/chart rendering.
5. **Auto-stop**: When the container stops, the engine stops monitoring and clears the snapshot. The ViewModel resets all monitoring state when `engineDidUpdateState` reports a non-running status.
6. **Task cancellation**: The `AsyncStream` finishes when monitoring stops; any `for await` loops exit naturally.

---

## New Files

### 1. `Sources/Components/ResourceMonitoringSection.swift`

The main container view for the monitoring tab. Contains all metric cards arranged vertically.

#### `ResourceMonitoringSection`
- **Input**: `@ObservedObject var viewModel: ContainerViewModel`
- **Behavior**: Shows a "Monitoring inactive" placeholder when `!viewModel.isMonitoringResources`, otherwise displays all metric cards.
- **Layout**: `VStack(spacing: 15)` with `.padding(.horizontal, 40)` matching other sections.

#### `CPUMetricsCard`
- **Input**: `cpu: CPUMetrics`, `history: [Double]`
- **Displays**:
  - Max allocated CPU cores and total percentage capacity (e.g., "Max: 2 cores (200%)")
  - Overall CPU usage as a percentage with a progress bar (0 to max allocated)
  - Per-core usage bars (when `perCoreUsagePercent` is available)
  - User / System / Idle breakdown
  - Mini sparkline chart scaled from 0 to max allocated (coreCount × 100%)

#### `MemoryMetricsCard`
- **Input**: `memory: MemoryMetrics`, `history: [Double]`
- **Displays**:
  - Usage percentage with progress bar (0–100%)
  - Used / Total bytes with "(Max)" label (formatted as MB/GB) showing max allocated memory
  - Free / Available / Buffers / Cached breakdown (when detailed metrics enabled)
  - Swap usage (when available)
  - Mini sparkline chart scaled from 0% to 100% of allocated memory

#### `NetworkMetricsCard`
- **Input**: `network: NetworkMetrics`
- **Displays**:
  - Aggregate RX/TX rates formatted as KB/s or MB/s
  - Cumulative total RX/TX bytes
  - Per-interface breakdown table (name, rx rate, tx rate, errors)

#### `DiskIOMetricsCard`
- **Input**: `diskIO: DiskIOMetrics`
- **Displays**:
  - Read/Write throughput rates (KB/s or MB/s)
  - Read/Write operation rates (ops/s)
  - Cumulative read/written bytes

#### `SnapshotQualityBadge`
- **Input**: `quality: SnapshotQuality`
- **Displays**:
  - Green "Complete" badge for `.complete`
  - Orange "Degraded" badge with missing metric types for `.degraded(missing:)`
  - Red "Failed" badge with reason for `.failed(reason:)`

#### `SparklineView`
- **Input**: `data: [Double]`, `lineColor: Color`, `height: CGFloat`, `maxValue: Double?` (optional)
- **Behavior**: Draws a mini line chart using `Path` from the rolling data array. When `maxValue` is provided, the Y-axis is fixed from 0 to `maxValue` so the graph shows usage relative to the allocated maximum (e.g., 0–200% for 2 CPU cores, 0–100% for memory). When `maxValue` is `nil`, falls back to auto-scaling based on the data range.
- **Layout**: Fixed height, fills available width

#### Helper: `MetricProgressBar`
- **Input**: `value: Double` (0-100), `label: String`, `color: Color`
- **Displays**: A horizontal bar with label and percentage text

#### Helper: `formatBytes(_: UInt64) -> String`
- Formats byte counts to human-readable strings (B, KB, MB, GB)

#### Helper: `formatRate(_: Double) -> String`
- Formats byte-per-second rates to human-readable throughput strings

---

### 2. Changes to `Sources/ViewModels/ContainerViewModel.swift`

#### New Published Properties
```swift
// MARK: - Resource Monitoring State
@Published private(set) var latestSnapshot: ResourceSnapshot?
@Published private(set) var isMonitoringResources: Bool = false
@Published private(set) var cpuHistory: [Double] = []
@Published private(set) var memoryHistory: [Double] = []
@Published private(set) var networkRxHistory: [Double] = []
@Published private(set) var networkTxHistory: [Double] = []
```

#### New Delegate Method
```swift
func engine(_ engine: any ContainerEngine, didUpdateResourceSnapshot snapshot: ResourceSnapshot) {
    latestSnapshot = snapshot
    isMonitoringResources = engine.isMonitoringResources

    // Maintain rolling history (max 60 entries for ~2 minutes at 2s interval)
    appendToHistory(&cpuHistory, value: snapshot.cpu.usagePercent, maxCount: 60)
    appendToHistory(&memoryHistory, value: snapshot.memory.usagePercent, maxCount: 60)
    appendToHistory(&networkRxHistory, value: snapshot.network.totalRxBytesPerSec, maxCount: 60)
    appendToHistory(&networkTxHistory, value: snapshot.network.totalTxBytesPerSec, maxCount: 60)
}
```

#### State Reset in `engineDidUpdateState`
When the container is no longer running, clear all monitoring state:
```swift
if !engine.status.isActive {
    latestSnapshot = nil
    isMonitoringResources = false
    cpuHistory = []
    memoryHistory = []
    networkRxHistory = []
    networkTxHistory = []
}
```

---

### 3. Changes to `Sources/Views/ContentView.swift`

#### Tab Picker Update
Add a "Resources" tab (index 3) to the segmented picker:
```swift
Picker("", selection: $viewModel.selectedTab) {
    Text("Control").tag(0)
    Text("Terminal").tag(1)
    Text("Files").tag(2)
    Text("Resources").tag(3)
}
```

#### Tab Content Switch
Add case 3 for the resource monitoring section:
```swift
case 3:
    ResourceMonitoringSection(viewModel: viewModel)
```

---

## Visual Design

All metric cards follow the existing app design language:
- White semi-transparent background: `Color.white.opacity(0.8)`
- Corner radius: `10`
- Internal padding: `.padding()`
- Section header: `.font(.system(size: 12, weight: .semibold))` + `.foregroundColor(.secondary)`
- Monospaced values: `.font(.system(size: 12, design: .monospaced))`
- Progress bars use `GeometryReader` with color-coded fills (green < 60%, orange 60-85%, red > 85%)
- Sparkline charts are drawn with SwiftUI `Path` in a compact `Canvas` or `Shape`

---

## State & Lifecycle Summary

| Event | ViewModel Action | UI Effect |
|---|---|---|
| Container starts | Engine auto-starts monitoring; delegate fires snapshots | Resources tab becomes available; cards populate |
| Snapshot received | `didUpdateResourceSnapshot` updates `@Published` props + history arrays | All visible cards re-render with new data |
| Container stops | `engineDidUpdateState` clears monitoring state | Resources tab shows "Monitoring inactive" |
| User switches to Resources tab | No action; view reads existing `@Published` state | Cards render from latest snapshot |
| App backgrounded | No action; monitoring continues; stream buffers newest(1) | When foregrounded, latest data is immediately available |
| Manual stop monitoring | `engine.stopResourceMonitoring()` | Same as container stop behavior |

---

## Metric Formatting Reference

| Metric | Unit | Format Example |
|---|---|---|
| CPU usage | Percent | `45.2%` |
| Memory usage | Bytes → MB/GB | `512.3 MB / 2.0 GB` |
| Memory percent | Percent | `25.6%` |
| Network rate | Bytes/s → KB/s or MB/s | `1.2 MB/s` |
| Network total | Bytes → MB/GB | `45.6 MB` |
| Disk throughput | Bytes/s → KB/s or MB/s | `850.0 KB/s` |
| Disk ops | Ops/s | `120 ops/s` |

---

## Max Allocation & Graph Scaling

Each resource card displays the **maximum allocated value** for the container, and sparkline graphs are scaled from **0 to the max allocated** rather than auto-scaling to the current data range. The max allocation values now come from `activeResourceLimits` (the actual limits used when the container was started) rather than the hardcoded `PodConfiguration.default`.

### Per-Resource Max Allocation

| Resource | Max Allocated | Source | Graph Y-Axis |
|---|---|---|---|
| CPU | `coreCount × 100%` (e.g., 200% for 2 cores) | `CPUMetrics.coreCount` from `activeResourceLimits.cpuCores` | 0 – coreCount × 100% |
| Memory | `totalBytes` (e.g., 512 MB) | `MemoryMetrics.totalBytes` from `activeResourceLimits.memoryBytes` | 0% – 100% of allocated |
| Network | N/A (rate-based, no fixed cap) | — | Auto-scaled to data range |
| Disk I/O | N/A (rate-based, no fixed cap) | — | No sparkline |

### Graph Scaling Behavior

The `SparklineView` accepts an optional `maxValue` parameter:
- **When provided** (CPU, Memory): The Y-axis is fixed from 0 to `maxValue`. Low usage appears as a small line near the bottom of the graph, making it easy to judge utilization relative to capacity.
- **When omitted** (Network): The Y-axis auto-scales to `data.max()`, which is appropriate for rate-based metrics where there is no predefined ceiling.

