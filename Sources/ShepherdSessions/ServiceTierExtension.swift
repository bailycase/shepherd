import Darwin
import Foundation
import ShepherdCore

/// The service tier extension: installed in Shepherd's pi home with its other files
/// (`PiHome.install`, outside extensions/ so pi never discovers a second copy) and loaded by an
/// agent's own pi only (`StatusExtension.command`), which is also the only pi started with
/// `SHEPHERD_EXT_SERVICE_TIER`. It reads the file `ServiceTierFile` keeps for the agent on every
/// provider request. A native subagent is another pi process started without any `SHEPHERD_`
/// variable (the children extension removes them), so it runs on Standard whatever its parent's
/// tier is.
public enum ServiceTierExtension {
    static let fileName = "shepherd-service-tier.ts"
    /// The environment variable that names an agent's tier file.
    public static let environmentKey = "SHEPHERD_EXT_SERVICE_TIER"

    /// Where `PiHome.install` writes the extension: what an agent's pi loads with `-e`.
    public static func path(in home: PiHome) -> String {
        home.directory.appendingPathComponent(fileName).path
    }

    /// The variable that turns the extension on for one agent's pi, naming the agent's file.
    public static func environment(for agentID: AgentID, in home: PiHome) -> [String: String] {
        ServiceTierFile.url(for: agentID, in: home).map { [environmentKey: $0.path] } ?? [:]
    }

    @discardableResult
    static func install(in home: PiHome) throws -> URL {
        let path = home.directory.appendingPathComponent(fileName)
        try PiHome.write(Data(extensionSource.utf8), to: path, mode: 0o600)
        return path
    }
    static var extensionSource: String { EmbeddedExtensions.source("shepherd-service-tier.ts") }
}

/// What the host keeps for an agent's pi to read: `<home>/service-tier/<agent>.json`, the agent's
/// tier, rewritten atomically whenever it changes and before its pi starts. A file rather than a
/// message because the extension reads it synchronously on each request (a change applies to the
/// next model call of a running agent), it needs no connection (a pi started by Retry or a
/// relaunch, or one whose socket is down, still reads the current tier), and a torn read cannot
/// happen: the file is replaced by rename.
public enum ServiceTierFile {
    public static func directory(in home: PiHome) -> URL {
        home.directory.appendingPathComponent("service-tier", isDirectory: true)
    }

    /// The agent's file. The id is a UUID string, but a path is built from it, so anything else
    /// is refused.
    public static func url(for agentID: AgentID, in home: PiHome) -> URL? {
        let id = agentID.rawValue
        guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        return directory(in: home).appendingPathComponent("\(id).json")
    }

    /// Writes `tier` for the agent. Throws when the home can't be written; the agent then runs
    /// on whatever the file last held.
    public static func write(_ tier: ServiceTier, for agentID: AgentID, in home: PiHome) throws {
        guard let file = url(for: agentID, in: home) else { throw PiHomeError("Not a valid agent id: \(agentID.rawValue)") }
        let folder = directory(in: home)
        // A link in the home would carry the file somewhere else, such as the user's own pi.
        guard home.contains(file.path) else {
            throw PiHomeError("\(folder.path) leads outside Shepherd's pi home, so Shepherd won't write a service tier there")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try PiHome.write(Data(#"{"tier":"\#(tier.rawValue)"}"#.utf8), to: file, mode: 0o600)
    }

    /// The tier the agent's file holds; Standard when there is none or it can't be read.
    public static func read(for agentID: AgentID, in home: PiHome) -> ServiceTier {
        guard let file = url(for: agentID, in: home), let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["tier"] as? String, let tier = ServiceTier(rawValue: raw) else { return .standard }
        return tier
    }

    public static func remove(for agentID: AgentID, in home: PiHome) {
        guard let file = url(for: agentID, in: home) else { return }
        try? FileManager.default.removeItem(at: file)
    }
}
