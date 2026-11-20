import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol

@Suite("Project publication wire")
struct ProjectPublicationWireTests {
    private static let artifact = ProjectArtifactReceipt(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!, key: ProjectExecutionWireTests.key,
        taskID: ProjectExecutionWireTests.assignment.taskID, workerAgentID: ProjectExecutionWireTests.assignment.reservedWorkerID,
        sessionID: "session", generation: "generation", artifactName: "report.txt",
        sha256: String(repeating: "a", count: 64), sourceIdentity: String(repeating: "b", count: 64))
    private static let command = ProjectExecutionRequest.publicationRead(key: artifact.key, publicationID: artifact.id, offset: 0)
    static let wireRequest = RemoteRequest.projectExecution(id: 5, request: command)
    static let wireReply = reply(chunk: Data("report".utf8))

    private static func reply(chunk: Data) -> RemoteReply {
        var publication = artifact
        publication.size = Int64(chunk.count)
        var receipt = ProjectExecutionReceipt(key: publication.key, phase: .settled, admittedAt: 1_790_000_000)
        receipt.publications = [publication]
        var result = ProjectExecutionResult(receipt: receipt)
        result.publication = .init(publicationID: publication.id, offset: 0, data: chunk)
        return .projectExecution(id: 5, result: result)
    }

    @Test func publicationCommandsRoundTripAndChunksFitFrames() throws {
        #expect(try Wire.roundTrip(Self.wireRequest) == Self.wireRequest)
        #expect(try Wire.roundTrip(Self.wireReply) == Self.wireReply)
        #expect(Self.command.requiresPublications)
        let publication = Self.artifact
        let extensionRequest = ExtensionMessage.projectPublish(id: 9, agentID: publication.workerAgentID,
            request: .publish(publicationID: publication.id, sourcePath: "source.txt", artifactName: "report.txt"))
        #expect(extensionRequest.speaksFor == publication.workerAgentID && extensionRequest.replyID == 9)
        #expect(try JSONDecoder().decode(ExtensionMessage.self, from: JSONEncoder().encode(extensionRequest)) == extensionRequest)
        let extensionReply = ExtensionReply.projectPublish(id: 9, result: .init(active: true, artifact: publication))
        #expect(try JSONDecoder().decode(ExtensionReply.self, from: JSONEncoder().encode(extensionReply)) == extensionReply)
        let reply = Self.reply(chunk: Data(repeating: 255, count: ProjectArtifactReceipt.chunkBytes))
        let line = try NDJSON.encode(reply)
        var buffer = LineBuffer()
        let payloads = try buffer.append(line)
        let payload = try #require(payloads.first)
        #expect(try NDJSON.decode(RemoteReply.self, from: payload) == reply)
    }

    @Test func legacyRecordsDecodeWithoutPublicationsAndNamesAndBudgetsAreBounded() throws {
        let project = Project(name: "Legacy")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
        json.removeValue(forKey: "artifacts")
        #expect(try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: json)).artifacts.isEmpty)
        let publication = Self.artifact
        let receipt = ProjectExecutionReceipt(key: publication.key, phase: .cancelled)
        #expect(try JSONDecoder().decode(ProjectExecutionReceipt.self, from: JSONEncoder().encode(receipt)).publications == nil)
        for name in ["", "../a", ".env", "auth.json", "sessions", "a/b", "a\\b", "key.pem", "a\0b", String(repeating: "a", count: 256)] {
            #expect(!ProjectArtifactReceipt.safeComponent(name))
        }
        try publication.validate()
        var invalid = publication; invalid.size = Int64(ProjectArtifactReceipt.maximumBytes) + 1
        #expect(throws: ProjectValidationError.self) { try invalid.validate() }
        #expect(throws: ProjectValidationError.self) { try ProjectArtifactReceipt.validateCollection([publication, publication]) }
        let countOverflow = (0...ProjectArtifactReceipt.maximumCount).map { _ -> ProjectArtifactReceipt in
            var copy = publication; copy.id = UUID(); return copy
        }
        #expect(throws: ProjectValidationError.self) { try ProjectArtifactReceipt.validateCollection(countOverflow) }
        let byteOverflow = countOverflow.prefix(9).map { receipt in
            var copy = receipt; copy.size = Int64(ProjectArtifactReceipt.maximumBytes); return copy
        }
        #expect(throws: ProjectValidationError.self) { try ProjectArtifactReceipt.validateCollection(byteOverflow) }
    }
}
