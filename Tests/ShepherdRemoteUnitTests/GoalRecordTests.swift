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

    @Test func projectedDiagnosticsStayDisclosedAndTheModelRemainsVisible() {
        let decision = NativeGoalRecord("Goal needs you · looks met, evidence incomplete, confirm\nChecked by fixture/worker\n\nDetails:\nMissing evidence:\nr2: verify deployment\n\nTool evidence:\nproof-id: a recorded successful result")
        #expect(decision.line == "Goal needs you · looks met, evidence incomplete, confirm\nChecked by fixture/worker")
        #expect(decision.showsDetails)
        #expect(decision.evidence?.contains("r2: verify deployment") == true)
        #expect(!decision.line.contains("proof-id"))
        let error = NativeGoalRecord("Goal needs you · goal check failed · try again\n\nDetails:\nNo authenticated goal evaluator model is available.")
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
