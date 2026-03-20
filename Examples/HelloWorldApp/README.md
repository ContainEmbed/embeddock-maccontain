# HelloWorldApp - EmbedDock Example

A native macOS SwiftUI application demonstrating the EmbedDock library. Runs OCI-compliant Docker containers using Apple's Virtualization Framework.

## Features

- **OCI Image Import** - Load container images from `.tar`/`.tar.gz` files
- **One-Click Container Launch** - Start containers with automatic rootfs preparation
- **Built-in Terminal** - Execute commands inside running containers
- **File Browser** - Browse the container filesystem
- **Port Forwarding** - Access container services from localhost
- **Real-time Status** - Monitor container lifecycle, health, and networking

## Building

```bash
# From the Examples/HelloWorldApp/ directory:
swift build

# Sign with virtualization entitlement
codesign --force --sign - --entitlements vz.entitlements \
    .build/arm64-apple-macosx/debug/HelloWorldApp

# Run
.build/arm64-apple-macosx/debug/HelloWorldApp
```

## Usage

### Exporting a Docker Image

```bash
docker build -t my-app .
docker save my-app -o my-app.tar
```

### Running a Container

1. Launch HelloWorldApp
2. Click "Open OCI Image" or use `Cmd+O`
3. Select your `.tar` or `.tar.gz` file
4. Wait for container startup (Steps 1-10)
5. Access your app at `http://localhost:3000` (or configured port)

### Container Startup Steps

| Step | Description |
|------|-------------|
| 1/10 | Extracting OCI image |
| 2/10 | Importing to image store |
| 3/10 | Unpacking to EXT4 rootfs |
| 4/10 | Preparing init filesystem |
| 5/10 | Loading Linux kernel |
| 6/10 | Creating Virtual Machine |
| 7/10 | Creating Linux Pod |
| 8/10 | Extracting container config |
| 9/10 | Adding container to pod |
| 10/10 | Starting container |

## Architecture

The app follows a delegate-based MVVM pattern:

```
Views (SwiftUI)  <--@Published--  ContainerViewModel  --owns-->  ContainerEngine (Model)
```

### Project Structure

```
Sources/
  App/
    HelloWorldApp.swift        # @main SwiftUI entry point
  AppDelegate.swift            # macOS app delegate
  ViewModels/
    ContainerViewModel.swift   # Primary ViewModel
    ContentViewModel.swift     # Content-specific state
  Views/
    ContentView.swift          # Main container management view
    SettingsView.swift         # Port & configuration settings
  Components/
    ControlSection.swift       # Start/stop buttons, image picker
    StatusSection.swift        # Container status display
    TerminalSection.swift      # In-container terminal
    FilesSection.swift         # File browser, diagnostics
    NSTextFieldWrapper.swift   # AppKit text field bridge
```

## Troubleshooting

### Container Won't Start

1. Verify VM binaries are downloaded: `ls Sources/EmbedDock/Resources/`
2. Check entitlements: `codesign -d --entitlements - .build/arm64-apple-macosx/debug/HelloWorldApp`

### Port Forwarding Issues

- Wait 5-10 seconds after container start for the vsock bridge to establish
- Click "Check API" to verify the service is running inside the container
- Use the retry button if port forwarding shows "Error"

### Port Already in Use

```bash
lsof -i :3000
kill -9 <PID>
```

## Development

To use the local EmbedDock library during development, edit `Package.swift` and swap the dependency:

```swift
// Comment out the URL dependency:
// .package(url: "https://github.com/ContainEmbed/embeddock-maccontain.git", from: "0.1.0"),

// Uncomment the path dependency:
.package(path: "../../"),
```
