import Foundation
import ShepherdProtocol
import ShepherdTestSupport
import Testing

@Suite(.integrationTimeLimit)
struct WireRequestSequenceTests {
    @Test func wireMatchesGolden() throws {
        let summary = "scratch-host request sequences matched the golden"
        try ValidationGolden.check("c-wire.json", from: #filePath, step: "compare-golden", completion: summary) { golden in
            guard var expected = golden["sequences"] as? [String: [[String: [String: Any]]]],
                  let capabilities = expected["model-picker"]?.first?["reply"]?["capabilities"],
                  let browse = expected["browse-project-directory"], browse.first?["reply"] != nil else {
                throw ValidationGolden.Difference(expected: "c-wire.sequences", actual: "Missing or invalid sequence golden")
            }
            // Both connections must advertise the same capabilities. Store the list only once.
            expected["browse-project-directory"]?[0]["reply"]?["capabilities"] = capabilities
            try ValidationGolden.compare(expected, observations(seed: golden["seed"]), at: "c-wire.sequences")
        }
        try ValidationEvidence.record(in: ValidationEvidence.directory, step: "complete", status: "passed",
                                      expected: summary, actual: summary)
    }

    private func observations(seed value: Any?) throws -> Any {
        guard let seed = value as? [String: Any], let clientName = seed["clientName"] as? String,
              let version = seed["protocolVersion"] as? Int, let models = seed["models"] as? [String],
              let defaultModel = seed["defaultModel"] as? String, let directories = seed["directories"] as? [String],
              let missing = seed["missingDirectory"] as? String else {
            throw ValidationGolden.Difference(expected: "c-wire.seed", actual: "Missing or invalid sequence seed")
        }

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
        let sequences: [(String, [RemoteRequest])] = [
            ("model-picker", [hello(11), .listModels(id: 17)]),
            ("browse-project-directory", [hello(23), .listDir(id: 29, path: root.path),
                .listDir(id: 31, path: root.appendingPathComponent(missing).path), .listDir(id: 37, path: root.path)]),
        ]

        var observations: [String: [[String: [String: Any]]]] = [:]
        for (sequence, requests) in sequences {
            let client = try ExtensionClient(path: socket)
            observations[sequence] = try requests.map { request in
                let sent = try NDJSON.encode(request)
                try client.sendRaw(sent)
                var reply: [String: Any]
                repeat {
                    reply = try ValidationGolden.object(client.readLine())
                } while reply["id"] == nil  // Skip pushes, but keep a reply with the wrong ID.
                return ["request": try ValidationGolden.object(sent), "reply": reply]
            }
        }
        return ValidationGolden.normalize(observations, root: scratch.path)
    }
}
