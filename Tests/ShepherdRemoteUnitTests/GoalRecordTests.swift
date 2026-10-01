import Foundation
import Testing
import ShepherdRemote

@Suite("Goal transcript records")
struct GoalRecordTests {
    @Test func rawProofIsSeparateFromTheShortClosingLine() {
        let proof = "ab123456: 41 tests passed\tgo vet is clean\nFull proof."
        let record = NativeGoalRecord("Goal met · 41 tests passed\n\nEvidence:\n" + proof)
        #expect(record.line == "Goal met · 41 tests passed")
        #expect(record.isClosing)
        #expect(record.evidence == proof)
        #expect(!record.line.contains("ab123456") && !record.line.contains("\t"))
    }

    @Test func oldMetRecordsKeepTheirUnstructuredEvidenceBehindDisclosure() {
        let text = "Goal met · said something about ab123456\nab123456: passed\t41 tests"
        let record = NativeGoalRecord(text)
        #expect(record.line == "Goal met")
        #expect(record.evidence == text)
    }

    @Test func runtimeStopsKeepFullFeedbackAndAuthenticationErrorsBehindDisclosure() throws {
        struct Fixture: Decodable {
            struct Record: Decodable { let content: String }
            let records: [Record]
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("Tests/Extensions/goal-runtime-fixtures.json")))
        let decision = NativeGoalRecord(try #require(fixture.records.first { $0.content.contains("Choose staging or production") }?.content))
        #expect(decision.line == "Goal needs you · choose a deployment target")
        #expect(decision.showsDetails)
        #expect(decision.evidence?.contains("Choose staging or production; do not deploy until the user decides.") == true)
        let error = NativeGoalRecord(try #require(fixture.records.first { $0.content.contains("No authenticated goal evaluator") }?.content))
        #expect(error.line == "Goal needs you · goal check failed · try again")
        #expect(error.evidence == "No authenticated goal evaluator model is available.")
        #expect(error.showsDetails)
    }

    @Test func disclosureMarkersInsideProofNeverMoveRawEvidenceIntoTheReadableLine() {
        let text = "Goal met · tests passed\n\nEvidence:\nentry123: output\n\nDetails:\nmore output"
        let record = NativeGoalRecord(text)
        #expect(record.line == "Goal met · tests passed")
        #expect(!record.showsDetails)
        #expect(record.evidence == "entry123: output\n\nDetails:\nmore output")
    }

    @Test func theGoalConditionIsNeverMistakenForProof() {
        let text = "Goal set\nPrint the exact marker\n\nEvidence:\nthen stop."
        let record = NativeGoalRecord(text)
        #expect(record.line == text)
        #expect(record.evidence == nil)
        #expect(!record.isClosing)
    }
}
