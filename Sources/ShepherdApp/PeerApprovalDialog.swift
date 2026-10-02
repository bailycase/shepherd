import SwiftUI
import ShepherdSessions
import ShepherdUI

/// An agent's call on another thread, waiting for the user (Settings ▸ Pi ▸ Agent-to-agent
/// messages is Ask me): the same anatomy as `PeerDeleteDialog`. Only its buttons answer: Allow
/// once, Allow for this thread, or Deny (⎋); the sheet closes no other way. No button is the ⏎
/// default, so a Return typed as it appears never allows anything. Two minutes without an answer
/// is a Deny, made by the server.
struct PeerApprovalDialog: View {
    let presentation: PeerApprovalPresentation
    let answer: (AgentApprovalDecision) -> Void

    /// Deny is the ⎋ cancel action; neither Allow is prominent (no ⏎ default) or destructive.
    static func actions(_ answer: @escaping (AgentApprovalDecision) -> Void) -> [DialogAction] {
        [
            DialogAction("Deny", kind: .cancel) { answer(.deny) },
            DialogAction("Allow for this thread") { answer(.allowForThread) },
            DialogAction("Allow once") { answer(.allowOnce) },
        ]
    }

    var body: some View {
        DialogSheet(
            title: presentation.title,
            subtitle: presentation.subtitle,
            actions: Self.actions(answer)
        ) {
            ForEach(presentation.rows) { row in
                SheetRow(row.label) { value(row) }
            }
            if let label = presentation.textLabel, let text = presentation.text {
                SheetRow(label, alignment: .top) { message(text) }
            }
            // Not the footer's status: three buttons at a large text size leave it no room.
            if let status = presentation.status {
                Text(status)
                    .nwText(.caption)
                    .foregroundStyle(Color.nw.textSecondary)
                    .padding(.horizontal, NWDialogMetrics.inset)
                    .padding(.top, NW.Space.l)
            }
            Text(presentation.note)
                .nwText(.caption)
                .foregroundStyle(Color.nw.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, NWDialogMetrics.inset)
                .padding(.top, NW.Space.l)
        }
    }

    @ViewBuilder
    private func value(_ row: PeerApprovalPresentation.Row) -> some View {
        switch row.style {
        case .name:
            Text(row.value)
                .nwText(.ui)
                .foregroundStyle(Color.nw.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(row.value)
        case .secondary:
            Text(row.value)
                .nwText(.ui)
                .foregroundStyle(Color.nw.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        case .mono:
            Text(row.value)
                .font(.nw(.mono))
                .foregroundStyle(Color.nw.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(row.value)
                .textSelection(.enabled)
        }
    }

    /// The message as the agent wrote it: selectable, as tall as it is up to the limit, then scrolling.
    /// The scroll view is offered no height (`fixedSize`), so it is as tall as its text, and the frame
    /// stops it at the limit.
    private func message(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .nwText(.body)
                .foregroundStyle(Color.nw.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: AppLayout.peerApprovalTextMaxHeight)
        .fixedSize(horizontal: false, vertical: true)
    }
}
