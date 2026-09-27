import SwiftUI
import ShepherdUI
import ShepherdSessions

/// The first launch's welcome step (DESIGN.md › Dialogs and sheets › Welcome): Shepherd runs its
/// own pi, what came over from the user's pi, the keys found in the environment, and sign-in only
/// for what is still missing. A new user with no pi sees only sign-in. Restored agents wait until
/// it closes only when no provider can start them (`YourPiModel.Welcome.holdsAgents`).
struct PiWelcomeSheet: View {
    let welcome: YourPiModel.Welcome
    /// Opens Settings ▸ Pi's sign-in terminal beside the selected agent; nil with none selected.
    var signIn: (() -> Void)?
    let onClose: () -> Void

    /// One checklist row: a thing brought over, a key found, or a sign-in still missing.
    struct Row: Equatable, Identifiable {
        let title: String
        let detail: String
        var id: String { title }
    }

    /// The step's rows by section: names and kinds, never a value.
    struct Sections: Equatable {
        /// What the first copy brought over or reads live.
        var broughtOver: [Row] = []
        /// Key variables the login shell sets for providers with no login in Shepherd's pi.
        var environment: [Row] = []
        /// Providers the default model needs and nothing signs in to; empty when no provider at
        /// all can start an agent (the sign-in banner says so instead).
        var missing: [Row] = []
    }

    static func sections(_ welcome: YourPiModel.Welcome) -> Sections {
        let report = welcome.report
        var sections = Sections()
        var rows = report.logins.map { Row(title: PiProviders.name($0.provider), detail: YourPiText.detail($0.kind)) }
        if !report.customProviders.isEmpty {
            rows.append(Row(title: "Custom providers", detail: report.customProviders.joined(separator: ", ")))
        }
        if let file = report.instructions { rows.append(Row(title: "Instructions", detail: "\(file), read live")) }
        let folders = (report.skills + report.prompts).filter { !$0.hasPrefix("!") }.count
        if folders > 0 { rows.append(Row(title: "Skills and prompts", detail: "\(YourPiText.count(folders, "folder")), read in place")) }
        if let model = report.defaultModel { rows.append(Row(title: "Default model", detail: model)) }
        if report.trustedFolders > 0 { rows.append(Row(title: "Trusted folders", detail: "\(report.trustedFolders)")) }
        sections.broughtOver = rows
        for login in welcome.survey.logins where login.shepherd == nil {
            for name in login.environment where !sections.environment.contains(where: { $0.title == name }) {
                sections.environment.append(Row(title: name, detail: login.name))
            }
        }
        if welcome.survey.canStartAgents {
            sections.missing = welcome.missing.map { Row(title: PiProviders.name($0), detail: "Not signed in") }
        }
        return sections
    }

    /// A user with no pi of their own sees only sign-in.
    private var hasTheirPi: Bool { welcome.report.from != nil }

    var body: some View {
        let sections = Self.sections(welcome)
        DialogSheet(title: hasTheirPi ? "Shepherd runs its own pi" : "Sign in to a provider",
                    subtitle: hasTheirPi ? "Shepherd now runs its own copy of pi. The pi in your terminal is untouched."
                        : "Agents run on Shepherd's own copy of pi, and need a provider to reach a model.",
                    width: AppLayout.piWelcomeSheetWidth,
                    actions: actions) {
            VStack(alignment: .leading, spacing: 0) {
                if !sections.broughtOver.isEmpty {
                    header("Brought over from your pi")
                    ForEach(sections.broughtOver) { row in
                        NWChecklistRow(row.title, state: .done, stateLabel: "brought over", detail: row.detail)
                    }
                    if welcome.report.logins.contains(where: { $0.kind == .subscription }) {
                        Text("Sign-ins were copied once. When one side refreshes a subscription, the other may be signed out: sign in again there.")
                            .font(.nw(.caption))
                            .foregroundStyle(Color.nw.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, NWDialogMetrics.inset)
                            .padding(.top, NW.Space.m)
                    }
                }
                if !sections.environment.isEmpty {
                    header("Found in your environment")
                    ForEach(sections.environment) { row in
                        NWChecklistRow(row.title, state: .done, stateLabel: "found", detail: row.detail)
                    }
                }
                if !welcome.report.problems.isEmpty {
                    DialogBanner(state: .failed, title: "Some of your pi wasn't brought over",
                                 message: welcome.report.problems.joined(separator: " "))
                }
                if !sections.missing.isEmpty {
                    header("Still needed")
                    ForEach(sections.missing) { row in
                        NWChecklistRow(row.title, state: .attention, stateLabel: "not signed in", detail: row.detail)
                    }
                }
                if !welcome.survey.canStartAgents {
                    DialogBanner(title: "Sign in so agents can start", message: "Until you do, agents wait with Retry.")
                }
            }
        }
        .onExitCommand(perform: onClose)
    }

    private func header(_ title: String) -> some View {
        NWSectionHeader(title)
            .padding(.horizontal, NWDialogMetrics.inset)
            .padding(.top, NW.Space.m)
            .padding(.bottom, NW.Space.s)
    }

    private var actions: [DialogAction] {
        var actions: [DialogAction] = []
        if welcome.asksToSignIn {
            actions.append(DialogAction("Sign in…", isEnabled: signIn != nil,
                                        help: signIn == nil ? "Open an agent first, then sign in from Settings ▸ Pi." : nil) {
                signIn?()
                onClose()
            })
        }
        actions.append(DialogAction("Continue", kind: .prominent, action: onClose))
        return actions
    }
}
