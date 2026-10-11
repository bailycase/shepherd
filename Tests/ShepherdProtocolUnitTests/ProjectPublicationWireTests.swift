import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol

@Suite("Project publication wire")
struct ProjectPublicationWireTests {
    private var artifact: ProjectArtifactReceipt {
        .init(id: UUID(), key: .init(ownerID: UUID(), projectID: .init(), operationID: UUID()),
              taskID: .init(), workerAgentID: .init(), sessionID: "session", generation: "generation",
              artifactName: "report.txt", size: Int64(ProjectArtifactReceipt.chunkBytes),
              sha256: String(repeating: "a", count: 64), sourceIdentity: String(repeating: "b", count: 64))
    }

    @Test func publicationCommandsRoundTripAndChunksFitFrames() throws {
        let publication = artifact
        let command = ProjectExecutionRequest.publicationRead(key: publication.key, publicationID: publication.id, offset: 0)
        let wire = RemoteRequest.projectExecution(id: 5, request: command)
        #expect(try JSONDecoder().decode(RemoteRequest.self, from: JSONEncoder().encode(wire)) == wire)
        #expect(command.requiresPublications)
        let extensionRequest = ExtensionMessage.projectPublish(id: 9, agentID: publication.workerAgentID,
            request: .publish(publicationID: publication.id, sourcePath: "source.txt", artifactName: "report.txt"))
        #expect(extensionRequest.speaksFor == publication.workerAgentID && extensionRequest.replyID == 9)
        #expect(try JSONDecoder().decode(ExtensionMessage.self, from: JSONEncoder().encode(extensionRequest)) == extensionRequest)
        let extensionReply = ExtensionReply.projectPublish(id: 9, result: .init(active: true, artifact: publication))
        #expect(try JSONDecoder().decode(ExtensionReply.self, from: JSONEncoder().encode(extensionReply)) == extensionReply)
        var receipt = ProjectExecutionReceipt(key: publication.key, phase: .settled)
        receipt.publications = [publication]
        var result = ProjectExecutionResult(receipt: receipt)
        result.publication = .init(publicationID: publication.id, offset: 0, data: Data(repeating: 255, count: ProjectArtifactReceipt.chunkBytes))
        let reply = RemoteReply.projectExecution(id: 5, result: result)
        let data = try JSONEncoder().encode(reply)
        #expect(data.count < NDJSON.maxPayloadBytes)
        #expect(try JSONDecoder().decode(RemoteReply.self, from: data) == reply)
    }

    @Test func legacyRecordsDecodeWithoutPublicationsAndNamesAndBudgetsAreBounded() throws {
        let project = Project(name: "Legacy")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
        json.removeValue(forKey: "artifacts")
        #expect(try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: json)).artifacts.isEmpty)
        let publication = artifact
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
