import Foundation
import ShepherdSessions
import Testing
@testable import ShepherdApp

/// The sign-in sheet's state as the bridge's replies move it (SignIn* boards), with no process:
/// each reply fed in by hand.
@Suite("Sign-in sheet states")
@MainActor
struct PiSignInSessionTests {
    struct NoBridge: Error {}

    final class Recorder {
        var opened: [URL] = []
        var copied: [String] = []
        var landed: [String] = []
    }

    static func session(_ provider: String, key: Bool = false, origin: PiSignInSession.Origin = .settings,
                        pickedUp: Int = 0) -> (PiSignInSession, PiAuthStore, Recorder) {
        let store = PiAuthStore(pi: PiSetup.app, bridge: { throw NoBridge() })
        let recorder = Recorder()
        store.openURL = { recorder.opened.append($0) }
        store.copy = { recorder.copied.append($0) }
        store.onSignedIn = { provider in
            recorder.landed.append(provider)
            return pickedUp
        }
        let session = PiSignInSession(provider: provider, subscription: key ? nil : PiSignInCatalog.subscription(provider),
                                      origin: origin, store: store)
        return (session, store, recorder)
    }

    @Test func aBrowserSignInOpensThePageAtOnceAndLandsWithTheAgentsItPickedUp() {
        let (session, _, recorder) = Self.session("anthropic", pickedUp: 2)
        #expect(session.flow == .browser && session.phase == .starting)
        let url = URL(string: "https://claude.ai/oauth/authorize?x=1")!
        session.handle(.authURL(url, instructions: nil))
        #expect(session.phase == .browser && recorder.opened == [url] && session.authURL == url)
        session.handle(.prompt(PiSignInPrompt(id: "p1", kind: .manualCode, message: "Paste")))
        #expect(session.phase == .browser, "the code prompt waits behind Paste a code instead")
        session.handle(.promptClosed("p1"))
        session.handle(.done(provider: "anthropic", subscription: true))
        #expect(session.phase == .done(pickedUp: 2) && recorder.landed == ["anthropic"])
    }

    @Test func aTakenPortSaysSoAndPastingInsteadAsksForTheCode() {
        let (session, _, _) = Self.session("openai-codex")
        session.handle(.failed(PiSignInFailure(.portBusy, reason: "busy", port: 1455)))
        #expect(session.phase == .portBusy(1455) && !session.phase.isLive)
        session.pasteInstead()
        #expect(session.flow == .paste)
    }

    @Test func aRefusedCodeStaysOnThePasteFormInTheProvidersWords() {
        let (session, _, _) = Self.session("anthropic")
        session.handle(.authURL(URL(string: "https://claude.ai/a")!, instructions: nil))
        session.handle(.prompt(PiSignInPrompt(id: "p1", kind: .manualCode, message: "Paste")))
        session.pasteInstead()
        #expect(session.phase == .paste(rejected: nil))
        session.handle(.failed(PiSignInFailure(.other, reason: "That code was already used.")))
        #expect(session.phase == .paste(rejected: "That code was already used."))
    }

    @Test func aDeviceCodeIsShownAndCopiedAtOnce() {
        let (session, _, recorder) = Self.session("github-copilot")
        #expect(session.flow == .device)
        session.handle(.deviceCode(code: "8F3K-Q2WD", verificationURI: "https://github.com/login/device", expiresIn: 900))
        guard case .device(let code, let uri, let expires) = session.phase else { Issue.record("\(session.phase)"); return }
        #expect(code == "8F3K-Q2WD" && uri == "https://github.com/login/device" && expires != nil)
        #expect(recorder.copied == ["8F3K-Q2WD"], "It’s already on your clipboard")
        session.openDevicePage()
        #expect(recorder.opened == [URL(string: "https://github.com/login/device")!])
    }

    @Test func aKeyIsCheckedBeforeItCanBeSavedAndOnlyItsOwnCheckCounts() {
        let (session, _, _) = Self.session("deepseek", key: true)
        #expect(session.flow == .key && session.variable == "DEEPSEEK_API_KEY", "the variable pi reads is offered")
        session.handle(.prompt(PiSignInPrompt(id: "p1", kind: .secret, message: "Enter DeepSeek API key")))
        #expect(session.phase == .key && !session.keyCheck.allowsSave)
        session.handle(.checked(id: "c9", .works(models: ["x"])))
        #expect(session.keyCheck == .idle, "a check the sheet didn't ask for is ignored")
        session.handle(.checked(id: "c0", .rejected("401")))
        #expect(session.keyCheck == .rejected("401") && !session.keyCheck.allowsSave)
        session.handle(.checked(id: "c0", .unreachable("offline")))
        #expect(session.keyCheck.allowsSave, "a provider that can't be reached lets the key be saved")
    }

    @Test(arguments: [
        (PiSignInSession.KeyMode.paste, " sk-abc ", "", PiKeyInput.literal("sk-abc")),
        (.variable, "", "$DEEPSEEK_API_KEY", .variable("DEEPSEEK_API_KEY")),
        (.variable, "", "  ", nil),
    ] as [(PiSignInSession.KeyMode, String, String, PiKeyInput?)])
    func theKeyFormSavesAKeyOrAVariableName(mode: PiSignInSession.KeyMode, key: String, variable: String, input: PiKeyInput?) {
        let session = PiSignInSession(preview: "deepseek", flow: .key, phase: .key, keyMode: mode, key: key, variable: variable)
        #expect(session.keyInput == input)
    }

    @Test func pickingUpAgentsIsCounted() {
        #expect(PiSignInSheet.pickedUp(0) == nil)
        #expect(PiSignInSheet.pickedUp(1) == "1 waiting agent picked up where it left off.")
        #expect(PiSignInSheet.pickedUp(2) == "2 waiting agents picked up where they left off.")
        #expect(PiSignInSheet.ready(["deepseek-chat", "deepseek-reasoner"]) == "deepseek-chat and deepseek-reasoner are ready.")
        #expect(PiSignInSheet.shortURI("https://github.com/login/device") == "github.com/login/device")
    }

    @Test func aTurnErrorNamingAFailedRefreshMarksItsProviderExpired() {
        let (_, store, _) = Self.session("anthropic")
        store.noteTurnError("429 too many requests")
        #expect(store.expired.isEmpty)
        store.noteTurnError("OAuth refresh failed for openai-codex: invalid_grant")
        #expect(store.expired == ["openai-codex"])
        _ = store.landed("openai-codex")
        #expect(store.expired.isEmpty, "signing in again clears it")
    }
}
