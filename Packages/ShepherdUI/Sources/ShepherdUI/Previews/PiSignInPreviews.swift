import SwiftUI

// PiAuthStates: every sign-in part in its states, light and dark.

private let rowStates: [(String, String, NWProviderStatus, Bool, String)] = [
    ("Anthropic", "An", NWProviderStatus(dot: .on, word: "Signed in", parts: [.init("Claude Pro or Max")]), true, "Sign out"),
    ("OpenAI Codex", "Cx", NWProviderStatus(dot: .attention, word: "Expired · sign in again", wordTone: .attention,
                                            parts: [.init("ChatGPT Plus or Pro")]), true, "Sign in again"),
    ("Google", "Go", NWProviderStatus(dot: .off, word: "Not signed in", wordTone: .secondary, parts: [.init("Gemini")]), false, "Sign in"),
    ("Kimi", "Ki", NWProviderStatus(dot: .live, word: "Signing in…", parts: [.init("Kimi For Coding")], live: true), true, "Cancel"),
    ("OpenAI", "Oa", NWProviderStatus(dot: .on, word: "API key", parts: [.init("sk-proj-••••3kQz", mono: true, tone: .primary)]
                                      + NWKeySource.copiedFromYourPi.parts), false, "Change key"),
    ("DeepSeek", "Ds", NWProviderStatus(dot: .on, word: "API key", parts: [.init("sk-••••91c2", mono: true, tone: .primary)]
                                        + NWKeySource.variable("DEEPSEEK_API_KEY").parts), false, "Change key"),
    ("OpenRouter", "Or", NWProviderStatus(dot: .on, word: "From your environment", parts: [.init("$OPENROUTER_API_KEY", mono: true, small: true),
                                                                                         .init("in your login shell", tone: .tertiary, separated: false)]),
     false, "Change key"),
]

#Preview("Provider rows") {
    NWPreviewBoth {
        VStack(spacing: 0) {
            ForEach(Array(rowStates.enumerated()), id: \.offset) { index, row in
                if index > 0 { NWHairline() }
                NWProviderRow(row.0, badge: row.1, status: row.2, sharedLoginNote: row.3) {
                    Button(row.4) {}.buttonStyle(.nw(row.4 == "Sign in again" ? .primary : row.4 == "Sign out" || row.4 == "Cancel" ? .ghost : .secondary, size: .s))
                    NWProviderMenuButton(for: row.0) { Button("Sign out") {} }
                }
            }
            NWHairline()
            NWProviderRow("ollama", badge: "Ol", mono: true,
                          status: NWProviderStatus(dot: .off, word: "No key needed", wordTone: .tertiary,
                                                   parts: [.init("http://localhost:11434", mono: true, small: true, tone: .tertiary)])) { EmptyView() }
        }
        .nwBorder(Color.nw.lineSubtle, radius: 10)
        .frame(width: 640)
    }
}

#Preview("Key sources and the shared note") {
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.m) {
            NWKeySourceLabel(.copiedFromYourPi)
            NWKeySourceLabel(.variable("DEEPSEEK_API_KEY"))
            NWKeySourceLabel(.command("op read op://Dev/northwind/api-key"))
            NWSharedLoginNote()
        }
    }
}

#Preview("Import steps and summary") {
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.l) {
            NWSheetCard {
                NWImportStepRow("Logins", detail: "Anthropic, OpenAI Codex, Kimi", count: "3 subscriptions", state: .done)
                NWImportStepRow("Default model", count: "claude-opus", state: .now)
                NWImportStepRow("Trusted folders", state: .pending)
                NWImportStepRow("Extensions", detail: "Listed, switched off", count: "3 found", state: .done)
                NWImportStepRow("Logins and API keys", detail: "auth.json isn’t valid JSON", state: .failed)
            }
            NWImportSummary([.init("logins", count: 3), .init("API keys", count: 2), .init("custom providers"),
                             .init("default model", value: "claude-opus"), .init("trusted folders", count: 4)])
            NWSheetCard {
                NWImportSignInRow("OpenAI Codex", badge: "Cx", detail: "Your pi isn’t signed in to it") {}
                NWImportSignInRow("Kimi", badge: "Ki", detail: "Your pi’s sign-in couldn’t be copied", signedIn: true) {}
            }
            HStack(spacing: NW.Space.m) {
                NWSignInChoiceTile("Anthropic", detail: "Claude Pro or Max", badge: "An")
                NWSignInChoiceTile("Use an API key", detail: "OpenAI, OpenRouter and 30 more")
            }
        }
        .frame(width: 540)
    }
}

#Preview("Sign-in sheet parts") {
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.l) {
            NWSheetHeader("Sign in to Anthropic", subtitle: "With your Claude Pro or Max subscription", leading: .badge("An"), close: {})
            NWSignInSteps {
                NWSignInStepRow("Opened claude.ai in your browser", state: .done)
                NWSignInStepRow("Waiting for you in the browser", note: "Approve Shepherd on claude.ai. This closes by itself when you’re done.", state: .now)
                NWSignInStepRow("Save the sign-in to Shepherd’s pi", state: .pending)
            }
            NWDeviceCode("8F3K-Q2WD")
            NWFailureBox("Another sign-in is using localhost:1455",
                         detail: "Probably Codex CLI or your terminal pi’s /login, mid-way. Finish or cancel it there, then try again.")
            NWFailureBox("~/.pi/agent/auth.json", detail: "Unexpected token } in JSON at line 31, column 5", monoTitle: true, monoDetail: true)
            NWSheetFooter {
                Button("Copy link") {}.buttonStyle(.nw(.ghost))
            } actions: {
                Button("Cancel") {}.buttonStyle(.nw(.ghost))
                Button("Open browser again") {}.buttonStyle(.nw(.secondary))
            }
        }
        .frame(width: 500)
    }
}

#Preview("Agent waiting and not signed in") {
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.l) {
            NWAgentWaitingLine(message: "This agent was mid-turn when Shepherd quit. It picks up once your pi is brought over.",
                               trailing: "restored 9:41 AM")
            NWAgentNotSignedInCard(provider: "Anthropic", model: "claude-opus",
                                   reason: "Anthropic’s sign-in was skipped when your pi came over, so the agent is waiting for you. Your message is kept.",
                                   time: "9:43 AM", signIn: {}, useAnotherModel: {})
            NWSidebarRow("Plan shepherd extensions", leading: .waiting, accessory: .text("waiting"))
                .frame(width: 232)
        }
        .frame(width: 760)
    }
}

#Preview("From your pi rows") {
    NWPreviewBoth {
        VStack(spacing: 0) {
            NWCardLabel("Logins")
            NWReimportRow("Anthropic", badge: "An", detail: [.init("Subscription · Claude Pro or Max")], freshness: .same) {}
            NWHairline()
            NWReimportRow("OpenAI Codex", badge: "Cx", detail: [.init("Subscription · ChatGPT Plus or Pro")],
                          why: "Your pi’s sign-in changed on Sep 24.", freshness: .newer) {}
            NWHairline()
            NWReimportRow("Custom providers", detail: [.init("models.json", mono: true), .init("· northwind-gateway, ollama")],
                          freshness: .reimporting) {}
            NWHairline()
            NWExtensionRow("notify-slack", path: "extensions/notify-slack/", summary: "Posts to Slack when an agent finishes.",
                           state: .on, isOn: .constant(true)) {}
            NWHairline()
            NWExtensionRow("web-search", path: "extensions/web-search/", summary: "A web_search tool.",
                           state: .failed("Cannot find module 'turndown' · web-search/index.ts:4", lines: ["Error: Cannot find module 'turndown'"]),
                           isOn: .constant(true)) {}
        }
        .nwBorder(Color.nw.lineSubtle, radius: 10)
        .frame(width: 640)
    }
}
