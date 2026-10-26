import SwiftUI

#Preview("Dialog") {
    @Previewable @State var branch = "agent/calm-stone-3831"
    SHPreviewBoth {
        SHDialog("New worktree", message: "Creates a git worktree beside Shepherd on a new branch and starts an agent in it.") {
            SHSheetRow("Branch") {
                TextField("Branch", text: $branch).textFieldStyle(.sh(mono: true))
            }
            SHSheetRow("Base") {
                Text("origin/main").font(.sh(.mono)).foregroundStyle(.sh.textSecondary)
            }
            SHBanner(.attention, title: "Unreconciled work", message: "2 commits only on this branch will be lost with the worktree.")
                .padding(EdgeInsets(top: SH.Space.l, leading: SHDialogMetrics.inset, bottom: 0, trailing: SHDialogMetrics.inset))
        } status: {
            SHDialogStatus("Fetched origin 2m ago")
        } actions: {
            Button("Cancel") {}.buttonStyle(.sh(.ghost)).keyboardShortcut(.cancelAction)
            Button("Create and open") {}.buttonStyle(.sh(.primary)).keyboardShortcut(.defaultAction)
        }
        .shCard(radius: SH.Radius.l)
    }
}

#Preview("Checklist") {
    SHPreviewBoth {
        VStack(spacing: 0) {
            SHChecklistRow("commit remaining work", state: .done, detail: "2 files")
            SHChecklistRow("push branch to origin", state: .running)
            SHChecklistRow("create pull request", state: .failed, detail: "gh: not signed in") {
                Button("Open a terminal for gh login…") {}.buttonStyle(.sh(.ghost, size: .s))
            }
            SHChecklistRow("remove worktree", state: .queued, stateLabel: "Pending")
        }
        .frame(width: 460)
        .background(Color.sh.bgWindow)
    }
}

#Preview("Settings navigation") {
    SHPreviewBoth {
        VStack(spacing: 1) {
            SHSettingsNavRow("Appearance", systemImage: "circle.lefthalf.filled", selected: true) {}
            SHSettingsNavRow("Terminal", systemImage: "terminal", selected: false) {}
            SHSettingsNavRow("Pi", systemImage: "pi", selected: false) {}
        }
        .padding(SH.Space.s)
        .frame(width: 232)
        .background(Color.sh.bgBase)
    }
}
