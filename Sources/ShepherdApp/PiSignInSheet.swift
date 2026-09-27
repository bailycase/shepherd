import SwiftUI
import ShepherdUI
import ShepherdSessions

/// Sign in to <provider> (DESIGN.md › Dialogs and sheets › Sign in to <provider>; SignInBrowser,
/// SignInDevice, SignInPaste, SignInKey, SignInPortBusy): one sheet, four flows, over Settings or
/// the first launch's sheet. pi's own login runs behind it; this only draws where it stands.
struct PiSignInSheet: View {
    @Bindable var session: PiSignInSession
    let close: () -> Void
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NWSheetHeader(title, subtitle: subtitle, leading: .badge(PiSignInCatalog.badge(session.provider)), close: close)
            content
                .padding(.top, 18)
                .padding(.horizontal, NWPiSignInMetrics.sheetInset)
                .padding(.bottom, 20)
            footer
        }
        .frame(width: NWPiSignInMetrics.sheetWidth)
        .background(Color.nw.bgWindow)
        .nwAnimation(.disclosure, value: session.phase)
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
            VStack(alignment: .leading, spacing: 14) {
                NWFailureBox("Another sign-in is using localhost:\(port)",
                             detail: "Probably Codex CLI or your terminal pi’s /login, mid-way. Finish or cancel it there, then try again.")
                NWSignInSteps {
                    NWSignInStepRow("Open \(site) in your browser", state: .pending)
                    NWSignInStepRow("Save the sign-in to Shepherd’s pi", state: .pending)
                }
                if session.subscription?.pasteNeedsPort != true {
                    linkLine("Or skip the browser hand-off: sign in on \(site) and paste the code it shows.", link: "Paste a code instead") {
                        session.pasteInstead()
                    }
                }
            }
        default:
            VStack(alignment: .leading, spacing: 14) {
                NWSignInSteps { browserSteps(site: site) }
                if session.phase.isLive, session.phase != .saving {
                    linkLine("Browser on another computer?", link: "Paste a code instead") { session.pasteInstead() }
                }
            }
        }
    }

    @ViewBuilder private func browserSteps(site: String) -> some View {
        switch session.phase {
        case .starting:
            NWSignInStepRow("Open \(site) in your browser", state: .now)
            NWSignInStepRow("Waiting for you in the browser", state: .pending)
            NWSignInStepRow("Save the sign-in to Shepherd’s pi", state: .pending)
        case .done(let pickedUp):
            NWSignInStepRow("Opened \(site) in your browser", state: .done)
            NWSignInStepRow("Signed in", note: session.subscription?.plan, state: .done)
            NWSignInStepRow("Saved to Shepherd’s pi", note: Self.pickedUp(pickedUp), state: .done)
        case .failed(let reason):
            NWSignInStepRow("Opened \(site) in your browser", state: .done)
            NWSignInStepRow("\(site) didn’t sign you in", note: reason, state: .failed)
            NWSignInStepRow("Save the sign-in to Shepherd’s pi", note: "Nothing was saved.", state: .pending)
        case .saving:
            NWSignInStepRow("Opened \(site) in your browser", state: .done)
            NWSignInStepRow("Approved", state: .done)
            NWSignInStepRow("Saving the sign-in to Shepherd’s pi", state: .now)
        default:
            NWSignInStepRow("Opened \(site) in your browser", state: .done)
            NWSignInStepRow("Waiting for you in the browser",
                            note: "Approve Shepherd on \(site). This closes by itself when you’re done.", state: .now)
            NWSignInStepRow("Save the sign-in to Shepherd’s pi", state: .pending)
        }
    }

    @ViewBuilder private var paste: some View {
        let site = session.site
        switch session.phase {
        case .done(let pickedUp):
            NWSignInSteps {
                NWSignInStepRow("Signed in", note: session.subscription?.plan, state: .done)
                NWSignInStepRow("Saved to Shepherd’s pi", note: Self.pickedUp(pickedUp), state: .done)
            }
        case .failed(let reason):
            NWFailureBox("The sign-in didn’t finish", detail: reason)
        default:
            let rejected: String? = if case .paste(let reason) = session.phase { reason } else { nil }
            VStack(alignment: .leading, spacing: 14) {
                Text("After you approve Shepherd, \(site) shows a code. Paste it here to finish.")
                    .nwText(size: 13, lineHeight: 1.5)
                    .foregroundStyle(Color.nw.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: NW.Space.s) {
                    NWFieldLabel("Code from \(site)")
                    TextField("Paste the code", text: $session.code)
                        .textFieldStyle(.nw(mono: true, error: rejected != nil))
                        .focused($fieldFocused)
                        .disabled(session.phase == .saving)
                        .onSubmit { session.submitCode() }
                        .accessibilityLabel("Code from \(site)")
                    if let rejected {
                        Text(rejected).font(.nw(.caption)).foregroundStyle(Color.nw.failed).fixedSize(horizontal: false, vertical: true)
                    } else if session.phase == .saving {
                        Text("Checking the code with \(site)").font(.nw(.caption)).nwShimmer(active: true).foregroundStyle(Color.nw.textTertiary)
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
            VStack(alignment: .leading, spacing: 14) {
                (Text("Enter this code at ") + Text(Self.shortURI(uri)).font(.nwMono(12.5)).foregroundColor(Color.nw.textPrimary)
                    + Text(". It’s already on your clipboard."))
                    .nwText(size: 13, lineHeight: 1.5)
                    .foregroundStyle(Color.nw.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: NW.Space.m) {
                    NWDeviceCode(code)
                    HStack(spacing: NW.Space.m) {
                        Button { session.copyCode() } label: { Label("Copy", systemImage: "doc.on.doc") }
                            .buttonStyle(.nw(.ghost, size: .s))
                        Button { session.openDevicePage() } label: { Label("Open \(site)", systemImage: "arrow.up.forward.square") }
                            .buttonStyle(.nw(.secondary, size: .s))
                    }
                }
                NWSignInSteps {
                    NWSignInStepRow("Waiting for you to enter the code",
                                    note: expires.map { "The code works until \($0.formatted(date: .omitted, time: .shortened))." }, state: .now)
                }
            }
        case .done(let pickedUp):
            NWSignInSteps {
                NWSignInStepRow("Signed in", note: session.subscription?.plan, state: .done)
                NWSignInStepRow("Saved to Shepherd’s pi", note: Self.pickedUp(pickedUp), state: .done)
            }
        case .failed(let reason):
            NWSignInSteps {
                NWSignInStepRow("\(site) didn’t sign you in", note: reason, state: .failed)
                NWSignInStepRow("Save the sign-in to Shepherd’s pi", note: "Nothing was saved.", state: .pending)
            }
        default:
            NWSignInSteps {
                NWSignInStepRow("Asking \(site) for a code", state: .now)
                NWSignInStepRow("Waiting for you to enter the code", state: .pending)
            }
        }
    }

    @ViewBuilder private var keyForm: some View {
        switch session.phase {
        case .done(let pickedUp):
            NWSignInSteps {
                NWSignInStepRow("Works", state: .done)
                NWSignInStepRow("Saved to Shepherd’s pi", note: Self.pickedUp(pickedUp), state: .done)
            }
        case .failed(let reason):
            NWFailureBox("The key wasn’t saved", detail: reason)
        default:
            VStack(alignment: .leading, spacing: 14) {
                NWSegmentedPicker("How the key is given", selection: Binding(get: { session.keyMode }, set: { session.setKeyMode($0) }),
                                  options: [(.paste, "Paste a key"), (.variable, "Environment variable")])
                    .fixedSize()
                VStack(alignment: .leading, spacing: NW.Space.s) {
                    if session.keyMode == .paste {
                        NWFieldLabel("API key")
                        SecureField("Paste the key", text: $session.key)
                            .textFieldStyle(.nw(mono: true, error: rejected))
                            .focused($fieldFocused)
                            .onSubmit { session.saveKey() }
                            .accessibilityLabel("API key")
                    } else {
                        NWFieldLabel("Variable name")
                        TextField(PiProviders.environmentKeys[session.provider]?.first.map { "$" + $0 } ?? "$PROVIDER_API_KEY",
                                  text: $session.variable)
                            .textFieldStyle(.nw(mono: true, error: rejected))
                            .focused($fieldFocused)
                            .onSubmit { session.saveKey() }
                            .accessibilityLabel("Variable name")
                        Text("Read from your login shell each time an agent starts.")
                            .font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
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
            Text("Checking the key with \(name)").font(.nw(.caption)).nwShimmer(active: true).foregroundStyle(Color.nw.textTertiary)
        case .works(let models):
            HStack(alignment: .firstTextBaseline, spacing: NW.Space.s) {
                Text("Works.").font(.nw(.caption, weight: .medium)).foregroundStyle(Color.nw.done)
                if !models.isEmpty {
                    Text(Self.ready(models)).font(.nw(.caption)).foregroundStyle(Color.nw.textSecondary)
                }
            }
        case .rejected(let reason):
            Text("\(name) rejected this key (\(reason)).").font(.nw(.caption)).foregroundStyle(Color.nw.failed)
                .fixedSize(horizontal: false, vertical: true)
        case .unreachable(let reason):
            Text("Couldn’t reach \(name) to check it. \(reason)").font(.nw(.caption)).foregroundStyle(Color.nw.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        case .unset(let reason):
            Text(reason).font(.nw(.caption)).foregroundStyle(Color.nw.failed)
        }
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        switch session.phase {
        case .done:
            NWSheetFooter {
                Button("Done", action: close).buttonStyle(.nw(.primary)).keyboardShortcut(.defaultAction)
            }
        case .failed(let reason):
            NWSheetFooter {
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(reason, forType: .string) } label: {
                    Label("Copy details", systemImage: "doc.on.doc")
                }
                .buttonStyle(.nw(.ghost))
            } actions: {
                Button("Close", action: close).buttonStyle(.nw(.ghost)).keyboardShortcut(.cancelAction)
                Button { session.tryAgain() } label: { Label("Try again", systemImage: "arrow.clockwise") }
                    .buttonStyle(.nw(.primary)).keyboardShortcut(.defaultAction)
            }
        case .portBusy:
            NWSheetFooter {
                Button("Cancel", action: close).buttonStyle(.nw(.ghost)).keyboardShortcut(.cancelAction)
                Button { session.tryAgain() } label: { Label("Try again", systemImage: "arrow.clockwise") }
                    .buttonStyle(.nw(.primary)).keyboardShortcut(.defaultAction)
            }
        default:
            switch session.flow {
            case .browser:
                NWSheetFooter {
                    Button { session.copyLink() } label: { Label("Copy link", systemImage: "doc.on.doc") }
                        .buttonStyle(.nw(.ghost))
                        .disabled(session.authURL == nil)
                } actions: {
                    Button("Cancel", action: close).buttonStyle(.nw(.ghost)).keyboardShortcut(.cancelAction)
                    Button { session.openBrowserAgain() } label: { Label("Open browser again", systemImage: "arrow.up.forward.square") }
                        .buttonStyle(.nw(.secondary))
                        .disabled(session.authURL == nil)
                }
            case .paste:
                NWSheetFooter {
                    Button("Open \(session.site) again") { session.reopenForCode() }.buttonStyle(.nw(.ghost))
                } actions: {
                    Button("Cancel", action: close).buttonStyle(.nw(.ghost)).keyboardShortcut(.cancelAction)
                    Button("Continue") { session.submitCode() }
                        .buttonStyle(.nw(.primary)).keyboardShortcut(.defaultAction)
                        .disabled(session.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.phase == .saving)
                }
            case .device:
                NWSheetFooter {
                    Button("Cancel", action: close).buttonStyle(.nw(.ghost)).keyboardShortcut(.cancelAction)
                }
            case .key:
                NWSheetFooter {
                    Button("Cancel", action: close).buttonStyle(.nw(.ghost)).keyboardShortcut(.cancelAction)
                    Button("Save") { session.saveKey() }
                        .buttonStyle(.nw(.primary)).keyboardShortcut(.defaultAction)
                        .disabled(!session.keyCheck.allowsSave || session.phase == .saving)
                }
            }
        }
    }

    private func linkLine(_ text: String, link: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: NW.Space.xs) {
            Text(text).font(.nw(.ui)).foregroundStyle(Color.nw.textTertiary).fixedSize(horizontal: false, vertical: true)
            Button(link, action: action).buttonStyle(.nwLink(color: Color.nw.running))
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
