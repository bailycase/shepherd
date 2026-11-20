import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// What the Can't start banner says for a pi that stopped, before it served and on its own after.
@Suite("Start problem copy")
struct NativeStartPresentationTests {
    @Test(arguments: [
        (NativeStartProblem(kind: .stopped, signal: 9), "The agent stopped unexpectedly (signal 9)."),
        (NativeStartProblem(kind: .stopped, exitCode: 1), "The agent stopped unexpectedly (code 1)."),
        (NativeStartProblem(kind: .stopped, exitCode: 0), "The agent stopped unexpectedly (code 0)."),
        (NativeStartProblem(kind: .stopped), "The agent stopped unexpectedly."),
    ])
    func aStoppedAgentSaysHowItEnded(_ problem: NativeStartProblem, _ title: String) {
        #expect(problem.title == title)
    }

    @Test func aStoppedAgentPointsAtRetryAndSaysTheConversationIsSaved() {
        let problem = NativeStartProblem(kind: .stopped, signal: 9, lines: ["FATAL ERROR: heap out of memory"])
        #expect(problem.advice() == "Retry to start it again. Its conversation is saved.")
        #expect(problem.advice(host: "orbit") == "Retry on orbit to start it again. Its conversation is saved.")
        #expect(problem.message(host: "orbit")
                == "Retry on orbit to start it again. Its conversation is saved.\n\nFATAL ERROR: heap out of memory")
    }

    @Test(arguments: [
        (NativeStartProblem(kind: .exited, exitCode: 1), "pi exited while starting (code 1)."),
        (NativeStartProblem(kind: .exited, signal: 9), "pi exited while starting (signal 9)."),
        (NativeStartProblem(kind: .exited), "pi exited while starting (signal)."),
    ])
    func aPiThatExitedWhileStartingShowsTheSignalNumberWhenKnown(_ problem: NativeStartProblem, _ title: String) {
        #expect(problem.title == title)
        #expect(problem.advice() == "Retry to start it again.")
    }

    @Test func everyKindHasATitleAndAdvice() {
        for kind in NativeStartProblem.Kind.allCases {
            let problem = NativeStartProblem(kind: kind)
            #expect(!problem.title.isEmpty && !problem.advice().isEmpty && !problem.advice(host: "orbit").isEmpty)
        }
    }

    // MARK: Retry from a phone or tablet

    @Test func aPhoneWhoseHostTakesRestartRetriesInsteadOfSendingThePersonToTheHost() {
        let stopped = NativeStartProblem(kind: .stopped, signal: 9)
        #expect(stopped.advice(host: "orbit", retryHere: true) == "Retry to start it again. Its conversation is saved.")
        #expect(stopped.advice(host: "orbit", retryHere: false) == stopped.advice(host: "orbit"))
        #expect(stopped.advice(retryHere: false) == "Retry on the host to start it again. Its conversation is saved.")
        let signedOut = NativeStartProblem(kind: .notSignedIn)
        #expect(signedOut.advice(host: "orbit", retryHere: true) == "Sign in to a provider for Shepherd's pi (Settings ▸ Pi), then Retry.")
        #expect(signedOut.advice(host: "orbit") == "Sign in to a provider for Shepherd's pi (Settings ▸ Pi), then Retry on orbit.")
        #expect(signedOut.advice() == "Sign in to a provider for Shepherd's pi (Settings ▸ Pi), then Retry.")
    }

    @Test func aConversationItCouldNotFindOffersStartNewConversationBesideRetry() {
        let problem = NativeStartProblem(kind: .resumedAsNew)
        #expect(problem.actions(canRestart: true, canLocateFolder: true) == [.startNewConversation, .retry])
        #expect(problem.actions(canRestart: true, canLocateFolder: false) == [.startNewConversation, .retry])
        #expect(problem.actions(canRestart: false, canLocateFolder: false).isEmpty)
        let advice = "It would have started a new, empty one, so Shepherd stopped it. The conversation's file is untouched."
        #expect(problem.advice(host: "orbit", retryHere: true) == advice)
        #expect(problem.advice() == advice)
        #expect(problem.advice(host: "orbit") == advice + " Retry on orbit.")
    }

    @Test func aMissingFolderHasNoRetryOnAPhoneOnlyGuidanceForTheHost() {
        let problem = NativeStartProblem(kind: .folderMissing)
        #expect(problem.actions(canRestart: true, canLocateFolder: true) == [.locateFolder], "the Mac's Retry is Locate Folder…")
        #expect(problem.actions(canRestart: true, canLocateFolder: false).isEmpty)
        #expect(problem.actions(canRestart: false, canLocateFolder: false).isEmpty)
        #expect(problem.advice(host: "orbit", retryHere: true)
                == "It was moved, renamed or deleted. Locate Folder… moves this thread and its conversation to where it is now, on orbit.")
        #expect(problem.advice(host: "orbit", retryHere: true) == problem.advice(host: "orbit"))
    }

    @Test(arguments: NativeStartProblem.Kind.allCases.filter { $0 != .folderMissing && $0 != .resumedAsNew })
    func everyOtherProblemOffersRetryOnlyWhereTheClientCanRestart(_ kind: NativeStartProblem.Kind) {
        let problem = NativeStartProblem(kind: kind)
        #expect(problem.actions(canRestart: true, canLocateFolder: false) == [.retry])
        #expect(problem.actions(canRestart: true, canLocateFolder: true) == [.retry])
        #expect(problem.actions(canRestart: false, canLocateFolder: true).isEmpty)
    }

    @Test func aHostMustAdvertiseBothCapabilitiesBeforeRetryIsOffered() {
        let actions = RemoteProtocol.agentActionsCapability
        let restart = RemoteProtocol.agentRestartCapability
        #expect(NativeStartRestart.isOffered(by: [actions, restart]))
        #expect(NativeStartRestart.isOffered(by: RemoteProtocol.capabilities))
        #expect(!NativeStartRestart.isOffered(by: [actions]))
        #expect(!NativeStartRestart.isOffered(by: [restart]))
        #expect(!NativeStartRestart.isOffered(by: [String]()))
    }

    // MARK: The banner a phone draws

    private func banner(_ problem: NativeStartProblem?, restart: NativeStartRestartState? = nil, offered: Bool = true,
                        live: Bool = true) -> NativeStartBanner? {
        NativeStartBanner(problem: problem, restart: restart, offered: offered, live: live, host: "orbit")
    }

    @Test func noProblemAndNoRestartDrawsNothing() {
        #expect(banner(nil) == nil)
        #expect(banner(nil, restart: .failed("no")) == nil, "a refusal needs the problem it refused")
    }

    @Test func aConnectedHostThatTakesRestartOffersRetry() throws {
        let shown = try #require(banner(NativeStartProblem(kind: .stopped, signal: 9)))
        #expect(shown.actions == [.retry])
        #expect(shown.message == "Retry to start it again. Its conversation is saved.")
        #expect(!shown.inProgress)
    }

    @Test func aDroppedConnectionOffersNoRetryAndSendsThePersonToTheHost() throws {
        let shown = try #require(banner(NativeStartProblem(kind: .stopped, signal: 9), live: false))
        #expect(shown.actions.isEmpty)
        #expect(shown.message == "Retry on orbit to start it again. Its conversation is saved.")
        let again = try #require(banner(NativeStartProblem(kind: .resumedAsNew), live: false))
        #expect(again.actions.isEmpty && again.message.hasSuffix("Retry on orbit."))
    }

    @Test func aHostWithoutRestartOffersNoRetry() throws {
        let shown = try #require(banner(NativeStartProblem(kind: .stopped), offered: false))
        #expect(shown.actions.isEmpty)
        #expect(shown.message.hasPrefix("Retry on orbit"))
    }

    @Test func notSignedInOffersNoRetryWhereTheMacShowsItsSignInCardInstead() throws {
        let shown = try #require(banner(NativeStartProblem(kind: .notSignedIn)))
        #expect(shown.actions.isEmpty)
        #expect(shown.message == "Sign in to a provider for Shepherd's pi (Settings ▸ Pi), then Retry on orbit.")
    }

    @Test func aMissingFolderHasOnlyGuidance() throws {
        let shown = try #require(banner(NativeStartProblem(kind: .folderMissing)))
        #expect(shown.actions.isEmpty)
        #expect(shown.message.hasSuffix("on orbit."))
    }

    @Test func aRestartInProgressReplacesTheButtonsWithProgressWithOrWithoutTheProblem() throws {
        for restart in [NativeStartRestartState.asking, .starting] {
            for problem in [NativeStartProblem(kind: .stopped, signal: 9), nil] {
                let shown = try #require(banner(problem, restart: restart))
                #expect(shown.inProgress && shown.actions.isEmpty)
            }
        }
    }

    @Test func aRefusalStaysBesideTheProblemAndRetryComesBack() throws {
        let shown = try #require(banner(NativeStartProblem(kind: .stopped, signal: 9), restart: .failed("Couldn’t start the agent: no")))
        #expect(shown.actions == [.retry] && !shown.inProgress)
        #expect(shown.message == "Retry to start it again. Its conversation is saved.\n\nCouldn’t start the agent: no")
    }
}

/// Retry sent from a phone: the problem stays while the host is asked, and a refusal stays beside it.
@Suite("Retry a stopped agent", .timeLimit(.minutes(1)))
@MainActor
struct NativeStartRestartTests {
    typealias F = Fixture

    private func stopped(_ problem: NativeStartProblem) async -> (NativeThreadStore, FakeHost, Task<Void, Never>) {
        var snapshot = F.snapshot(generation: "start-problem", actions: [], messages: [])
        snapshot.startProblem = problem
        let host = FakeHost(snapshot)
        let store = manualStore()
        return (store, host, await start(store, host))
    }

    private func shown(_ store: NativeThreadStore) -> NativeStartBanner? {
        NativeStartBanner(store: store, offered: true, connected: true, host: "orbit")
    }

    @Test func retrySendsRestartPiAndTheThreadReadsAsStartingUntilPiIsUp() async {
        let (store, host, task) = await stopped(NativeStartProblem(kind: .stopped, signal: 9))
        defer { task.cancel() }
        #expect(store.startProblem != nil)
        host.starting = true
        var sent: [RemoteAgentAction] = []
        await NativeStartRestart.perform(.retry, store: store, offered: true, connected: true) { sent.append($0) }
        #expect(sent == [.restartPi(newConversation: false)])
        #expect(store.startProblem == nil && store.starting)
        #expect(shown(store)?.inProgress == true, "a thread with its history cached still says it is restarting")
    }

    @Test func theProblemStaysWhileTheHostIsAsked() async {
        let (store, _, task) = await stopped(NativeStartProblem(kind: .stopped, signal: 9))
        defer { task.cancel() }
        var release: CheckedContinuation<Void, Never>?
        let asked = Task { @MainActor in
            await NativeStartRestart.perform(.retry, store: store, offered: true, connected: true) { _ in await withCheckedContinuation { release = $0 } }
        }
        await until { store.startRestart == .asking }
        #expect(store.startProblem?.kind == .stopped, "the banner that owns the progress is still there")
        #expect(shown(store)?.inProgress == true)
        release?.resume()
        await asked.value
    }

    @Test func aDelayedRefusalStaysVisibleBesideRetry() async {
        struct Refused: LocalizedError { var errorDescription: String? { "the host said no" } }
        let (store, _, task) = await stopped(NativeStartProblem(kind: .stopped, signal: 9))
        defer { task.cancel() }
        var release: CheckedContinuation<Void, Never>?
        let asked = Task { @MainActor in
            await NativeStartRestart.perform(.retry, store: store, offered: true, connected: true) { _ in
                await withCheckedContinuation { release = $0 }
                throw Refused()
            }
        }
        await until { store.startRestart == .asking }
        #expect(shown(store)?.inProgress == true)
        release?.resume()
        await asked.value
        let banner = shown(store)
        #expect(banner?.inProgress == false && banner?.actions == [.retry], "the host still says pi is stopped, so Retry is back")
        #expect(banner?.message.hasSuffix("Couldn’t start the agent: the host said no") == true)
        // The next Retry clears the old refusal while it asks.
        var again: CheckedContinuation<Void, Never>?
        let second = Task { @MainActor in
            await NativeStartRestart.perform(.retry, store: store, offered: true, connected: true) { _ in await withCheckedContinuation { again = $0 } }
        }
        await until { store.startRestart == .asking }
        #expect(shown(store)?.inProgress == true && shown(store)?.message.contains("host said no") == false)
        again?.resume()
        await second.value
    }

    @Test func aPiThatStopsAgainAfterTheHostAcceptedBringsTheProblemBack() async {
        let (store, host, task) = await stopped(NativeStartProblem(kind: .stopped, signal: 9))
        defer { task.cancel() }
        await NativeStartRestart.perform(.retry, store: store, offered: true, connected: true) { _ in }
        #expect(store.startProblem?.kind == .stopped && shown(store)?.inProgress == false, "the host still says stopped: not stuck on starting")
        host.starting = true
        await NativeStartRestart.perform(.retry, store: store, offered: true, connected: true) { _ in }
        #expect(shown(store)?.inProgress == true)
        host.starting = false
        await store.refresh(fresh: true)
        #expect(shown(store)?.inProgress == false && shown(store)?.actions == [.retry], "pi stopped again")
    }

    @Test func startNewConversationSendsRestartPiForANewOne() async {
        let (store, _, task) = await stopped(NativeStartProblem(kind: .resumedAsNew))
        defer { task.cancel() }
        var sent: [RemoteAgentAction] = []
        await NativeStartRestart.perform(.startNewConversation, store: store, offered: true, connected: true) { sent.append($0) }
        #expect(sent == [.restartPi(newConversation: true)])
        #expect(sent.first?.capability == RemoteProtocol.agentRestartCapability)
    }

    @Test func locateFolderIsNotARestart() async {
        let (store, _, task) = await stopped(NativeStartProblem(kind: .folderMissing))
        defer { task.cancel() }
        await NativeStartRestart.perform(.locateFolder, store: store, offered: true, connected: true) { _ in Issue.record("nothing is sent") }
        #expect(store.startProblem?.kind == .folderMissing && store.startRestart == nil)
    }

    @Test func aSuspendedThreadOnAConnectedHostOffersNoRetryAndSendsNothing() async {
        let (store, _, task) = await stopped(NativeStartProblem(kind: .stopped, signal: 9))
        defer { task.cancel() }
        #expect(shown(store)?.actions == [.retry])
        store.suspend()
        #expect(store.startProblem != nil && !store.isLive, "a detached thread keeps its problem")
        #expect(shown(store)?.actions.isEmpty == true, "the buttons follow the same check the tap does")
        await NativeStartRestart.perform(.retry, store: store, offered: true, connected: true) { _ in Issue.record("nothing is sent") }
        #expect(store.startRestart == nil)
    }

    @Test func aHostThatDoesNotOfferRestartSendsNothing() async {
        let (store, _, task) = await stopped(NativeStartProblem(kind: .stopped, signal: 9))
        defer { task.cancel() }
        await NativeStartRestart.perform(.retry, store: store, offered: false, connected: true) { _ in Issue.record("nothing is sent") }
        await NativeStartRestart.perform(.retry, store: store, offered: true, connected: false) { _ in Issue.record("nothing is sent") }
        #expect(store.startRestart == nil)
    }

    @Test func detachingAfterTheHostAcceptedClearsStarting() async {
        let (store, host, task) = await stopped(NativeStartProblem(kind: .stopped, signal: 9))
        defer { task.cancel() }
        host.starting = true
        await NativeStartRestart.perform(.retry, store: store, offered: true, connected: true) { _ in }
        #expect(store.startRestart == .starting)
        store.suspend()
        #expect(store.startRestart == nil)
        #expect(NativeStartBanner(store: store, offered: true, connected: false, host: "orbit")?.inProgress != true,
                "an offline thread does not say it is starting")
    }
}
