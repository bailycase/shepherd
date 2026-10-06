import SwiftUI
import ShepherdUI
import ShepherdSessions

/// Settings ▸ Pi ▸ Sign-in (SettingsPiSignIn, SettingsPiSignInKeys; docs/design/settings-pi.md › Pi ▸ Sign-in):
/// Subscriptions, API keys and Custom providers, each provider with its state and what to do
/// about it. Everything here is Shepherd's pi's alone.
struct PiSignInSettings: View {
    let yourPi: YourPiModel
    let auth: PiAuthStore

    var body: some View {
        let page = PiSignInPage.make(survey: yourPi.survey ?? YourPiSurvey(), signingIn: signingIn, expired: auth.expired,
                                     needed: auth.needed, problems: auth.problems)
        ScrollViewReader { proxy in
            SettingsPage(title: "Sign-in",
                         explanation: "Subscriptions and API keys for agents on this Mac. They live in Shepherd’s own pi, so your terminal pi keeps its own.") {
                Button("Re-import from pi") { Task { await yourPi.reimport(.logins) } }
                .buttonStyle(.nw(.secondary, size: .s))
                .nwControlScale(.standard)
                .disabled(yourPi.survey?.folder == nil || yourPi.busy.contains(YourPiModel.rowID(.logins)))
                .help(yourPi.survey?.folder == nil ? "Shepherd found no pi of yours." : "Copies every sign-in from your pi again.")
            } content: {
                SettingsGroup(title: "Subscriptions") {
                    ForEach(page.subscriptions) { row in
                        providerRow(row).id(row.id)
                    }
                }
                SettingsGroup(title: "API keys",
                              footnote: "Pasted keys are saved in Shepherd’s pi, readable only by you. Environment variables and commands are read each time an agent starts.") {
                    ForEach(page.apiKeys) { row in
                        providerRow(row).id(row.id)
                    }
                    AddKeyRow(providers: page.addable) { auth.signIn($0, key: true) }
                }
                CLIProxyAPISettings(model: auth.proxy, auth: auth).id(CLIProxyAPIStore.provider)
                if !page.customProviders.isEmpty {
                    SettingsGroup(title: "Custom providers",
                                  trailing: (yourPi.pi.home.appendingPathComponent("models.json").path as NSString).abbreviatingWithTildeInPath) {
                        ForEach(page.customProviders) { row in
                            providerRow(row).id(row.id)
                        }
                    }
                }
                if let problem = yourPi.problems[YourPiModel.rowID(.logins)] {
                    NWInlineProblem(problem)
                }
            }
            .onChange(of: auth.focus, initial: true) {
                guard let focus = auth.focus else { return }
                withAnimation(NW.Motion.content.animation(reduceMotion: false)) { proxy.scrollTo(focus, anchor: .center) }
                auth.focus = nil
            }
        }
        .task { await yourPi.refresh() }
    }

    private var signingIn: String? {
        guard let session = auth.session, session.phase.isLive else { return nil }
        return session.provider
    }

    private func providerRow(_ row: ProviderRowModel) -> some View {
        NWProviderRow(row.name, badge: row.badge, mono: row.custom, status: PiSignInWords.status(row.auth),
                      sharedLoginNote: row.sharedLoginNote, problem: row.problem) {
            trailing(row)
            if hasMenu(row) {
                NWProviderMenuButton(for: row.name) { menu(row) }
            }
        }
    }

    @ViewBuilder private func trailing(_ row: ProviderRowModel) -> some View {
        switch row.auth {
        case .signedIn:
            Button("Sign out") { Task { await auth.signOut(row.id) } }
                .buttonStyle(.nw(.ghost, size: .s))
                .disabled(auth.signingOut.contains(row.id))
                .accessibilityLabel("Sign out of \(row.name)")
        case .expired:
            Button("Sign in again") { auth.signIn(row.id) }
                .buttonStyle(.nw(.primary, size: .s))
                .accessibilityLabel("Sign in to \(row.name) again")
        case .notSignedIn:
            Button("Sign in") { auth.signIn(row.id) }
                .buttonStyle(.nw(.secondary, size: .s))
                .accessibilityLabel("Sign in to \(row.name)")
        case .signingIn:
            Button("Cancel") { auth.closeSheet() }
                .buttonStyle(.nw(.ghost, size: .s))
                .accessibilityLabel("Cancel signing in to \(row.name)")
        case .key, .environment:
            Button("Change key") { auth.signIn(row.id, key: true) }
                .buttonStyle(.nw(.secondary, size: .s))
                .accessibilityLabel("Change \(row.name)’s key")
        case .noKey:
            EmptyView()
        }
    }

    private func hasMenu(_ row: ProviderRowModel) -> Bool {
        switch row.auth {
        case .noKey, .signingIn: false
        default: true
        }
    }

    @ViewBuilder private func menu(_ row: ProviderRowModel) -> some View {
        switch row.auth {
        case .key, .environment:
            Button("Change key…") { auth.signIn(row.id, key: true) }
            reimportItem(row)
            Divider()
            Button("Remove key", role: .destructive) { Task { await auth.signOut(row.id) } }
                .disabled({ if case .environment = row.auth { true } else { false } }())
        default:
            Button("Sign in again") { auth.signIn(row.id) }
            reimportItem(row)
            if row.auth.isSignedIn || { if case .expired = row.auth { true } else { false } }() {
                Divider()
                Button("Sign out", role: .destructive) { Task { await auth.signOut(row.id) } }
            }
        }
    }

    /// Re-import from pi, with how it stands as the item's second line.
    private func reimportItem(_ row: ProviderRowModel) -> some View {
        Button { Task { await yourPi.reimport(.login(row.id)) } } label: {
            Text("Re-import from pi")
            if let word = PiSignInWords.freshness(row.freshness) { Text(word) }
        }
        .disabled(row.freshness == nil)
    }
}

/// Add an API key: a row of its own whose menu lists the providers with no key yet.
private struct AddKeyRow: View {
    let providers: [String]
    let add: (String) -> Void
    @State private var hovering = false

    var body: some View {
        let nw = Color.nw
        Menu {
            ForEach(providers, id: \.self) { provider in
                Button(PiSignInCatalog.name(provider)) { add(provider) }
            }
        } label: {
            HStack(spacing: NWPiSignInMetrics.addGap) {
                Image(systemName: "plus").font(.nwSans(NWPiSignInMetrics.addGlyphSize, .medium)).foregroundStyle(nw.running).frame(width: NWPiSignInMetrics.badge)
                Text("Add an API key").font(.nwSans(NWPiSignInMetrics.proseSize)).foregroundStyle(nw.running)
                Text(PiSignInPage.addableSummary(providers)).font(.nw(.caption)).foregroundStyle(nw.textTertiary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, NWPiSignInMetrics.rowSides)
            .frame(minHeight: AppLayout.addKeyRowHeight)
            .background(hovering ? nw.bgHover : .clear)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(providers.isEmpty)
        .onHover { hovering = $0 }
        .accessibilityLabel("Add an API key")
    }
}

/// How a provider's sign-in reads (docs/design/settings-pi.md › Pi ▸ Sign-in's table): its dot, word and details.
enum PiSignInWords {
    static func status(_ auth: ProviderAuth) -> NWProviderStatus {
        switch auth {
        case .signedIn(let plan):
            NWProviderStatus(dot: .on, word: "Signed in", parts: plan.map { [.init($0)] } ?? [])
        case .expired(let plan):
            NWProviderStatus(dot: .attention, word: "Expired · sign in again", wordTone: .attention, parts: plan.map { [.init($0)] } ?? [])
        case .notSignedIn(let plan):
            NWProviderStatus(dot: .off, word: "Not signed in", wordTone: .secondary, parts: plan.map { [.init($0)] } ?? [])
        case .signingIn(let plan):
            NWProviderStatus(dot: .live, word: "Signing in…", parts: plan.map { [.init($0)] } ?? [], live: true)
        case .key(let display, let copied):
            NWProviderStatus(dot: .on, word: "API key", parts: keyParts(display, copied: copied))
        case .environment(let variable):
            NWProviderStatus(dot: .on, word: "From your environment",
                             parts: [.init("$" + variable, mono: true, small: true), .init("in your login shell", tone: .tertiary, separated: false)])
        case .noKey(let baseURL):
            NWProviderStatus(dot: .off, word: "No key needed", wordTone: .tertiary,
                             parts: baseURL.map { [.init($0, mono: true, small: true, tone: .tertiary)] } ?? [])
        }
    }

    /// A key's mask and source: "sk-proj-••••3kQz copied from your pi", "sk-••••91c2 reads
    /// $DEEPSEEK_API_KEY", "runs a command op read …".
    static func keyParts(_ display: PiKeyDisplay, copied: Bool) -> [NWProviderStatus.Part] {
        if let command = display.command {
            return [.init("runs a command", tone: .tertiary), .init(command, mono: true, small: true, separated: false, middle: true)]
        }
        if display.runsCommand { return [.init("runs a command", tone: .tertiary)] }
        if let name = display.variables.first {
            return NWKeySource.variable(name).parts.enumerated().map { index, part in
                var part = part
                if index == 0 { part.separated = true }
                return part
            }
        }
        var parts: [NWProviderStatus.Part] = [.init(display.masked ?? "••••", mono: true, tone: .primary)]
        if copied { parts += NWKeySource.copiedFromYourPi.parts }
        return parts
    }

    /// How a copy stands, in the menu's words: "same as here", "newer in your pi", "changed here".
    static func freshness(_ freshness: PiFreshness?) -> String? {
        switch freshness {
        case .sameAsYourPi?: "same as here"
        case .newerInYourPi?: "newer in your pi"
        case .changedHere?: "changed here"
        case nil: nil
        }
    }
}
