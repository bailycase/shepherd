import SwiftUI

// PiAuthStates: every sign-in part in its states, light and dark.

private let rowStates: [(String, String, SHProviderStatus, Bool, String)] = [
    ("Anthropic", "An", SHProviderStatus(dot: .on, word: "Signed in", parts: [.init("Claude Pro or Max")]), true, "Sign out"),
    ("OpenAI Codex", "Cx", SHProviderStatus(dot: .attention, word: "Expired · sign in again", wordTone: .attention,
                                            parts: [.init("ChatGPT Plus or Pro")]), true, "Sign in again"),
    ("Google", "Go", SHProviderStatus(dot: .off, word: "Not signed in", wordTone: .secondary, parts: [.init("Gemini")]), false, "Sign in"),
    ("Kimi", "Ki", SHProviderStatus(dot: .live, word: "Signing in…", parts: [.init("Kimi For Coding")], live: true), true, "Cancel"),
    ("OpenAI", "Oa", SHProviderStatus(dot: .on, word: "API key", parts: [.init("sk-proj-••••3kQz", mono: true, tone: .primary)]
                                      + SHKeySource.copiedFromYourPi.parts), false, "Change key"),
    ("DeepSeek", "Ds", SHProviderStatus(dot: .on, word: "API key", parts: [.init("sk-••••91c2", mono: true, tone: .primary)]
                                        + SHKeySource.variable("DEEPSEEK_API_KEY").parts), false, "Change key"),
    ("OpenRouter", "Or", SHProviderStatus(dot: .on, word: "From your environment", parts: [.init("$OPENROUTER_API_KEY", mono: true, small: true),
                                                                                         .init("in your login shell", tone: .tertiary, separated: false)]),
     false, "Change key"),
]

#Preview("Provider rows") {
    SHPreviewBoth {
        VStack(spacing: 0) {
            ForEach(Array(rowStates.enumerated()), id: \.offset) { index, row in
                if index > 0 { SHHairline() }
                SHProviderRow(row.0, badge: row.1, status: row.2, sharedLoginNote: row.3) {
                    Button(row.4) {}.buttonStyle(.sh(row.4 == "Sign in again" ? .primary : row.4 == "Sign out" || row.4 == "Cancel" ? .ghost : .secondary, size: .s))
                    SHProviderMenuButton(for: row.0) { Button("Sign out") {} }
                }
            }
            SHHairline()
            SHProviderRow("ollama", badge: "Ol", mono: true,
                          status: SHProviderStatus(dot: .off, word: "No key needed", wordTone: .tertiary,
                                                   parts: [.init("http://localhost:11434", mono: true, small: true, tone: .tertiary)])) { EmptyView() }
        }
        .shBorder(Color.sh.lineSubtle, radius: 10)
        .frame(width: 640)
    }
}

#Preview("Key sources and the shared note") {
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: SH.Space.m) {
            SHKeySourceLabel(.copiedFromYourPi)
            SHKeySourceLabel(.variable("DEEPSEEK_API_KEY"))
            SHKeySourceLabel(.command("op read op://Dev/northwind/api-key"))
            SHSharedLoginNote()
        }
    }
}

#Preview("Import steps and summary") {
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: SH.Space.l) {
            SHSheetCard {
                SHImportStepRow("Logins", detail: "Anthropic, OpenAI Codex, Kimi", count: "3 subscriptions", state: .done)
                SHImportStepRow("Default model", count: "claude-opus", state: .now)
                SHImportStepRow("Trusted folders", state: .pending)
                SHImportStepRow("Extensions", detail: "Listed, switched off", count: "3 found", state: .done)
                SHImportStepRow("Logins and API keys", detail: "auth.json isn’t valid JSON", state: .failed)
            }
            SHImportSummary([.init("logins", count: 3), .init("API keys", count: 2), .init("custom providers"),
                             .init("default model", value: "claude-opus"), .init("trusted folders", count: 4)])
            SHSheetCard {
                SHImportSignInRow("OpenAI Codex", badge: "Cx", detail: "Your pi isn’t signed in to it") {}
                SHImportSignInRow("Kimi", badge: "Ki", detail: "Your pi’s sign-in couldn’t be copied", signedIn: true) {}
            }
            HStack(spacing: SH.Space.m) {
                SHSignInChoiceTile("Anthropic", detail: "Claude Pro or Max", badge: "An")
                SHSignInChoiceTile("Use an API key", detail: "OpenAI, OpenRouter and 30 more")
            }
        }
        .frame(width: 540)
    }
}

#Preview("Sign-in sheet parts") {
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: SH.Space.l) {
            SHSheetHeader("Sign in to Anthropic", subtitle: "With your Claude Pro or Max subscription", leading: .badge("An"), close: {})
            SHSignInSteps {
                SHSignInStepRow("Opened claude.ai in your browser", state: .done)
                SHSignInStepRow("Waiting for you in the browser", note: "Approve Shepherd on claude.ai. This closes by itself when you’re done.", state: .now)
                SHSignInStepRow("Save the sign-in to Shepherd’s pi", state: .pending)
            }
            SHDeviceCode("8F3K-Q2WD")
            SHFailureBox("Another sign-in is using localhost:1455",
                         detail: "Probably Codex CLI or your terminal pi’s /login, mid-way. Finish or cancel it there, then try again.")
            SHFailureBox("~/.pi/agent/auth.json", detail: "Unexpected token } in JSON at line 31, column 5", monoTitle: true, monoDetail: true)
            SHSheetFooter {
                Button("Copy link") {}.buttonStyle(.sh(.ghost))
            } actions: {
                Button("Cancel") {}.buttonStyle(.sh(.ghost))
                Button("Open browser again") {}.buttonStyle(.sh(.secondary))
            }
        }
        .frame(width: 500)
    }
}

#Preview("Agent waiting and not signed in") {
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: SH.Space.l) {
            SHAgentWaitingLine(message: "This agent was mid-turn when Shepherd quit. It picks up once your pi is brought over.",
                               trailing: "restored 9:41 AM")
            SHAgentNotSignedInCard(provider: "Anthropic", model: "claude-opus",
                                   reason: "Anthropic’s sign-in was skipped when your pi came over, so the agent is waiting for you. Your message is kept.",
                                   time: "9:43 AM", signIn: {}) {
                Button("gpt-5.3-codex") {}
                Button("deepseek-chat") {}
            }
            SHSidebarRow("Plan shepherd extensions", leading: .waiting, accessory: .text("waiting"))
                .frame(width: 232)
        }
        .frame(width: 760)
    }
}

#Preview("From your pi rows") {
    SHPreviewBoth {
        VStack(spacing: 0) {
            SHCardLabel("Logins")
            SHReimportRow("Anthropic", badge: "An", detail: [.init("Subscription · Claude Pro or Max")], freshness: .same) {}
            SHHairline()
            SHReimportRow("OpenAI Codex", badge: "Cx", detail: [.init("Subscription · ChatGPT Plus or Pro")],
                          why: "Your pi’s sign-in changed on Sep 24.", freshness: .newer) {}
            SHHairline()
            SHReimportRow("Custom providers", detail: [.init("models.json", mono: true), .init("· northwind-gateway, ollama")],
                          freshness: .reimporting) {}
            SHHairline()
            SHExtensionRow("notify-slack", path: "extensions/notify-slack/", summary: "Posts to Slack when an agent finishes.",
                           state: .on, isOn: .constant(true)) {}
            SHHairline()
            SHExtensionRow("web-search", path: "extensions/web-search/", summary: "A web_search tool.",
                           state: .failed("Cannot find module 'turndown' · web-search/index.ts:4", lines: ["Error: Cannot find module 'turndown'"]),
                           isOn: .constant(true)) {}
        }
        .shBorder(Color.sh.lineSubtle, radius: 10)
        .frame(width: 640)
    }
}
