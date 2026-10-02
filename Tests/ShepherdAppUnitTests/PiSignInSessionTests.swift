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

    /// pi 0.87.1's Anthropic login listened on its port even for a pasted code (pi 1.0's no longer
    /// fails with the port taken, but the sheet is as drawn), so a taken port returns the sheet to
    /// the port's box, with no paste to offer.
    @Test func aTakenPortDuringAPasteSaysSoAndAnthropicOffersNoPaste() {
        let (session, _, _) = Self.session("anthropic")
        session.handle(.failed(PiSignInFailure(.portBusy, reason: "busy", port: 53692)))
        #expect(session.phase == .portBusy(53692))
        session.pasteInstead()
        #expect(session.flow == .browser && session.phase == .portBusy(53692), "nothing to paste into")

        let (codex, _, _) = Self.session("openai-codex")
        codex.handle(.authURL(URL(string: "https://auth.openai.com/a")!, instructions: nil))
        codex.pasteInstead()
        codex.handle(.failed(PiSignInFailure(.portBusy, reason: "busy", port: 1455)))
        #expect(codex.flow == .browser && codex.phase == .portBusy(1455), "the box, not a paste form with a port footer")
    }

    @Test func continueBeforePiAsksSendsTheCodeWhenItDoes() {
        let (session, _, _) = Self.session("anthropic")
        session.handle(.authURL(URL(string: "https://claude.ai/a")!, instructions: nil))
        session.pasteInstead()
        session.code = " FAKE-CODE "
        session.submitCode()
        #expect(session.phase == .saving && !session.submitReady)
        session.handle(.prompt(PiSignInPrompt(id: "p1", kind: .manualCode, message: "Paste")))
        #expect(session.phase == .saving && !session.submitReady, "the code went as the prompt's answer")
    }

    @Test func continueAfterARefusedCodeOpensAFreshPage() {
        let (session, _, _) = Self.session("anthropic")
        session.handle(.authURL(URL(string: "https://claude.ai/a")!, instructions: nil))
        session.handle(.prompt(PiSignInPrompt(id: "p1", kind: .manualCode, message: "Paste")))
        session.pasteInstead()
        session.handle(.failed(PiSignInFailure(.other, reason: "That code was already used.")))
        session.code = "OLD-CODE"
        session.submitCode()
        #expect(session.phase == .paste(rejected: nil) && session.code.isEmpty, "the old page's code can't work for a new login")
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

    @Test func aKeyCannotBeSavedBeforeItsCheckIsRequested() {
        let (session, _, _) = Self.session("deepseek", key: true)
        #expect(session.flow == .key && session.variable == "DEEPSEEK_API_KEY", "the variable pi reads is offered")
        session.handle(.prompt(PiSignInPrompt(id: "p1", kind: .secret, message: "Enter DeepSeek API key")))
        #expect(session.phase == .key && !session.keyCheck.allowsSave)
        session.handle(.checked(id: "c9", .works(models: ["x"])))
        #expect(session.keyCheck == .idle, "a check the sheet didn't ask for is ignored")
        // No check was dispatched: fabricated replies cannot establish that this key was checked.
        session.handle(.checked(id: "c0", .works(models: ["x"])))
        #expect(!session.keyCheck.allowsSave)
    }

    @Test(arguments: ["edit", "clear", "mode"])
    func aReplyForThePreviousKeyCannotEnableSaveDuringDebounce(change: String) {
        let (session, _, _) = Self.session("deepseek", key: true)
        defer { session.end() }
        session.handle(.prompt(PiSignInPrompt(id: "p1", kind: .secret, message: "Key")))
        // No suspension here: the new key's debounced request cannot have been dispatched.
        switch change {
        case "mode": session.setKeyMode(.variable)
        case "clear": session.key = "old"; session.key = ""
        default: session.key = "new-unchecked-key"
        }
        session.handle(.checked(id: "c0", .works(models: ["fixture"])))
        #expect(!session.keyCheck.allowsSave)
        session.saveKey()
        #expect(session.phase == .key)
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
