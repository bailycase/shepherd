import SwiftUI
import ShepherdUI
import ShepherdSessions

/// Settings ▸ Pi ▸ Sign-in (SettingsPiSignIn, SettingsPiSignInKeys; docs/design/settings-pi.md › Pi ▸ Sign-in):
/// Subscriptions, API keys and Custom providers, each provider with its state and what to do
/// about it. Everything here is Shepherd's pi's alone.
struct PiSignInSettings: View {
    let yourPi: YourPiModel
    let auth: PiAuthStore
    @State private var renaming: Renaming?
    @State private var newName = ""

    /// The account the Rename alert is up for.
    private struct Renaming: Equatable {
        let provider: String
        let providerName: String
        let account: PiAccount
    }

    var body: some View {
        let page = PiSignInPage.make(survey: yourPi.survey ?? YourPiSurvey(), signingIn: signingIn, expired: auth.expired,
                                     needed: auth.needed, problems: auth.problems, accounts: auth.accounts)
        ScrollViewReader { proxy in
            SettingsPage(title: "Sign-in",
                         explanation: "Subscriptions and API keys for agents on this Mac. They live in Shepherd’s own pi, so your terminal pi keeps its own.") {
                Button("Re-import from pi") { Task { await yourPi.reimport(.logins) } }
                .buttonStyle(.sh(.secondary, size: .s))
                .shControlScale(.standard)
                .disabled(yourPi.survey?.folder == nil || yourPi.busy.contains(YourPiModel.rowID(.logins)))
                .help(yourPi.survey?.folder == nil ? "Shepherd found no pi of yours." : "Copies every sign-in from your pi again.")
            } content: {
                SettingsGroup(title: "Subscriptions") {
                    ForEach(page.subscriptions) { row in
                        providerRow(row).id(row.id)
                    }
                }
                SettingsGroup(title: "API keys",
                              footnote: "Pasted keys are saved in Shepherd’s pi, readable only by you. Environment variables are read each time an agent starts. Command values are not supported.") {
                    ForEach(page.apiKeys) { row in
                        providerRow(row).id(row.id)
                    }
                    AddKeyRow(providers: page.addable) { auth.signIn($0, key: true) }
                }
                if !page.customProviders.isEmpty {
                    SettingsGroup(title: "Custom providers",
                                  trailing: (yourPi.pi.home.appendingPathComponent("models.json").path as NSString).abbreviatingWithTildeInPath) {
                        ForEach(page.customProviders) { row in
                            providerRow(row).id(row.id)
                        }
                    }
                }
                if let problem = yourPi.problems[YourPiModel.rowID(.logins)] {
                    SHInlineProblem(problem)
                }
            }
            .onChange(of: auth.focus, initial: true) {
                guard let focus = auth.focus else { return }
                withAnimation(SH.Motion.content.animation(reduceMotion: false)) { proxy.scrollTo(focus, anchor: .center) }
                auth.focus = nil
            }
        }
        .task { await yourPi.refresh() }
        .task { await auth.refreshAccounts() }
        .alert("Rename account", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
               presenting: renaming) { target in
            TextField("Name", text: $newName)
            Button("Rename") {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name != target.account.name else { return }
                Task { await auth.renameAccount(target.provider, target.account.id, to: name) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            Text("A name for this \(target.providerName) account, shown only here.")
        }
    }

    private var signingIn: String? {
        guard let session = auth.session, session.phase.isLive else { return nil }
        return session.provider
    }

    private func providerRow(_ row: ProviderRowModel) -> some View {
        VStack(spacing: 0) {
            SHProviderRow(row.name, badge: row.badge, mono: row.custom, status: PiSignInWords.status(row.auth),
                          sharedLoginNote: row.sharedLoginNote, problem: row.problem) {
                trailing(row)
                if hasMenu(row) {
                    SHProviderMenuButton(for: row.name) { menu(row) }
                }
            }
            if let list = row.accounts, list.accounts.count > 1 {
                accounts(row, list)
            }
        }
    }

    /// A provider's saved accounts, once there are two: each with Use and its menu, then rotation.
    @ViewBuilder private func accounts(_ row: ProviderRowModel, _ list: PiAccountList) -> some View {
        let now = Date()
        SHHairline().padding(.leading, SHPiAccountMetrics.inset)
        VStack(spacing: 0) {
            ForEach(list.accounts) { account in
                let active = account.id == list.active
                let limited = account.limitedUntil.flatMap { $0 > now ? $0.formatted(date: .omitted, time: .shortened) : nil }
                SHProviderAccountRow(account.name, state: SHAccountState(active: active, limitedUntil: limited)) {
                    if !active {
                        Button("Use") { Task { await auth.switchAccount(row.id, to: account.id) } }
                            .buttonStyle(.sh(.secondary, size: .s))
                            .accessibilityLabel("Use \(account.name) for \(row.name)")
                    }
                    SHProviderMenuButton(for: account.name) {
                        Button("Rename…") {
                            newName = account.name
                            renaming = Renaming(provider: row.id, providerName: row.name, account: account)
                        }
                        Divider()
                        Button("Remove", role: .destructive) { Task { await auth.removeAccount(row.id, account.id) } }
                    }
                }
            }
        }
        .padding(.top, SH.Space.s)
        SHAccountRotationRow(provider: row.name, isOn: Binding(get: { list.rotate },
                                                               set: { on in Task { await auth.setRotate(row.id, on) } }))
    }

    /// Subscriptions and keys in auth.json can save more than one account; a variable or custom provider can't.
    private func canAddAccount(_ row: ProviderRowModel) -> Bool {
        guard !row.custom else { return false }
        switch row.auth {
        case .signedIn, .key: return true
        default: return false
        }
    }

    @ViewBuilder private func trailing(_ row: ProviderRowModel) -> some View {
        switch row.auth {
        case .signedIn:
            Button("Sign out") { Task { await auth.signOut(row.id) } }
                .buttonStyle(.sh(.ghost, size: .s))
                .disabled(auth.signingOut.contains(row.id))
                .accessibilityLabel("Sign out of \(row.name)")
                .help((row.accounts?.accounts.count ?? 0) > 1 ? "Signs out of every saved \(row.name) account." : "")
        case .expired:
            Button("Sign in again") { auth.signIn(row.id) }
                .buttonStyle(.sh(.primary, size: .s))
                .accessibilityLabel("Sign in to \(row.name) again")
        case .notSignedIn:
            Button("Sign in") { auth.signIn(row.id) }
                .buttonStyle(.sh(.secondary, size: .s))
                .accessibilityLabel("Sign in to \(row.name)")
        case .signingIn:
            Button("Cancel") { auth.closeSheet() }
                .buttonStyle(.sh(.ghost, size: .s))
                .accessibilityLabel("Cancel signing in to \(row.name)")
        case .key, .environment:
            Button("Change key") { auth.signIn(row.id, key: true) }
                .buttonStyle(.sh(.secondary, size: .s))
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
            if canAddAccount(row) {
                Button("Add another account…") { Task { await auth.addAccount(row.id, key: true) } }
            }
            reimportItem(row)
            Divider()
            Button("Remove key", role: .destructive) { Task { await auth.signOut(row.id) } }
                .disabled({ if case .environment = row.auth { true } else { false } }())
        default:
            Button("Sign in again") { auth.signIn(row.id) }
            if canAddAccount(row) {
                Button("Add another account…") { Task { await auth.addAccount(row.id) } }
            }
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
        let sh = Color.sh
        Menu {
            ForEach(providers, id: \.self) { provider in
                Button(PiSignInCatalog.name(provider)) { add(provider) }
            }
        } label: {
            HStack(spacing: SHPiSignInMetrics.addGap) {
                Image(systemName: "plus").font(.shSans(SHPiSignInMetrics.addGlyphSize, .medium)).foregroundStyle(sh.running).frame(width: SHPiSignInMetrics.badge)
                Text("Add an API key").font(.shSans(SHPiSignInMetrics.proseSize)).foregroundStyle(sh.running)
                Text(PiSignInPage.addableSummary(providers)).font(.sh(.caption)).foregroundStyle(sh.textTertiary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SHPiSignInMetrics.rowSides)
            .frame(minHeight: AppLayout.addKeyRowHeight)
            .background(hovering ? sh.bgHover : .clear)
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
    static func status(_ auth: ProviderAuth) -> SHProviderStatus {
        switch auth {
        case .signedIn(let plan):
            SHProviderStatus(dot: .on, word: "Signed in", parts: plan.map { [.init($0)] } ?? [])
        case .expired(let plan):
            SHProviderStatus(dot: .attention, word: "Expired · sign in again", wordTone: .attention, parts: plan.map { [.init($0)] } ?? [])
        case .notSignedIn(let plan):
            SHProviderStatus(dot: .off, word: "Not signed in", wordTone: .secondary, parts: plan.map { [.init($0)] } ?? [])
        case .signingIn(let plan):
            SHProviderStatus(dot: .live, word: "Signing in…", parts: plan.map { [.init($0)] } ?? [], live: true)
        case .key(let display, let copied):
            SHProviderStatus(dot: .on, word: "API key", parts: keyParts(display, copied: copied))
        case .environment(let variable):
            SHProviderStatus(dot: .on, word: "From your environment",
                             parts: [.init("$" + variable, mono: true, small: true), .init("in your login shell", tone: .tertiary, separated: false)])
        case .noKey(let baseURL):
            SHProviderStatus(dot: .off, word: "No key needed", wordTone: .tertiary,
                             parts: baseURL.map { [.init($0, mono: true, small: true, tone: .tertiary)] } ?? [])
        }
    }

    /// A key's mask and source: "sk-proj-••••3kQz copied from your pi", "sk-••••91c2 reads
    /// $DEEPSEEK_API_KEY", or "command not supported". Command text is never shown.
    static func keyParts(_ display: PiKeyDisplay, copied: Bool) -> [SHProviderStatus.Part] {
        if display.runsCommand { return [.init("command not supported", tone: .tertiary)] }
        if let name = display.variables.first {
            return SHKeySource.variable(name).parts.enumerated().map { index, part in
                var part = part
                if index == 0 { part.separated = true }
                return part
            }
        }
        var parts: [SHProviderStatus.Part] = [.init(display.masked ?? "••••", mono: true, tone: .primary)]
        if copied { parts += SHKeySource.copiedFromYourPi.parts }
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
