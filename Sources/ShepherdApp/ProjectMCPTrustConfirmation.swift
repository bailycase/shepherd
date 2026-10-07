import SwiftUI
import ShepherdUI

/// The confirmation names the captured host and folder, never a later selection.
struct ProjectMCPTrustConfirmation: View {
    let model: ProjectsModel
    let project: ProjectsRow
    let dismiss: () -> Void

    var body: some View {
        DialogSheet(title: "Trust this project?",
                    subtitle: "Approve \(project.project.displayPath) on \(project.host.name).",
                    actions: [
                        DialogAction("Cancel", kind: .cancel, action: dismiss),
                        DialogAction(model.mcpTrustSaving ? "Saving…" : "Trust project", kind: .prominent) {
                            Task { if await model.approveMCPProject(project) { dismiss() } }
                        },
                    ]) {
            VStack(alignment: .leading, spacing: NW.Space.l) {
                Text("Pi can load this folder's MCP servers, settings, instructions, skills and executable extensions, and install its configured packages. Local MCP servers can run commands on this host. Pi also applies this approval to projects inside this folder. Approve only a project whose contents you trust.")
                    .font(.nw(.ui)).foregroundStyle(Color.nw.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Approval applies to new or restarted threads. It does not confirm server connections or tool availability. Saved OAuth credentials are separate.")
                    .font(.nw(.caption)).foregroundStyle(Color.nw.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let reason = model.mcpTrustError { NWInlineProblem(reason) }
            }
            .padding(.horizontal, NWDialogMetrics.inset)
        }
        .disabled(model.mcpTrustSaving)
        .interactiveDismissDisabled(model.mcpTrustSaving)
    }
}
