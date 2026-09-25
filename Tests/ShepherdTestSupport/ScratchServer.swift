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

    /// Starts on a fresh directory, or on `dir` to restart over an existing state file.
    public init(dir: URL? = nil, modelCatalog: @escaping SessionServer.ModelCatalog = { ScratchServer.standInModels }) throws {
        self.dir = try dir ?? makeScratchDirectory("srv")
        server = SessionServer(socketPath: self.dir.appendingPathComponent("s.sock").path,
                               stateURL: self.dir.appendingPathComponent("state.json"),
                               modelCatalog: modelCatalog)
        let broadcasts = broadcasts
        server.onStateChanged = { state in broadcasts.withValue { $0.append(state) } }
        try server.start()
    }

    /// Stops the server; `keepFiles` leaves the directory for a restart test.
    public func stop(keepFiles: Bool = false) {
        server.stop()
        if !keepFiles { try? FileManager.default.removeItem(at: dir) }
    }
}
