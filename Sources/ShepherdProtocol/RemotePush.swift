import Foundation

/// A phone authorizes one host to send generic alerts to its relay registration.
/// The device's APNs token and management credential never travel to the host.
public struct RemotePushRegistration: Codable, Hashable, Sendable {
    public let id: String
    public let sendToken: String

    public init(id: String, sendToken: String) {
        self.id = id
        self.sendToken = sendToken
    }
}
