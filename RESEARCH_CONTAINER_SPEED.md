# Research: Container Loading & Startup Speed Optimization

## EmbedDock — Parallel Execution & Multi-Container Architecture

---

## Executive Summary

This document presents a research-level analysis of how to improve container loading and startup speed in EmbedDock. It covers two dimensions:

1. **Single-container parallelization** — What sequential steps in the current 10-step startup pipeline can run concurrently?
2. **Multi-container parallel loading** — What architectural changes would let us load and run N containers simultaneously?

---

## Part 1: Current Architecture — Sequential Startup Pipeline

### 1.1 The Current 10-Step Pipeline (StartupCoordinator)

Today, `StartupCoordinator.startFromImage()` runs these steps **strictly sequentially**:

```
Step  1: Extract OCI tar file          → ImageLoader.extractTar()         [DISK I/O]
Step  2: Import into image store       → ImageLoader.importFromDirectory() [DISK I/O]
Step  3: Unpack image to EXT4 rootfs   → ImageService.prepareRootfs()     [CPU + DISK I/O]
Step  4: Prepare init filesystem       → PodFactory.prepareInitFilesystem()[CPU + DISK I/O]
Step  5: Load Linux kernel             → PodFactory.loadKernel()           [DISK I/O]
Step  6: Create VZVirtualMachineManager→ PodFactory.createVMManager()      [CPU - fast]
Step  7: Create LinuxPod               → PodFactory.createPod()            [CPU + N/W]
Step  8: Extract image config          → ImageConfigExtractor.extract()    [CPU - fast]
Step  9: Add container to pod          → PodFactory.addContainer()         [CPU]
Step 10: Start pod + start container   → pod.create() + pod.startContainer[VM BOOT]
```

**Total sequential time**: Every step waits for the previous one. The critical path is the sum of all step durations.

### 1.2 Dependency Analysis — What Actually Depends on What?

```
                    ┌─────────────────────────────────────┐
                    │         ENTRY: imageFile, port       │
                    └──────────┬──────────────────────────┘
                               │
                    ┌──────────▼──────────────────────────┐
                    │  Step 1-2: Extract & Import OCI tar  │
                    │  OUTPUT: image (Image object)        │
                    └──────────┬──────────────────────────┘
                               │
              ┌────────────────┼────────────────────┐
              │                │                    │
   ┌──────────▼────┐  ┌───────▼───────┐  ┌────────▼────────┐
   │ Step 3:       │  │ Step 8:       │  │                  │
   │ Unpack rootfs │  │ Extract image │  │ INDEPENDENT:     │
   │ (needs image) │  │ config        │  │                  │
   │               │  │ (needs image) │  │ Step 4: Init FS  │
   └──────┬────────┘  └───────┬───────┘  │ Step 5: Kernel   │
          │                   │          │ (need NOTHING     │
          │                   │          │  from image)      │
          │                   │          └────────┬──────────┘
          │                   │                   │
          │            ┌──────▼──────────────┐    │
          │            │ Step 6: Create VMM  │◄───┘
          │            │ (needs kernel+initfs)│
          │            └──────┬──────────────┘
          │                   │
          │            ┌──────▼──────────────┐
          │            │ Step 7: Create Pod  │
          │            │ (needs VMM)         │
          │            └──────┬──────────────┘
          │                   │
          ├───────────────────┤
          │                   │
   ┌──────▼───────────────────▼──────┐
   │ Step 9: Add container to pod    │
   │ (needs rootfs + config + pod)   │
   └──────────────┬──────────────────┘
                  │
   ┌──────────────▼──────────────────┐
   │ Step 10: pod.create() + start   │
   │ (needs everything above)        │
   └─────────────────────────────────┘
```

### 1.3 Parallelization Opportunities Within a Single Container Launch

#### Opportunity A: Init FS + Kernel can start IMMEDIATELY (no image dependency)

**Current**: Steps 4 & 5 wait for Steps 1-3 to complete.
**Observation**: `prepareInitFilesystem()` and `loadKernel()` have ZERO dependency on the OCI image. They only need the bundled binaries (pre-init, vminitd, vmexec, vmlinux) which are static resources.

```swift
// PROPOSED: Launch these in parallel at the very start
async let initfs = podFactory.prepareInitFilesystem()
async let kernel = podFactory.loadKernel()        // (needs to be exposed)
async let image  = imageLoader.loadFromFile(imageFile)
```

**Estimated time savings**: Init FS generation (first run) can take 2-5s, kernel loading ~0.5s. These currently run after rootfs preparation which itself takes 3-10s. Running them in parallel with Steps 1-3 saves **2-5 seconds** on first boot, ~0.5s on subsequent boots (init.block is cached).

#### Opportunity B: Image config extraction runs in parallel with rootfs preparation

**Current**: Step 8 (config extraction) runs after Step 7 (pod creation).
**Observation**: `ImageConfigExtractor.extract()` only needs the `Image` object and `Platform` — it doesn't need the rootfs or the pod.

```swift
// After image is loaded (Steps 1-2):
async let rootfsURL   = imageService.prepareRootfs(from: image, platform: platform)
async let imageConfig = ImageConfigExtractor(image: image, platform: platform).extract()
```

**Estimated time savings**: Config extraction is fast (~100ms) but it currently waits behind rootfs unpacking (3-10s) and VM creation. Running it in parallel removes it from the critical path.

#### Opportunity C: VM creation can start before rootfs is ready

**Current**: VMM + Pod creation (Steps 5-7) wait for rootfs.
**Observation**: `VZVirtualMachineManager` and `LinuxPod` creation don't need the rootfs — they only need the kernel and init filesystem. The rootfs is only needed when `addContainer()` is called (Step 9).

```swift
// PROPOSED: Two parallel tracks after image starts loading
// Track 1: Image pipeline
async let image = imageLoader.loadFromFile(imageFile)

// Track 2: VM pipeline (independent)
async let initfs = podFactory.prepareInitFilesystem()
// ... then create VMM and Pod using initfs + kernel
```

**This is the highest-impact optimization**: VM boot (kernel decompression, vminitd startup) is the single slowest step. Starting it earlier gives the VM time to boot while the rootfs is still being prepared.

#### Opportunity D: Host directory access verification can be pre-checked

**Current**: `FileManager.default.contentsOfDirectory(at: ~/Desktop)` runs in the middle of Step 9.
**Observation**: This TCC permission check is independent, can run at `initialize()` time or in parallel with everything else.

```swift
// In DefaultContainerEngine.initialize():
try verifyHostDirectoryAccess()  // Fail fast, before any heavy work
```

#### Opportunity E: Post-launch parallelism already exists (but can be improved)

**Current**: `PostLaunchHandler.handle()` runs health check, communication setup, and port forwarding sequentially.
**Observation**: Communication setup and health check are independent. Port forwarding setup only needs the pod (not health check results).

```swift
// PROPOSED: Run health check and communication setup in parallel
async let healthResult = diagnosticsHelper.testHTTPResponseWithRetry(pod: pod, port: port)
async let commResult   = setupCommunication(pod: pod, port: port)
// Port forwarding can start as soon as pod is available (it already is)
async let forwardResult = setupPortForwarding(pod: pod, port: port)
```

### 1.4 Proposed Optimized Pipeline — Single Container

```
TIME ──────────────────────────────────────────────────────────►

PARALLEL TRACK 1 (Image Pipeline):
  ├─ [Extract OCI tar] ─► [Import to store] ─► [Unpack EXT4 rootfs] ────────┐
  │                                          └─► [Extract image config] ──┐  │
  │                                                                       │  │
PARALLEL TRACK 2 (VM Pipeline):                                           │  │
  ├─ [Prepare init FS] ──┐                                                │  │
  ├─ [Load kernel] ──────┤                                                │  │
  │                       ├─► [Create VMM] ─► [Create Pod] ──┐            │  │
  │                                                          │            │  │
PARALLEL TRACK 3 (Validation):                                │            │  │
  ├─ [Verify host dir access]                                │            │  │
  ├─ [Check prerequisites]                                   │            │  │
                                                             │            │  │
BARRIER: Wait for all tracks ◄───────────────────────────────┴────────────┴──┘
  │
  ├─ [Add container to pod] (needs rootfs + config + pod)
  ├─ [pod.create() + startContainer()] (VM boot + container start)
  │
  ├─ POST-LAUNCH (parallel):
  │    ├─ [Health check]
  │    ├─ [Communication setup]
  │    └─ [Port forwarding]
```

**Expected total time reduction**: 30-50% for first boot, 20-35% for subsequent boots (init.block cached).

### 1.5 Implementation Sketch — Parallel `startFromImage`

```swift
func startFromImage(imageFile: URL, port: Int) async throws -> LinuxPod {
    let platform = Platform(arch: "arm64", os: "linux", variant: "v8")

    // ═══════════════════════════════════════════════════════
    // PHASE 1: All-parallel resource preparation
    // ═══════════════════════════════════════════════════════

    // Track 1: Image pipeline (extract → import → unpack)
    async let imageTask = imageLoader.loadFromFile(imageFile)

    // Track 2: VM foundation (init FS + kernel — zero image dependency)
    async let initfsTask = podFactory.prepareInitFilesystem()

    // Wait for image (needed for rootfs + config)
    let image = try await imageTask

    // Now fork: rootfs preparation and config extraction in parallel
    async let rootfsTask   = imageService.prepareRootfs(from: image, platform: platform)
    async let configTask   = ImageConfigExtractor(image: image, platform: platform).extract()

    // Wait for VM foundation (needed for pod creation)
    let initfs = try await initfsTask

    // Create pod while rootfs is still preparing
    let podID = "container-\(UUID().uuidString.prefix(8))"
    let pod = try await podFactory.createPod(podID: podID, initfs: initfs)

    // ═══════════════════════════════════════════════════════
    // PHASE 2: Assembly (must wait for all resources)
    // ═══════════════════════════════════════════════════════

    let rootfsURL = try await rootfsTask
    let imageConfig = try await configTask
    let rootfs = podFactory.createRootfsMount(from: rootfsURL)

    // Add container (needs rootfs + config + pod — all now ready)
    let containerConfig = buildContainerConfig(imageConfig, rootfs, port)
    try await podFactory.addContainer(to: pod, config: containerConfig)

    // ═══════════════════════════════════════════════════════
    // PHASE 3: Boot
    // ═══════════════════════════════════════════════════════

    try await pod.create()
    try await pod.startContainer("main")

    return pod
}
```

---

## Part 2: Multi-Container Parallel Loading Architecture

### 2.1 Current Limitation — Single Container at a Time

The current architecture has these hard constraints preventing multi-container:

| Constraint | Location | Nature |
|---|---|---|
| `DefaultContainerEngine` holds a single `currentPod` | `DefaultContainerEngine.swift:52` | Architecture |
| `@MainActor` on engine and coordinators | Multiple files | Concurrency |
| Fixed network address `192.168.127.2/24` | `PodFactory.swift:39` | Network |
| Single `ContainerOperations` instance | `DefaultContainerEngine.swift:69` | State |
| Single `communicationManager` and `portForwarder` | `DefaultContainerEngine.swift:59-60` | State |
| Fixed `containerID: "main"` | `StartupCoordinator.swift:105` | Naming |

### 2.2 Architecture Vision — Multi-Container Engine

#### Core Concept: Container Registry with Isolated Pods

```
┌──────────────────────────────────────────────────────────────────┐
│                     MultiContainerEngine                         │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │              ContainerRegistry (actor)                    │    │
│  │                                                          │    │
│  │  containers: [ContainerID: ContainerInstance]             │    │
│  │                                                          │    │
│  │  ┌─────────────────┐  ┌─────────────────┐               │    │
│  │  │ ContainerInstance│  │ ContainerInstance│  ...          │    │
│  │  │ id: "web-app"   │  │ id: "api-server"│               │    │
│  │  │ pod: LinuxPod   │  │ pod: LinuxPod   │               │    │
│  │  │ status: running │  │ status: loading │               │    │
│  │  │ network: .2/24  │  │ network: .3/24  │               │    │
│  │  │ hostPort: 3000  │  │ hostPort: 3001  │               │    │
│  │  │ comm: CommMgr   │  │ comm: CommMgr   │               │    │
│  │  │ ops: ContOps    │  │ ops: ContOps    │               │    │
│  │  │ forwarder: TCP  │  │ forwarder: TCP  │               │    │
│  │  └─────────────────┘  └─────────────────┘               │    │
│  └──────────────────────────────────────────────────────────┘    │
│                                                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────────────┐      │
│  │ SharedImageStore│ │ NetworkPool │  │ ResourceLimiter   │      │
│  │ (shared across  │ │ (IP alloc)  │  │ (CPU/mem budget)  │      │
│  │  all containers)│ │             │  │                   │      │
│  └──────────────┘  └──────────────┘  └───────────────────┘      │
└──────────────────────────────────────────────────────────────────┘
```

### 2.3 Key Architectural Changes Required

#### Change 1: ContainerInstance — Self-Contained Unit

Each container must be a fully isolated unit with its own lifecycle:

```swift
/// A single container instance with all its associated resources.
actor ContainerInstance {
    let id: ContainerID
    let pod: LinuxPod
    let communicationManager: CommunicationManager
    let containerOperations: ContainerOperations
    let portForwarder: TcpPortForwarder?
    private(set) var status: ContainerStatus

    // Each instance owns its own lifecycle
    func start() async throws { ... }
    func stop() async throws { ... }
    func exec(_ command: [String]) async throws -> ExecResult { ... }
}
```

#### Change 2: NetworkPool — Dynamic IP Allocation

The current hardcoded `192.168.127.2/24` must become a managed pool:

```swift
/// Manages IP address allocation for multiple containers in the vmnet subnet.
actor NetworkPool {
    /// The vmnet subnet (e.g., 192.168.127.0/24)
    private let subnet: CIDRv4
    /// Gateway is always .1 (e.g., 192.168.127.1)
    private let gateway: IPv4Address
    /// Available host addresses (.2 through .254)
    private var available: Set<UInt8>  // [2, 3, 4, ... 254]
    /// Currently leased addresses
    private var leased: [ContainerID: UInt8]

    func lease(for containerID: ContainerID) throws -> (address: String, gateway: String) {
        guard let octet = available.popFirst() else {
            throw ContainerizationError(.resourceExhausted,
                message: "No IP addresses available (max 253 containers)")
        }
        leased[containerID] = octet
        return (
            address: "192.168.127.\(octet)/24",
            gateway: "192.168.127.1"
        )
    }

    func release(for containerID: ContainerID) {
        if let octet = leased.removeValue(forKey: containerID) {
            available.insert(octet)
        }
    }
}
```

#### Change 3: Shared EventLoopGroup

Currently each engine creates its own `MultiThreadedEventLoopGroup(numberOfThreads: 2)`. For multi-container, a shared group prevents thread explosion:

```swift
/// Shared NIO event loop group scaled to machine capabilities.
/// Rule of thumb: 2 threads per container, capped at available cores.
let sharedEventLoopGroup = MultiThreadedEventLoopGroup(
    numberOfThreads: min(System.coreCount, maxContainers * 2)
)
```

#### Change 4: ResourceLimiter — Budget-Based Scheduling

Prevent over-subscription of host resources:

```swift
actor ResourceLimiter {
    let totalCPUs: Int          // Available host cores
    let totalMemoryBytes: UInt64 // Available host memory
    private var allocatedCPUs: Int = 0
    private var allocatedMemory: UInt64 = 0

    /// Check if a new container can be admitted.
    func canAdmit(cpus: Int, memoryBytes: UInt64) -> Bool {
        return (allocatedCPUs + cpus <= totalCPUs) &&
               (allocatedMemory + memoryBytes <= totalMemoryBytes)
    }

    /// Reserve resources for a container.
    func reserve(cpus: Int, memoryBytes: UInt64) throws {
        guard canAdmit(cpus: cpus, memoryBytes: memoryBytes) else {
            throw ContainerizationError(.resourceExhausted,
                message: "Insufficient resources: need \(cpus) CPUs + \(memoryBytes/1024/1024)MB, "
                       + "available: \(totalCPUs - allocatedCPUs) CPUs + \((totalMemoryBytes - allocatedMemory)/1024/1024)MB")
        }
        allocatedCPUs += cpus
        allocatedMemory += memoryBytes
    }

    func release(cpus: Int, memoryBytes: UInt64) {
        allocatedCPUs = max(0, allocatedCPUs - cpus)
        allocatedMemory = max(0, allocatedMemory &- memoryBytes)
    }
}
```

### 2.4 Parallel Container Launch Strategy

#### Strategy: Phased Pipeline with Shared Resources

```
TIME ──────────────────────────────────────────────────────────────────►

SHARED PHASE (done once):
  ├─ [Load kernel] ─────────────────────────────┐
  ├─ [Prepare init FS (if not cached)] ─────────┤
  │                                              ▼
  │                                    kernel + initfs READY
  │
PARALLEL LAUNCH (per container):
  │
  │  Container A:                    Container B:                Container C:
  │  ├─ [Extract/Pull image A]       ├─ [Extract/Pull image B]   ├─ [Pull image C]
  │  ├─ [Unpack rootfs A]            ├─ [Unpack rootfs B]        ├─ [Unpack rootfs B]
  │  ├─ [Create Pod A (IP .2)]       ├─ [Create Pod B (IP .3)]   ├─ [Create Pod C (IP .4)]
  │  ├─ [Add container + boot]       ├─ [Add container + boot]   ├─ [Add container + boot]
  │  ├─ [Port forward :3000]         ├─ [Port forward :3001]     ├─ [Port forward :3002]
  │  ▼                               ▼                           ▼
  │  RUNNING                         RUNNING                     RUNNING
```

#### Implementation: `launchMultiple()`

```swift
/// Launch multiple containers in parallel with resource management.
func launchMultiple(_ specs: [ContainerSpec]) async throws -> [ContainerInstance] {
    // 1. Pre-validate all resources can be admitted
    for spec in specs {
        try resourceLimiter.reserve(cpus: spec.cpus, memoryBytes: spec.memory)
    }

    // 2. Prepare shared resources (kernel + initfs) once
    async let sharedKernel = loadKernel()
    async let sharedInitfs = prepareInitFilesystem()
    let kernel = try await sharedKernel
    let initfs = try await sharedInitfs

    // 3. Launch all containers in parallel using TaskGroup
    return try await withThrowingTaskGroup(of: ContainerInstance.self) { group in
        for spec in specs {
            group.addTask {
                let network = try await self.networkPool.lease(for: spec.id)
                return try await self.launchSingle(
                    spec: spec,
                    kernel: kernel,
                    initfs: initfs,
                    networkAddress: network.address,
                    networkGateway: network.gateway
                )
            }
        }

        var results: [ContainerInstance] = []
        for try await instance in group {
            results.append(instance)
        }
        return results
    }
}
```

### 2.5 Concurrency Concerns and @MainActor Strategy

#### Problem: `@MainActor` on everything blocks parallelism

Currently, `DefaultContainerEngine`, `StartupCoordinator`, `PostLaunchHandler`, `ContainerOperations`, and `TcpPortForwarder` are all `@MainActor`. This means only one can execute at a time on the main thread.

#### Solution: Move to actor isolation per-container

```
CURRENT:                              PROPOSED:
┌─────────────────────────┐           ┌─────────────────────────┐
│     @MainActor          │           │     @MainActor          │
│ ┌─────────────────────┐ │           │ (only UI state updates) │
│ │ Engine              │ │           └──────────┬──────────────┘
│ │ StartupCoordinator  │ │                      │
│ │ PostLaunchHandler   │ │           ┌──────────▼──────────────┐
│ │ ContainerOperations │ │           │   ContainerRegistry     │
│ │ TcpPortForwarder    │ │           │   (actor - not MainActor)│
│ │ ... everything ...  │ │           │                         │
│ └─────────────────────┘ │           │  ┌──actor──┐ ┌──actor──┐│
└─────────────────────────┘           │  │Instance │ │Instance ││
                                      │  │   A     │ │   B     ││
All work serialized on               │  └─────────┘ └─────────┘│
main thread. No parallelism.         └─────────────────────────┘
                                      Each instance runs on its
                                      own actor = true parallelism
```

**Key change**: Replace `@MainActor` with regular `actor` isolation on everything except the thin UI notification layer:

```swift
// Only the delegate bridge stays on @MainActor
@MainActor
protocol ContainerEngineDelegate {
    func engineDidUpdateState(_ engine: any ContainerEngine)
    func engine(_ engine: any ContainerEngine, didUpdateProgress: String)
}

// Everything else becomes a regular actor or nonisolated
actor ContainerInstance { ... }
actor ContainerRegistry { ... }
actor NetworkPool { ... }
```

### 2.6 Shared Image Store — Deduplication

When multiple containers use the same base image (e.g., all using `node:20-alpine`), we should deduplicate:

```swift
actor SharedImageCache {
    private var prepared: [String: URL] = [:]  // imageRef → rootfs path
    private var inFlight: [String: Task<URL, Error>] = [:]

    /// Get or prepare a rootfs, deduplicating concurrent requests for the same image.
    func rootfs(for imageRef: String, prepare: () async throws -> URL) async throws -> URL {
        // Already prepared?
        if let cached = prepared[imageRef] {
            return cached
        }

        // Already being prepared by another container?
        if let existing = inFlight[imageRef] {
            return try await existing.value
        }

        // First request — start preparation
        let task = Task {
            try await prepare()
        }
        inFlight[imageRef] = task

        let result = try await task.value
        prepared[imageRef] = result
        inFlight.removeValue(forKey: imageRef)
        return result
    }
}
```

**Important**: Each container still needs its **own copy** of the rootfs EXT4 file (since the container writes to it). But the OCI layer unpacking can be done once and then copied via `clonefile()` (which is nearly free on APFS due to copy-on-write).

```swift
// Use APFS clonefile for near-instant rootfs duplication
func cloneRootfs(from source: URL, for containerID: String) throws -> URL {
    let dest = workDir.appendingPathComponent("\(containerID).ext4")
    // clonefile is O(1) on APFS — no actual data copy
    let result = clonefile(source.path, dest.path, 0)
    guard result == 0 else {
        // Fallback to regular copy on non-APFS
        try FileManager.default.copyItem(at: source, to: dest)
        return dest
    }
    return dest
}
```

### 2.7 Port Allocation Strategy

Each container needs a unique host port. Options:

```swift
actor PortAllocator {
    private var nextPort: UInt16
    private var allocated: Set<UInt16> = []

    init(basePort: UInt16 = 3000) {
        self.nextPort = basePort
    }

    /// Allocate the next available port.
    func allocate() throws -> UInt16 {
        let port = nextPort
        guard port < 65535 else {
            throw ContainerizationError(.resourceExhausted, message: "No ports available")
        }
        allocated.insert(port)
        nextPort += 1
        return port
    }

    /// Allocate a specific port (for user-specified mappings).
    func allocate(specific port: UInt16) throws -> UInt16 {
        guard !allocated.contains(port) else {
            throw ContainerizationError(.invalidArgument,
                message: "Port \(port) already allocated to another container")
        }
        allocated.insert(port)
        return port
    }

    func release(_ port: UInt16) {
        allocated.remove(port)
    }
}
```

---

## Part 3: Bottleneck Analysis & Estimated Impact

### 3.1 Time Profile of Current Sequential Pipeline

| Step | Operation | Est. Time | Bottleneck Type |
|------|-----------|-----------|-----------------|
| 1 | OCI tar extraction | 1-3s | Disk I/O |
| 2 | Image store import | 0.5-1s | Disk I/O |
| 3 | EXT4 rootfs unpack | 3-10s | CPU + Disk I/O (heaviest) |
| 4 | Init FS generation | 2-5s (first) / 0s (cached) | Disk I/O |
| 5 | Kernel loading | 0.1-0.5s | Disk I/O |
| 6 | VMM creation | <0.1s | CPU (negligible) |
| 7 | Pod creation | 0.1-0.5s | CPU |
| 8 | Config extraction | <0.1s | CPU (negligible) |
| 9 | Add container | 0.1-0.5s | CPU |
| 10 | VM boot + container start | 3-8s | VM Boot (heaviest) |
| - | Post-launch (health+comm+fwd) | 2-5s | Network I/O + wait |
| | **Total (first boot)** | **~12-34s** | |
| | **Total (cached init.block)** | **~10-29s** | |

### 3.2 Projected Times After Parallelization

**Single container, optimized pipeline:**

| Phase | Operations (parallel) | Est. Time |
|-------|----------------------|-----------|
| Phase 1a | Extract/Import OCI tar + Init FS + Kernel | max(1-3s, 2-5s first / 0s cached, 0.5s) |
| Phase 1b | Unpack rootfs + Extract config + Create VMM/Pod | max(3-10s, 0.1s, 0.6s) |
| Phase 2 | Add container + Boot | 3-8s |
| Phase 3 | Health + Comm + Port fwd (parallel) | max(2s, 0.5s, 0.5s) |
| | **Total (first boot, parallel)** | **~10-23s** |
| | **Total (cached, parallel)** | **~8-20s** |

**Multiple containers (N=3), parallel:**

| Scenario | Sequential (N×single) | Parallel | Savings |
|----------|----------------------|----------|---------|
| 3 containers, first boot | ~36-102s | ~12-25s | ~66-75% |
| 3 containers, cached | ~30-87s | ~10-22s | ~67-75% |
| 3 containers, same image | ~30-87s | ~9-20s | ~70-77% |

### 3.3 Top 3 Highest-Impact Changes (Priority Order)

1. **Parallel init FS + kernel + image loading** (Part 1, Opportunity A+C)
   - Effort: Low (restructure async let calls in StartupCoordinator)
   - Impact: 2-5s savings per launch
   - Risk: Low (no architectural changes)

2. **APFS clonefile for rootfs deduplication** (Part 2, Section 2.6)
   - Effort: Medium (add SharedImageCache actor)
   - Impact: Eliminates 3-10s per duplicate image in multi-container
   - Risk: Low (clonefile is well-tested on APFS)

3. **Actor-per-container isolation** (Part 2, Section 2.5)
   - Effort: High (refactor @MainActor → actor isolation)
   - Impact: Enables true multi-container parallelism
   - Risk: Medium (requires careful Sendable conformance audit)

---

## Part 4: Summary of Recommended Changes

### Phase 1 — Quick Wins (Single Container Speed)

| # | Change | File(s) | Effort |
|---|--------|---------|--------|
| 1 | Parallel `async let` for init FS + kernel + image loading | `StartupCoordinator.swift` | Small |
| 2 | Parallel image config extraction with rootfs prep | `StartupCoordinator.swift` | Small |
| 3 | Move host directory access check to `initialize()` | `DefaultContainerEngine.swift` | Small |
| 4 | Parallel post-launch (health + comm + forwarding) | `PostLaunchHandler.swift` | Small |
| 5 | Expose `loadKernel()` from PodFactory for early loading | `PodFactory.swift` | Small |

### Phase 2 — Multi-Container Foundation

| # | Change | New/Modified | Effort |
|---|--------|-------------|--------|
| 6 | Introduce `ContainerInstance` actor | New file | Medium |
| 7 | Introduce `ContainerRegistry` actor | New file | Medium |
| 8 | Introduce `NetworkPool` for IP allocation | New file | Medium |
| 9 | Introduce `PortAllocator` | New file | Small |
| 10 | Introduce `ResourceLimiter` | New file | Medium |
| 11 | Refactor `DefaultContainerEngine` → multi-container | Major refactor | Large |

### Phase 3 — Advanced Optimizations

| # | Change | Detail | Effort |
|---|--------|--------|--------|
| 12 | `SharedImageCache` with APFS `clonefile()` | Deduplicate rootfs across containers | Medium |
| 13 | Remove `@MainActor` from non-UI code | Enable true parallelism | Large |
| 14 | Shared `EventLoopGroup` across containers | Prevent thread explosion | Small |
| 15 | Pre-warmed VM pool (keep idle VMs booted) | Near-instant container start | Large |

---

## Appendix A: Pre-Warmed VM Pool (Advanced Concept)

The ultimate speed optimization: keep a pool of booted VMs waiting for containers.

```
                    ┌─────────────────────────────────┐
                    │         VM Pool Manager          │
                    │                                  │
                    │  Pool: [VM₁(idle), VM₂(idle)]    │
                    │  Max: 3, Min: 1, Warm: 2         │
                    └──────────────┬──────────────────┘
                                   │
    startContainer("web-app") ─────┤
                                   │
                    ┌──────────────▼──────────────────┐
                    │  1. Grab idle VM₁ from pool      │
                    │  2. Attach rootfs + config        │
                    │  3. Start container process       │
                    │  4. Replenish: boot VM₃ in bg     │
                    └─────────────────────────────────┘

    Result: Container starts in ~1-2s instead of ~8-15s
            (VM boot time is completely eliminated)
```

This is the equivalent of what cloud providers do with "warm pools" and "firecracker microVMs". The VM boot (3-8s) is removed from the critical path entirely.

---

*Research completed: March 2026*
*Codebase analyzed: EmbedDock (embeddock-maccontain) on development branch*
