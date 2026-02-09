import Foundation
import Combine
import Containerization
import ContainerizationOCI
import ContainerizationArchive
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
final class ContainerManager {
    // MARK: - Public State (read-only)

    private(set) var status: ContainerStatus = .idle
    private(set) var containerURL: String?
    private(set) var isCommunicationReady: Bool = false
    private(set) var lastDiagnosticReport: DiagnosticReport?

    /// Container active state derived from the unified status.
    /// True for ANY active state (initializing, running, stopping) — not just `.running`.
    var isRunning: Bool { status.isActive }

    // MARK: - Delegate

    weak var delegate: ContainerManagerDelegate?

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
    }

    func initialize() async throws {
        logger.info("🔧 [ContainerManager] Initializing...")
        reportProgress("Initializing image store...")

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

        reportProgress("Ready")
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

        updateStatus(.initializing(step: .extractingImage))
        defer { cleanupOnFailure() }

        do {
            // Phase 1: Launch via StartupCoordinator
            let pod = try await launchFromImage(imageFile: imageFile, port: port)
            self.currentPod = pod
            updateStatus(.running(health: .healthy, forwarding: .inactive))

            // Phase 2: Post-launch (health check, communication, port forwarding)
            let result = await performPostLaunch(pod: pod, options: .imageStart(port: port))
            applyPostLaunchResult(result, port: port)
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

        updateStatus(.initializing(step: .extractingImage))
        defer { cleanupOnFailure() }

        do {
            // Phase 1: Launch via NodeServerCoordinator
            let pod = try await launchNodeServer(jsFile: jsFile, imageName: imageName, port: port)
            self.currentPod = pod
            updateStatus(.running(health: .healthy, forwarding: .inactive))

            // Phase 2: Post-launch (communication, port forwarding)
            let result = await performPostLaunch(pod: pod, options: .nodeServer(port: port))
            applyPostLaunchResult(result, port: port)
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

        updateStatus(.stopping)
        reportProgress("Stopping container...")

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
        isCommunicationReady = false
        updateStatus(.idle)
    }

    // MARK: - Lifecycle Helpers (Composition)

    /// Stops any existing running container before starting a new one.
    private func ensureStoppedIfRunning() async throws {
        guard isRunning else { return }
        reportProgress("Stopping existing container...")
        updateStatus(.stopping)
        do {
            try await stopContainer()
        } catch {
            logger.error("❌ [ContainerManager] Failed to stop previous container: \(error)")
        }
    }

    /// Shared prerequisite check for both launch paths.
    private func checkPrerequisites() throws {
        updateStatus(.initializing(step: .checkingPrerequisites))
        reportProgress("Checking prerequisites...")
        do {
            try prerequisiteChecker?.checkAll()
        } catch {
            updateStatus(.failed(error: "Missing prerequisites"))
            throw error
        }
    }

    /// Delegates to StartupCoordinator for OCI image launch.
    private func launchFromImage(imageFile: URL, port: Int) async throws -> LinuxPod {
        guard let coordinator = startupCoordinator else {
            throw ContainerizationError(.notFound, message: "Startup coordinator not initialized")
        }
        coordinator.onProgress = { [weak self] msg in self?.reportProgress(msg) }
        return try await coordinator.startFromImage(imageFile: imageFile, port: port)
    }

    /// Delegates to NodeServerCoordinator for Node.js launch.
    private func launchNodeServer(jsFile: URL, imageName: String, port: Int) async throws -> LinuxPod {
        guard let coordinator = nodeServerCoordinator else {
            throw ContainerizationError(.notFound, message: "Node server coordinator not initialized")
        }
        coordinator.onProgress = { [weak self] msg in self?.reportProgress(msg) }
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

        // Map health and forwarding into unified status
        let health: ContainerStatus.HealthState = result.isHealthy
            ? .healthy
            : .unhealthy(reason: result.healthWarning ?? "Unknown")
        let forwarding = mapForwardingStatus(result.portForwardingStatus)
        updateStatus(.running(health: health, forwarding: forwarding))

        if result.portForwarder != nil {
            observePortForwarder()
        }

        notifyDelegate()
    }

    /// Handles launch failures — marks failed, captures diagnostics.
    private func handleLaunchFailure(error: Error, phase: String) {
        updateStatus(.failed(error: error.localizedDescription))
        if let pod = currentPod, let diag = diagnosticsHelper {
            Task {
                let report = await diag.printDiagnostics(pod: pod, phase: phase, error: error)
                self.lastDiagnosticReport = report
                self.delegate?.containerManager(self, didProduceDiagnosticReport: report)
            }
        }
    }

    /// Cleanup guard: if we’re not running after a deferred block, stop the pod.
    private func cleanupOnFailure() {
        if status.canStart {
            Task { try? await self.currentPod?.stop(); self.currentPod = nil }
        }
    }

    // MARK: - Port Forwarding

    /// Start port forwarding for a running container (public for retry scenarios).
    func startPortForwarding(hostPort: UInt16, containerPort: UInt16, bridgePort: UInt16 = 5000) async throws {
        guard let pod = currentPod else {
            throw ContainerizationError(.invalidState, message: "No container is running")
        }

        updateForwarding(.starting)

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
            self.containerURL = "http://localhost:\(hostPort)"
            updateForwarding(mapForwardingStatus(forwarder.status))
            observePortForwarder()
            notifyDelegate()
        } catch {
            updateForwarding(.error(error.localizedDescription))
            throw error
        }
    }

    func stopPortForwarding() async {
        if let forwarder = portForwarder {
            await forwarder.stop()
            portForwarder = nil
            updateForwarding(.inactive)
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
            Task { @MainActor in self?.reportProgress(msg) }
        }
    }

    func prepareRootfs(from image: ContainerImage, platform: Platform) async throws -> URL {
        guard let service = imageService else {
            throw ContainerizationError(.notFound, message: "Image service not initialized")
        }
        return try await service.prepareRootfs(from: image, platform: platform) { [weak self] msg in
            Task { @MainActor in self?.reportProgress(msg) }
        }
    }

    // MARK: - Private State Helpers

    /// Update the unified container status and notify the delegate.
    private func updateStatus(_ newStatus: ContainerStatus) {
        guard status != newStatus else { return }
        #if DEBUG
        print("🔄 [ContainerManager] \(status) → \(newStatus)")
        #endif
        status = newStatus
        notifyDelegate()
    }

    /// Update only the forwarding sub-state within a running status.
    private func updateForwarding(_ forwarding: ContainerStatus.ForwardingState) {
        guard case .running(let health, _) = status else { return }
        updateStatus(.running(health: health, forwarding: forwarding))
    }

    /// Map TcpPortForwarder's ForwardingStatus to unified ContainerStatus.ForwardingState.
    private func mapForwardingStatus(_ fs: ForwardingStatus) -> ContainerStatus.ForwardingState {
        switch fs {
        case .inactive: return .inactive
        case .starting: return .starting
        case .active(let n): return .active(connections: n)
        case .error(let msg): return .error(msg)
        }
    }

    /// Observe the port forwarder's status changes and update unified status.
    private func observePortForwarder() {
        Task { @MainActor [weak self] in
            guard let self, let forwarder = self.portForwarder else { return }
            for await _ in forwarder.$status.values {
                self.updateForwarding(self.mapForwardingStatus(forwarder.status))
            }
        }
    }

    /// Notify the delegate of state changes.
    private func notifyDelegate() {
        delegate?.containerManagerDidUpdate(self)
    }

    /// Send an ephemeral progress message to the delegate.
    private func reportProgress(_ message: String) {
        delegate?.containerManager(self, didUpdateProgress: message)
    }
}
