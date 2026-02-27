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

    /// Start forwarding a host TCP port to a container TCP port via Unix socket relay.
    func startPortForwarding(hostPort: UInt16, containerPort: UInt16) async throws

    /// Stop any active port forwarding.
    func stopPortForwarding() async

    /// Return the list of active communication channel types.
    func activeChannels() async -> [CommunicationType]
}
