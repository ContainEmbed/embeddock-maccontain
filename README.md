# EmbedDock

[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange.svg)](https://swift.org)
[![macOS 15+](https://img.shields.io/badge/macOS-15+-blue.svg)](https://developer.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

A Swift library for running OCI-compliant Linux containers on macOS using Apple's Virtualization Framework. EmbedDock wraps [Apple's Containerization framework](https://github.com/apple/containerization) into a high-level, composable API for embedding container runtimes directly into macOS applications.

## Requirements

- **macOS 15.0+** (Sequoia)
- **Apple Silicon** (M1/M2/M3/M4)
- **Swift 6.2+**

## Installation

### Swift Package Manager

Add EmbedDock to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/ContainEmbed/embeddock-maccontain.git", from: "0.1.0"),
]
```

Then add the product to your target:

```swift
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "EmbedDock", package: "embeddock-maccontain"),
    ]
)
```

### Download VM Binaries

EmbedDock requires VM guest binaries (vminitd, vmexec, vmlinux, pre-init) that are not included in the git repository due to their size (~239MB). Download them after cloning:

```bash
./scripts/download-resources.sh
```

Or download a specific version:

```bash
./scripts/download-resources.sh 0.1.0
```

> **Note:** The download script uses `gh` CLI if available (handles authentication), otherwise falls back to `curl`.

### Entitlements

Applications using EmbedDock must be signed with the virtualization entitlement:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.virtualization</key>
    <true/>
</dict>
</plist>
```

Sign your binary after building:

```bash
codesign --force --sign - --entitlements vz.entitlements .build/arm64-apple-macosx/debug/YourApp
```

## Quick Start

```swift
import EmbedDock

// Create the container engine
let engine = try await ContainerEngineFactory.create(
    workDir: workDirectory,
    logger: logger
)

// Load an OCI image
try await engine.loadImage(from: imagePath)

// Start the container
try await engine.start()

// Execute a command
let output = try await engine.execute(["echo", "Hello from container!"])

// Stop when done
try await engine.stop()
```

## Architecture

EmbedDock is organized into focused modules:

| Module | Purpose |
|--------|---------|
| `ContainerEngine/` | Core engine: lifecycle, networking, file ops, image management |
| `Lifecycle/` | Container lifecycle orchestration (startup, cleanup, state) |
| `Container/` | Container creation, rootfs setup, pod factory |
| `Image/` | OCI image loading and registry management |
| `Communication/` | Host-guest communication (vsock, HTTP, Unix socket) |
| `PortForwarding/` | TCP port forwarding from host to container |
| `Diagnostics/` | Health probes and diagnostic reports |
| `Logging/` | Structured log handler |
| `Helpers/` | Utility types (OutputCollector, ResumableOnce) |
| `Types/` | Shared type definitions |

### How It Works

```
macOS Host
  YourApp (SwiftUI/AppKit/CLI)
    EmbedDock Library
      Apple Containerization Framework
        Virtualization.framework
          Linux VM (ARM64)
            vminitd (PID 1)
              Your Container (EXT4 rootfs)
```

1. **OCI image** is loaded from a `.tar`/`.tar.gz` file or pulled from a registry
2. **EXT4 rootfs** is created from the OCI layers
3. **Linux VM** boots using Apple's Virtualization Framework with a bundled kernel
4. **Container** runs inside the VM with process isolation
5. **Port forwarding** bridges host TCP ports to the container via vsock

## Examples

See [`Examples/HelloWorldApp/`](Examples/HelloWorldApp/) for a complete SwiftUI macOS application demonstrating EmbedDock usage. It includes:

- OCI image import and container lifecycle management
- Built-in terminal for executing commands inside containers
- File browser for the container filesystem
- Port forwarding configuration
- Real-time status monitoring

## Dependencies

| Package | Purpose |
|---------|---------|
| [apple/containerization](https://github.com/apple/containerization) | Core container runtime |
| [apple/swift-log](https://github.com/apple/swift-log) | Structured logging |
| [apple/swift-nio](https://github.com/apple/swift-nio) | Async networking |

## License

MIT License. See [LICENSE](LICENSE) for details.

Based on [Apple's Containerization framework](https://github.com/apple/containerization).
