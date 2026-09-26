import SwiftUI

#Preview("Dialog") {
    @Previewable @State var branch = "agent/calm-stone-3831"
    NWPreviewBoth {
        NWDialog("New worktree", message: "Creates a git worktree beside Shepherd on a new branch and starts an agent in it.") {
            NWSheetRow("Branch") {
                TextField("Branch", text: $branch).textFieldStyle(.nw(mono: true))
            }
            NWSheetRow("Base") {
                Text("origin/main").font(.nw(.mono)).foregroundStyle(.nw.textSecondary)
            }
            NWBanner(.attention, title: "Unreconciled work", message: "2 commits only on this branch will be lost with the worktree.")
                .padding(EdgeInsets(top: NW.Space.l, leading: NWDialogMetrics.inset, bottom: 0, trailing: NWDialogMetrics.inset))
        } status: {
            NWDialogStatus("Fetched origin 2m ago")
        } actions: {
            Button("Cancel") {}.buttonStyle(.nw(.secondary)).keyboardShortcut(.cancelAction)
            Button("Create and open") {}.buttonStyle(.nw(.primary)).keyboardShortcut(.defaultAction)
        }
        .nwCard(radius: NW.Radius.l)
    }
}

#Preview("Checklist") {
    NWPreviewBoth {
        VStack(spacing: 0) {
            NWChecklistRow("commit remaining work", state: .done, detail: "2 files")
            NWChecklistRow("push branch to origin", state: .running)
            NWChecklistRow("create pull request", state: .failed, detail: "gh: not signed in") {
                Button("Open a terminal for gh login…") {}.buttonStyle(.nw(.ghost, size: .s))
            }
            NWChecklistRow("remove worktree", state: .queued, stateLabel: "Pending")
        }
        .frame(width: 460)
        .background(Color.nw.bgWindow)
    }
}

#Preview("Settings navigation") {
    NWPreviewBoth {
        VStack(spacing: 1) {
            NWSettingsNavRow("Appearance", systemImage: "circle.lefthalf.filled", selected: true) {}
            NWSettingsNavRow("Terminal", systemImage: "terminal", selected: false) {}
            NWSettingsNavRow("Pi", systemImage: "pi", selected: false) {}
        }
        .padding(NW.Space.s)
        .frame(width: 232)
        .background(Color.nw.bgBase)
    }
}
