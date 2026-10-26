import SwiftUI
import ShepherdUI
import ShepherdSessions

/// Sign in to <provider> (docs/design/dialogs-and-palette.md › Dialogs and sheets › Sign in to <provider>; SignInBrowser,
/// SignInDevice, SignInPaste, SignInKey, SignInPortBusy): one sheet, four flows, over Settings or
/// the first launch's sheet. pi's own login runs behind it; this only draws where it stands.
struct PiSignInSheet: View {
    @Bindable var session: PiSignInSession
    let close: () -> Void
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SHSheetHeader(title, subtitle: subtitle, leading: .badge(PiSignInCatalog.badge(session.provider)), close: close)
            content
                .padding(.top, SHPiSignInMetrics.bodyTop)
                .padding(.horizontal, SHPiSignInMetrics.sheetInset)
                .padding(.bottom, SHPiSignInMetrics.bodyBottom)
            footer
        }
        .frame(width: SHPiSignInMetrics.sheetWidth)
        .background(Color.sh.bgWindow)
        .shAnimation(.disclosure, value: session.phase)
        .task(id: session.phase) {
            // One opened from /login or an agent's card closes by itself once it lands.
            guard case .done = session.phase, session.origin == .slash || session.origin == .agentCard else { return }
            try? await Task.sleep(for: AppLayout.signInAutoCloseDelay)
            if !Task.isCancelled { close() }
        }
    }

    private var title: String { "Sign in to \(session.name)" }

    private var subtitle: String {
        switch session.flow {
        case .paste: "Paste a code instead of the browser hand-off"
        case .key: "With an API key"
        case .browser, .device: session.subscription?.sheetSubtitle ?? "With your account"
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch session.flow {
        case .browser: browser
        case .paste: paste
        case .device: device
        case .key: keyForm
        }
    }

    @ViewBuilder private var browser: some View {
        let site = session.site
        switch session.phase {
        case .portBusy(let port):
            VStack(alignment: .leading, spacing: SHPiSignInMetrics.bodyGap) {
                SHFailureBox("Another sign-in is using localhost:\(port)",
                             detail: "Probably Codex CLI or your terminal pi’s /login, mid-way. Finish or cancel it there, then try again.")
                SHSignInSteps {
                    SHSignInStepRow("Open \(site) in your browser", state: .pending)
                    SHSignInStepRow("Save the sign-in to Shepherd’s pi", state: .pending)
                }
                if session.subscription?.pasteNeedsPort != true {
                    linkLine("Or skip the browser hand-off: sign in on \(site) and paste the code it shows.", link: "Paste a code instead") {
                        session.pasteInstead()
                    }
                }
            }
        default:
            VStack(alignment: .leading, spacing: SHPiSignInMetrics.bodyGap) {
                SHSignInSteps { browserSteps(site: site) }
                if session.phase.isLive, session.phase != .saving {
                    linkLine("Browser on another computer?", link: "Paste a code instead") { session.pasteInstead() }
                }
            }
        }
    }

    @ViewBuilder private func browserSteps(site: String) -> some View {
        switch session.phase {
        case .starting:
            SHSignInStepRow("Open \(site) in your browser", state: .now)
            SHSignInStepRow("Waiting for you in the browser", state: .pending)
            SHSignInStepRow("Save the sign-in to Shepherd’s pi", state: .pending)
        case .done(let pickedUp):
            SHSignInStepRow("Opened \(site) in your browser", state: .done)
            SHSignInStepRow("Signed in", note: session.subscription?.plan, state: .done)
            SHSignInStepRow("Saved to Shepherd’s pi", note: Self.pickedUp(pickedUp), state: .done)
        case .failed(let reason):
            SHSignInStepRow("Opened \(site) in your browser", state: .done)
            SHSignInStepRow("\(site) didn’t sign you in", note: reason, state: .failed)
            SHSignInStepRow("Save the sign-in to Shepherd’s pi", note: "Nothing was saved.", state: .pending)
        case .saving:
            SHSignInStepRow("Opened \(site) in your browser", state: .done)
            SHSignInStepRow("Approved", state: .done)
            SHSignInStepRow("Saving the sign-in to Shepherd’s pi", state: .now)
        default:
            SHSignInStepRow("Opened \(site) in your browser", state: .done)
            SHSignInStepRow("Waiting for you in the browser",
                            note: "Approve Shepherd on \(site). This closes by itself when you’re done.", state: .now)
            SHSignInStepRow("Save the sign-in to Shepherd’s pi", state: .pending)
        }
    }

    @ViewBuilder private var paste: some View {
        let site = session.site
        switch session.phase {
        case .done(let pickedUp):
            SHSignInSteps {
                SHSignInStepRow("Signed in", note: session.subscription?.plan, state: .done)
                SHSignInStepRow("Saved to Shepherd’s pi", note: Self.pickedUp(pickedUp), state: .done)
            }
        case .failed(let reason):
            SHFailureBox("The sign-in didn’t finish", detail: reason)
        default:
            let rejected: String? = if case .paste(let reason) = session.phase { reason } else { nil }
            VStack(alignment: .leading, spacing: SHPiSignInMetrics.bodyGap) {
                Text("After you approve Shepherd, \(site) shows a code. Paste it here to finish.")
                    .shText(size: SHPiSignInMetrics.proseSize, lineHeight: SHPiSignInMetrics.proseLeading)
                    .foregroundStyle(Color.sh.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: SH.Space.s) {
                    SHFieldLabel("Code from \(site)")
                    TextField("Paste the code", text: $session.code)
                        .textFieldStyle(.sh(mono: true, error: rejected != nil))
                        .focused($fieldFocused)
                        .disabled(session.phase == .saving)
                        .onSubmit { session.submitCode() }
                        .accessibilityLabel("Code from \(site)")
                    if let rejected {
                        Text(rejected).font(.sh(.caption)).foregroundStyle(Color.sh.failed).fixedSize(horizontal: false, vertical: true)
                    } else if session.phase == .saving {
                        Text("Checking the code with \(site)").font(.sh(.caption)).shShimmer(active: true).foregroundStyle(Color.sh.textTertiary)
                    }
                }
            }
            .onAppear { fieldFocused = true }
        }
    }

    @ViewBuilder private var device: some View {
        let site = session.site
        switch session.phase {
        case .device(let code, let uri, let expires):
            VStack(alignment: .leading, spacing: SHPiSignInMetrics.bodyGap) {
                (Text("Enter this code at ") + Text(Self.shortURI(uri)).font(.shMono(SHPiSignInMetrics.proseMonoSize)).foregroundColor(Color.sh.textPrimary)
                    + Text(". It’s already on your clipboard."))
                    .shText(size: SHPiSignInMetrics.proseSize, lineHeight: SHPiSignInMetrics.proseLeading)
                    .foregroundStyle(Color.sh.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: SH.Space.m) {
                    SHDeviceCode(code)
                    HStack(spacing: SH.Space.m) {
                        Button { session.copyCode() } label: { Label("Copy", systemImage: "doc.on.doc") }
                            .buttonStyle(.sh(.ghost, size: .s))
                        Button { session.openDevicePage() } label: { Label("Open \(site)", systemImage: "arrow.up.forward.square") }
                            .buttonStyle(.sh(.secondary, size: .s))
                    }
                }
                SHSignInSteps {
                    SHSignInStepRow("Waiting for you to enter the code",
                                    note: expires.map { "The code works until \($0.formatted(date: .omitted, time: .shortened))." }, state: .now)
                }
            }
        case .done(let pickedUp):
            SHSignInSteps {
                SHSignInStepRow("Signed in", note: session.subscription?.plan, state: .done)
                SHSignInStepRow("Saved to Shepherd’s pi", note: Self.pickedUp(pickedUp), state: .done)
            }
        case .failed(let reason):
            SHSignInSteps {
                SHSignInStepRow("\(site) didn’t sign you in", note: reason, state: .failed)
                SHSignInStepRow("Save the sign-in to Shepherd’s pi", note: "Nothing was saved.", state: .pending)
            }
        default:
            SHSignInSteps {
                SHSignInStepRow("Asking \(site) for a code", state: .now)
                SHSignInStepRow("Waiting for you to enter the code", state: .pending)
            }
        }
    }

    @ViewBuilder private var keyForm: some View {
        switch session.phase {
        case .done(let pickedUp):
            SHSignInSteps {
                SHSignInStepRow("Works", state: .done)
                SHSignInStepRow("Saved to Shepherd’s pi", note: Self.pickedUp(pickedUp), state: .done)
            }
        case .failed(let reason):
            SHFailureBox("The key wasn’t saved", detail: reason)
        default:
            VStack(alignment: .leading, spacing: SHPiSignInMetrics.bodyGap) {
                SHSegmentedPicker("How the key is given", selection: Binding(get: { session.keyMode }, set: { session.setKeyMode($0) }),
                                  options: [(.paste, "Paste a key"), (.variable, "Environment variable")])
                    .fixedSize()
                VStack(alignment: .leading, spacing: SH.Space.s) {
                    if session.keyMode == .paste {
                        SHFieldLabel("API key")
                        SecureField("Paste the key", text: $session.key)
                            .textFieldStyle(.sh(mono: true, error: rejected))
                            .focused($fieldFocused)
                            .onSubmit { session.saveKey() }
                            .accessibilityLabel("API key")
                    } else {
                        SHFieldLabel("Variable name")
                        TextField(PiProviders.environmentKeys[session.provider]?.first.map { "$" + $0 } ?? "$PROVIDER_API_KEY",
                                  text: $session.variable)
                            .textFieldStyle(.sh(mono: true, error: rejected))
                            .focused($fieldFocused)
                            .onSubmit { session.saveKey() }
                            .accessibilityLabel("Variable name")
                        Text("Read from your login shell each time an agent starts.")
                            .font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                    }
                }
                check
                if let page = PiSignInCatalog.keyPages[session.provider], let url = URL(string: "https://\(page)") {
                    linkLine("No key yet?", link: "Get one on \(page)") { NSWorkspace.shared.open(url) }
                }
            }
            .onAppear { fieldFocused = true }
        }
    }

    private var rejected: Bool {
        if case .rejected = session.keyCheck { return true }
        if case .unset = session.keyCheck { return true }
        return false
    }

    @ViewBuilder private var check: some View {
        let name = session.name
        switch session.keyCheck {
        case .idle:
            EmptyView()
        case .checking:
            Text("Checking the key with \(name)").font(.sh(.caption)).shShimmer(active: true).foregroundStyle(Color.sh.textTertiary)
        case .works(let models):
            HStack(alignment: .firstTextBaseline, spacing: SH.Space.s) {
                Text("Works.").font(.sh(.caption, weight: .medium)).foregroundStyle(Color.sh.done)
                if !models.isEmpty {
                    Text(Self.ready(models)).font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary)
                }
            }
        case .rejected(let reason):
            Text("\(name) rejected this key (\(reason)).").font(.sh(.caption)).foregroundStyle(Color.sh.failed)
                .fixedSize(horizontal: false, vertical: true)
        case .unreachable(let reason):
            Text("Couldn’t reach \(name) to check it. \(reason)").font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        case .unset(let reason):
            Text(reason).font(.sh(.caption)).foregroundStyle(Color.sh.failed)
        }
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        switch session.phase {
        case .done:
            SHSheetFooter {
                Button("Done", action: close).buttonStyle(.sh(.primary)).keyboardShortcut(.defaultAction)
            }
        case .failed(let reason):
            SHSheetFooter {
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(reason, forType: .string) } label: {
                    Label("Copy details", systemImage: "doc.on.doc")
                }
                .buttonStyle(.sh(.ghost))
            } actions: {
                Button("Close", action: close).buttonStyle(.sh(.ghost)).keyboardShortcut(.cancelAction)
                Button { session.tryAgain() } label: { Label("Try again", systemImage: "arrow.clockwise") }
                    .buttonStyle(.sh(.primary)).keyboardShortcut(.defaultAction)
            }
        case .portBusy:
            SHSheetFooter {
                Button("Cancel", action: close).buttonStyle(.sh(.ghost)).keyboardShortcut(.cancelAction)
                Button { session.tryAgain() } label: { Label("Try again", systemImage: "arrow.clockwise") }
                    .buttonStyle(.sh(.primary)).keyboardShortcut(.defaultAction)
            }
        default:
            switch session.flow {
            case .browser:
                SHSheetFooter {
                    Button { session.copyLink() } label: { Label("Copy link", systemImage: "doc.on.doc") }
                        .buttonStyle(.sh(.ghost))
                        .disabled(session.authURL == nil)
                } actions: {
                    Button("Cancel", action: close).buttonStyle(.sh(.ghost)).keyboardShortcut(.cancelAction)
                    Button { session.openBrowserAgain() } label: { Label("Open browser again", systemImage: "arrow.up.forward.square") }
                        .buttonStyle(.sh(.secondary))
                        .disabled(session.authURL == nil)
                }
            case .paste:
                SHSheetFooter {
                    Button("Open \(session.site) again") { session.reopenForCode() }.buttonStyle(.sh(.ghost))
                } actions: {
                    Button("Cancel", action: close).buttonStyle(.sh(.ghost)).keyboardShortcut(.cancelAction)
                    Button("Continue") { session.submitCode() }
                        .buttonStyle(.sh(.primary)).keyboardShortcut(.defaultAction)
                        .disabled(session.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.phase == .saving)
                }
            case .device:
                SHSheetFooter {
                    Button("Cancel", action: close).buttonStyle(.sh(.ghost)).keyboardShortcut(.cancelAction)
                }
            case .key:
                SHSheetFooter {
                    Button("Cancel", action: close).buttonStyle(.sh(.ghost)).keyboardShortcut(.cancelAction)
                    Button("Save") { session.saveKey() }
                        .buttonStyle(.sh(.primary)).keyboardShortcut(.defaultAction)
                        .disabled(!session.keyCheck.allowsSave || session.phase == .saving)
                }
            }
        }
    }

    private func linkLine(_ text: String, link: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: SH.Space.xs) {
            Text(text).font(.sh(.ui)).foregroundStyle(Color.sh.textTertiary).fixedSize(horizontal: false, vertical: true)
            Button(link, action: action).buttonStyle(.shLink(color: Color.sh.running))
        }
    }

    // MARK: Words

    /// "2 waiting agents picked up where they left off."; nil for none.
    static func pickedUp(_ count: Int) -> String? {
        switch count {
        case 0: nil
        case 1: "1 waiting agent picked up where it left off."
        default: "\(count) waiting agents picked up where they left off."
        }
    }

    /// "deepseek-chat and deepseek-reasoner are ready."
    static func ready(_ models: [String]) -> String {
        switch models.count {
        case 0: ""
        case 1: "\(models[0]) is ready."
        case 2: "\(models[0]) and \(models[1]) are ready."
        default: "\(models.prefix(2).joined(separator: ", ")) and more are ready."
        }
    }

    /// "github.com/login/device" for "https://github.com/login/device".
    static func shortURI(_ uri: String) -> String {
        var text = uri
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        return text
    }
}
