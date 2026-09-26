import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import Testing
@testable import ShepherdApp

/// What the Mac's system notifications say (NotifCatalog, NotifMac): the title names the thread,
/// the subtitle is the kind, the body one sentence, the actions are the app's own choices for that
/// moment, and none shows while you're watching the agent.
@Suite("Agent banners")
struct AgentBannersTests {
    private let space = Fixture.space("s")

    private func agent(_ status: AgentStatus) -> Agent {
        var agent = Fixture.agent("Fix login", in: space).agent
        agent.status = status
        return agent
    }

    @Test(arguments: [
        (TurnFailure?.none, String?.some("Done. 3 files changed, tests pass."), "Turn finished",
         "Done. 3 files changed, tests pass.", [BannerAction.review], AgentBanner.Level.passive),
        (nil, nil, "Turn finished", "Finished its turn.", [.review], .passive),
        (TurnFailure(message: "Build failed in RemoteClient.swift."), nil, "Turn failed",
         "Build failed in RemoteClient.swift.", [.retry, .open], .active),
        (TurnFailure(message: nil), nil, "Turn failed", "The model request failed.", [.retry, .open], .active),
        (TurnFailure(message: "  \n"), nil, "Turn failed", "The model request failed.", [.retry, .open], .active),
    ])
    func aTurnEndingSaysWhatHappened(failure: TurnFailure?, result: String?, kind: String, body: String,
                                     actions: [BannerAction], level: AgentBanner.Level) throws {
        let agent = agent(.done)
        let banner = try #require(AgentBanners.status(of: agent, from: .working, failure: failure, result: result, watching: false))
        #expect(banner.title == "Fix login")
        #expect(banner.subtitle == kind)
        #expect(banner.body == body)
        #expect(banner.actions == actions)
        #expect(banner.level == level)
        // Successes are quiet; failures are not.
        #expect(banner.sound == (failure != nil))
        #expect(banner.target == .agent(agent.id))
        #expect(banner.group == "thread:\(agent.id.rawValue)")
        #expect(banner.identifier == "shepherd-status-\(agent.id.rawValue)")
    }

    /// Launch resets, session restarts and a question are not a turn ending, and nothing posts
    /// while you're watching the agent.
    @Test(arguments: [
        (AgentStatus.idle, AgentStatus.done, false),
        (.done, .done, false),
        (.working, .idle, false),
        (.working, .working, false),
        (.working, .blocked, false),
        (.blocked, .working, false),
        (.working, .done, true),
    ])
    func onlyATurnEndingPosts(from old: AgentStatus, to status: AgentStatus, posts: Bool) {
        let failure = TurnFailure(message: "boom")
        #expect((AgentBanners.status(of: agent(status), from: old, failure: failure, watching: false) != nil) == posts)
        #expect(AgentBanners.status(of: agent(status), from: old, failure: failure, watching: true) == nil)
    }

    /// A long error shows its first line, cut short.
    @Test func aFailureQuotesTheFirstLineOfItsError() throws {
        let long = String(repeating: "x", count: 300)
        let banner = try #require(AgentBanners.status(of: agent(.done), from: .working,
                                                      failure: TurnFailure(message: "\(long)\nstack"), watching: false))
        #expect(banner.body.count == AgentBanners.quoteLimit)
        #expect(banner.body.hasSuffix("…"))
    }

    // MARK: The turn's result and its prompt

    private func message(_ role: String, _ text: String, status: String? = nil) -> NativeThreadMessage {
        NativeThreadMessage(entryID: UUID().uuidString, role: role, blocks: [NativeThreadBlock(kind: .text, text: text)],
                            status: status)
    }

    @Test(arguments: [
        ("**Done.** 3 files changed, tests pass.\n\nDetails follow.", "Done. 3 files changed, tests pass."),
        ("## Summary\n- Fixed `RemoteClient`", "Summary"),
        ("   ", nil),
    ])
    func theResultIsTheClosingReplysFirstLineWithoutMarkdown(reply: String, result: String?) {
        #expect(AgentBanners.result(reply) == result)
    }

    @Test func theClosingReplyIsTheLastAnswerAfterTheLastPrompt() {
        let messages = [message("user", "Fix it"), message("assistant", "Looking."), message("toolResult", "ok"),
                        message("assistant", "Done. Tests pass.")]
        #expect(AgentBanners.closingReply(in: messages) == "Done. Tests pass.")
        #expect(AgentBanners.closingReply(in: messages + [message("user", "And the docs?")]) == nil)
        #expect(AgentBanners.lastPrompt(in: messages) == "Fix it")
        #expect(AgentBanners.lastPrompt(in: messages + [message("user", "Later", status: "queued")]) == "Fix it",
                "a queued message has not opened a turn")
    }

    // MARK: Questions

    @Test func aSelectQuestionOffersItsOptions() {
        let agent = agent(.blocked)
        let dialog = NativeThreadDialog(id: "d1", kind: .select, title: "Which key joins a refund?", options: ["order_id", "payment_id"])
        let banner = AgentBanners.question(NativeQuestionPrompt(dialog: dialog), asked: "Which key joins a refund?",
                                           title: agent.name, target: .agent(agent.id), automation: false)
        #expect(banner.title == "Fix login")
        #expect(banner.subtitle == "Question")
        #expect(banner.body == "Which key joins a refund?")
        #expect(banner.actions == [.option(1, title: "order_id"), .option(2, title: "payment_id")])
        #expect(banner.question == "d1")
        #expect(banner.level == .active)
        #expect(banner.identifier == "shepherd-question-\(agent.id.rawValue)")
    }

    @Test(arguments: [
        (NativeThreadDialog.Kind.confirm, [BannerAction.option(1, title: "Yes"), .option(2, title: "No")]),
        (.input, [.reply(placeholder: "Type your answer…")]),
        (.editor, [.reply(placeholder: "Type your answer…")]),
    ])
    func eachKindOfQuestionOffersTheDocksChoices(kind: NativeThreadDialog.Kind, actions: [BannerAction]) {
        let prompt = NativeQuestionPrompt(dialog: NativeThreadDialog(id: "d", kind: kind, title: "Go on?"))
        #expect(AgentBanners.answers(prompt) == actions)
    }

    /// A question the dock can't answer (an external editor open) only opens the thread; one the
    /// thread couldn't be read for still says what it asks.
    @Test func aQuestionThatCannotBeAnsweredHereOnlyOpens() {
        let blocked = NativeQuestionPrompt(dialog: NativeThreadDialog(id: "d", kind: .input, title: "Name?", unavailable: "external-editor"))
        #expect(AgentBanners.answers(blocked) == [.open])
        let unread = AgentBanners.question(nil, asked: "Name?", title: "Triage", target: .agent(AgentID()), automation: true)
        #expect(unread.actions == [.open])
        #expect(unread.body == "Name?")
        #expect(unread.subtitle == "Automation question")
    }

    private func asking(_ id: String, _ question: String?, options: [String]? = ["Yes", "No"]) -> ChildRun {
        var run = Fixture.child(id, attention: true)
        run.question = question.map { ChildQuestion(text: $0, options: options) }
        return run
    }

    @Test func aSubagentsQuestionNamesTheThreadAndTheSubagent() {
        let agent = agent(.working)
        let target = BannerTarget.agent(agent.id)
        let banner = AgentBanners.subagentQuestion(asking("worker", "Delete the old fixtures?\nThey are unused."), of: agent.name, target: target)
        #expect(banner.title == "Fix login · worker")
        #expect(banner.subtitle == "Subagent question")
        #expect(banner.body == "Delete the old fixtures?")
        #expect(banner.actions == [.option(1, title: "Yes"), .option(2, title: "No"), .reply(placeholder: "Reply to worker…")])
        #expect(banner.question == "worker")
        #expect(banner.group == "thread:\(agent.id.rawValue)")
        #expect(banner.identifier == "shepherd-subagent-\(agent.id.rawValue)-worker")
    }

    /// Falls back to the run's attention text, and to a sentence of its own.
    @Test func aSubagentQuestionWithoutTextStillPosts() {
        var run = Fixture.child("lane", attention: true)
        run.attentionText = "Waiting on approval"
        let target = BannerTarget.agent(AgentID())
        #expect(AgentBanners.subagentQuestion(run, of: "Fix login", target: target).body == "Waiting on approval")
        #expect(AgentBanners.subagentQuestion(Fixture.child("lane", attention: true), of: "Fix login", target: target).body
                == "Waiting on your answer.")
    }

    @Test func aHostGoingAwaySaysSoWithRetry() {
        let id = UUID()
        let banner = AgentBanners.hostOffline(name: "horizon", hostID: id)
        #expect(banner.title == "horizon is offline")
        #expect(banner.subtitle == "Host")
        #expect(banner.body == "Remote agents resume when it’s back.")
        #expect(banner.actions == [.reconnect])
        #expect(banner.actions.map(\.title) == ["Retry"])
        #expect(banner.group == "host:\(id.uuidString)")
    }

    /// A remote thread's banners are its host's: another host's thread with the same id is apart.
    @Test func aRemoteThreadsBannersCarryItsHost() {
        let agentID = AgentID()
        let one = BannerTarget.remote(RemoteAgentRef(hostID: UUID(), agentID: agentID))
        let other = BannerTarget.remote(RemoteAgentRef(hostID: UUID(), agentID: agentID))
        #expect(AgentBanners.identifier("question", one) != AgentBanners.identifier("question", other))
        #expect(AgentBanners.group(one) != AgentBanners.group(.agent(agentID)))
    }

    // MARK: Answering

    @Test func anOptionOrReplyAnswersWhoeverAsked() throws {
        let select = NativeQuestionPrompt(dialog: NativeThreadDialog(id: "d", kind: .select, title: "Key?", options: ["order_id", "payment_id"]))
        let picked = try #require(AgentBanners.answer(select, option: 2, words: nil))
        #expect(select.dialogAnswer(picked) == .select(value: "payment_id"))
        #expect(AgentBanners.answer(select, option: 9, words: nil) == nil)

        let confirm = NativeQuestionPrompt(dialog: NativeThreadDialog(id: "d", kind: .confirm, title: "Go?"))
        #expect(AgentBanners.answer(confirm, option: 2, words: nil).flatMap(confirm.dialogAnswer) == .confirm(value: false))

        let input = NativeQuestionPrompt(dialog: NativeThreadDialog(id: "d", kind: .input, title: "Name?"))
        #expect(AgentBanners.answer(input, option: nil, words: "  shepherd ").flatMap(input.dialogAnswer) == .input(value: "shepherd"))
        #expect(AgentBanners.answer(input, option: nil, words: "   ") == nil)

        let subagent = NativeQuestionPrompt(runID: "r", name: "reviewer", question: "Rename?", options: ["Replace everywhere", "Rename new ones"])
        #expect(AgentBanners.answer(subagent, option: 1, words: nil).flatMap(subagent.messageReply) == "Replace everywhere")
        #expect(AgentBanners.answer(subagent, option: nil, words: "Neither").flatMap(subagent.messageReply) == "Neither")
    }

    @Test func aResponseNamesItsActionAmongTheBannersActions() {
        let actions: [BannerAction] = [.option(1, title: "Yes"), .option(2, title: "No"), .reply(placeholder: "Reply…")]
        #expect(BannerAction.named("option.2", in: actions) == .option(2, title: "No"))
        #expect(BannerAction.named("reply", in: actions) == .reply(placeholder: "Reply…"))
        #expect(BannerAction.named("retry", in: actions) == nil)
        // Answering and retrying never bring Shepherd forward; Open and Review do.
        #expect(actions.allSatisfy { !$0.opensShepherd })
        #expect(BannerAction.open.opensShepherd && BannerAction.review.opensShepherd)
    }

    @Test func aBannersTargetComesBackFromItsUserInfo() {
        let agent = AgentID(), host = UUID()
        #expect(AgentNotifications.target(["agentID": agent.rawValue]) == .agent(agent))
        #expect(AgentNotifications.target(["agentID": agent.rawValue, "hostID": host.uuidString])
                == .remote(RemoteAgentRef(hostID: host, agentID: agent)))
        #expect(AgentNotifications.target(["hostID": host.uuidString]) == .host(host))
        #expect(AgentNotifications.target([:]) == nil)
    }

    // MARK: Once per question

    /// One banner per question: a republish of the same question posts nothing, a new question
    /// from the same run posts again, and a run that stops asking comes down.
    @Test func eachSubagentQuestionPostsOnceAndComesDownWhenAnswered() {
        var asks = SubagentAsks<AgentID>()
        let agent = AgentID(), other = AgentID()
        #expect(asks.update(agent, children: [Fixture.child("live"), asking("a", "First?")]).asking.map(\.id) == ["a"])
        #expect(asks.update(agent, children: [Fixture.child("live"), asking("a", "First?")]).asking.isEmpty, "a republish")
        #expect(asks.update(agent, children: [asking("a", "First?"), asking("b", "Other?")]).asking.map(\.id) == ["b"])
        #expect(asks.update(agent, children: [asking("a", "Second?"), asking("b", "Other?")]).asking.map(\.id) == ["a"])
        #expect(asks.update(other, children: [asking("a", "Second?")]).asking.map(\.id) == ["a"], "agents apart")
        let answered = asks.update(agent, children: [Fixture.child("a"), asking("b", "Other?")])
        #expect(answered.asking.isEmpty)
        #expect(answered.answered == ["a"])
        #expect(asks.update(agent, children: [asking("a", "Second?"), asking("b", "Other?")]).asking.map(\.id) == ["a"])
        #expect(asks.forget(agent) == ["a", "b"])
        #expect(asks.update(agent, children: [asking("b", "Other?")]).asking.map(\.id) == ["b"])
    }

    @Test func eachThreadQuestionPostsOnceAndComesDownWhenAnswered() {
        var asks = ThreadAsks<AgentID>()
        let agent = AgentID()
        #expect(asks.update(agent, waitingOn: nil) == nil)
        #expect(asks.update(agent, waitingOn: "Keep the alias?") == .asked("Keep the alias?"))
        #expect(asks.update(agent, waitingOn: " Keep the alias? ") == nil, "the same question")
        #expect(asks.update(agent, waitingOn: "Which key?") == .asked("Which key?"))
        #expect(asks.current(agent) == "Which key?")
        #expect(asks.update(agent, waitingOn: "  ") == .answered)
        #expect(!asks.isAsking(agent))
        _ = asks.update(agent, waitingOn: "Again?")
        #expect(asks.prune { $0 == agent } == [agent])
        #expect(asks.update(agent, waitingOn: "Again?") == .asked("Again?"), "a deleted thread forgets")
    }
}
