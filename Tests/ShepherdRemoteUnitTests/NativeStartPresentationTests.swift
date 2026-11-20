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
        #expect(problem.advice(host: "horizon") == "Retry on horizon to start it again. Its conversation is saved.")
        #expect(problem.message(host: "horizon")
                == "Retry on horizon to start it again. Its conversation is saved.\n\nFATAL ERROR: heap out of memory")
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
            #expect(!problem.title.isEmpty && !problem.advice().isEmpty && !problem.advice(host: "horizon").isEmpty)
        }
    }

    // MARK: Retry from a phone or tablet

    @Test func aPhoneWhoseHostTakesRestartRetriesInsteadOfSendingThePersonToTheHost() {
        let stopped = NativeStartProblem(kind: .stopped, signal: 9)
        #expect(stopped.advice(host: "horizon", retryHere: true) == "Retry to start it again. Its conversation is saved.")
        #expect(stopped.advice(host: "horizon", retryHere: false) == stopped.advice(host: "horizon"))
        #expect(stopped.advice(retryHere: false) == "Retry on the host to start it again. Its conversation is saved.")
        let signedOut = NativeStartProblem(kind: .notSignedIn)
        #expect(signedOut.advice(host: "horizon", retryHere: true) == "Sign in to a provider for Shepherd's pi (Settings ▸ Pi), then Retry.")
        #expect(signedOut.advice(host: "horizon") == "Sign in to a provider for Shepherd's pi (Settings ▸ Pi), then Retry on horizon.")
        #expect(signedOut.advice() == "Sign in to a provider for Shepherd's pi (Settings ▸ Pi), then Retry.")
    }

    @Test func aConversationItCouldNotFindOffersStartNewConversationBesideRetry() {
        let problem = NativeStartProblem(kind: .resumedAsNew)
        #expect(problem.actions(canRestart: true, canLocateFolder: true) == [.startNewConversation, .retry])
        #expect(problem.actions(canRestart: true, canLocateFolder: false) == [.startNewConversation, .retry])
        #expect(problem.actions(canRestart: false, canLocateFolder: false).isEmpty)
        let advice = "It would have started a new, empty one, so Shepherd stopped it. The conversation's file is untouched."
        #expect(problem.advice(host: "horizon", retryHere: true) == advice)
        #expect(problem.advice() == advice)
        #expect(problem.advice(host: "horizon") == advice + " Retry on horizon.")
    }

    @Test func aMissingFolderHasNoRetryOnAPhoneOnlyGuidanceForTheHost() {
        let problem = NativeStartProblem(kind: .folderMissing)
        #expect(problem.actions(canRestart: true, canLocateFolder: true) == [.locateFolder], "the Mac's Retry is Locate Folder…")
        #expect(problem.actions(canRestart: true, canLocateFolder: false).isEmpty)
        #expect(problem.actions(canRestart: false, canLocateFolder: false).isEmpty)
        #expect(problem.advice(host: "horizon", retryHere: true)
                == "It was moved, renamed or deleted. Locate Folder… moves this thread and its conversation to where it is now, on horizon.")
        #expect(problem.advice(host: "horizon", retryHere: true) == problem.advice(host: "horizon"))
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
}

/// Retry sent from a phone: the banner goes at once, the host is asked, and a refusal comes back.
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

    @Test func retrySendsRestartPiAndTheThreadReadsAsStarting() async throws {
        let (store, _, task) = await stopped(NativeStartProblem(kind: .stopped, signal: 9))
        defer { task.cancel() }
        #expect(store.startProblem != nil)
        var sent: [RemoteAgentAction] = []
        try await NativeStartRestart.perform(.retry, store: store) { sent.append($0) }
        #expect(sent == [.restartPi(newConversation: false)])
        #expect(store.startProblem == nil && store.starting)
    }

    @Test func startNewConversationSendsRestartPiForANewOne() async throws {
        let (store, _, task) = await stopped(NativeStartProblem(kind: .resumedAsNew))
        defer { task.cancel() }
        var sent: [RemoteAgentAction] = []
        try await NativeStartRestart.perform(.startNewConversation, store: store) { sent.append($0) }
        #expect(sent == [.restartPi(newConversation: true)])
        #expect(sent.first?.capability == RemoteProtocol.agentRestartCapability)
    }

    @Test func aRefusedRestartBringsTheProblemBackAndThrows() async {
        struct Refused: Error {}
        let (store, _, task) = await stopped(NativeStartProblem(kind: .stopped, signal: 9))
        defer { task.cancel() }
        await #expect(throws: Refused.self) {
            try await NativeStartRestart.perform(.retry, store: store) { _ in throw Refused() }
        }
        #expect(store.startProblem?.kind == .stopped, "the host still says pi is stopped")
    }

    @Test func locateFolderIsNotARestart() async throws {
        let (store, _, task) = await stopped(NativeStartProblem(kind: .folderMissing))
        defer { task.cancel() }
        try await NativeStartRestart.perform(.locateFolder, store: store) { _ in Issue.record("nothing is sent") }
        #expect(store.startProblem?.kind == .folderMissing)
    }
}
