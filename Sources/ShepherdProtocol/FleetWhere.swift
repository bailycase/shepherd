import Foundation

/// Where a Mac's Shepherd listens, as `Shepherd --fleet-where` prints it for another Mac that reached it over SSH. Read only: the
/// answer comes from the host on that Mac and nothing is written there. It names the Mac and its routes, never a code or a token.
public struct FleetWhere: Codable, Hashable, Sendable {
    public static let version = 1

    public var v: Int
    public var hostID: UUID
    public var name: String
    /// The app's name and version, for "Shepherd Nightly 1.9" (the version a person sees, else the build number).
    public var app: String?
    public var build: String?
    public var port: UInt16
    public var routes: [FleetReportedRoute]

    public init(hostID: UUID, name: String, app: String? = nil, build: String? = nil, port: UInt16, routes: [FleetReportedRoute]) {
        v = Self.version
        self.hostID = hostID
        self.name = name
        self.app = app
        self.build = build
        self.port = port
        self.routes = routes
    }

    /// Why a Mac has nothing to say.
    public enum Unavailable: Error, Equatable, Sendable {
        /// The host answered but isn't listening (no Mac or device is paired, no code is showing and Serve this Mac is off).
        case notServing
    }

    /// What `snapshot` (a host's read of itself) says; throws while the host isn't listening.
    public init(snapshot: FleetSnapshot, app: String?, version: String? = nil) throws {
        guard let hostID = snapshot.hostID, let port = snapshot.port else { throw Unavailable.notServing }
        self.init(hostID: hostID, name: snapshot.name, app: app, build: version ?? snapshot.build, port: port, routes: snapshot.routes)
    }

    /// The output of the command: JSON, one object on its own line (a login shell may print its own lines around it).
    public static func read(_ output: Data) -> FleetWhere? {
        let lines = String(decoding: output.prefix(64 << 10), as: UTF8.self).split(whereSeparator: \.isNewline)
        for line in lines.reversed() where line.hasPrefix("{") {
            guard let value = try? JSONDecoder().decode(FleetWhere.self, from: Data(line.utf8)), value.isValid else { continue }
            return value
        }
        return nil
    }

    /// Something a Mac could have said: a version this build reads, a port, a name, and routes that are words of address or name
    /// characters.
    public var isValid: Bool {
        v == Self.version && port > 0 && !name.isEmpty && name.utf8.count <= 200 && !routes.isEmpty
            && FleetRouteReport(port: port, routes: routes).isValid
    }

    /// The line the command prints.
    public func line() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(self)) ?? Data(), as: UTF8.self)
    }
}
