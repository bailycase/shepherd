import SwiftUI
import ShepherdUI
import ShepherdSessions
import ShepherdRemote
import ShepherdProtocol

/// Settings ▸ Models ▸ Accounts (SettingsPiSignIn, SettingsPiSignInKeys):
/// Subscriptions, API keys and Custom providers, each provider with its state and what to do
/// about it. Everything here is Shepherd's pi's alone.
struct PiSignInSettings: View {
    let yourPi: YourPiModel
    let auth: PiAuthStore
    /// Opens Settings ▸ Tools, where extensions that add providers are added. Nil hides the link.
    var openExtensions: (() -> Void)? = nil
    /// Opens Settings ▸ Tools at one extension's row, by its copy's destination.
    var openExtension: ((String) -> Void)? = nil
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
                                     needed: auth.needed, problems: auth.problems, accounts: auth.accounts, providers: auth.providers,
                                     owners: auth.providerOwners)
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: AppLayout.settingsGroupSpacing) {
                if let problem = auth.providersProblem { SHInlineProblem(problem) }
                SettingsGroup(title: "Subscriptions", footnote: PiSignInWords.sharedLoginNote(page.subscriptions.filter(\.sharedLoginNote).map(\.name)),
                              links: [SettingsLink("Re-import from pi",
                                                   enabled: yourPi.survey?.folder != nil && !yourPi.busy.contains(YourPiModel.rowID(.logins)),
                                                   help: yourPi.survey?.folder == nil ? "Shepherd found no pi of yours." : "Copies every sign-in from your pi again.") {
                                  Task { await yourPi.reimport(.logins) }
                              }] + (openExtensions.map { open in
                                  [SettingsLink("Add a provider", help: "Providers come from extensions, added in Settings ▸ Tools.", action: open)]
                              } ?? [])) {
                    ForEach(page.subscriptions) { row in
                        providerRow(row).id(row.id)
                    }
                }
                SettingsGroup(title: "API keys", footnote: "Sign in once: every Mac in the fleet uses the same keys.") {
                    ForEach(page.apiKeys) { row in
                        providerRow(row).id(row.id)
                    }
                    AddKeyRow(providers: page.addable, names: page.providerNames) { auth.signIn($0, key: true) }
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
            .shControlScale(.settings)
            .onChange(of: auth.focus, initial: true) {
                guard let focus = auth.focus else { return }
                withAnimation(SH.Motion.content.animation(reduceMotion: false)) { proxy.scrollTo(focus, anchor: .center) }
                auth.focus = nil
            }
        }
        .task { await yourPi.refresh() }
        .task(id: yourPi.survey?.extensions) {
            await auth.refreshProviders()
            await auth.refreshAccounts()
        }
        // Again after a sign-in, sign-out, account switch or new account. Keyed on ids alone: the
        // read saves usage into the accounts, which must not start another read.
        .task(id: UsageInputs(subscriptions: page.subscriptions.map(\.auth),
                              accounts: auth.accounts.mapValues { [$0.active ?? ""] + $0.accounts.map(\.id) })) { await auth.refreshUsage() }
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

    private struct UsageInputs: Equatable {
        let subscriptions: [ProviderAuth]
        let accounts: [String: [String]]
    }

    private var signingIn: String? {
        guard let session = auth.session, session.phase.isLive else { return nil }
        return session.provider
    }

    /// One provider: its dot, name, one hint line (plan, usage, key source), then its account menu, its
    /// sign-in button and a ⋯ menu for the rest.
    private func providerRow(_ row: ProviderRowModel) -> some View {
        let list = row.accounts.flatMap { $0.accounts.count > 1 ? $0 : nil }
        return SettingsRow(title: row.name, subtitle: hint(row, list: list), problem: row.problem,
                           dot: Self.dot(PiSignInWords.status(row.auth).dot), mono: row.custom) {
            HStack(spacing: SH.Space.s) {
                if let list {
                    SHPopupMenu(list.accounts.first { $0.id == list.active }?.title ?? "Account", minWidth: 0) {
                        ForEach(list.accounts) { account in
                            Button(account.title) { Task { await auth.switchAccount(row.id, to: account.id) } }
                        }
                    }
                    .accessibilityLabel("Account for \(row.name)")
                }
                trailing(row)
                if hasMenu(row) {
                    SHProviderMenuButton(for: row.name) { menu(row, list: list) }
                }
            }
        }
    }

    static func dot(_ dot: SHProviderStatus.Dot) -> SHRowDot {
        switch dot {
        case .on: .on
        case .attention, .live: .warn
        case .off: .off
        }
    }

    /// "Claude Max · 41% of the week used": plan, usage, key source, or the state's word.
    private func hint(_ row: ProviderRowModel, list: PiAccountList?) -> String {
        let status = PiSignInWords.status(row.auth)
        var parts: [String] = []
        if case .signedIn = row.auth {} else { parts.append(status.word) }
        parts += status.parts.map(\.text)
        if let list { parts.append("\(list.accounts.count) accounts") }
        else if row.auth.isSignedIn, let window = (auth.usage[row.id] ?? []).max(by: { $0.usedPercent < $1.usedPercent }) {
            parts.append(HostInventoryPresentation.usageWords(HostUsageWindow(name: window.name, usedPercent: window.usedPercent)))
        }
        if row.auth.isSignedIn, let balance = auth.balances[row.id] { parts.append(PiSignInWords.balance(balance)) }
        if let source = row.source { parts.append("from \(source)") }
        return parts.joined(separator: " · ")
    }

    /// Subscriptions and keys in auth.json can save more than one account; a variable or custom provider can't.
    private func canAddAccount(_ row: ProviderRowModel) -> Bool {
        guard !row.custom, row.signInAvailable else { return false }
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
                .disabled(!row.signInAvailable)
                .buttonStyle(.sh(.primary, size: .s))
                .accessibilityLabel("Sign in to \(row.name) again")
        case .notSignedIn:
            Button("Sign in") { auth.signIn(row.id) }
                .disabled(!row.signInAvailable)
                .buttonStyle(.sh(.secondary, size: .s))
                .accessibilityLabel("Sign in to \(row.name)")
        case .signingIn:
            Button("Cancel") { auth.closeSheet() }
                .buttonStyle(.sh(.ghost, size: .s))
                .accessibilityLabel("Cancel signing in to \(row.name)")
        case .key, .environment:
            Button("Change key") { auth.signIn(row.id, key: true) }
                .disabled(!row.signInAvailable)
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

    @ViewBuilder private func menu(_ row: ProviderRowModel, list: PiAccountList? = nil) -> some View {
        if let list, let account = list.accounts.first(where: { $0.id == list.active }) {
            Button("Rename \(account.title)…") {
                newName = account.name
                renaming = Renaming(provider: row.id, providerName: row.name, account: account)
            }
            Button("Remove \(account.title)", role: .destructive) { Task { await auth.removeAccount(row.id, account.id) } }
            Button(list.rotate ? "Stop rotating accounts" : "Rotate accounts when one hits its limit") {
                Task { await auth.setRotate(row.id, !list.rotate) }
            }
            Divider()
        }
        switch row.auth {
        case .key, .environment:
            Button("Change key…") { auth.signIn(row.id, key: true) }.disabled(!row.signInAvailable)
            if canAddAccount(row) {
                Button("Add another account…") { Task { await auth.addAccount(row.id, key: true) } }
            }
            reimportItem(row)
            extensionItem(row)
            Divider()
            Button("Remove key", role: .destructive) { Task { await auth.signOut(row.id) } }
                .disabled({ if case .environment = row.auth { true } else { false } }())
        default:
            Button("Sign in again") { auth.signIn(row.id) }.disabled(!row.signInAvailable)
            if canAddAccount(row) {
                Button("Add another account…") { Task { await auth.addAccount(row.id) } }
            }
            reimportItem(row)
            extensionItem(row)
            if row.auth.isSignedIn || { if case .expired = row.auth { true } else { false } }() {
                Divider()
                Button("Sign out", role: .destructive) { Task { await auth.signOut(row.id) } }
            }
        }
    }

    /// Show the extension a provider came from, in Settings ▸ Tools.
    @ViewBuilder private func extensionItem(_ row: ProviderRowModel) -> some View {
        if let source = row.source, let id = row.sourceID, let openExtension {
            Button("Show the \(source) extension") { openExtension(id) }
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

/// Add an API key: a row whose menu lists the providers with no key yet.
private struct AddKeyRow: View {
    let providers: [String]
    var names: [String: String] = [:]
    let add: (String) -> Void

    var body: some View {
        SettingsRow(title: "Add an API key") {
            SHPopupMenu("Choose a provider", minWidth: 0) {
                ForEach(providers, id: \.self) { provider in
                    Button(names[provider] ?? PiSignInCatalog.name(provider)) { add(provider) }
                }
            }
            .disabled(providers.isEmpty)
            .accessibilityLabel("Add an API key")
        }
    }
}

/// How a provider's sign-in reads: its dot, word and details.
enum PiSignInWords {
    /// "Credit $18.40": the remote client's words, so both read the same.
    static func balance(_ balance: PiBalance, locale: Locale = .current) -> String {
        HostInventoryPresentation.balanceWords(HostBalance(amount: balance.amount, currency: balance.currency, label: balance.label), locale: locale)
    }

    /// "resets 3:40 PM" today, "resets Thu 3:40 PM" later. A window whose reset has passed (an
    /// old reading) is back to 0%.
    static func usage(_ windows: [PiUsageWindow], now: Date = Date()) -> [SHUsageWindow] {
        windows.map { window in
            if let date = window.resetsAt, date <= now { return SHUsageWindow(name: window.name, fraction: 0, resets: nil) }
            let resets = window.resetsAt.map { date in
                Calendar.current.isDate(date, inSameDayAs: now)
                    ? "resets " + date.formatted(date: .omitted, time: .shortened)
                    : "resets " + date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
            }
            return SHUsageWindow(name: window.name, fraction: window.usedPercent / 100, resets: resets)
        }
    }

    /// "as of 2 hr. ago" for a reading older than 15 minutes; nil for a fresh one.
    static func asOf(_ readAt: Date?, now: Date = Date()) -> String? {
        guard let readAt, now.timeIntervalSince(readAt) > staleAfter else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "as of " + formatter.localizedString(for: readAt, relativeTo: now)
    }

    static let staleAfter: TimeInterval = 15 * 60

    /// Once under Subscriptions: "Signing in to Anthropic, OpenAI Codex, Kimi or Radius here and in
    /// your terminal pi can sign one of them out."
    static func sharedLoginNote(_ providers: [String]) -> String? {
        guard !providers.isEmpty else { return nil }
        return "Signing in to \(providers.formatted(.list(type: .or))) here and in your terminal pi can sign one of them out."
    }

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

/// Models' header button: copies every sign-in from the user's pi again.
struct PiReimportLoginsButton: View {
    let yourPi: YourPiModel

    var body: some View {
        Button("Re-import from pi") { Task { await yourPi.reimport(.logins) } }
            .buttonStyle(.sh(.secondary, size: .s))
            .shControlScale(.settings)
            .disabled(yourPi.survey?.folder == nil || yourPi.busy.contains(YourPiModel.rowID(.logins)))
            .help(yourPi.survey?.folder == nil ? "Shepherd found no pi of yours." : "Copies every sign-in from your pi again.")
    }
}
