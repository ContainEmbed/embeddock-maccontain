import Foundation
import Combine
import Containerization
import ContainerizationOCI
import ContainerizationArchive
import AppKit
import ContainerizationEXT4
import ContainerizationError
import Logging
import ContainerizationExtras
import ContainerizationOS
import NIO

typealias ContainerImage = Containerization.Image
typealias OCIMount = ContainerizationOCI.Mount
typealias ContainerCommunicationManager = CommunicationManager

@MainActor
class ContainerManager: ObservableObject {
    @Published private(set) var stateMachine = ContainerStateMachine()
    @Published var statusMessage = "Ready"
    @Published var containerURL: String?
    @Published var isCommunicationReady = false
    @Published var portForwardingStatus: ForwardingStatus = .inactive
    @Published private(set) var lastDiagnosticReport: DiagnosticReport?

    /// Container active state derived from the state machine.
    /// True for ANY active state (initializing, starting, running, stopping) — not just `.running`.
    var isRunning: Bool { !stateMachine.state.canStart }

    /// Forwards state machine changes to ContainerManager's objectWillChange for SwiftUI.
    private var stateMachineCancellable: AnyCancellable?

    private var currentPod: LinuxPod?
    private var imageStore: ImageStore?
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private let logger: Logger
    private let storeURL: URL
    private let workDir: URL

    private var communicationManager: ContainerCommunicationManager?
    private var portForwarder: TcpPortForwarder?

    private var prerequisiteChecker: PrerequisiteChecker?
    private var startupCoordinator: StartupCoordinator?
    private var nodeServerCoordinator: NodeServerCoordinator?
    private var postLaunchHandler: PostLaunchHandler?
    private var cleanupCoordinator: CleanupCoordinator?
    private var containerOperations: ContainerOperations?
    private var imageService: ImageService?
    private var imageLoader: ImageLoader?
    private var diagnosticsHelper: DiagnosticsHelper?
    private var podFactory: PodFactory?

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        self.storeURL = appSupport.appendingPathComponent("HelloWorldApp/images")
        self.workDir = appSupport.appendingPathComponent("HelloWorldApp/containers")
        try? FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        var logger = Logger(label: "com.example.HelloWorldApp")
        logger.logLevel = .debug
        self.logger = logger

        // Forward state machine changes to ContainerManager so SwiftUI views update immediately
        stateMachineCancellable = stateMachine.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func initialize() async throws {
        logger.info("🔧 [ContainerManager] Initializing...")
        statusMessage = "Initializing image store..."

        self.imageStore = try ImageStore(path: storeURL)
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)

        self.prerequisiteChecker = PrerequisiteChecker(workDir: workDir, logger: logger)
        self.diagnosticsHelper = DiagnosticsHelper(workDir: workDir, logger: logger)
        self.cleanupCoordinator = CleanupCoordinator(logger: logger)
        self.containerOperations = ContainerOperations(logger: logger)

        self.imageService = ImageService(
            imageStore: imageStore!,
            workDir: workDir,
            logger: logger
        )

        self.imageLoader = ImageLoader(
            imageStore: imageStore!,
            workDir: workDir,
            logger: logger
        )

        self.podFactory = PodFactory(
            workDir: workDir,
            logger: logger,
            eventLoopGroup: eventLoopGroup!,
            prerequisiteChecker: prerequisiteChecker!
        )

        self.startupCoordinator = StartupCoordinator(
            imageLoader: imageLoader!,
            imageService: imageService!,
            podFactory: podFactory!,
            imageStore: imageStore!,
            diagnosticsHelper: diagnosticsHelper!,
            logger: logger
        )

        self.nodeServerCoordinator = NodeServerCoordinator(
            imageService: imageService!,
            podFactory: podFactory!,
            imageStore: imageStore!,
            diagnosticsHelper: diagnosticsHelper!,
            workDir: workDir,
            logger: logger
        )

        self.postLaunchHandler = PostLaunchHandler(
            diagnosticsHelper: diagnosticsHelper!,
            containerOperations: containerOperations!,
            logger: logger
        )

        statusMessage = "Ready"
        logger.info("✅ [ContainerManager] Initialization complete")
    }

    deinit {
        logger.info("🔚 [ContainerManager] Deinitializing, shutting down event loop...")
        try? eventLoopGroup?.syncShutdownGracefully()
    }

    // MARK: - Container Lifecycle

    func startContainerFromImage(imageFile: URL, port: Int) async throws {
        try await ensureStoppedIfRunning()
        try checkPrerequisites()

        stateMachine.transitionToStep(.extractingImage)
        defer { cleanupOnFailure() }

        do {
            // Phase 1: Launch via StartupCoordinator
            let pod = try await launchFromImage(imageFile: imageFile, port: port)
            self.currentPod = pod
            stateMachine.markRunning()

            // Phase 2: Post-launch (health check, communication, port forwarding)
            let result = await performPostLaunch(pod: pod, options: .imageStart(port: port))
            applyPostLaunchResult(result, port: port)

            if !result.isHealthy, let warning = result.healthWarning {
                stateMachine.markUnhealthy(reason: warning)
                statusMessage = "⚠️ Container running but \(warning)"
            }
        } catch {
            handleLaunchFailure(error: error, phase: "startContainerFromImage")
            throw error
        }
    }

    func startNodeServer(jsFile: URL, imageName: String, port: Int) async throws {
        guard !isRunning else {
            throw ContainerizationError(.invalidState, message: "Container is already running")
        }

        try checkPrerequisites()

        stateMachine.transitionToStep(.extractingImage)
        defer { cleanupOnFailure() }

        do {
            // Phase 1: Launch via NodeServerCoordinator
            let pod = try await launchNodeServer(jsFile: jsFile, imageName: imageName, port: port)
            self.currentPod = pod
            stateMachine.markRunning()

            // Phase 2: Post-launch (communication, port forwarding)
            let result = await performPostLaunch(pod: pod, options: .nodeServer(port: port))
            applyPostLaunchResult(result, port: port)

            statusMessage = "✅ Node.js container running at \(result.containerURL)"
        } catch {
            handleLaunchFailure(error: error, phase: "startNodeServer")
            throw error
        }
    }

    func stopContainer() async throws {
        guard let pod = currentPod else {
            forceClearState()
            return
        }

        stateMachine.markStopping()
        statusMessage = "Stopping container..."

        if let coordinator = cleanupCoordinator {
            let completed = await coordinator.performCleanupWithMasterTimeout(
                pod: pod,
                portForwarder: portForwarder,
                communicationManager: communicationManager,
                masterTimeout: 30
            )
            if !completed {
                logger.error("❌ [ContainerManager] Cleanup timed out, forcing state clear")
            }
        }

        forceClearState()
    }

    private func forceClearState() {
        currentPod = nil
        portForwarder = nil
        communicationManager = nil
        containerOperations?.configure(pod: nil, communicationManager: nil, diagnosticsHelper: nil)
        containerURL = nil
        stateMachine.reset()
        isCommunicationReady = false
        portForwardingStatus = .inactive
        statusMessage = "Container stopped"
    }

    // MARK: - Lifecycle Helpers (Composition)

    /// Stops any existing running container before starting a new one.
    private func ensureStoppedIfRunning() async throws {
        guard isRunning else { return }
        statusMessage = "Stopping existing container..."
        stateMachine.markStopping()
        do {
            try await stopContainer()
        } catch {
            logger.error("❌ [ContainerManager] Failed to stop previous container: \(error)")
        }
    }

    /// Shared prerequisite check for both launch paths.
    private func checkPrerequisites() throws {
        stateMachine.transitionToStep(.checkingPrerequisites)
        statusMessage = "Checking prerequisites..."
        do {
            try prerequisiteChecker?.checkAll()
        } catch {
            stateMachine.markFailed(error: "Missing prerequisites")
            statusMessage = "❌ Missing prerequisites - check logs"
            throw error
        }
    }

    /// Delegates to StartupCoordinator for OCI image launch.
    private func launchFromImage(imageFile: URL, port: Int) async throws -> LinuxPod {
        guard let coordinator = startupCoordinator else {
            throw ContainerizationError(.notFound, message: "Startup coordinator not initialized")
        }
        coordinator.onProgress = { [weak self] msg in self?.statusMessage = msg }
        return try await coordinator.startFromImage(imageFile: imageFile, port: port)
    }

    /// Delegates to NodeServerCoordinator for Node.js launch.
    private func launchNodeServer(jsFile: URL, imageName: String, port: Int) async throws -> LinuxPod {
        guard let coordinator = nodeServerCoordinator else {
            throw ContainerizationError(.notFound, message: "Node server coordinator not initialized")
        }
        coordinator.onProgress = { [weak self] msg in self?.statusMessage = msg }
        return try await coordinator.start(jsFile: jsFile, imageName: imageName, port: port)
    }

    /// Delegates post-launch steps (health, communication, port forwarding) to PostLaunchHandler.
    private func performPostLaunch(pod: LinuxPod, options: PostLaunchOptions) async -> PostLaunchResult {
        guard let handler = postLaunchHandler else {
            logger.error("❌ [ContainerManager] PostLaunchHandler not initialized")
            return PostLaunchResult(
                communicationManager: nil,
                isCommunicationReady: false,
                portForwarder: nil,
                containerURL: "http://localhost:\(options.port)",
                portForwardingStatus: .inactive,
                isHealthy: false,
                healthWarning: "PostLaunchHandler not initialized",
                diagnosticReport: nil
            )
        }
        return await handler.handle(pod: pod, options: options)
    }

    /// Applies the PostLaunchResult to ContainerManager state.
    private func applyPostLaunchResult(_ result: PostLaunchResult, port: Int) {
        self.communicationManager = result.communicationManager
        self.isCommunicationReady = result.isCommunicationReady
        self.portForwarder = result.portForwarder
        self.containerURL = result.containerURL
        self.portForwardingStatus = result.portForwardingStatus

        if result.portForwarder != nil {
            // Observe port forwarder status changes
            Task { @MainActor [weak self] in
                guard let forwarder = self?.portForwarder else { return }
                for await _ in forwarder.$status.values {
                    self?.portForwardingStatus = forwarder.status
                }
            }
        }

        statusMessage = "✅ Container running at \(result.containerURL)"
    }

    /// Handles launch failures — marks failed, captures diagnostics.
    private func handleLaunchFailure(error: Error, phase: String) {
        stateMachine.markFailed(error: error.localizedDescription)
        statusMessage = "❌ Failed: \(error.localizedDescription)"
        if let pod = currentPod, let diag = diagnosticsHelper {
            Task {
                lastDiagnosticReport = await diag.printDiagnostics(pod: pod, phase: phase, error: error)
            }
        }
    }

    /// Cleanup guard: if we're not running after a deferred block, stop the pod.
    private func cleanupOnFailure() {
        if !isRunning {
            Task { try? await self.currentPod?.stop(); self.currentPod = nil }
        }
    }

    // MARK: - Port Forwarding

    /// Start port forwarding for a running container (public for retry scenarios).
    func startPortForwarding(hostPort: UInt16, containerPort: UInt16, bridgePort: UInt16 = 5000) async throws {
        guard let pod = currentPod else {
            throw ContainerizationError(.invalidState, message: "No container is running")
        }

        portForwardingStatus = .starting

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
            self.containerURL = "http://localhost:\(hostPort)"

            Task { @MainActor [weak self] in
                for await _ in forwarder.$status.values {
                    self?.portForwardingStatus = forwarder.status
                }
            }
        } catch {
            portForwardingStatus = .error(error.localizedDescription)
            throw error
        }
    }

    func stopPortForwarding() async {
        if let forwarder = portForwarder {
            await forwarder.stop()
            portForwarder = nil
            portForwardingStatus = .inactive
        }
    }

    // MARK: - Communication Layer

    func getCommunicationManager() -> ContainerCommunicationManager? {
        communicationManager
    }

    func getActiveChannels() async -> [CommunicationType] {
        guard let commManager = communicationManager else { return [] }
        return await commManager.activeChannelTypes
    }

    // MARK: - Container Operations (Delegated)

    func executeCommand(_ command: [String], workingDirectory: String? = nil) async throws -> ExecResult {
        guard let ops = containerOperations else {
            throw ContainerizationError(.invalidState, message: "Container operations not initialized")
        }
        return try await ops.executeCommand(command, workingDirectory: workingDirectory)
    }

    func checkContainerAPI(port: Int) async throws -> (statusCode: Int, body: String) {
        guard let ops = containerOperations else {
            throw ContainerizationError(.invalidState, message: "Container operations not initialized")
        }
        return try await ops.checkContainerAPI(port: port)
    }

    func httpRequest(
        method: String = "GET",
        path: String = "/",
        body: Data? = nil,
        headers: [String: String] = [:]
    ) async throws -> HTTPResponse {
        guard let ops = containerOperations else {
            throw ContainerizationError(.invalidState, message: "Container operations not initialized")
        }
        return try await ops.httpRequest(method: method, path: path, body: body, headers: headers)
    }

    func sendToContainer(_ message: String) async throws -> String {
        let result = try await executeCommand(["echo", message])
        return result.stdoutString
    }

    func readContainerFile(_ path: String) async throws -> String {
        guard let ops = containerOperations else {
            throw ContainerizationError(.invalidState, message: "Container operations not initialized")
        }
        return try await ops.readContainerFile(path)
    }

    func writeContainerFile(_ path: String, content: String) async throws {
        guard let ops = containerOperations else {
            throw ContainerizationError(.invalidState, message: "Container operations not initialized")
        }
        try await ops.writeContainerFile(path, content: content)
    }

    func listContainerDirectory(_ path: String) async throws -> [String] {
        guard let ops = containerOperations else {
            throw ContainerizationError(.invalidState, message: "Container operations not initialized")
        }
        return try await ops.listContainerDirectory(path)
    }

    func getContainerEnvironment() async throws -> [String: String] {
        guard let ops = containerOperations else {
            throw ContainerizationError(.invalidState, message: "Container operations not initialized")
        }
        return try await ops.getContainerEnvironment()
    }

    func getContainerProcesses() async throws -> String {
        guard let ops = containerOperations else {
            throw ContainerizationError(.invalidState, message: "Container operations not initialized")
        }
        return try await ops.getContainerProcesses()
    }

    func isPortListening(_ port: Int) async throws -> Bool {
        guard let ops = containerOperations else {
            throw ContainerizationError(.invalidState, message: "Container operations not initialized")
        }
        return try await ops.isPortListening(port)
    }

    // MARK: - Image Operations (Delegated)

    // MARK: - Diagnostics (Delegated)

    /// Get system information (macOS version, memory, CPU).
    func getSystemInfo() -> [String: String] {
        diagnosticsHelper?.getSystemInfo() ?? [:]
    }

    /// Read a log file from the container work directory.
    func readLogFile(name: String, lastLines: Int = 100) -> String? {
        diagnosticsHelper?.readLogFile(name: name, lastLines: lastLines)
    }

    /// Re-print the last diagnostic report to the log.
    func reprintLastDiagnosticReport() {
        guard let report = lastDiagnosticReport else {
            logger.info("ℹ️ [ContainerManager] No diagnostic report available")
            return
        }
        diagnosticsHelper?.printReport(report)
    }

    // MARK: - Image Operations (Delegated)

    func pullNodeImage(reference: String, platform: Platform? = nil) async throws -> ContainerImage {
        guard let service = imageService else {
            throw ContainerizationError(.notFound, message: "Image service not initialized")
        }
        return try await service.pullImage(reference: reference, platform: platform) { [weak self] msg in
            Task { @MainActor in self?.statusMessage = msg }
        }
    }

    func prepareRootfs(from image: ContainerImage, platform: Platform) async throws -> URL {
        guard let service = imageService else {
            throw ContainerizationError(.notFound, message: "Image service not initialized")
        }
        return try await service.prepareRootfs(from: image, platform: platform) { [weak self] msg in
            Task { @MainActor in self?.statusMessage = msg }
        }
    }
}
