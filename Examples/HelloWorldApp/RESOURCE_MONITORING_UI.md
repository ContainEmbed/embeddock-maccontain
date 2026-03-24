# Resource Monitoring UI Components

## Overview

This document describes the SwiftUI UI components added to the HelloWorldApp example to visualize real-time container resource metrics from the `ResourceMonitoring` module. The resource monitoring system collects CPU, memory, network I/O, disk I/O, and GPU metrics from running containers at configurable intervals (default 2s) via `ContainerResourceMonitoring` protocol.

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
        ├─ GPUMetricsCard (placeholder when unavailable)
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
  - Overall CPU usage as a percentage with a progress bar
  - Per-core usage bars (when `perCoreUsagePercent` is available)
  - User / System / Idle breakdown
  - Mini sparkline chart from history array

#### `MemoryMetricsCard`
- **Input**: `memory: MemoryMetrics`, `history: [Double]`
- **Displays**:
  - Usage percentage with progress bar
  - Used / Total bytes (formatted as MB/GB)
  - Free / Available / Buffers / Cached breakdown (when detailed metrics enabled)
  - Swap usage (when available)
  - Mini sparkline chart from history array

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

#### `GPUMetricsCard`
- **Input**: `gpu: GPUMetrics`
- **Displays**:
  - "GPU monitoring not available" when `!gpu.isAvailable`
  - Utilization percentage, memory usage, temperature, and power when available

#### `SnapshotQualityBadge`
- **Input**: `quality: SnapshotQuality`
- **Displays**:
  - Green "Complete" badge for `.complete`
  - Orange "Degraded" badge with missing metric types for `.degraded(missing:)`
  - Red "Failed" badge with reason for `.failed(reason:)`

#### `SparklineView`
- **Input**: `data: [Double]`, `lineColor: Color`, `height: CGFloat`
- **Behavior**: Draws a mini line chart using `Path` from the rolling data array
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
| GPU utilization | Percent | `72.5%` |
| GPU memory | Bytes → MB/GB | `1.5 GB / 8.0 GB` |
| Temperature | Celsius | `65.0 °C` |
| Power | Watts | `150.0 W` |
