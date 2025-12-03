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

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                             macOS Host                                       │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                        HelloWorldApp (SwiftUI)                          ││
│  │  ┌───────────────┐  ┌──────────────────┐  ┌─────────────────────────┐  ││
│  │  │ ContentView   │  │ ContainerManager │  │ TcpPortForwarder        │  ││
│  │  │ (UI Layer)    │──│ (Control Logic)  │──│ (Host Port Binding)     │  ││
│  │  └───────────────┘  └────────┬─────────┘  └──────────┬──────────────┘  ││
│  └──────────────────────────────┼───────────────────────┼──────────────────┘│
│                                 │                       │                    │
│  ┌──────────────────────────────┴───────────────────────┴──────────────────┐│
│  │                    Containerization Framework                           ││
│  │  ┌────────────────┐  ┌─────────────────┐  ┌──────────────────────────┐ ││
│  │  │ ImageStore     │  │ LinuxPod        │  │ VZVirtualMachineManager  │ ││
│  │  │ (OCI Images)   │  │ (Container Mgmt)│  │ (VM Lifecycle)           │ ││
│  │  └────────────────┘  └─────────────────┘  └──────────────────────────┘ ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                    │                                         │
│                          ┌─────────┴─────────┐                              │
│                          │   Vsock Bridge    │                              │
│                          │   (Host ↔ Guest)  │                              │
│                          └─────────┬─────────┘                              │
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

### Component Overview

| Component | Role |
|-----------|------|
| **ContentView** | SwiftUI interface for user interaction |
| **ContainerManager** | Orchestrates container lifecycle (pull, unpack, start, stop) |
| **ContainerCommunication** | Handles exec, HTTP requests, and message passing |
| **TcpPortForwarder** | Bridges host TCP ports to container via vsock |
| **ImageStore** | Manages OCI image storage and layer unpacking |
| **LinuxPod** | Represents a running container with its VM |
| **VZVirtualMachineManager** | Interfaces with Apple Virtualization Framework |
| **vminitd** | Linux binary running as PID 1 inside the VM |
| **vmexec** | Executes commands inside containers |

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

### Verifying Guest Binaries

Run the verification script to check binary integrity:

```bash
./scripts/setup-guest-binaries.sh verify
```

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
├── Package.swift                 # Swift package manifest
├── signing/
│   └── vz.entitlements          # Virtualization entitlement
├── scripts/
│   ├── setup-guest-binaries.sh  # Binary management script
│   └── versions.json            # Version tracking
├── Sources/
│   ├── HelloWorldApp/           # Main application
│   │   ├── main.swift           # App entry point & SwiftUI
│   │   ├── ContainerManager.swift    # Container lifecycle
│   │   ├── ContainerCommunication.swift  # Exec/HTTP comm
│   │   ├── TcpPortForwarder.swift    # Port forwarding
│   │   ├── AppDelegate.swift    # macOS app delegate
│   │   └── Resources/
│   │       ├── vminitd          # Guest init binary
│   │       └── vmexec           # Guest exec binary
│   ├── Containerization/        # Core container library
│   ├── ContainerizationOCI/     # OCI image handling
│   ├── ContainerizationEXT4/    # EXT4 filesystem
│   ├── ContainerizationArchive/ # Archive extraction
│   ├── ContainerizationIO/      # I/O utilities
│   ├── ContainerizationOS/      # OS abstractions
│   ├── ContainerizationNetlink/ # Netlink for networking
│   ├── ContainerizationExtras/  # Utility extensions
│   ├── ContainerizationError/   # Error types
│   ├── CShim/                   # C shims for syscalls
│   ├── cctl/                    # CLI tool
│   └── Integration/             # Integration utilities
└── bin/
    ├── cctl                     # Pre-built CLI
    └── containerization-integration
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

To rebuild or update:

```bash
# Verify existing binaries
./scripts/setup-guest-binaries.sh verify

# Download from GitHub (requires gh CLI)
./scripts/setup-guest-binaries.sh download

# Build using Docker (requires Docker)
./scripts/setup-guest-binaries.sh build-docker

# Show info
./scripts/setup-guest-binaries.sh info
```

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

### 1. Container Start Failure at Step 10 (RESTART REQUIRED)

**Issue**: Sometimes containers fail during the final startup step (Step 10).

**Symptoms**:
- App shows "Step 10/10: Starting container..." and then fails
- Error message may reference VM or process start failure
- Subsequent attempts also fail

**Root Cause**: Resource cleanup from previous container runs may be incomplete, or VM state becomes inconsistent.

**Solution**: 
1. **Restart the app** completely
2. Try starting the container again
3. If persistent, also restart your Mac to clear virtualization state

**Prevention**:
- Always click "Stop Container" before closing the app
- Wait for the stop operation to complete before quitting

---

### 2. Stop Container Button May Not Work

**Issue**: Clicking "Stop Container" sometimes doesn't stop the container properly.

**Symptoms**:
- Container status still shows as running after clicking stop
- App becomes unresponsive or hangs
- Subsequent container starts fail

**Root Cause**: The VM or container process may be in an inconsistent state, or the stop signal doesn't propagate correctly through the vsock bridge to vminitd.

**Solution**:
1. Wait 10-15 seconds for the stop operation to complete
2. If the app becomes unresponsive, **force quit** the app (Cmd+Q or Force Quit from Apple menu)
3. Restart the app before trying to start a new container

**Prevention**:
- Avoid stopping containers immediately after starting them
- Wait for the container to fully initialize before stopping
- Don't close the app window while a container is running - use "Stop Container" first

---

### 3. Port Forwarding May Not Work Initially

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

### 4. Docker Build Upstream Issue

**Issue**: `./scripts/setup-guest-binaries.sh build-docker` fails with `statfs` error.

**Root Cause**: Bug in upstream `apple/containerization` repository's `Cgroup2Manager.swift` - missing Linux system call import.

**Workaround**: Use pre-built binaries via `download` command or use existing verified binaries.

---

## 🔍 Troubleshooting

### Container Won't Start

1. **Check prerequisites**:
   ```bash
   ./scripts/setup-guest-binaries.sh verify
   ```

2. **Check kernel exists**:
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

- [ ] Better error recovery for Step 10 failures
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
