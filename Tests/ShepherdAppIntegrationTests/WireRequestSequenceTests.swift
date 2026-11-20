import Foundation
import ShepherdProtocol
import ShepherdTestSupport
import Testing

struct WireRequestSequenceTests {
    @Test func wireMatchesGolden() throws {
        let golden = try WireGolden.read()
        let seed = try #require(golden["seed"] as? [String: Any])
        let clientName = try #require(seed["clientName"] as? String)
        let version = try #require(seed["protocolVersion"] as? Int)
        let models = try #require(seed["models"] as? [String])
        let defaultModel = try #require(seed["defaultModel"] as? String)
        let directories = try #require(seed["directories"] as? [String])
        let missing = try #require(seed["missingDirectory"] as? String)

        let host = try ScratchServer(modelCatalog: { ModelListing(models: models, defaultModel: defaultModel) })
        defer { host.stop() }
        let socket = host.dir.appendingPathComponent("host.sock").path
        try host.server.startLocalListener(path: socket)
        let scratch = host.dir.resolvingSymlinksInPath()
        let root = scratch.appendingPathComponent("browse", isDirectory: true)
        for name in directories {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }

        func hello(_ id: Int) -> RemoteRequest {
            .hello(id: id, token: "", clientName: clientName, protocolVersion: version)
        }
        let sequences: [(String, [(String, RemoteRequest)])] = [
            ("model-picker", [("hello", hello(11)), ("list-models", .listModels(id: 17))]),
            ("browse-project-directory", [
                ("hello", hello(23)), ("list-projects", .listDir(id: 29, path: root.path)),
                ("missing-directory", .listDir(id: 31, path: root.appendingPathComponent(missing).path)),
                ("list-again", .listDir(id: 37, path: root.path)),
            ]),
        ]

        var observations: [String: Any] = [:]
        for (sequence, requests) in sequences {
            let client = try ExtensionClient(path: socket)
            observations[sequence] = try requests.map { step, request -> [String: Any] in
                let sent = try NDJSON.encode(request)
                try client.sendRaw(sent)
                func normalized(_ frame: Data) throws -> [String: Any] {
                    let line = String(decoding: frame, as: UTF8.self).replacingOccurrences(of: scratch.path, with: "<scratch>")
                    return try WireGolden.object(Data(line.utf8))
                }
                // These clients don't subscribe to pushes. Keep the next frame even if its ID is missing or wrong.
                let reply = try normalized(client.readLine())
                return ["step": step, "request": try normalized(sent), "reply": reply]
            }
        }

        try WireGolden.check(golden["sequences"], observations, at: "sequences", step: "compare-golden")
        let summary = "scratch-host request sequences matched the golden"
        for step in ["compare-golden", "complete"] {
            try ValidationEvidence.record(in: ValidationEvidence.directory, step: step, status: "passed",
                                          expected: summary, actual: summary)
        }
    }
}
