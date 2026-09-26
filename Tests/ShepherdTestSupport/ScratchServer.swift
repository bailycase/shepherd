import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions

/// A real in-process `SessionServer` on scratch paths, with every broadcast state recorded.
/// Call `stop()` when done (it also removes the scratch directory).
public final class ScratchServer: @unchecked Sendable {
    public let dir: URL
    public let server: SessionServer
    public let broadcasts = Locked<[ShepherdState]>([])

    public var socketPath: String { dir.appendingPathComponent("s.sock").path }
    public var stateURL: URL { dir.appendingPathComponent("state.json") }

    /// What a remote `listModels` answers unless a test passes its own catalog: never pi's.
    public static let standInModels = ModelListing(models: ["stub/model-a", "stub/model-b"], defaultModel: "stub/model-a")

    /// Starts on a fresh directory, or on `dir` to restart over an existing state file. The
    /// skills pi loads from elsewhere come from `piSkills`: none unless a test passes a reader,
    /// never this machine's pi.
    public init(dir: URL? = nil, modelCatalog: @escaping SessionServer.ModelCatalog = { ScratchServer.standInModels },
                piSkills: SkillsStore.PiSkillsReader? = nil) throws {
        self.dir = try dir ?? makeScratchDirectory("srv")
        // An Undo's trashed files land in the scratch directory, never the user's Trash.
        let trash = self.dir.appendingPathComponent("Trash", isDirectory: true)
        server = SessionServer(socketPath: self.dir.appendingPathComponent("s.sock").path,
                               stateURL: self.dir.appendingPathComponent("state.json"),
                               modelCatalog: modelCatalog,
                               skillsDirectory: self.dir.appendingPathComponent("agent-skills", isDirectory: true),
                               piSkills: piSkills,
                               trash: { url in try ScratchServer.moveToTrash(url, trash: trash) })
        let broadcasts = broadcasts
        server.onStateChanged = { state in broadcasts.withValue { $0.append(state) } }
        try server.start()
    }

    /// Where an Undo on this server moves the files a turn created.
    public var trash: URL { dir.appendingPathComponent("Trash", isDirectory: true) }

    /// Moves `url` into `trash` under a unique name, as the Finder's Trash would.
    static func moveToTrash(_ url: URL, trash: URL) throws {
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)"))
    }

    /// Stops the server; `keepFiles` leaves the directory for a restart test.
    public func stop(keepFiles: Bool = false) {
        server.stop()
        if !keepFiles { try? FileManager.default.removeItem(at: dir) }
    }
}
