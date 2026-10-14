import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

@Suite("Project tool activity lines")
struct NativeProjectToolActivityTests {
    private func call(_ tool: String, arguments: String = "{}", output: String, error: Bool = false) -> NativeActivityCall {
        var message = NativeThreadMessage(entryID: tool, role: "toolResult", blocks: [.init(kind: .text, text: output)],
                                          toolName: tool, toolCallID: tool, status: "complete")
        message.argumentsText = arguments
        if error { message.isError = true }
        return NativeActivityCall(message)
    }

    /// What the tools really return (`ProjectContextExtension`): `JSON.stringify(project)`, `{status, artifact}`, `{error, message}`.
    @Test func aPublishedFileReadsAsItsNameNotItsJSON() {
        let artifact = #"{"status":"published","artifact":{"id":"0F0E2C3A-1111-2222-3333-444455556666","artifactName":"verification.txt","relativePath":"verification.txt","sha256":"abc","state":"ready"}}"#
        let burst = nativeActivityBurst([call("project_publish", arguments: #"{"sourcePath":"verification.txt","artifactName":"verification.txt"}"#, output: artifact)])
        #expect(burst.label == "Published verification.txt" && burst.meta.isEmpty)
        #expect(!burst.label.contains("{") && !burst.meta.contains("{"))
        #expect(burst.calls[0].output == artifact, "the raw result stays in the expanded details")
        #expect(burst.calls[0].arguments?.contains("sourcePath") == true)
    }

    @Test func aStagedFileIsNeverSaidToBePublished() {
        let staged = #"{"status":"staged; waiting for owner","artifact":{"artifactName":"report.md","state":"staged"}}"#
        let burst = nativeActivityBurst([call("project_publish", arguments: #"{"artifactName":"report.md"}"#, output: staged)])
        #expect(burst.label == "Staged report.md" && burst.meta == "waiting for the owner")
    }

    @Test func readingAndInspectingTheProjectSayWhatTheyReadWithoutItsIDs() {
        let project = #"{"id":"4aee013b","revision":9,"tasks":[{"id":"t1","title":"Publish verification file","phase":"settled"},{"id":"t2","title":"Other","phase":"running"}],"artifacts":[],"coordinatorAgentID":"63835c7b-a08e-4568-86ed-edc8eed0a910"}"#
        let read = nativeActivityBurst([call("project_read", output: project)])
        #expect(read.label == "Read the project" && read.meta == "2 threads")
        let inspect = nativeActivityBurst([call("project_inspect", arguments: #"{"taskID":"t1"}"#, output: #"{"tasks":[{"id":"t1","title":"Publish verification file"}],"messages":[]}"#)])
        #expect(inspect.label == "Inspected a thread" && inspect.meta == "Publish verification file")
        let again = nativeActivityBurst([call("project_inspect", output: "{}"), call("project_inspect", output: "{}")])
        #expect(again.label == "Inspected threads 2 times")
        #expect(nativeActivityBursts([call("project_read", output: project), call("project_read", output: project)]).count == 1, "consecutive calls of one tool still merge")
    }

    @Test func aRefusalShowsTheToolsOwnMessageAndAnUnparseableResultInventsNothing() {
        let failed = nativeActivityBurst([call("project_publish", arguments: "{}", output: #"{"error":"publication_scope","message":"Only an active native-scoped Project worker may publish."}"#, error: true)])
        #expect(failed.state == .failed && failed.label == "Couldn’t publish")
        #expect(failed.meta.contains("Only an active native-scoped Project worker may publish."), "\(failed.meta)")
        #expect(!failed.meta.contains("publication_scope"))
        let odd = nativeActivityBurst([call("project_read", output: "not json at all")])
        #expect(odd.label == "Read the project" && odd.meta.isEmpty, "no count is invented from text it cannot read")
        let bare = nativeActivityBurst([call("project_publish", output: "ok")])
        #expect(bare.label == "Publish", "an unknown result is not claimed as published")
    }

    /// `project_question` returns `{"answer":…}` or `{"cancelled":true}`; the question comes from the call's own arguments.
    @Test func aQuestionReadsAsAskingAnsweredOrCancelledNeverAsItsJSON() {
        let args = #"{"question":"Pick the test word","options":["ALPHA","BETA"]}"#
        let running: NativeActivityCall = {
            var message = NativeThreadMessage(entryID: "q", role: "toolResult", blocks: [], toolName: "project_question", toolCallID: "q", status: "running")
            message.argumentsText = args
            return NativeActivityCall(message)
        }()
        let waiting = nativeActivityBurst([running])
        #expect(waiting.state == .running && waiting.label == "Waiting for your answer · Pick the test word", "\(waiting.label)")
        let answered = nativeActivityBurst([call("project_question", arguments: args, output: #"{"answer":"BETA"}"#)])
        #expect(answered.label == "Asked a question" && answered.meta == "Pick the test word · BETA", "\(answered.label) | \(answered.meta)")
        #expect(!answered.label.contains("{") && !answered.meta.contains("{") && !answered.meta.contains("\"answer\""))
        #expect(answered.calls[0].output == #"{"answer":"BETA"}"#, "the raw result stays in the expanded details")
        let cancelled = nativeActivityBurst([call("project_question", arguments: args, output: #"{"cancelled":true}"#)])
        #expect(cancelled.label == "Question cancelled" && cancelled.meta == "Pick the test word", "cancelled is not an answer: \(cancelled.meta)")
        let failed = nativeActivityBurst([call("project_question", arguments: args, output: "Native question UI unavailable; no answer received.", error: true)])
        #expect(failed.state == .failed && failed.label == "Couldn’t ask the question")
        let free = nativeActivityBurst([call("project_question", arguments: #"{"question":"Which port?\nSecond line"}"#, output: #"{"answer":"8080"}"#)])
        #expect(free.meta == "Which port? · 8080", "only the first line of the question: \(free.meta)")
    }

    /// `project_assign` and `project_follow_up` carry the coordinator's own choice of model and thinking: the line names the thread,
    /// then what it runs at; the Project JSON the tool returns is never the line.
    @Test func anAssignmentReadsAsTheThreadItStartedAndTheModelAndThinkingItChose() {
        let project = #"{"id":"p","revision":3,"tasks":[{"id":"t1","title":"Library API draft","phase":"queued"}]}"#
        let started = nativeActivityBurst([call("project_assign", arguments: #"{"expectedRevision":2,"spaceID":"s","title":"Library API draft","prompt":"Draft it","model":"anthropic/claude-sonnet-4-5","thinking":"high"}"#, output: project)])
        #expect(started.label == "Started thread Library API draft" && started.meta == "claude-sonnet-4-5 · high", "\(started.label) | \(started.meta)")
        let onlyThinking = nativeActivityBurst([call("project_assign", arguments: #"{"title":"Library API draft","prompt":"x","thinking":"high"}"#, output: project)])
        #expect(onlyThinking.label == "Started thread Library API draft" && onlyThinking.meta == "high")
        let plain = nativeActivityBurst([call("project_assign", arguments: #"{"title":"Library API draft","prompt":"x"}"#, output: project)])
        #expect(plain.label == "Started thread Library API draft" && plain.meta.isEmpty, "no choice named: the Project's defaults, said nowhere")
        // A follow-up names its task by ID: its title is the owner's, from the tool's own result.
        let follow = nativeActivityBurst([call("project_follow_up", arguments: #"{"taskID":"t1","text":"Again","thinking":"low"}"#, output: project)])
        #expect(follow.label == "Sent a follow-up to Library API draft" && follow.meta == "low", "\(follow.label) | \(follow.meta)")
        #expect(!started.label.contains("{") && !started.meta.contains("{") && !follow.meta.contains("{"))
        let running: NativeActivityCall = {
            var message = NativeThreadMessage(entryID: "a", role: "toolResult", blocks: [], toolName: "project_assign", toolCallID: "a", status: "running")
            message.argumentsText = #"{"title":"Library API draft","prompt":"x","thinking":"high"}"#
            return NativeActivityCall(message)
        }()
        #expect(nativeActivityBurst([running]).label == "Starting thread Library API draft")
        let refused = nativeActivityBurst([call("project_assign", arguments: #"{"title":"x","thinking":"extreme"}"#, output: #"{"error":"invalid_project","message":"Unknown thinking level."}"#, error: true)])
        #expect(refused.state == .failed && refused.label == "Couldn’t assign the thread" && refused.meta.contains("Unknown thinking level."))
    }

    @Test func otherToolsKeepTheirOrdinaryLine() {
        let other = nativeActivityBurst([call("some_other_tool", arguments: #"{"query":"x"}"#, output: "{}")])
        #expect(other.label.hasPrefix("Used some_other_tool"))
    }
}
