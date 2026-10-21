import Foundation

public struct PortForward: Identifiable, Codable, Equatable {
    public enum Transport: String, CaseIterable, Codable { case tcp, udp }
    public var id: UUID
    public var transport: Transport
    public var hostPort: Int
    public var guestPort: Int

    public init(id: UUID = UUID(), transport: Transport = .tcp, hostPort: Int = 8080, guestPort: Int = 80) {
        self.id = id
        self.transport = transport
        self.hostPort = hostPort
        self.guestPort = guestPort
    }

    public func validate() throws {
        guard (1...65535).contains(hostPort), (1...65535).contains(guestPort) else {
            throw LibraryError.invalidConfiguration("Forwarded ports must be between 1 and 65535.")
        }
    }

    /// Listen only on the Mac's loopback interface, never expose the guest on every network.
    public var qemuOption: String { "hostfwd=\(transport.rawValue):127.0.0.1:\(hostPort)-:\(guestPort)" }
}
