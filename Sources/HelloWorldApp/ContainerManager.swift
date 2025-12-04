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

import Foundation
import Containerization
import ContainerizationOCI
import ContainerizationArchive
import ContainerizationEXT4
import ContainerizationError
import Logging

// Type aliases to resolve ambiguities
typealias ContainerImage = Containerization.Image
typealias OCIMount = ContainerizationOCI.Mount
import ContainerizationExtras
import ContainerizationOS
import NIO

@MainActor
class ContainerManager: ObservableObject {
    @Published var isRunning = false
    @Published var statusMessage = "Ready"
    @Published var containerURL: String?
    
    private var imageStore: ImageStore?
    private var currentPod: LinuxPod?
    private let storeURL: URL
    private let workDir: URL
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private let logger: Logger
    
    // Communication layer
    private var communicationManager: ContainerCommunicationManager?
    @Published var isCommunicationReady = false
    
    // Port forwarding
    private var portForwarder: TcpPortForwarder?
    @Published var portForwardingStatus: ForwardingStatus = .inactive
    
    init() {
        // Set up image store location in user's Application Support
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        self.storeURL = appSupport.appendingPathComponent("HelloWorldApp/images")
        self.workDir = appSupport.appendingPathComponent("HelloWorldApp/containers")
        
        // Create directories if needed
        try? FileManager.default.createDirectory(
            at: storeURL,
            withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(
            at: workDir,
            withIntermediateDirectories: true
        )
        
        // Initialize logger
        var logger = Logger(label: "com.example.HelloWorldApp")
        logger.logLevel = .debug
        self.logger = logger
    }
    
    func initialize() async throws {
        logger.info("🔧 [ContainerManager] Initializing...")
        statusMessage = "Initializing image store..."
        
        logger.debug("📁 [ContainerManager] Creating image store at: \(self.storeURL.path)")
        self.imageStore = try ImageStore(path: storeURL)
        logger.info("✅ [ContainerManager] Image store created successfully")
        
        // Initialize event loop group for networking
        logger.debug("🌐 [ContainerManager] Creating event loop group with 2 threads")
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        logger.info("✅ [ContainerManager] Event loop group initialized")
        
        statusMessage = "Ready"
        logger.info("✅ [ContainerManager] Initialization complete")
    }
    
    deinit {
        logger.info("🔚 [ContainerManager] Deinitializing, shutting down event loop...")
        try? eventLoopGroup?.syncShutdownGracefully()
        logger.info("✅ [ContainerManager] Event loop shutdown complete")
    }
    
    // MARK: - Prerequisite Checking
    
    private func checkPrerequisites() throws {
        logger.info("🔍 [ContainerManager] Checking prerequisites...")
        
        // Check 1: vminitd
        do {
            let vminitdPath = try getVminitdPath()
            logger.info("✅ [ContainerManager] vminitd found at: \(vminitdPath.path)")
        } catch {
            logger.error("❌ [ContainerManager] vminitd NOT FOUND")
            logger.error("📝 [ContainerManager] Required: Build guest binaries with 'make guest-binaries' in vminitd/")
            logger.error("💡 [ContainerManager] See BINARY_BUILD_GUIDE.md for instructions")
            throw error
        }
        
        // Check 2: vmexec
        do {
            let vmexecPath = try getVmexecPath()
            logger.info("✅ [ContainerManager] vmexec found at: \(vmexecPath.path)")
        } catch {
            logger.error("❌ [ContainerManager] vmexec NOT FOUND")
            logger.error("📝 [ContainerManager] Required: Build guest binaries with 'make guest-binaries'")
            throw error
        }
        
        // Check 3: Kernel
        do {
            let kernelPath = try getKernelPath()
            logger.info("✅ [ContainerManager] Kernel found at: \(kernelPath.path)")
            
            // Check kernel size (should be > 10MB)
            let attrs = try FileManager.default.attributesOfItem(atPath: kernelPath.path)
            if let size = attrs[.size] as? Int64 {
                logger.info("📊 [ContainerManager] Kernel size: \(size / 1024 / 1024) MB")
            }
        } catch {
            logger.error("❌ [ContainerManager] Kernel (vmlinux) NOT FOUND")
            logger.error("📝 [ContainerManager] Expected locations:")
            logger.error("   - \(workDir.path)/vmlinux")
            logger.error("   - ~/.local/share/containerization/vmlinux")
            logger.error("💡 [ContainerManager] Download from: https://github.com/kata-containers/kata-containers/releases")
            logger.error("💡 [ContainerManager] Or build with 'make kernel' in kernel/")
            throw error
        }
        
        // Check 4: Init filesystem (optional - can be created)
        let initBlockURL = workDir.appendingPathComponent("init.block")
        if FileManager.default.fileExists(atPath: initBlockURL.path) {
            logger.info("✅ [ContainerManager] init.block found at: \(initBlockURL.path)")
        } else {
            logger.warning("⚠️ [ContainerManager] init.block NOT FOUND (will attempt to create)")
            logger.info("📝 [ContainerManager] Will be created at: \(initBlockURL.path)")
        }
        
        logger.info("✅ [ContainerManager] All prerequisites checked")
    }
    
    // MARK: - Resource Path Helpers
    
    private func getResourcePath(_ name: String) -> URL? {
        // Try to find in Bundle's Resources
        if let resourcePath = Bundle.main.resourcePath {
            let url = URL(fileURLWithPath: resourcePath).appendingPathComponent(name)
            logger.debug("🔍 [ContainerManager] Checking bundle resources: \(url.path)")
            if FileManager.default.fileExists(atPath: url.path) {
                logger.info("✅ [ContainerManager] Found in bundle: \(url.path)")
                return url
            }
        }
        
        // Try in source tree Resources directory for development
        if let executablePath = Bundle.main.executablePath {
            let execURL = URL(fileURLWithPath: executablePath)
            logger.debug("🔍 [ContainerManager] Executable path: \(executablePath)")
            // When running from .build/arm64-apple-macosx/debug, need to go up 4 levels
            let projectRoot = execURL.deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            logger.debug("🔍 [ContainerManager] Project root: \(projectRoot.path)")
            let sourceResourcesURL = projectRoot
                .appendingPathComponent("Sources/HelloWorldApp/Resources/\(name)")
            logger.debug("🔍 [ContainerManager] Checking source tree: \(sourceResourcesURL.path)")
            logger.debug("🔍 [ContainerManager] File exists: \(FileManager.default.fileExists(atPath: sourceResourcesURL.path))")
            if FileManager.default.fileExists(atPath: sourceResourcesURL.path) {
                logger.info("✅ [ContainerManager] Found in source tree: \(sourceResourcesURL.path)")
                return sourceResourcesURL
            }
        }
        
        logger.error("❌ [ContainerManager] Could not find resource: \(name)")
        return nil
    }
    
    private func getVminitdPath() throws -> URL {
        guard let path = getResourcePath("vminitd") else {
            throw ContainerizationError(.notFound, message: "vminitd binary not found in Resources/. Please build guest binaries first. See BINARY_BUILD_GUIDE.md")
        }
        return path
    }
    
    private func getVmexecPath() throws -> URL {
        guard let path = getResourcePath("vmexec") else {
            throw ContainerizationError(.notFound, message: "vmexec binary not found in Resources/. Please build guest binaries first.")
        }
        return path
    }
    
    private func getKernelPath() throws -> URL {
        // For now, we'll need a kernel binary. Users should provide it or we download it
        // Let's check common locations
        let possiblePaths = [
            workDir.appendingPathComponent("vmlinux"),
            URL(fileURLWithPath: "/opt/homebrew/share/containerization/vmlinux"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/share/containerization/vmlinux")
        ]
        
        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path.path) {
                return path
            }
        }
        
        throw ContainerizationError(.notFound, message: "Linux kernel (vmlinux) not found. Please download from kata-containers or build one.")
    }
    
    // MARK: - Image Pull
    
    func pullNodeImage(reference: String, platform: Platform? = nil) async throws -> ContainerImage {
        guard let imageStore = self.imageStore else {
            throw ContainerizationError(.notFound, message: "Image store not initialized")
        }
        
        statusMessage = "Parsing reference: \(reference)"
        let ref = try Reference.parse(reference)
        ref.normalize()
        
        let normalizedReference = ref.description
        statusMessage = "Pulling image: \(normalizedReference)"
        
        // Determine platform - default to current architecture
        let targetPlatform = platform ?? Platform(
            arch: "arm64", // Change to "amd64" if needed
            os: "linux"
        )
        
        // Check if image already exists
        if let existing = try? await imageStore.get(reference: normalizedReference) {
            statusMessage = "Image already exists locally"
            return existing
        }
        
        // Pull from registry
        statusMessage = "Downloading from registry..."
        let image = try await withAuthentication(ref: normalizedReference) { auth in
            return try await imageStore.pull(
                reference: normalizedReference,
                platform: targetPlatform,
                insecure: false,
                auth: auth
            )
        }
        
        guard let image = image else {
            throw ContainerizationError(.notFound, message: "Failed to pull image")
        }
        
        statusMessage = "Image pulled successfully"
        return image
    }
    
    // MARK: - Rootfs Preparation
    
    func prepareRootfs(from image: ContainerImage, platform: Platform) async throws -> URL {
        logger.debug("🏗️ [prepareRootfs] Starting rootfs preparation")
        statusMessage = "Preparing container rootfs..."
        
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HelloWorldApp-containers")
            .appendingPathComponent(UUID().uuidString)
        
        logger.debug("📂 [prepareRootfs] Creating temp directory: \(tempDir.path)")
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )
        logger.debug("✅ [prepareRootfs] Temp directory created")
        
        statusMessage = "Unpacking image layers..."
        logger.debug("🔧 [prepareRootfs] Creating EXT4 unpacker with 2 GiB block size")
        let unpacker = EXT4Unpacker(blockSizeInBytes: 2.gib())
        
        // Get manifest to determine image name
        logger.debug("📋 [prepareRootfs] Getting image index")
        _ = try await image.index()
        let name = image.reference.split(separator: "/").last.map(String.init) ?? "container"
        logger.debug("🏷️ [prepareRootfs] Image name: \(name)")
        
        let rootfsURL = tempDir.appendingPathComponent("\(name).ext4")
        logger.debug("📍 [prepareRootfs] Rootfs will be created at: \(rootfsURL.path)")
        
        statusMessage = "Creating EXT4 filesystem..."
        logger.info("📦 [prepareRootfs] Unpacking image layers to EXT4...")
        let _ = try await unpacker.unpack(image, for: platform, at: rootfsURL)
        logger.info("✅ [prepareRootfs] EXT4 filesystem created")
        
        statusMessage = "Rootfs ready at: \(rootfsURL.path)"
        logger.info("✅ [prepareRootfs] Rootfs preparation complete: \(rootfsURL.path)")
        return rootfsURL
    }
    
    // MARK: - Container Start
    
    func startContainerFromImage(imageFile: URL, port: Int) async throws {
        logger.info("🚀 [ContainerManager] Starting container from image file: \(imageFile.lastPathComponent)")
        
        // Stop any existing container first
        if isRunning {
            logger.warning("⚠️ [ContainerManager] Container already running, stopping it first...")
            statusMessage = "Stopping existing container..."
            do {
                try await stopContainer()
                logger.info("✅ [ContainerManager] Previous container stopped")
            } catch {
                logger.error("❌ [ContainerManager] Failed to stop previous container: \(error)")
                // Continue anyway - try to start new one
            }
        }
        
        // Check prerequisites FIRST before starting
        logger.info("🔍 [ContainerManager] Step 0/10: Checking prerequisites")
        statusMessage = "Checking prerequisites..."
        do {
            try checkPrerequisites()
            logger.info("✅ [ContainerManager] Prerequisites check passed")
        } catch {
            statusMessage = "❌ Missing prerequisites - check logs"
            logger.error("❌ [ContainerManager] Prerequisites check failed: \(error.localizedDescription)")
            throw error
        }
        
        logger.debug("🔄 [ContainerManager] Setting isRunning to true")
        isRunning = true
        defer {
            if !isRunning {
                logger.debug("🧹 [ContainerManager] Cleanup: Container failed to start, stopping pod if exists")
                // Cleanup on failure
                Task {
                    try? await self.currentPod?.stop()
                    self.currentPod = nil
                }
            }
        }
        
        do {
            logger.info("📦 [ContainerManager] Step 1/10: Extracting OCI image")
            statusMessage = "Step 1/10: Extracting OCI image..."
            
            guard let imageStore = self.imageStore else {
                throw ContainerizationError(.notFound, message: "Image store not initialized")
            }
            
            // Create temp directory for extraction
            let tempExtractDir = workDir.appendingPathComponent("temp-\(UUID().uuidString)")
            logger.debug("📂 [ContainerManager] Creating temp directory: \(tempExtractDir.path)")
            try FileManager.default.createDirectory(at: tempExtractDir, withIntermediateDirectories: true)
            logger.info("✅ [ContainerManager] Temp directory created")
            
            defer {
                logger.debug("🧹 [ContainerManager] Cleaning up temp directory")
                try? FileManager.default.removeItem(at: tempExtractDir)
            }
            
            // Extract tar file
            logger.info("📦 [ContainerManager] Extracting tar file using /usr/bin/tar")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            
            // Detect if it's compressed based on file extension
            let isCompressed = imageFile.pathExtension == "gz" || imageFile.pathExtension == "tgz"
            process.arguments = isCompressed ? 
                ["-xzf", imageFile.path, "-C", tempExtractDir.path] :
                ["-xf", imageFile.path, "-C", tempExtractDir.path]
            
            logger.debug("🔧 [ContainerManager] Running: tar \(process.arguments!.joined(separator: " "))")
            try process.run()
            process.waitUntilExit()
            
            logger.debug("📊 [ContainerManager] Tar process exit code: \(process.terminationStatus)")
            guard process.terminationStatus == 0 else {
                logger.error("❌ [ContainerManager] Tar extraction failed with code \(process.terminationStatus)")
                throw ContainerizationError(.internalError, message: "Failed to extract OCI image tar file")
            }
            logger.info("✅ [ContainerManager] Tar extraction complete")
            
            logger.info("📥 [ContainerManager] Step 2/10: Loading OCI image into image store")
            statusMessage = "Step 2/10: Importing container image..."
            let images = try await imageStore.load(from: tempExtractDir)
            logger.debug("📋 [ContainerManager] Loaded \(images.count) image(s)")
            
            guard let image = images.first else {
                logger.error("❌ [ContainerManager] No valid OCI image found in tar file")
                throw ContainerizationError(.notFound, message: "No valid OCI image found in tar file")
            }
            
            logger.info("✅ [ContainerManager] Loaded OCI image: \(image.reference)")
            
            logger.info("🔧 [ContainerManager] Step 3/10: Unpacking image layers to EXT4 rootfs")
            statusMessage = "Step 3/10: Unpacking container image..."
            logger.debug("🏗️ [ContainerManager] Creating platform config: arm64/linux/v8")
            let platform = Platform(arch: "arm64", os: "linux", variant: "v8")
            logger.debug("📦 [ContainerManager] Calling prepareRootfs()")
            let rootfsURL = try await prepareRootfs(from: image, platform: platform)
            logger.info("✅ [ContainerManager] Rootfs prepared at: \(rootfsURL.path)")
            
            logger.debug("🗂️ [ContainerManager] Creating rootfs mount object")
            let rootfs = Containerization.Mount.block(
                format: "ext4",
                source: rootfsURL.path,
                destination: "/",
                options: []
            )
            logger.debug("✅ [ContainerManager] Rootfs mount configured")
            
            logger.info("🗄️ [ContainerManager] Step 4/10: Preparing init filesystem")
            statusMessage = "Step 4/10: Preparing init filesystem..."
            
            let initBlockURL = workDir.appendingPathComponent("init.block")
            logger.debug("📍 [ContainerManager] Init block path: \(initBlockURL.path)")
            let initfs: Containerization.Mount
            
            if FileManager.default.fileExists(atPath: initBlockURL.path) {
                logger.info("✅ [ContainerManager] Using existing init.block")
                initfs = .block(format: "ext4", source: initBlockURL.path, destination: "/", options: ["ro"])
            } else {
                logger.warning("⚠️ [ContainerManager] init.block not found, attempting to create from vminitd image")
                logger.info("🔍 [ContainerManager] Looking for init image: vminit:latest")
                let initReference = "vminit:latest"
                do {
                    logger.debug("📥 [ContainerManager] Fetching init image from store")
                    let initImage = try await imageStore.getInitImage(reference: initReference)
                    logger.info("✅ [ContainerManager] Init image found, creating init.block")
                    initfs = try await initImage.initBlock(at: initBlockURL, for: SystemPlatform.linuxArm)
                    logger.info("✅ [ContainerManager] init.block created successfully")
                } catch {
                    logger.error("❌ [ContainerManager] Failed to get init image: \(error.localizedDescription)")
                    throw ContainerizationError(.notFound, message: "Init image 'vminit:latest' not found. Please create it first using: make init")
                }
            }
            
            logger.info("🐧 [ContainerManager] Step 5/10: Loading Linux kernel")
            statusMessage = "Step 5/10: Loading Linux kernel..."
            logger.debug("🔍 [ContainerManager] Getting kernel path")
            let kernelPath = try getKernelPath()
            logger.debug("📍 [ContainerManager] Kernel path: \(kernelPath.path)")
            
            var kernel = Kernel(path: .init(filePath: kernelPath.path), platform: .linuxArm)
            logger.debug("🔧 [ContainerManager] Adding debug to kernel command line")
            kernel.commandLine.addDebug()
            logger.info("✅ [ContainerManager] Kernel configured")
            
            logger.info("🖥️ [ContainerManager] Step 6/10: Creating Virtual Machine Manager")
            statusMessage = "Step 6/10: Starting virtual machine..."
            guard let eventLoop = eventLoopGroup else {
                logger.error("❌ [ContainerManager] Event loop group not initialized")
                throw ContainerizationError(.notFound, message: "Event loop not initialized")
            }
            logger.debug("✅ [ContainerManager] Event loop group available")
            
            logger.debug("🏗️ [ContainerManager] Creating VZVirtualMachineManager")
            let vmm = VZVirtualMachineManager(
                kernel: kernel,
                initialFilesystem: initfs,
                group: eventLoop
            )
            logger.info("✅ [ContainerManager] Virtual Machine Manager created")
            
            logger.info("🐳 [ContainerManager] Step 7/10: Creating Linux Pod")
            statusMessage = "Step 7/10: Creating container pod..."
            let podID = "container-\(UUID().uuidString.prefix(8))"
            logger.debug("🆔 [ContainerManager] Pod ID: \(podID)")
            logger.debug("🔧 [ContainerManager] Configuring pod: 2 CPUs, 512 MiB RAM, NAT networking")
            
            let bootlogPath = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bootlog-\(podID).txt")
            logger.info("📝 [ContainerManager] Bootlog will be saved to: \(bootlogPath.path)")
            let pod = try LinuxPod(podID, vmm: vmm, logger: logger) { config in
                config.cpus = 2
                config.memoryInBytes = 512.mib()
                config.interfaces = [
                    NATInterface(address: "192.168.127.2/24", gateway: "192.168.127.1")
                ]
                config.bootlog = bootlogPath
            }
            logger.info("✅ [ContainerManager] Linux Pod created with ID: \(podID)")
            
            logger.info("⚙️ [ContainerManager] Step 8/10: Extracting container configuration from image")
            statusMessage = "Step 8/10: Configuring container..."
            logger.debug("📋 [ContainerManager] Getting image config for platform")
            let imageConfig = try await image.config(for: platform)
            
            // Extract command and environment from image config
            let command = (imageConfig.config?.entrypoint ?? []) + (imageConfig.config?.cmd ?? ["/bin/sh"])
            let envVars = imageConfig.config?.env ?? ["PATH=/usr/local/bin:/usr/bin:/bin"]
            let containerWorkDir = imageConfig.config?.workingDir ?? "/"
            
            logger.info("📝 [ContainerManager] Container command: \(command.joined(separator: " "))")
            logger.debug("🌍 [ContainerManager] Environment: \(envVars.joined(separator: ", "))")
            logger.debug("📂 [ContainerManager] Working directory: \(containerWorkDir)")
            
            logger.info("➕ [ContainerManager] Step 9/10: Adding container to pod")
            statusMessage = "Step 9/10: Adding container to pod..."
            logger.debug("🔧 [ContainerManager] Configuring container 'main' with rootfs")
            try await pod.addContainer("main", rootfs: rootfs) { config in
                config.hostname = "container"
                config.process.arguments = command
                config.process.workingDirectory = containerWorkDir
                config.process.environmentVariables = envVars + ["PORT=\(port)"]
            }
            logger.info("✅ [ContainerManager] Container added to pod")
            
            logger.info("🚀 [ContainerManager] Step 10/10: Creating and starting the pod")
            statusMessage = "Step 10/10: Starting container..."
            logger.debug("🏗️ [ContainerManager] Creating pod")
            try await pod.create()
            logger.info("✅ [ContainerManager] Pod created")
            
            logger.debug("▶️ [ContainerManager] Starting container 'main'")
            try await pod.startContainer("main")
            logger.info("✅ [ContainerManager] Container started successfully")
            
            logger.debug("💾 [ContainerManager] Storing pod reference")
            self.currentPod = pod
            
            // NAT networking isolates the container - it's not directly accessible from host
            logger.info("📝 [TcpPortForwarder] Note: Container is running in isolated NAT network")
            let containerIP = "192.168.127.2"
            logger.info("📝 [TcpPortForwarder] Container accessible at: http://\(containerIP):\(port) (VM-internal only)")
            logger.info("💡 [TcpPortForwarder] To access from host, port forwarding needs to be configured")
            
            self.containerURL = "http://\(containerIP):\(port) (VM-internal)"
            statusMessage = "✅ Container running at \(containerIP):\(port) (inside VM)"
            
            logger.info("✅✅✅ [ContainerManager] Container started successfully!")
            logger.info("🧪 [ContainerManager] Testing container response...")
            
            // Test that the container is actually responding by curl from within the VM
            do {
                let curlProcess = try await pod.execInContainer(
                    "main",
                    processID: "test-curl",
                    configuration: { config in
                        config.arguments = ["curl", "-s", "-m", "5", "http://localhost:\(port)/"]
                        config.workingDirectory = "/"
                    }
                )
                try await curlProcess.start()
                let exitStatus = try await curlProcess.wait(timeoutInSeconds: 10)
                
                if exitStatus.exitCode == 0 {
                    logger.info("✅ [ContainerManager] Container HTTP server is responding!")
                    statusMessage = "✅ Container running and responding (VM-internal network)"
                } else {
                    logger.warning("⚠️ [ContainerManager] Container may not be responding yet (exit code: \(exitStatus.exitCode))")
                }
            } catch {
                logger.warning("⚠️ [ContainerManager] Could not test container response: \(error)")
            }
            
            // Initialize communication layer
            logger.info("🔗 [ContainerManager] Setting up communication layer...")
            self.communicationManager = ContainerCommunicationManager(pod: pod, logger: logger)
            do {
                _ = try await self.communicationManager?.setupHTTPCommunication(port: port)
                self.isCommunicationReady = true
                logger.info("✅ [ContainerManager] Communication layer ready")
            } catch {
                logger.warning("⚠️ [ContainerManager] Communication layer setup failed: \(error)")
            }
            
            // Start port forwarding for external access
            logger.info("🌐 [ContainerManager] Setting up port forwarding...")
            do {
                try await startPortForwarding(hostPort: UInt16(port), containerPort: UInt16(port))
                self.containerURL = "http://localhost:\(port)"
                statusMessage = "✅ Container running at localhost:\(port)"
            } catch {
                logger.warning("⚠️ [ContainerManager] Port forwarding setup failed: \(error)")
                logger.info("💡 [ContainerManager] Container still accessible via internal tools (Check API button)")
            }
            
        } catch {
            logger.error("❌ [ContainerManager] Container start failed: \(error.localizedDescription)")
            logger.debug("🔍 [ContainerManager] Full error: \(String(describing: error))")
            isRunning = false
            statusMessage = "❌ Failed: \(error.localizedDescription)"
            throw error
        }
    }
    
    func startNodeServer(jsFile: URL, imageName: String, port: Int) async throws {
        guard !isRunning else {
            throw ContainerizationError(.invalidState, message: "Container is already running")
        }
        
        isRunning = true
        defer {
            if !isRunning {
                // Cleanup on failure
                Task {
                    try? await self.currentPod?.stop()
                    self.currentPod = nil
                }
            }
        }
        
        do {
            // Step 1: Pull the Node.js image
            statusMessage = "Pulling container image: \(imageName)..."
            let image = try await pullNodeImage(reference: imageName)
            
            // Step 2: Unpack image to EXT4 rootfs
            statusMessage = "Unpacking container image..."
            let platform = Platform(arch: "arm64", os: "linux", variant: "v8")
            let rootfsURL = try await prepareRootfs(from: image, platform: platform)
            let rootfs = Containerization.Mount.block(
                format: "ext4",
                source: rootfsURL.path,
                destination: "/",
                options: []
            )
            
            // Step 3: Prepare init filesystem
            statusMessage = "Preparing init filesystem..."
            guard let imageStore = self.imageStore else {
                throw ContainerizationError(.notFound, message: "Image store not initialized")
            }
            
            // Get or create init.block
            let initBlockURL = workDir.appendingPathComponent("init.block")
            let initfs: Containerization.Mount
            
            if FileManager.default.fileExists(atPath: initBlockURL.path) {
                logger.info("Using existing init.block")
                initfs = .block(format: "ext4", source: initBlockURL.path, destination: "/", options: ["ro"])
            } else {
                logger.info("Creating init.block - checking for vminitd reference...")
                // Try to get init image from a known reference
                // Users should have already created this with: cctl rootfs create --vminitd ... --image vminit:latest
                let initReference = "vminit:latest"
                do {
                    let initImage = try await imageStore.getInitImage(reference: initReference)
                    initfs = try await initImage.initBlock(at: initBlockURL, for: SystemPlatform.linuxArm)
                } catch {
                    throw ContainerizationError(.notFound, message: "Init image 'vminit:latest' not found. Please create it first using: make init")
                }
            }
            
            // Step 4: Set up kernel
            statusMessage = "Loading Linux kernel..."
            let kernelPath = try getKernelPath()
            var kernel = Kernel(path: .init(filePath: kernelPath.path), platform: .linuxArm)
            kernel.commandLine.addDebug()
            
            // Step 5: Create Virtual Machine Manager
            statusMessage = "Starting virtual machine..."
            guard let eventLoop = eventLoopGroup else {
                throw ContainerizationError(.notFound, message: "Event loop not initialized")
            }
            
            let vmm = VZVirtualMachineManager(
                kernel: kernel,
                initialFilesystem: initfs,
                group: eventLoop
            )
            
            // Step 6: Create Linux Pod
            statusMessage = "Creating container pod..."
            let podID = "nodejs-server-\(UUID().uuidString.prefix(8))"
            let pod = try LinuxPod(podID, vmm: vmm, logger: logger) { config in
                config.cpus = 2
                config.memoryInBytes = 512.mib()
                config.interfaces = [
                    NATInterface(address: "192.168.127.2/24", gateway: "192.168.127.1")
                ]
            }
            
            // Step 7: Copy JS file into container-accessible location
            statusMessage = "Copying JavaScript file..."
            let appDir = workDir.appendingPathComponent("app")
            try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
            let destFile = appDir.appendingPathComponent(jsFile.lastPathComponent)
            try? FileManager.default.removeItem(at: destFile)
            try FileManager.default.copyItem(at: jsFile, to: destFile)
            
            // Step 8: Add container to pod
            statusMessage = "Configuring Node.js container..."
            try await pod.addContainer("nodejs", rootfs: rootfs) { config in
                config.hostname = "nodejs-container"
                config.process.arguments = ["node", "/app/\(jsFile.lastPathComponent)"]
                config.process.workingDirectory = "/app"
                config.process.environmentVariables = [
                    "PATH=/usr/local/bin:/usr/bin:/bin",
                    "NODE_ENV=production",
                    "PORT=\(port)"
                ]
                
                // Mount the JS file directory into the container using virtiofs
                config.mounts.append(
                    Containerization.Mount.share(
                        source: appDir.path,
                        destination: "/app",
                        options: ["ro"]
                    )
                )
            }
            
            // Step 9: Create and start the pod
            statusMessage = "Starting container..."
            try await pod.create()
            try await pod.startContainer("nodejs")
            
            // Store pod reference
            self.currentPod = pod
            
            // Update UI state
            self.containerURL = "http://localhost:\(port)"
            statusMessage = "✅ Container running on port \(port)"
            
            logger.info("Container started successfully")
            
        } catch {
            isRunning = false
            statusMessage = "❌ Failed: \(error.localizedDescription)"
            logger.error("Failed to start container: \(error)")
            throw error
        }
    }
    
    /// Robust container stop with guaranteed completion within 30 seconds.
    /// This is idempotent - calling it when no container is running is safe and succeeds.
    func stopContainer() async throws {
        logger.info("🛑 [ContainerManager] Stopping container (robust cleanup)")
        
        // Early exit if nothing to stop - but still clear any residual state
        guard let pod = currentPod else {
            logger.info("ℹ️ [ContainerManager] No container pod to stop, clearing residual state")
            forceClearState()
            return
        }
        
        statusMessage = "Stopping container..."
        
        // Master timeout: 30 seconds maximum for entire cleanup
        let masterTimeoutSeconds: UInt32 = 30
        
        do {
            try await Timeout.run(seconds: masterTimeoutSeconds) { [self] in
                await self.performCleanupSequence(pod: pod)
            }
        } catch is CancellationError {
            logger.error("❌ [ContainerManager] Cleanup timed out after \(masterTimeoutSeconds)s, forcing state clear")
        } catch {
            logger.error("❌ [ContainerManager] Cleanup error: \(error)")
        }
        
        // ALWAYS clear state - this runs regardless of any errors/timeouts above
        forceClearState()
        
        logger.info("✅ [ContainerManager] Container stopped")
    }
    
    /// Phase 1: Stop external-facing resources in parallel, then stop pod
    private func performCleanupSequence(pod: LinuxPod) async {
        // Phase 1: Stop port forwarding and communication in parallel
        logger.debug("🔄 [Cleanup] Phase 1: External resources")
        
        // Stop port forwarder with timeout
        await stopPortForwarderWithTimeout(timeoutSeconds: 5)
        
        // Stop communication manager with timeout
        await stopCommunicationWithTimeout(timeoutSeconds: 3)
        
        // Phase 2: Stop pod with 15 second timeout
        logger.debug("🔄 [Cleanup] Phase 2: Pod stop")
        await stopPodWithTimeout(pod: pod, timeoutSeconds: 15)
    }
    
    /// Stop port forwarder with timeout
    private func stopPortForwarderWithTimeout(timeoutSeconds: UInt32) async {
        guard let forwarder = portForwarder else { return }
        
        do {
            try await Timeout.run(seconds: timeoutSeconds) {
                await forwarder.stop()
            }
            logger.debug("✅ [Cleanup] Port forwarder stopped")
        } catch {
            logger.warning("⚠️ [Cleanup] Port forwarder stop timed out after \(timeoutSeconds)s")
        }
        
        // Always clear regardless of success
        portForwarder = nil
        portForwardingStatus = .inactive
    }
    
    /// Stop communication manager with timeout
    private func stopCommunicationWithTimeout(timeoutSeconds: UInt32) async {
        guard let commManager = communicationManager else { return }
        
        do {
            try await Timeout.run(seconds: timeoutSeconds) {
                await commManager.disconnect()
            }
            logger.debug("✅ [Cleanup] Communication manager disconnected")
        } catch {
            logger.warning("⚠️ [Cleanup] Communication disconnect timed out after \(timeoutSeconds)s")
        }
        
        // Always clear regardless of success
        communicationManager = nil
        isCommunicationReady = false
    }
    
    /// Stop pod with timeout
    private func stopPodWithTimeout(pod: LinuxPod, timeoutSeconds: UInt32) async {
        do {
            try await Timeout.run(seconds: timeoutSeconds) {
                try await pod.stop()
            }
            logger.debug("✅ [Cleanup] Pod stopped")
        } catch is CancellationError {
            logger.warning("⚠️ [Cleanup] Pod stop timed out after \(timeoutSeconds)s, VM may be orphaned")
        } catch {
            logger.warning("⚠️ [Cleanup] Pod stop error: \(error)")
        }
    }
    
    /// Force clear all state - ALWAYS succeeds, NEVER throws
    private func forceClearState() {
        logger.debug("🔄 [Cleanup] Force clearing state")
        
        // Clear all references (allows ARC to clean up)
        currentPod = nil
        portForwarder = nil
        communicationManager = nil
        
        // Reset UI state
        containerURL = nil
        isRunning = false
        isCommunicationReady = false
        portForwardingStatus = .inactive
        statusMessage = "Container stopped"
        
        logger.info("✅ [Cleanup] State cleared")
    }
    
    func checkContainerAPI(port: Int) async throws -> (statusCode: Int, body: String) {
        logger.info("🌐 [ContainerManager] Checking container API at localhost:\(port)")
        
        guard let pod = currentPod else {
            logger.warning("⚠️ [ContainerManager] No container is running")
            throw ContainerizationError(.invalidState, message: "No container is running")
        }
        
        logger.debug("📡 [ContainerManager] Executing curl inside container")
        
        // Create buffers to collect stdout and stderr
        final class OutputCollector: Writer, @unchecked Sendable {
            private let lock = NSLock()
            private var buffer = Data()
            
            func write(_ data: Data) throws {
                lock.withLock {
                    buffer.append(data)
                }
            }
            
            func close() throws {
                // No-op
            }
            
            func getOutput() -> Data {
                lock.withLock {
                    return buffer
                }
            }
        }
        
        let stdoutCollector = OutputCollector()
        let stderrCollector = OutputCollector()
        
        // First, check if curl exists, otherwise try wget
        let checkCurlProcess = try await pod.execInContainer(
            "main",
            processID: "check-curl-\(UUID().uuidString.prefix(8))",
            configuration: { config in
                config.arguments = ["which", "curl"]
                config.workingDirectory = "/"
            }
        )
        try await checkCurlProcess.start()
        let curlExists = try await checkCurlProcess.wait(timeoutInSeconds: 5)
        
        let useWget = curlExists.exitCode != 0
        
        // Execute curl or wget inside the container to check the API
        let curlProcess = try await pod.execInContainer(
            "main",
            processID: "api-check-\(UUID().uuidString.prefix(8))",
            configuration: { config in
                if useWget {
                    // Use wget as fallback (common in Alpine images)
                    config.arguments = [
                        "wget",
                        "-q",                     // Quiet mode
                        "-O", "-",                // Output to stdout
                        "-T", "10",               // 10 second timeout
                        "http://localhost:\(port)/"
                    ]
                } else {
                    // Use curl (preferred)
                    config.arguments = [
                        "curl",
                        "-X", "GET",              // Use GET for API check (more common)
                        "-w", "\n%{http_code}",   // Write HTTP status code on new line
                        "-s",                     // Silent mode
                        "-m", "10",               // 10 second timeout
                        "http://localhost:\(port)/"
                    ]
                }
                config.workingDirectory = "/"
                config.stdout = stdoutCollector
                config.stderr = stderrCollector
            }
        )
        
        logger.debug("▶️ [ContainerManager] Starting curl process")
        try await curlProcess.start()
        
        logger.debug("⏳ [ContainerManager] Waiting for curl to complete")
        let exitStatus = try await curlProcess.wait(timeoutInSeconds: 15)
        
        // Read both stdout and stderr
        let output = stdoutCollector.getOutput()
        let errorOutput = stderrCollector.getOutput()
        let outputString = String(decoding: output, as: UTF8.self)
        let errorString = String(decoding: errorOutput, as: UTF8.self)
        
        logger.debug("📄 [ContainerManager] Curl stdout:\n\(outputString)")
        logger.debug("📄 [ContainerManager] Curl stderr:\n\(errorString)")
        
        guard exitStatus.exitCode == 0 else {
            logger.error("❌ [ContainerManager] Curl/wget failed with exit code: \(exitStatus.exitCode)")
            logger.error("❌ [ContainerManager] Stderr: \(errorString)")
            
            // Check if we got an HTTP error (server is running but returned error status)
            if errorString.contains("HTTP/1.1 4") || errorString.contains("HTTP/1.1 5") || 
               outputString.contains("HTTP/1.1 4") || outputString.contains("HTTP/1.1 5") {
                // Server is responding! Extract the status code
                let combinedOutput = errorString + outputString
                if let range = combinedOutput.range(of: "HTTP/1.1 ") {
                    let statusStart = combinedOutput.index(range.upperBound, offsetBy: 0)
                    let statusEnd = combinedOutput.index(statusStart, offsetBy: min(3, combinedOutput.distance(from: statusStart, to: combinedOutput.endIndex)))
                    let statusStr = String(combinedOutput[statusStart..<statusEnd])
                    let statusCode = Int(statusStr) ?? 0
                    
                    logger.info("✅ [ContainerManager] Server is running! HTTP \(statusCode)")
                    return (statusCode: statusCode, body: "Server responded with HTTP \(statusCode). The server is running but returned an error for this endpoint.")
                }
            }
            
            // Provide more helpful error message
            let errorMessage: String
            if errorString.contains("curl: command not found") || errorString.contains("not found") || errorString.contains("wget: not found") {
                errorMessage = "Neither curl nor wget found in container. The container image may not include HTTP tools."
            } else if errorString.contains("Connection refused") || errorString.contains("refused") {
                errorMessage = "Connection refused - the application may not be running on port \(port)"
            } else if errorString.contains("Could not resolve host") || errorString.contains("bad address") {
                errorMessage = "Network error - could not resolve localhost"
            } else if outputString.isEmpty && errorString.isEmpty {
                errorMessage = "No response from container. The service may not be ready yet."
            } else {
                errorMessage = "API check failed with exit code \(exitStatus.exitCode). Error: \(errorString.isEmpty ? outputString : errorString)"
            }
            
            throw ContainerizationError(.invalidState, message: errorMessage)
        }
        
        // Parse output - for curl, last line is status code; for wget, just return body with assumed 200
        let lines = outputString.split(separator: "\n", omittingEmptySubsequences: false)
        
        // Try to parse status code from curl output
        var statusCode = 200  // Default for wget
        var body = outputString
        
        if let lastLine = lines.last, let parsedCode = Int(lastLine.trimmingCharacters(in: CharacterSet.whitespaces)) {
            // curl format: body + status code on last line
            statusCode = parsedCode
            body = lines.dropLast().joined(separator: "\n")
        }
        
        logger.info("✅ [ContainerManager] API check complete - Status: \(statusCode)")
        return (statusCode: statusCode, body: body)
    }
    
    // MARK: - Port Forwarding
    
    /// Start port forwarding to allow external access to the container
    func startPortForwarding(hostPort: UInt16, containerPort: UInt16, bridgePort: UInt16 = 5000) async throws {
        guard let pod = currentPod else {
            throw ContainerizationError(.invalidState, message: "No container is running")
        }
        
        logger.info("🌐 [ContainerManager] Starting port forwarding: localhost:\(hostPort) -> container:\(containerPort)")
        portForwardingStatus = .starting
        
        // Create and start the port forwarder
        let forwarder = TcpPortForwarder(
            hostPort: hostPort,
            containerPort: containerPort,
            bridgePort: bridgePort,
            pod: pod,
            logger: logger
        )
        
        do {
            try await forwarder.start()
            self.portForwarder = forwarder
            self.portForwardingStatus = forwarder.status
            
            // Observe status changes
            Task { @MainActor [weak self] in
                for await _ in forwarder.$status.values {
                    self?.portForwardingStatus = forwarder.status
                }
            }
            
            logger.info("✅ [ContainerManager] Port forwarding active")
        } catch {
            logger.error("❌ [ContainerManager] Port forwarding failed: \(error)")
            portForwardingStatus = .error(error.localizedDescription)
            throw error
        }
    }
    
    /// Stop port forwarding
    func stopPortForwarding() async {
        if let forwarder = portForwarder {
            await forwarder.stop()
            portForwarder = nil
            portForwardingStatus = .inactive
            logger.info("✅ [ContainerManager] Port forwarding stopped")
        }
    }
    
    // MARK: - Communication Layer Methods
    
    /// Get the communication manager for advanced communication with the container
    func getCommunicationManager() -> ContainerCommunicationManager? {
        return communicationManager
    }
    
    /// Execute a command inside the container and return the result
    func executeCommand(_ command: [String], workingDirectory: String? = nil) async throws -> ExecResult {
        guard let commManager = communicationManager else {
            throw ContainerizationError(.invalidState, message: "Communication manager not initialized")
        }
        
        return try await commManager.exec(command: command, workingDirectory: workingDirectory)
    }
    
    /// Make an HTTP request to the container service
    func httpRequest(
        method: String = "GET",
        path: String = "/",
        body: Data? = nil,
        headers: [String: String] = [:]
    ) async throws -> HTTPResponse {
        guard let commManager = communicationManager else {
            throw ContainerizationError(.invalidState, message: "Communication manager not initialized")
        }
        
        return try await commManager.httpRequest(method: method, path: path, body: body, headers: headers)
    }
    
    /// Send data to the container and receive a response (convenience method)
    func sendToContainer(_ message: String) async throws -> String {
        let result = try await executeCommand(["echo", message])
        return result.stdoutString
    }
    
    /// Read a file from the container
    func readContainerFile(_ path: String) async throws -> String {
        let result = try await executeCommand(["cat", path])
        if result.isSuccess {
            return result.stdoutString
        } else {
            throw ContainerizationError(.notFound, message: "File not found: \(path)")
        }
    }
    
    /// Write data to a file in the container
    func writeContainerFile(_ path: String, content: String) async throws {
        // Use sh -c to handle special characters and create parent directories
        let escapedContent = content.replacingOccurrences(of: "'", with: "'\\''")
        let result = try await executeCommand([
            "sh", "-c",
            "mkdir -p $(dirname '\(path)') && echo '\(escapedContent)' > '\(path)'"
        ])
        
        if !result.isSuccess {
            throw ContainerizationError(.internalError, message: "Failed to write file: \(result.stderrString)")
        }
    }
    
    /// List files in a directory in the container
    func listContainerDirectory(_ path: String) async throws -> [String] {
        let result = try await executeCommand(["ls", "-la", path])
        if result.isSuccess {
            return result.stdoutString.components(separatedBy: "\n").filter { !$0.isEmpty }
        } else {
            throw ContainerizationError(.notFound, message: "Directory not found: \(path)")
        }
    }
    
    /// Get environment variables from the container
    func getContainerEnvironment() async throws -> [String: String] {
        let result = try await executeCommand(["env"])
        var envVars: [String: String] = [:]
        
        for line in result.stdoutString.components(separatedBy: "\n") {
            if let equalIndex = line.firstIndex(of: "=") {
                let key = String(line[..<equalIndex])
                let value = String(line[line.index(after: equalIndex)...])
                envVars[key] = value
            }
        }
        
        return envVars
    }
    
    /// Get running processes in the container
    func getContainerProcesses() async throws -> String {
        let result = try await executeCommand(["ps", "aux"])
        return result.stdoutString
    }
    
    /// Check if a port is listening in the container
    func isPortListening(_ port: Int) async throws -> Bool {
        // Try using netstat or ss if available
        let result = try await executeCommand([
            "sh", "-c",
            "netstat -tlnp 2>/dev/null | grep ':\(port)' || ss -tlnp 2>/dev/null | grep ':\(port)' || echo 'not found'"
        ])
        
        return !result.stdoutString.contains("not found") && result.isSuccess
    }
    
    // MARK: - Authentication Helper
    
    private func withAuthentication<T>(
        ref: String,
        _ body: @Sendable @escaping (Authentication?) async throws -> T?
    ) async throws -> T? {
        let parsedRef = try Reference.parse(ref)
        guard let host = parsedRef.resolvedDomain else {
            return try await body(nil)
        }
        
        // Check environment variables first
        if let auth = authenticationFromEnv(host: host) {
            return try await body(auth)
        }
        
        // Check keychain
        let keychain = KeychainHelper(id: "com.example.HelloWorldApp")
        if let auth = try? keychain.lookup(domain: host) {
            return try await body(auth)
        }
        
        return try await body(nil)
    }
    
    private func authenticationFromEnv(host: String) -> Authentication? {
        let env = ProcessInfo.processInfo.environment
        guard env["REGISTRY_HOST"] == host else { return nil }
        guard let user = env["REGISTRY_USERNAME"],
              let password = env["REGISTRY_TOKEN"] else { return nil }
        return BasicAuthentication(username: user, password: password)
    }
}
