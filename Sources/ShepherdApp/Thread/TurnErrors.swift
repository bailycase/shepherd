import SwiftUI
import ShepherdUI
import ShepherdRemote

extension EnvironmentValues {
    /// The thread's record of which errors show Details and which folded ones were opened.
    @Entry var turnErrorExpansion: NativeTurnErrorExpansion? = nil
    /// Opens Settings ▸ Pi ▸ Sign-in for the thread's provider: what a card for a login that no
    /// longer works offers (a local thread; a remote one has no sign-in here).
    @Entry var turnErrorSignIn: (() -> Void)? = nil
}

/// A failed request in the thread (TurnErrors): the card, or the line it folds to. Details and
/// unfolding live in the thread's store (`NativeTurnErrorExpansion`), so a row the list rebuilds
/// keeps them.
struct TurnErrorItem: View {
    let error: NativeTurnError
    var folded = false
    var retry: (() -> Void)? = nil
    @Environment(\.turnErrorExpansion) private var expansion
    @Environment(\.turnErrorSignIn) private var signIn

    var body: some View {
        let id = error.id
        SHTurnError(SHTurnError.Content(error), folded: folded,
                    details: expansion.map { store in Binding { store.detailsOpen.contains(id) } set: { store.setDetails(id, open: $0) } },
                    unfolded: expansion.map { store in Binding { store.unfolded.contains(id) } set: { if $0 { store.unfold(id) } } },
                    retry: retry, signIn: Self.offersSignIn(error) ? signIn : nil)
    }

    /// Whether the card offers Sign in again: the provider rejected the credential, or its refresh failed.
    static func offersSignIn(_ error: NativeTurnError) -> Bool {
        error.kind == .auth || PiAuthText.isSignInFailure(error.copyText)
    }
}

/// pi retrying the request that just failed: the retry line, counting down to the next try.
struct RetryLineItem: View {
    let line: NativeRetryLine

    var body: some View {
        SHRetryLine(glyph: line.glyph, count: line.count, countdownEnds: Date(timeIntervalSince1970: line.retryAt / 1000)) { now in
            line.text(now: now.timeIntervalSince1970 * 1000)
        }
    }
}

extension SHTurnError.Content {
    /// The card's values from the thread's reading of the error (`NativeTurnError`).
    init(_ error: NativeTurnError) {
        self.init(
            glyph: error.glyph, title: error.title,
            message: error.message.map { span in
                switch span {
                case .text(let text): .text(text)
                case .code(let text): .code(text)
                case .link(let display, let url): .link(display: display, url: url)
                }
            },
            chips: error.chips, source: error.source, tries: error.tries, time: error.time, foldedMeta: error.foldedMeta,
            facts: error.facts.map { SHTurnError.Fact($0.label, $0.value, mono: $0.mono) },
            body: error.body.map { token in
                switch token {
                case .plain(let text): .plain(text)
                case .key(let text): .key(text)
                case .string(let text): .string(text)
                case .redacted(let text): .redacted(text)
                case .link(let text): .link(text)
                }
            },
            copyText: error.copyText)
    }
}
