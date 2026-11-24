import Foundation
import ShepherdCore
import ShepherdProtocol

// The iPhone's Shepherd location in Files (its File Provider extension): every paired Mac, each Mac's threads, and each
// thread's folder through `files.v1`. These are the parts of it that are plain values, so they are checked here.

/// Where one item of the location is, and its File Provider identifier (`identifier`, `init?(identifier:)`).
public enum FilesLocation: Hashable, Sendable {
    /// The location itself: the paired Macs.
    case root
    /// A paired Mac (`RemoteHostRecord.id`): its threads.
    case host(UUID)
    /// A thread's folder.
    case thread(host: UUID, agent: AgentID)
    /// A file or folder of a thread's folder, `path` relative to it.
    case entry(host: UUID, agent: AgentID, path: String)

    /// The identifier the extension hands Files. An agent id never holds "/", so the path is all that follows it.
    public var identifier: String {
        switch self {
        case .root: "root"
        case .host(let host): "h/\(host.uuidString)"
        case .thread(let host, let agent): "t/\(host.uuidString)/\(agent.rawValue)"
        case .entry(let host, let agent, let path): "f/\(host.uuidString)/\(agent.rawValue)/\(path)"
        }
    }

    public init?(identifier: String) {
        let parts = identifier.split(separator: "/", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "root" where parts.count == 1: self = .root
        case "h" where parts.count == 2:
            guard let host = UUID(uuidString: parts[1]) else { return nil }
            self = .host(host)
        case "t" where parts.count == 3:
            guard let host = UUID(uuidString: parts[1]), !parts[2].isEmpty else { return nil }
            self = .thread(host: host, agent: AgentID(rawValue: parts[2]))
        case "f" where parts.count == 4:
            guard let host = UUID(uuidString: parts[1]), !parts[2].isEmpty, !parts[3].isEmpty else { return nil }
            self = .entry(host: host, agent: AgentID(rawValue: parts[2]), path: parts[3])
        default: return nil
        }
    }

    public var parent: FilesLocation {
        switch self {
        case .root, .host: return .root
        case .thread(let host, _): return .host(host)
        case .entry(let host, let agent, let path):
            let folder = (path as NSString).deletingLastPathComponent
            return folder.isEmpty ? .thread(host: host, agent: agent) : .entry(host: host, agent: agent, path: folder)
        }
    }

    /// A child of a thread's folder or of a folder in it, named `name`.
    public func child(_ name: String) -> FilesLocation? {
        switch self {
        case .thread(let host, let agent): .entry(host: host, agent: agent, path: name)
        case .entry(let host, let agent, let path): .entry(host: host, agent: agent, path: path + "/" + name)
        case .root, .host: nil
        }
    }

    /// The folder `files.v1` lists for it, relative to the thread's folder: "" for the thread's folder itself.
    public var folderPath: String? {
        switch self {
        case .thread: ""
        case .entry(_, _, let path): path
        case .root, .host: nil
        }
    }
}

public enum FilesNames {
    /// Names for siblings in order, each usable as a file name and none repeated: "/" can't be in one, and a second
    /// "Fix login" is "Fix login 2".
    public static func unique(_ names: [String]) -> [String] {
        var taken = Set<String>()
        return names.map { raw in
            let base = raw.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
            let name = base.isEmpty ? "Untitled" : base
            var candidate = name
            var n = 2
            while !taken.insert(candidate.lowercased()).inserted {
                candidate = "\(name) \(n)"
                n += 1
            }
            return candidate
        }
    }

    /// Where a phone's edit goes when the Mac's file changed under it: beside it, never over either. "README.md" is
    /// "README (iPhone).md", then "README (iPhone 2).md" while that is taken.
    public static func conflictCopy(of name: String, device: String, taken: Set<String>) -> String {
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        let lowered = Set(taken.map { $0.lowercased() })
        var n = 1
        while true {
            let label = n == 1 ? device : "\(device) \(n)"
            let candidate = ext.isEmpty ? "\(stem) (\(label))" : "\(stem) (\(label)).\(ext)"
            if !lowered.contains(candidate.lowercased()) { return candidate }
            n += 1
        }
    }

    /// The threads a Mac's folder shows, with their folder names: those still on that Mac, in its order.
    public static func threads(_ agents: [Agent]) -> [(agent: AgentID, name: String)] {
        let shown = agents.filter { $0.movedTo == nil }
        return Array(zip(shown.map(\.id), unique(shown.map(\.name)))).map { ($0.0, $0.1) }
    }
}

extension ThreadFileEntry {
    /// The entry's content version for Files: it moves when the file's size or modification time does. A host older
    /// than `files.create.v1` lists no time, so only a size change shows there.
    public var filesVersion: Data {
        Data("\(size ?? -1):\(modified.map { String($0) } ?? "")".utf8)
    }
}
