import Foundation

/// A pairing link: where to find a Mac that shows a code, and the code, in one URL that can go by AirDrop or Messages
/// (`shepherd://fleet/join?...`). It says *where*; the code in it is the only proof, checked by the same handshake as a
/// typed one (`fleetPair`, `fleetPairDevice`) over a direct connection after the answering Mac's id matches the link's.
/// The link stops working when its code does: it carries the code's expiry, and the Mac that shows the code drops it when it
/// is used or expires.
///
/// Each app edition has its own scheme, so Shepherd, Shepherd Nightly and a Dev build never open each other's links.
public struct FleetPairingLink: Hashable, Sendable {
    /// What the code opens: a Mac joining a fleet (Join a fleet), or a phone, iPad or Mac app added as a client (Add a device).
    public enum Purpose: String, Hashable, Sendable {
        case join, device
    }

    public var purpose: Purpose
    /// The Mac that shows the code.
    public var hostID: UUID
    public var name: String
    public var port: UInt16
    /// Every way that Mac said it can be reached, most useful first (`FleetRouteReport`).
    public var routes: [FleetReportedRoute]
    public var code: String
    /// Epoch milliseconds the code stops working.
    public var expiresAt: Double

    public init(purpose: Purpose = .join, hostID: UUID, name: String, port: UInt16, routes: [FleetReportedRoute], code: String, expiresAt: Double) {
        self.purpose = purpose
        self.hostID = hostID
        self.name = name
        self.port = port
        self.routes = routes
        self.code = code
        self.expiresAt = expiresAt
    }

    public func isExpired(at now: Date) -> Bool { now.timeIntervalSince1970 * 1000 >= expiresAt }

    /// Routes a link carries (a link is read aloud, pasted and shared: it stays short) and the longest name.
    public static let maxRoutes = 8
    public static let maxNameBytes = 100
    static let version = "1"
    static let host = "fleet"
    static let path = "/join"

    // MARK: Editions

    /// The schemes of Shepherd's editions: stable, Nightly and a Dev build.
    public static let stableScheme = "shepherd"
    public static let nightlyScheme = "shepherd-nightly"
    public static let devScheme = "shepherd-dev"
    public static let allSchemes = [stableScheme, nightlyScheme, devScheme]

    /// The scheme an app of this bundle identifier registers and opens. Anything that isn't Nightly or Dev (a tool, a test runner)
    /// is the stable app.
    public static func scheme(bundleIdentifier: String?) -> String {
        switch bundleIdentifier {
        case ShepherdEdition.nightlyBundleIdentifier: nightlyScheme
        case "\(ShepherdEdition.mainBundleIdentifier).dev": devScheme
        default: stableScheme
        }
    }

    /// The running app's scheme.
    public static var currentScheme: String { scheme(bundleIdentifier: Bundle.main.bundleIdentifier) }

    /// "Shepherd Nightly" for `shepherd-nightly`: what a refusal says another edition's link is for.
    public static func appName(ofScheme scheme: String) -> String? {
        switch scheme {
        case stableScheme: "Shepherd"
        case nightlyScheme: "Shepherd Nightly"
        case devScheme: "Shepherd Dev"
        default: nil
        }
    }

    // MARK: Writing

    /// The link, in `scheme`'s edition. At most `maxRoutes` routes and a name of at most `maxNameBytes` go in it.
    public func url(scheme: String = FleetPairingLink.currentScheme) -> URL {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = Self.host
        parts.path = Self.path
        var items = [URLQueryItem(name: "v", value: Self.version), URLQueryItem(name: "id", value: hostID.uuidString),
                     URLQueryItem(name: "n", value: Self.truncated(name, bytes: Self.maxNameBytes)), URLQueryItem(name: "p", value: String(port))]
        for route in routes.prefix(Self.maxRoutes) { items.append(URLQueryItem(name: "r", value: "\(route.host),\(route.kind.rawValue)")) }
        items.append(URLQueryItem(name: "c", value: code))
        items.append(URLQueryItem(name: "x", value: String(Int64(expiresAt))))
        if purpose == .device { items.append(URLQueryItem(name: "use", value: Purpose.device.rawValue)) }
        parts.queryItems = items
        return parts.url!
    }

    private static func truncated(_ text: String, bytes: Int) -> String {
        var result = ""
        for character in text {
            guard result.utf8.count + String(character).utf8.count <= bytes else { break }
            result.append(character)
        }
        return result
    }

    // MARK: Reading

    /// What a pasted or opened text turned out to be.
    public enum Reading: Hashable, Sendable {
        case link(FleetPairingLink)
        /// A pairing link of another edition (`appName`'s): this app doesn't open it.
        case otherEdition(appName: String)
        /// A link of this edition that can't be a Mac's: a part is missing, malformed or out of bounds.
        case malformed
        /// Anything else.
        case notALink
    }

    /// Reads `text` (surrounding spaces and line breaks don't count) as a pairing link of the edition whose scheme is `scheme`.
    public static func read(_ text: String, scheme: String = FleetPairingLink.currentScheme) -> Reading {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: trimmed), let found = parts.scheme?.lowercased(), allSchemes.contains(found),
              parts.host == host else { return .notALink }
        guard found == scheme else { return .otherEdition(appName: appName(ofScheme: found) ?? found) }
        guard parts.path == path, let link = Self.link(from: parts.queryItems ?? []) else { return .malformed }
        return .link(link)
    }

    /// Reads `text` as a pairing link of any edition: an iPhone or iPad pairs with a Mac of whichever edition shared it.
    public static func readAnyEdition(_ text: String) -> Reading {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = URLComponents(string: trimmed)?.scheme?.lowercased(), allSchemes.contains(scheme) else { return .notALink }
        return read(trimmed, scheme: scheme)
    }

    /// Whether `url` is shaped like a pairing link of some edition (`shepherd://fleet/...`), whether or not it reads.
    public static func isPairingURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), allSchemes.contains(scheme) else { return false }
        return url.host() == host
    }

    /// The link of `url`, as `read` says it.
    public static func read(_ url: URL, scheme: String = FleetPairingLink.currentScheme) -> Reading { read(url.absoluteString, scheme: scheme) }

    private static func link(from items: [URLQueryItem]) -> FleetPairingLink? {
        func one(_ name: String) -> String? {
            let values = items.filter { $0.name == name }.compactMap(\.value)
            return values.count == 1 ? values[0] : nil
        }
        guard one("v") == version, let id = one("id").flatMap(UUID.init(uuidString:)), let name = one("n"), !name.isEmpty,
              name.utf8.count <= maxNameBytes, let port = one("p").flatMap(UInt16.init), port > 0,
              let code = one("c"), code.count == FleetProtocol.codeLength, code.allSatisfy({ $0.isASCII && $0.isNumber }),
              let expiry = one("x").flatMap(Int64.init), expiry > 0 else { return nil }
        let purpose: Purpose
        switch items.first(where: { $0.name == "use" })?.value {
        case nil: purpose = .join
        case Purpose.device.rawValue?: purpose = .device
        default: return nil
        }
        let raw = items.filter { $0.name == "r" }.compactMap(\.value)
        guard raw.count <= FleetRouteReport.maxRoutes else { return nil }
        var routes: [FleetReportedRoute] = []
        for entry in raw {
            // A kind this build doesn't know is skipped, not refused: a newer Mac may name more kinds.
            guard let comma = entry.lastIndex(of: ",") else { return nil }
            let host = String(entry[..<comma])
            guard FleetRouteReport.isHost(host) else { return nil }
            if let kind = FleetRouteKind(rawValue: String(entry[entry.index(after: comma)...])) { routes.append(FleetReportedRoute(host: host, kind: kind)) }
        }
        guard !routes.isEmpty else { return nil }
        return FleetPairingLink(purpose: purpose, hostID: id, name: name, port: port, routes: routes, code: code, expiresAt: Double(expiry))
    }
}
