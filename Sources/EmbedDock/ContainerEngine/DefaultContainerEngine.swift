//===----------------------------------------------------------------------===//
//
// Default Container Engine — Concrete Implementation
//
//===----------------------------------------------------------------------===//

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

// Internal type aliases — not exposed through protocols.
typealias OCIMount = ContainerizationOCI.Mount
typealias ContainerCommunicationManager = CommunicationManager

// MARK: - Default Container Engine

/// Concrete implementation of `ContainerEngine`.
///
/// Composes existing domain modules (startup, cleanup, operations, etc.)
/// behind a single protocol-based facade.  The app layer should always
/// reference `any ContainerEngine` instead of this class directly.
@MainActor
final class DefaultContainerEngine: ContainerEngine {

    // MARK: - ContainerLifecycle — State

    private(set) var status: ContainerStatus = .idle
    private(set) var containerURL: String?
    private(set) var isCommunicationReady: Bool = false

    /// True for ANY active state (initializing, running, stopping).
    var isRunning: Bool { status.isActive }

    // MARK: - ContainerDiagnosing — State

    private(set) var lastDiagnosticReport: DiagnosticReport?

    // MARK: - Delegate

    weak var delegate: ContainerEngineDelegate?

    // MARK: - Private Infrastructure

    private var currentPod: LinuxPod?
    private var imageStore: ImageStore?
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private let logger: Logger
    private let storeURL: URL
    private let workDir: URL

    private var communicationManager: ContainerCommunicationManager?
    private var portForwarder: TcpPortForwarder?

    // MARK: - Composition Modules

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

    // MARK: - Initialization

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        self.storeURL = appSupport.appendingPathComponent("HelloWorldApp/images")
        self.workDir = appSupport.appendingPathComponent("HelloWorldApp/containers")
        try? FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        var logger = Logger(label: "com.example.HelloWorldApp.engine")
        logger.logLevel = .debug
        self.logger = logger
    }

    deinit {
        logger.info("🔚 [Engine] Deinitializing, shutting down event loop...")
        try? eventLoopGroup?.syncShutdownGracefully()
    }

    // MARK: - ContainerLifecycle

    func initialize() async throws {
        logger.info("🔧 [Engine] Initializing...")
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

        // Initialise the run manifest with the current PID so a crash leaves a
        // traceable artefact on disk.
        await RunManifest.shared.initialize(logger: logger)

        // Clean up any resources left over from a previous crashed or force-killed run.
        let cleaner = StaleResourceCleaner(logger: logger)
        let report = await cleaner.cleanIfNeeded()
        if report.foundStaleManifest {
            logger.info("🧹 [Engine] Startup stale-resource cleanup: \(report)")
        }

        reportProgress("Ready")
        logger.info("✅ [Engine] Initialization complete")
    }

    func startFromImage(imageFile: URL, port: Int) async throws {
        try await ensureStoppedIfRunning()
        try checkPrerequisites()

        updateStatus(.initializing(step: .extractingImage))
        defer { cleanupOnFailure() }

        do {
            let pod = try await launchFromImage(imageFile: imageFile, port: port)
            self.currentPod = pod
            updateStatus(.running(health: .healthy, forwarding: .inactive))

            let result = await performPostLaunch(pod: pod, options: .imageStart(port: port))
            applyPostLaunchResult(result, port: port)
        } catch {
            handleLaunchFailure(error: error, phase: "startFromImage")
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
            let pod = try await launchNodeServer(jsFile: jsFile, imageName: imageName, port: port)
            self.currentPod = pod
            updateStatus(.running(health: .healthy, forwarding: .inactive))

            let result = await performPostLaunch(pod: pod, options: .nodeServer(port: port))
            applyPostLaunchResult(result, port: port)
        } catch {
            handleLaunchFailure(error: error, phase: "startNodeServer")
            throw error
        }
    }

    func stop() async throws {
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
                logger.error("❌ [Engine] Cleanup timed out, forcing state clear")
            }
        }

        forceClearState()

        // Remove the run manifest — clean shutdown means no resources are dangling.
        await RunManifest.shared.clear(logger: logger)
    }

    // MARK: - ContainerExecutor

    func execute(_ command: [String], workingDirectory: String? = nil) async throws -> ExecResult {
        guard let ops = containerOperations else {
            throw ContainerizationError(.invalidState, message: "Container operations not initialized")
        }
        return try await ops.executeCommand(command, workingDirectory: workingDirectory)
    }

    func checkAPI(port: Int) async throws -> (statusCode: Int, body: String) {
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

    // MARK: - ContainerFileOperations

    func readFile(_ path: String) async throws -> String {
        guard let ops = containerOperations else {
            throw ContainerizationError(.invalidState, message: "Container operations not initialized")
        }
        return try await ops.readContainerFile(path)
    }

    func writeFile(_ path: String, content: String) async throws {
        guard let ops = containerOperations else {
            throw ContainerizationError(.invalidState, message: "Container operations not initialized")
        }
        try await ops.writeContainerFile(path, content: content)
    }

    func listDirectory(_ path: String) async throws -> [String] {
        guard let ops = containerOperations else {
            throw ContainerizationError(.invalidState, message: "Container operations not initialized")
        }
        return try await ops.listContainerDirectory(path)
    }

    func environment() async throws -> [String: String] {
        guard let ops = containerOperations else {
            throw ContainerizationError(.invalidState, message: "Container operations not initialized")
        }
        return try await ops.getContainerEnvironment()
    }

    func processes() async throws -> String {
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

    // MARK: - ContainerNetworking

    func startPortForwarding(hostPort: UInt16, containerPort: UInt16) async throws {
        guard let pod = currentPod else {
            throw ContainerizationError(.invalidState, message: "No container is running")
        }

        updateForwarding(.starting)

        let forwarder = TcpPortForwarder(
            hostPort: hostPort,
            containerPort: containerPort,
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

    func activeChannels() async -> [CommunicationType] {
        guard let commManager = communicationManager else { return [] }
        return await commManager.activeChannelTypes
    }

    // MARK: - ContainerImageManaging

    func pullImage(reference: String, platform: ContainerPlatform? = nil) async throws -> ContainerImageRef {
        guard let service = imageService else {
            throw ContainerizationError(.notFound, message: "Image service not initialized")
        }
        let image = try await service.pullImage(reference: reference, platform: platform?.toPlatform()) { [weak self] msg in
            Task { @MainActor in self?.reportProgress(msg) }
        }
        return ContainerImageRef(image)
    }

    func prepareRootfs(from image: ContainerImageRef, platform: ContainerPlatform) async throws -> URL {
        guard let service = imageService else {
            throw ContainerizationError(.notFound, message: "Image service not initialized")
        }
        return try await service.prepareRootfs(from: image.image, platform: platform.toPlatform()) { [weak self] msg in
            Task { @MainActor in self?.reportProgress(msg) }
        }
    }

    // MARK: - ContainerDiagnosing

    func systemInfo() -> [String: String] {
        diagnosticsHelper?.getSystemInfo() ?? [:]
    }

    func readLogFile(name: String, lastLines: Int = 100) -> String? {
        diagnosticsHelper?.readLogFile(name: name, lastLines: lastLines)
    }

    func reprintLastDiagnosticReport() {
        guard let report = lastDiagnosticReport else {
            logger.info("ℹ️ [Engine] No diagnostic report available")
            return
        }
        diagnosticsHelper?.printReport(report)
    }

    // MARK: - Termination Cleanup

    /// Perform best-effort cleanup when the app is about to terminate.
    ///
    /// Designed to be called from `AppDelegate.applicationShouldTerminate(_:)`.
    /// Starts an async Task that stops any running container and clears the run
    /// manifest, then calls `completion` so AppDelegate can reply to the system.
    ///
    /// macOS allows up to ~30 seconds before force-killing the process; we stay
    /// well inside that window via the CleanupCoordinator timeouts (≤30 s).
    func performTerminationCleanup(completion: @escaping @Sendable () -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { completion(); return }
            if self.isRunning {
                self.logger.info("👋 [Engine] Termination cleanup — stopping running container")
                try? await self.stop()
            } else {
                // Even if not running, ensure manifest is cleared
                await RunManifest.shared.clear(logger: self.logger)
            }
            completion()
        }
    }

    // MARK: - Private State Helpers

    private func forceClearState() {
        currentPod = nil
        portForwarder = nil
        communicationManager = nil
        containerOperations?.configure(pod: nil, communicationManager: nil, diagnosticsHelper: nil)
        containerURL = nil
        isCommunicationReady = false
        updateStatus(.idle)
    }

    private func updateStatus(_ newStatus: ContainerStatus) {
        guard status != newStatus else { return }
        #if DEBUG
        print("🔄 [Engine] \(status) → \(newStatus)")
        #endif
        status = newStatus
        notifyDelegate()
    }

    private func updateForwarding(_ forwarding: ContainerStatus.ForwardingState) {
        guard case .running(let health, _) = status else { return }
        updateStatus(.running(health: health, forwarding: forwarding))
    }

    private func mapForwardingStatus(_ fs: ForwardingStatus) -> ContainerStatus.ForwardingState {
        switch fs {
        case .inactive: return .inactive
        case .starting: return .starting
        case .active(let n): return .active(connections: n)
        case .recovering(let attempt): return .recovering(attempt: attempt)
        case .error(let msg): return .error(msg)
        }
    }

    private func observePortForwarder() {
        Task { @MainActor [weak self] in
            guard let self, let forwarder = self.portForwarder else { return }
            for await _ in forwarder.$status.values {
                self.updateForwarding(self.mapForwardingStatus(forwarder.status))
            }
        }
    }

    private func notifyDelegate() {
        delegate?.engineDidUpdateState(self)
    }

    private func reportProgress(_ message: String) {
        delegate?.engine(self, didUpdateProgress: message)
    }

    // MARK: - Lifecycle Helpers (Composition)

    private func ensureStoppedIfRunning() async throws {
        guard isRunning else { return }
        reportProgress("Stopping existing container...")
        updateStatus(.stopping)
        do {
            try await stop()
        } catch {
            logger.error("❌ [Engine] Failed to stop previous container: \(error)")
        }
    }

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

    private func launchFromImage(imageFile: URL, port: Int) async throws -> LinuxPod {
        guard let coordinator = startupCoordinator else {
            throw ContainerizationError(.notFound, message: "Startup coordinator not initialized")
        }
        coordinator.onProgress = { [weak self] msg in self?.reportProgress(msg) }
        return try await coordinator.startFromImage(imageFile: imageFile, port: port)
    }

    private func launchNodeServer(jsFile: URL, imageName: String, port: Int) async throws -> LinuxPod {
        guard let coordinator = nodeServerCoordinator else {
            throw ContainerizationError(.notFound, message: "Node server coordinator not initialized")
        }
        coordinator.onProgress = { [weak self] msg in self?.reportProgress(msg) }
        return try await coordinator.start(jsFile: jsFile, imageName: imageName, port: port)
    }

    private func performPostLaunch(pod: LinuxPod, options: PostLaunchOptions) async -> PostLaunchResult {
        guard let handler = postLaunchHandler else {
            logger.error("❌ [Engine] PostLaunchHandler not initialized")
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

    private func applyPostLaunchResult(_ result: PostLaunchResult, port: Int) {
        self.communicationManager = result.communicationManager
        self.isCommunicationReady = result.isCommunicationReady
        self.portForwarder = result.portForwarder
        self.containerURL = result.containerURL

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

    private func handleLaunchFailure(error: Error, phase: String) {
        updateStatus(.failed(error: error.localizedDescription))
        if let pod = currentPod, let diag = diagnosticsHelper {
            Task {
                let report = await diag.printDiagnostics(pod: pod, phase: phase, error: error)
                self.lastDiagnosticReport = report
                self.delegate?.engine(self, didProduceDiagnosticReport: report)
            }
        }
    }

    private func cleanupOnFailure() {
        if status.canStart {
            Task { try? await self.currentPod?.stop(); self.currentPod = nil }
        }
    }
}
