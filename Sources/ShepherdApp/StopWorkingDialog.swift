import SwiftUI
import ShepherdRemote
import ShepherdUI

/// Asks before Stop all working threads stops them: the count in the title, then the first few by name.
struct StopWorkingDialog: View {
    let targets: [StopAllWorking.Target]
    let stop: () -> Void
    let cancel: () -> Void

    /// Longer lists end in "and n more".
    static let listLimit = 5

    var body: some View {
        DialogSheet(title: StopAllWorking.confirmTitle(count: targets.count), subtitle: StopAllWorking.confirmMessage,
                    actions: [
                        DialogAction("Cancel", kind: .cancel, action: cancel),
                        DialogAction(StopAllWorking.confirmButton, kind: .destructive, action: stop),
                    ]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(targets.prefix(Self.listLimit), id: \.self) { target in
                    HStack(spacing: SH.Space.m) {
                        SHStatusDot(.running)
                        Text(target.name)
                            .font(.sh(.ui))
                            .foregroundStyle(Color.sh.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(minHeight: SH.Height.rowCompact)
                    .accessibilityElement(children: .combine)
                }
                if targets.count > Self.listLimit {
                    Text("and \(targets.count - Self.listLimit) more")
                        .shText(.caption)
                        .foregroundStyle(Color.sh.textTertiary)
                        .frame(minHeight: SH.Height.rowCompact)
                }
            }
            .padding(.horizontal, SHDialogMetrics.inset)
        }
    }
}
