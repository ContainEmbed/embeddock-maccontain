# 🐳 HelloWorldApp - Native macOS Container Runtime

[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange.svg)](https://swift.org)
[![macOS 15+](https://img.shields.io/badge/macOS-15+-blue.svg)](https://developer.apple.com/macos/)
[![Apple Virtualization](https://img.shields.io/badge/Framework-Apple%20Virtualization-purple.svg)](https://developer.apple.com/documentation/virtualization)
[![License](https://img.shields.io/badge/License-Apache%202.0-green.svg)](LICENSE)

A native macOS application that runs OCI-compliant Docker containers using Apple's Virtualization Framework. Built entirely in Swift, this project demonstrates how to run Linux containers on macOS without Docker Desktop.

---

## 📖 Table of Contents

- [Overview](#-overview)
- [Features](#-features)
- [Architecture](#-architecture)
- [Prerequisites](#-prerequisites)
- [Installation](#-installation)
- [Usage](#-usage)
- [How It Works](#-how-it-works)
- [Project Structure](#-project-structure)
- [Development Details](#-development-details)
- [Known Issues](#-known-issues)
- [Troubleshooting](#-troubleshooting)
- [Contributing](#-contributing)

---

## 🎯 Overview

HelloWorldApp is a proof-of-concept macOS application that can:

1. **Load OCI container images** (`.tar`, `.tar.gz`, `.tgz` files exported from Docker)
2. **Boot a lightweight Linux VM** using Apple's Virtualization Framework
3. **Run containers inside the VM** with full process isolation
4. **Forward ports** from your Mac to the container services
5. **Execute commands** inside running containers
6. **Provide a SwiftUI interface** for container management

This project is based on [Apple's Containerization framework](https://github.com/apple/containerization) and serves as a learning resource for understanding how container runtimes work at a low level.

---

## ✨ Features

### Container Management
- 📦 **OCI Image Import** - Load container images exported as tar archives
- 🚀 **One-Click Container Launch** - Start containers with automatic rootfs preparation
- 🛑 **Container Lifecycle Control** - Start, stop, and restart containers
- 📊 **Status Monitoring** - Real-time container status updates

### Container Interaction
- 🖥️ **Built-in Terminal** - Execute commands directly inside containers
- 📂 **File Browser** - Browse container filesystem (`/`, `/app`, `/tmp`)
- 🔄 **Process Viewer** - List running processes inside the container
- 🌐 **API Health Check** - Test HTTP endpoints inside containers

### Networking
- 🔌 **Port Forwarding** - Access container services from localhost
- 🌍 **NAT Networking** - Isolated container network with internet access
- 📡 **Vsock Communication** - High-performance host-guest communication

### User Interface
- 🎨 **Modern SwiftUI Design** - Native macOS look and feel
- 🔧 **Settings Panel** - Configure container port and other options
- 📋 **Quick Commands** - Pre-defined command buttons for common tasks

---

## 🏗️ Architecture

### System Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                             macOS Host                                       │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                        HelloWorldApp (SwiftUI)                          ││
│  │                                                                         ││
│  │  ┌─────────────┐  ┌────────────────────┐  ┌──────────────────────────┐ ││
│  │  │ Views &     │  │ ContentViewModel   │  │ ContainerManager         │ ││
│  │  │ Components  │──│ (MVVM Binding)     │──│ (Thin Orchestrator)      │ ││
│  │  └─────────────┘  └────────────────────┘  └──────────┬───────────────┘ ││
│  │                                                      │                  ││
│  │  ┌───────────────────────────────────────────────────┴────────────────┐ ││
│  │  │                   Composition Modules                              │ ││
│  │  │                                                                    │ ││
│  │  │  Lifecycle/         Image/          Container/       Diagnostics/  │ ││
│  │  │  ┌──────────────┐  ┌─────────────┐ ┌──────────────┐ ┌───────────┐ │ ││
│  │  │  │Startup       │  │ImageLoader  │ │PodFactory    │ │Diagnostics│ │ ││
│  │  │  │Coordinator   │  │ImageService │ │Container     │ │Helper     │ │ ││
│  │  │  │NodeServer    │  └─────────────┘ │Operations    │ └───────────┘ │ ││
│  │  │  │Coordinator   │                  │ContainerFile │               │ ││
│  │  │  │PostLaunch    │  Communication/  │System        │ PortForward/  │ ││
│  │  │  │Handler       │  ┌─────────────┐ └──────────────┘ ┌───────────┐ │ ││
│  │  │  │Cleanup       │  │Communication│                  │TcpPort    │ │ ││
│  │  │  │Coordinator   │  │Manager      │                  │Forwarder  │ │ ││
│  │  │  │Prerequisite  │  │HTTP/Vsock/  │                  │GuestBridge│ │ ││
│  │  │  │Checker       │  │UnixSocket   │                  │Connection │ │ ││
│  │  │  │StateMachine  │  └─────────────┘                  │Relay      │ │ ││
│  │  │  └──────────────┘                                   └───────────┘ │ ││
│  │  └────────────────────────────────────────────────────────────────────┘ ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                    Containerization Framework (Apple)                    ││
│  │  ImageStore · LinuxPod · VZVirtualMachineManager · Kernel · EXT4        ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                    │ Vsock                                   │
└────────────────────────────────────┼────────────────────────────────────────┘
                                     │
┌────────────────────────────────────┼────────────────────────────────────────┐
│                           Linux VM (ARM64)                                   │
│  ┌─────────────────────────────────┴───────────────────────────────────────┐│
│  │                          vminitd (PID 1)                                ││
│  │           Guest agent managing container lifecycle                      ││
│  └─────────────────────────────────┬───────────────────────────────────────┘│
│                                    │                                         │
│  ┌─────────────────────────────────┴───────────────────────────────────────┐│
│  │                         Container (EXT4 rootfs)                         ││
│  │  ┌─────────────────────────────────────────────────────────────────┐   ││
│  │  │  Your Application (e.g., Node.js Express server)                │   ││
│  │  │  - Runs with containerized filesystem                           │   ││
│  │  │  - Isolated network namespace (192.168.127.2)                   │   ││
│  │  │  - Accessible via port forwarding or internal curl              │   ││
│  │  └─────────────────────────────────────────────────────────────────┘   ││
│  └─────────────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────────┘
```

### Design Pattern: Composition-Based Orchestration

`ContainerManager` is a **thin orchestrator** that delegates every responsibility to focused, single-purpose modules. Both container launch paths (`startContainerFromImage` and `startNodeServer`) follow the same 3-phase pattern:

```
1. Pre-flight  →  ensureStoppedIfRunning() / checkPrerequisites()
2. Launch      →  StartupCoordinator  or  NodeServerCoordinator
3. Post-launch →  PostLaunchHandler (health, communication, port forwarding)
```

### Module Overview

#### Lifecycle (`Lifecycle/`)

| Module | Role |
|--------|------|
| **ContainerStateMachine** | Type-safe state machine (idle → initializing → running → stopping → failed) |
| **StartupCoordinator** | Multi-step OCI image → container launch pipeline |
| **NodeServerCoordinator** | Multi-step Node.js pull → configure → launch pipeline |
| **PostLaunchHandler** | Shared post-launch steps: health check, communication setup, port forwarding |
| **CleanupCoordinator** | Phased cleanup with per-phase and master timeouts |
| **PrerequisiteChecker** | Validates kernel, vminitd, vmexec, init.block presence |

#### Image (`Image/`)

| Module | Role |
|--------|------|
| **ImageLoader** | Loads OCI images from `.tar` / `.tar.gz` files |
| **ImageService** | Pulls images from registries, unpacks to EXT4 rootfs |

#### Container (`Container/`)

| Module | Role |
|--------|------|
| **PodFactory** | Creates LinuxPods with kernel, VM manager, and container config |
| **ContainerOperations** | High-level exec, file I/O, API health checks on running containers |
| **ContainerFileSystem** | File browsing and read/write inside running containers |

#### Communication (`Communication/`)

| Module | Role |
|--------|------|
| **CommunicationManager** | Central hub for container communication channels |
| **HTTPCommunicator** | HTTP-based communication via container IP |
| **VsockCommunicator** | High-performance Vsock host-guest communication |
| **UnixSocketCommunicator** | Unix domain socket communication |

#### Port Forwarding (`PortForwarding/`)

| Module | Role |
|--------|------|
| **TcpPortForwarder** | Bridges host TCP ports to container via vsock |
| **GuestBridge** | Manages socat process inside VM for vsock-to-TCP relay |
| **ConnectionRelay** | Per-connection bidirectional data relay |
| **ForwardingStatus** | Observable port forwarding state enum |

#### Diagnostics (`Diagnostics/`)

| Module | Role |
|--------|------|
| **DiagnosticsHelper** | Crash detection, health probes, diagnostic reports, system info |

#### UI Layer

| Module | Location | Role |
|--------|----------|------|
| **HelloWorldApp** | `App/` | SwiftUI app entry point |
| **ContentViewModel** | `ViewModels/` | MVVM view model for main content |
| **ContentView** | `Views/` | Main container management interface |
| **SettingsView** | `Views/` | Port and configuration settings |
| **ControlSection** | `Components/` | Start/stop buttons, image picker |
| **StatusSection** | `Components/` | Container status, system info, channels |
| **TerminalSection** | `Components/` | In-container command execution |
| **FilesSection** | `Components/` | Container file browser, boot log, diagnostics |

#### Infrastructure

| Module | Location | Role |
|--------|----------|------|
| **AppDelegate** | root | macOS application delegate, auto-start via CLI |
| **DebugLogHandler** | `Logging/` | Custom structured log handler |
| **OutputCollector** | `Helpers/` | Shared stdout/stderr collector for exec |
| **ResumableOnce** | `Helpers/` | One-shot async continuation helper |
| **vminitd** | `Resources/` | Linux binary — PID 1 inside the VM |
| **vmexec** | `Resources/` | Linux binary — command execution inside containers |

---

## 📋 Prerequisites

### System Requirements
- **macOS 15.0** (Sequoia) or later
- **Apple Silicon** (M1/M2/M3/M4) Mac - required for ARM64 Linux VMs
- **Xcode 16+** with Command Line Tools
- **Swift 6.2+** toolchain

### Required Components

1. **Linux Kernel** (`vmlinux`)
   - A Linux kernel compiled for ARM64
   - Download from [Kata Containers releases](https://github.com/kata-containers/kata-containers/releases)
   - Place at: `~/Library/Application Support/HelloWorldApp/containers/vmlinux`

2. **Guest Binaries** (included in Resources/)
   - `vminitd` - Init process for the Linux VM
   - `vmexec` - Command execution helper

---

## 🚀 Installation

### Quick Start

```bash
# Clone the repository
git clone <repository-url>
cd embeddock-maccontain

# Build the app (debug mode)
swift build

# Sign with virtualization entitlement
codesign --force --sign - --entitlements signing/vz.entitlements \
    .build/arm64-apple-macosx/debug/HelloWorldApp

# Run the app
.build/arm64-apple-macosx/debug/HelloWorldApp
```

### Using Make/Tasks

```bash
# Build and sign in one command (via VS Code task)
swift build && codesign --force --sign - --entitlements signing/vz.entitlements \
    .build/arm64-apple-macosx/debug/HelloWorldApp
```

### Release Build

```bash
# Build optimized release
swift build -c release

# Sign the release binary
codesign --force --sign - --entitlements signing/vz.entitlements \
    .build/arm64-apple-macosx/release/HelloWorldApp
```

---

## 📖 Usage

### Exporting a Docker Image

First, export your Docker container as a tar file:

```bash
# Build your Docker image
docker build -t my-app .

# Save to tar file
docker save my-app -o my-app.tar

# Or save with compression
docker save my-app | gzip > my-app.tar.gz
```

### Running a Container

1. **Launch HelloWorldApp**
2. **Click "Open OCI Image"** or use `Cmd+O`
3. **Select your `.tar` or `.tar.gz` file**
4. **Wait for container startup** (Steps 1-10 shown in status)
5. **Access your app** at `http://localhost:3000` (or configured port)

### Container Startup Steps

The app performs these steps when starting a container:

| Step | Description | Time |
|------|-------------|------|
| 1/10 | Extracting OCI image | ~2s |
| 2/10 | Importing to image store | ~1s |
| 3/10 | Unpacking to EXT4 rootfs | ~5-30s |
| 4/10 | Preparing init filesystem | ~1s |
| 5/10 | Loading Linux kernel | ~1s |
| 6/10 | Creating Virtual Machine | ~1s |
| 7/10 | Creating Linux Pod | ~1s |
| 8/10 | Extracting container config | <1s |
| 9/10 | Adding container to pod | ~1s |
| 10/10 | Starting container | ~2s |

### Using the Terminal Tab

Execute commands inside the running container:

```bash
# Examples of commands you can run
ls -la        # List files
ps aux        # Show processes
env           # Show environment variables
cat /etc/os-release  # Check Linux distribution
```

### Checking API Endpoints

Click **"Check API"** to test if your container's HTTP service is responding. This executes `curl` or `wget` inside the container to verify the service is up.

---

## ⚙️ How It Works

### 1. OCI Image Processing

When you open a `.tar` file:

```swift
// Extract tar file
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
process.arguments = ["-xzf", imageFile.path, "-C", tempExtractDir.path]
try process.run()

// Load into image store
let images = try await imageStore.load(from: tempExtractDir)
```

### 2. EXT4 Rootfs Creation

Container layers are unpacked into an EXT4 filesystem:

```swift
let unpacker = EXT4Unpacker(blockSizeInBytes: 2.gib())
let rootfsURL = try await unpacker.unpack(image, for: platform, at: rootfsURL)
```

### 3. Virtual Machine Creation

Apple's Virtualization Framework boots a Linux VM:

```swift
let vmm = VZVirtualMachineManager(
    kernel: kernel,
    initialFilesystem: initfs,
    group: eventLoop
)

let pod = try LinuxPod(podID, vmm: vmm, logger: logger) { config in
    config.cpus = 2
    config.memoryInBytes = 512.mib()
    config.interfaces = [
        NATInterface(address: "192.168.127.2/24", gateway: "192.168.127.1")
    ]
}
```

### 4. Container Execution

The container runs inside the VM with isolated resources:

```swift
try await pod.addContainer("main", rootfs: rootfs) { config in
    config.hostname = "container"
    config.process.arguments = command  // e.g., ["node", "server.js"]
    config.process.environmentVariables = envVars
}

try await pod.create()
try await pod.startContainer("main")
```

### 5. Port Forwarding

A vsock-based bridge enables host-to-container communication:

```
Host (localhost:3000)
        ↓ (NWListener accepts TCP)
TcpPortForwarder
        ↓ (pod.dialVsock connects to VM)
Vsock Port 5000
        ↓ (socat/nc inside VM)
Container (localhost:3000 inside VM)
```

### 6. Command Execution

Commands are executed via the vminitd agent:

```swift
let process = try await pod.execInContainer(
    "main",
    processID: "exec-\(UUID())",
    configuration: { config in
        config.arguments = ["ls", "-la"]
        config.stdout = outputCollector
    }
)
try await process.start()
let exitStatus = try await process.wait(timeoutInSeconds: 30)
```

---

## 📁 Project Structure

```
embeddock-maccontain/
├── Package.swift                          # Swift package manifest
├── README.md
├── LICENSE
├── app-config.json                        # Application configuration
├── sample-express-server.tar              # Sample OCI image for testing
├── signing/
│   └── vz.entitlements                    # Virtualization entitlement
├── bin/
│   ├── cctl                               # Pre-built CLI
│   └── containerization-integration       # Integration helper
│
└── Sources/
    ├── HelloWorldApp/                     # ── Main Application ──
    │   ├── ContainerManager.swift         # Thin orchestrator (composition root)
    │   ├── AppDelegate.swift              # macOS app delegate, CLI auto-start
    │   │
    │   ├── App/
    │   │   └── HelloWorldApp.swift        # @main SwiftUI entry point
    │   │
    │   ├── Lifecycle/                     # Container lifecycle coordination
    │   │   ├── ContainerState.swift       # State machine (ContainerState, StartupStep)
    │   │   ├── StartupCoordinator.swift   # OCI image → container pipeline
    │   │   ├── NodeServerCoordinator.swift # Node.js pull → container pipeline
    │   │   ├── PostLaunchHandler.swift    # Post-launch: health, comms, port forwarding
    │   │   ├── CleanupCoordinator.swift   # Phased shutdown with timeouts
    │   │   └── PrerequisiteChecker.swift  # Validates kernel, binaries, resources
    │   │
    │   ├── Image/                         # OCI image handling
    │   │   ├── ImageLoader.swift          # Load images from .tar/.tar.gz files
    │   │   └── ImageService.swift         # Pull from registries, unpack to EXT4
    │   │
    │   ├── Container/                     # Container runtime operations
    │   │   ├── PodFactory.swift           # Pod/VM creation with kernel & config
    │   │   ├── ContainerOperations.swift  # Exec, file I/O, API checks
    │   │   └── ContainerFileSystem.swift  # File browsing inside containers
    │   │
    │   ├── Communication/                 # Host ↔ container communication
    │   │   ├── CommunicationManager.swift # Central channel manager
    │   │   ├── Protocols.swift            # ContainerCommunicator protocol
    │   │   ├── Errors.swift               # Communication error types
    │   │   ├── HTTPCommunicator.swift     # HTTP channel implementation
    │   │   ├── VsockCommunicator.swift    # Vsock channel implementation
    │   │   └── UnixSocketCommunicator.swift # Unix socket channel
    │   │
    │   ├── PortForwarding/                # TCP port forwarding via vsock
    │   │   ├── TcpPortForwarder.swift     # Host TCP → container via vsock
    │   │   ├── GuestBridge.swift          # In-VM socat vsock-to-TCP bridge
    │   │   ├── ConnectionRelay.swift      # Per-connection data relay
    │   │   └── ForwardingStatus.swift     # Observable forwarding state
    │   │
    │   ├── Diagnostics/                   # Health & diagnostics
    │   │   └── DiagnosticsHelper.swift    # Crash detection, health probes, reports
    │   │
    │   ├── Views/                         # SwiftUI views
    │   │   ├── ContentView.swift          # Main container management view
    │   │   └── SettingsView.swift         # Port & configuration settings
    │   │
    │   ├── ViewModels/                    # MVVM view models
    │   │   └── ContentViewModel.swift     # Main view model
    │   │
    │   ├── Components/                    # Reusable SwiftUI sections
    │   │   ├── ControlSection.swift       # Start/stop buttons, image picker
    │   │   ├── StatusSection.swift        # Status, system info, channels
    │   │   ├── TerminalSection.swift      # In-container terminal
    │   │   ├── FilesSection.swift         # File browser, boot log, diagnostics
    │   │   └── NSTextFieldWrapper.swift   # AppKit text field bridge
    │   │
    │   ├── Helpers/                       # Shared utilities
    │   │   ├── OutputCollector.swift      # Stdout/stderr collector
    │   │   └── ResumableOnce.swift        # One-shot async continuation
    │   │
    │   ├── Logging/                       # Log infrastructure
    │   │   └── DebugLogHandler.swift      # Structured log handler
    │   │
    │   └── Resources/                     # Guest binaries
    │       ├── vminitd                    # Linux ARM64 — VM init (PID 1)
    │       └── vmexec                     # Linux ARM64 — exec helper
    │
    ├── Containerization/                  # Core container library (Apple)
    ├── ContainerizationOCI/               # OCI image spec handling
    ├── ContainerizationEXT4/              # EXT4 filesystem creation
    ├── ContainerizationArchive/           # Archive extraction
    ├── ContainerizationIO/                # I/O utilities
    ├── ContainerizationOS/                # OS abstractions
    ├── ContainerizationNetlink/           # Netlink for networking
    ├── ContainerizationExtras/            # Utility extensions
    ├── ContainerizationError/             # Error types
    ├── CShim/                             # C shims for syscalls
    ├── cctl/                              # CLI tool
    └── Integration/                       # Integration utilities
```

---

## 🔧 Development Details

### Key Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| swift-log | 1.6.3 | Structured logging |
| swift-argument-parser | 1.5.1 | CLI argument parsing |
| swift-nio | 2.85.0 | Async networking |
| swift-crypto | 3.12.3 | Cryptographic operations |
| grpc-swift | 1.26.1 | gRPC communication |
| swift-protobuf | 1.30.0 | Protocol buffers |
| async-http-client | 1.26.1 | HTTP client |
| swift-system | 1.5.0 | System call wrappers |

### Building Guest Binaries

The guest binaries (`vminitd`, `vmexec`) run inside the Linux VM. They are:

- **Architecture**: Linux ARM64 (aarch64)
- **Linking**: Statically linked (no external dependencies)
- **Size**: ~255-270 MB each (includes Swift runtime)
- **Purpose**: 
  - `vminitd` - Runs as PID 1, manages container lifecycle
  - `vmexec` - Executes commands inside containers

### Entitlements

The app requires the virtualization entitlement (`signing/vz.entitlements`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "...">
<plist version="1.0">
<dict>
    <key>com.apple.security.virtualization</key>
    <true/>
</dict>
</plist>
```

Without this entitlement, the app cannot create virtual machines.

### Logging

The app uses structured logging throughout. Enable debug logging:

```swift
LoggingSystem.bootstrap { label in
    var handler = StreamLogHandler.standardOutput(label: label)
    handler.logLevel = .debug
    return handler
}
```

Log output includes emoji prefixes for easy scanning:
- 🚀 Startup/Launch
- ✅ Success
- ❌ Error
- ⚠️ Warning
- 📦 Image/Container operations
- 🔧 Configuration
- 📡 Network operations
- 🖥️ Command execution

---

## ⚠️ Known Issues

### 1. Container Start at Step 10

**Improvement**: Step 10 now includes a **90-second timeout** with automatic crash detection and diagnostic capture. The `StartupCoordinator` and `NodeServerCoordinator` both perform immediate crash checks after container start.

**If Step 10 still fails**:
1. Check the **Diagnostics** button in the Files section for a captured `DiagnosticReport`
2. View the **Boot Log** for kernel/vminitd messages
3. Restart the app and try again
4. If persistent, restart your Mac to clear virtualization state

**Prevention**:
- Always click "Stop Container" before closing the app
- Wait for the cleanup to complete (uses `CleanupCoordinator` with phased timeouts)

---

### 2. Port Forwarding May Not Work Initially

**Issue**: After container starts, `localhost:3000` may not be accessible immediately.

**Symptoms**:
- Browser shows "Connection refused"
- "Check API" button works (uses internal curl) but external access fails

**Root Cause**: The vsock bridge inside the VM takes time to establish, or socat may need to be installed.

**Solution**:
- Wait 5-10 seconds after container start
- Click "Check API" to verify the service is running inside the container
- If port forwarding shows "Error", click the retry button

---

### 3. Large Binary Sizes

**Issue**: Guest binaries are ~255 MB each (~510 MB total).

**Root Cause**: Static linking of Swift runtime for Linux. Each binary includes the complete Swift standard library.

**Impact**: 
- Longer initial download/build times
- Larger app bundle size

**Note**: This is expected behavior for statically-linked Swift binaries.

---

## 🔍 Troubleshooting

### Container Won't Start

1. **Check kernel exists**:
   ```bash
   ls -la ~/Library/Application\ Support/HelloWorldApp/containers/vmlinux
   ```

3. **Check entitlements**:
   ```bash
   codesign -d --entitlements - .build/arm64-apple-macosx/debug/HelloWorldApp
   ```

### "No container is running" Error

The container may have crashed. Check the bootlog:
```bash
cat /tmp/bootlog-container-*.txt
```

### Port Already in Use

```bash
# Find what's using port 3000
lsof -i :3000

# Kill the process
kill -9 <PID>
```

### VM Cleanup

If VMs aren't being cleaned up properly:
```bash
# List running VM processes
ps aux | grep -i virtualization

# Force cleanup (restart may be safer)
pkill -f HelloWorldApp
```

### Reset Application State

```bash
# Remove all stored images and containers
rm -rf ~/Library/Application\ Support/HelloWorldApp
```

---

## 🤝 Contributing

Contributions are welcome! This project is educational and demonstrates:

1. Using Apple Virtualization Framework
2. OCI container image handling
3. Linux container runtime concepts
4. SwiftUI macOS application development
5. Vsock-based host-guest communication

### Development Setup

1. Fork the repository
2. Install Xcode 16+ and Swift 6.2
3. Build and test locally
4. Submit pull requests

### Areas for Improvement

- [x] Better error recovery for Step 10 failures (timeout + crash detection + diagnostic reports)
- [x] Modular architecture with composition pattern (12 focused modules)
- [x] Type-safe state machine for container lifecycle
- [x] Multi-channel communication (HTTP, Vsock, Unix Socket)
- [x] Phased cleanup with per-component timeouts
- [x] Diagnostic reports with system info capture
- [ ] Support for more container image formats
- [ ] Persistent container storage
- [ ] Multiple concurrent containers
- [ ] Network bridge instead of NAT
- [ ] GPU passthrough for ML workloads

---

## 📄 License

This project is licensed under the Apache License 2.0. See [LICENSE](LICENSE) for details.

Based on [Apple's Containerization framework](https://github.com/apple/containerization).

---

## 🙏 Acknowledgments

- **Apple Containerization Team** - For the foundational framework
- **Kata Containers Project** - For compatible Linux kernels
- **Swift Community** - For the excellent ecosystem

---

*Built with ❤️ for the macOS container community*
