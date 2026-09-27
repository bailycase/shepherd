import SwiftUI
import ShepherdUI
import ShepherdSessions

/// The first launch's welcome step (DESIGN.md › Dialogs and sheets › Welcome): Shepherd runs its
/// own pi, what came over from the user's pi, and sign-in only when no provider can start an
/// agent. Restored agents wait until it closes, whichever way.
struct PiWelcomeSheet: View {
    let welcome: YourPiModel.Welcome
    /// Opens Settings ▸ Pi's sign-in terminal beside the selected agent; nil with none selected.
    var signIn: (() -> Void)?
    let onClose: () -> Void

    /// One thing brought over, as its checklist row shows it.
    struct Row: Equatable, Identifiable {
        let title: String
        let detail: String
        var id: String { title }
    }

    /// What the first copy brought over, and the key variables the login shell sets for providers
    /// with no login: names and kinds, never a value.
    static func rows(_ welcome: YourPiModel.Welcome) -> [Row] {
        let report = welcome.report
        var rows = report.logins.map { Row(title: PiProviders.name($0.provider), detail: YourPiText.detail($0.kind)) }
        if !report.customProviders.isEmpty {
            rows.append(Row(title: "Custom providers", detail: report.customProviders.joined(separator: ", ")))
        }
        if let file = report.instructions { rows.append(Row(title: "Instructions", detail: "\(file), read live")) }
        let folders = (report.skills + report.prompts).filter { !$0.hasPrefix("!") }.count
        if folders > 0 { rows.append(Row(title: "Skills and prompts", detail: "\(YourPiText.count(folders, "folder")), read in place")) }
        if let model = report.defaultModel { rows.append(Row(title: "Default model", detail: model)) }
        if report.trustedFolders > 0 { rows.append(Row(title: "Trusted folders", detail: "\(report.trustedFolders)")) }
        for login in welcome.survey.logins where login.shepherd == nil {
            for name in login.environment where !rows.contains(where: { $0.title == name }) {
                rows.append(Row(title: name, detail: "In your environment"))
            }
        }
        return rows
    }

    var body: some View {
        let rows = Self.rows(welcome)
        DialogSheet(title: "Shepherd runs its own pi",
                    subtitle: "Shepherd now runs its own copy of pi. The pi in your terminal is untouched.",
                    width: AppLayout.piWelcomeSheetWidth,
                    actions: actions) {
            VStack(alignment: .leading, spacing: 0) {
                if !rows.isEmpty {
                    NWSectionHeader("Brought over from your pi")
                        .padding(.horizontal, NWDialogMetrics.inset)
                        .padding(.top, NW.Space.m)
                        .padding(.bottom, NW.Space.s)
                    ForEach(rows) { row in
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
                if !welcome.report.problems.isEmpty {
                    DialogBanner(state: .failed, title: "Some of your pi wasn't brought over",
                                 message: welcome.report.problems.joined(separator: " "))
                }
                if !welcome.survey.canStartAgents {
                    DialogBanner(title: "Sign in so agents can start", message: "Until you do, agents wait with Retry.")
                }
            }
        }
        .onExitCommand(perform: onClose)
    }

    private var actions: [DialogAction] {
        var actions: [DialogAction] = []
        if !welcome.survey.canStartAgents {
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
