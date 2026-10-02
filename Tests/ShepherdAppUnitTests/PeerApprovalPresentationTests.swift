import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import Testing
@testable import ShepherdApp

/// What the approval dialog says about an agent's call on another thread: every action's title and
/// sentence, the rows that tell the target from another thread of its name, and the long message.
@Suite("Peer approval dialog words")
struct PeerApprovalPresentationTests {
    private static let space = Fixture.space("billing-service", path: "/Users/me/Developer/billing-service")
    private static let lead = Fixture.agent("Coordinate the release", in: space, order: 0)
    private static let worker = Fixture.agent("Flaky integration tests", in: space, order: 1)
    private static let state = ShepherdState(spaces: [space], tabs: [lead.tab, worker.tab], agents: [lead.agent, worker.agent])

    private static func prompt(_ action: AgentGatedAction) -> AgentApprovalPrompt {
        AgentApprovalPrompt(requestID: "token", senderID: lead.agent.id, action: action)
    }

    private static func make(_ action: AgentGatedAction, waiting: Int = 0, in state: ShepherdState = state) -> PeerApprovalPresentation {
        PeerApprovalPresentation.make(prompt(action), in: state, waiting: waiting)
    }

    private static let to = worker.agent.id

    /// Each action's title and the sentence that names who wants what.
    @Test(arguments: [
        (AgentGatedAction.send(targetAgentID: to, text: "hi", delivery: .task), "Message another thread",
         "“Coordinate the release” wants to message “Flaky integration tests”."),
        (.send(targetAgentID: to, text: "hi", delivery: .report), "Message another thread",
         "“Coordinate the release” wants to send “Flaky integration tests” a report."),
        (.steer(targetAgentID: to, text: "stop"), "Steer another thread",
         "“Coordinate the release” wants to steer “Flaky integration tests”."),
        (.interrupt(targetAgentID: to), "Interrupt another thread",
         "“Coordinate the release” wants to stop what “Flaky integration tests” is doing."),
        (.read(targetAgentID: to), "Read another thread",
         "“Coordinate the release” wants to read “Flaky integration tests”'s conversation."),
        (.spawn(cwd: "/tmp/api", prompt: "fix the build"), "Start a new thread",
         "“Coordinate the release” wants to start a new thread."),
    ])
    func eachActionSaysWhoWantsWhat(action: AgentGatedAction, title: String, sentence: String) {
        let words = Self.make(action)

        #expect(words.title == title)
        #expect(words.subtitle == sentence + " If you don't answer within two minutes, it is denied.")
    }

    @Test func theTimeoutIsTheServersTimeout() {
        #expect(AgentMessageGate.approvalTimeout == 120 && PeerApprovalPresentation.timeoutWords == "two minutes")
    }

    @Test func aMessageShowsItsTargetItsDeliveryAndWhoAsked() {
        let words = Self.make(.send(targetAgentID: Self.to, text: "Rerun the flaky test with -count=20.", delivery: .task))

        #expect(words.rows == [
            .init(label: "To", value: "Flaky integration tests", style: .name),
            .init(label: "Directory", value: "/Users/me/Developer/billing-service".replacingHome, style: .mono),
            .init(label: "Space", value: "billing-service", style: .secondary),
            .init(label: "Delivery", value: "Starts or queues a turn", style: .secondary),
            .init(label: "Asked by", value: "Coordinate the release", style: .secondary),
        ])
        #expect(words.textLabel == "Message" && words.text == "Rerun the flaky test with -count=20.")
    }

    @Test func aReportSaysItStartsNoTurnAndASteerSaysWhenItLands() {
        let report = Self.make(.send(targetAgentID: Self.to, text: "ok", delivery: .report))
        let steer = Self.make(.steer(targetAgentID: Self.to, text: "ok"))

        #expect(report.rows.first { $0.label == "Delivery" }?.value == "Context only, starts no turn")
        #expect(steer.rows.first { $0.label == "Delivery" }?.value == "Lands at its next step, or starts an idle thread")
    }

    @Test func aWorktreeThreadIsToldApartByItsBranchNotItsFolder() {
        var branch = Self.worker.agent
        branch.worktreeBranch = "fix/flaky-integration-tests"
        let state = ShepherdState(spaces: [Self.space], tabs: [Self.lead.tab, Self.worker.tab], agents: [Self.lead.agent, branch])

        let rows = Self.make(.read(targetAgentID: Self.to), in: state).rows

        #expect(rows.contains(.init(label: "Branch", value: "fix/flaky-integration-tests", style: .mono)))
        #expect(!rows.contains { $0.label == "Directory" })
    }

    /// Interrupting and reading carry no text; starting a thread names its folder and its prompt.
    @Test func onlyWhatCarriesWordsShowsAMessageRow() {
        #expect(Self.make(.interrupt(targetAgentID: Self.to)).text == nil)
        #expect(Self.make(.read(targetAgentID: Self.to)).text == nil)
        let spawn = Self.make(.spawn(cwd: "/Users/me/src/api", prompt: "Fix the build."))
        #expect(spawn.textLabel == "Prompt" && spawn.text == "Fix the build.")
        #expect(spawn.rows.map(\.label) == ["Folder", "Asked by"])
        #expect(spawn.rows.first?.style == .mono)
    }

    @Test func allowingForTheThreadSaysWhatItCoversAndForHowLong() {
        let note = Self.make(.read(targetAgentID: Self.to)).note

        #expect(note == "Allow for this thread lets “Coordinate the release” message, steer, interrupt, read and start threads until you quit Shepherd or its pi restarts.")
    }

    @Test(arguments: [(0, nil as String?), (1, "1 more waiting"), (3, "3 more waiting")])
    func callsQueuedBehindThisOneAreCounted(waiting: Int, status: String?) {
        #expect(Self.make(.read(targetAgentID: Self.to), waiting: waiting).status == status)
    }

    @Test func agentsThatAreGoneAreNamedGenerically() {
        let alone = ShepherdState(spaces: [Self.space], tabs: [], agents: [])
        let words = Self.make(.send(targetAgentID: Self.to, text: "hi", delivery: .task), in: alone)

        #expect(words.subtitle.hasPrefix("An agent wants to message another thread."))
        #expect(words.rows == [.init(label: "To", value: "Another thread", style: .secondary),
                               .init(label: "Delivery", value: "Starts or queues a turn", style: .secondary),
                               .init(label: "Asked by", value: "An agent", style: .secondary)])
    }

    /// A long message is cut for the dialog and the rest counted, never silently dropped.
    @Test(arguments: [0, 1, 3_999, 4_000])
    func aMessageUpToTheLimitIsShownWhole(length: Int) {
        let text = String(repeating: "x", count: length)
        #expect(PeerApprovalPresentation.clipped(text) == text)
    }

    @Test func aLongerMessageIsCutAndTheRestCounted() {
        let text = String(repeating: "x", count: 4_000) + String(repeating: "y", count: 1_234)

        let clipped = PeerApprovalPresentation.clipped(text)

        #expect(clipped == String(repeating: "x", count: 4_000) + "\n… 1234 more characters")
        #expect(Self.make(.send(targetAgentID: Self.to, text: text, delivery: .task)).text == clipped)
    }
}

private extension String {
    /// A path as the dialog shows it: the home folder as ~.
    var replacingHome: String { (self as NSString).abbreviatingWithTildeInPath }
}
