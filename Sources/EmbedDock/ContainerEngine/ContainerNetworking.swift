//===----------------------------------------------------------------------===//
//
// Container Networking Protocol
//
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - Container Networking

/// Port forwarding and communication channel management.
@MainActor
public protocol ContainerNetworking {

    /// Start forwarding a host TCP port to a container TCP port via vsock.
    func startPortForwarding(hostPort: UInt16, containerPort: UInt16, bridgePort: UInt16) async throws

    /// Stop any active port forwarding.
    func stopPortForwarding() async

    /// Return the list of active communication channel types.
    func activeChannels() async -> [CommunicationType]
}

// MARK: - Convenience Defaults

extension ContainerNetworking {

    /// Start port forwarding with the default bridge port (5000).
    public func startPortForwarding(hostPort: UInt16, containerPort: UInt16) async throws {
        try await startPortForwarding(hostPort: hostPort, containerPort: containerPort, bridgePort: 5000)
    }
}
