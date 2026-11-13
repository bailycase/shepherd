import SwiftUI
import ShepherdCore
import ShepherdUI

/// What Settings ▸ Fleet ▸ Code edits (FleetSettings): whether a dispatch carries the checkout's uncommitted changes, and, per space, what
/// stays home when its checkout is sent. Plain values and closures, so the page previews without a host.
struct FleetCodeSettings {
    var uncommitted: FleetUncommittedChanges
    var setUncommitted: (FleetUncommittedChanges) -> Void
    var spaces: [FleetExcludeSpace]
    var setExcludes: (SpaceID, FleetSnapshotExcludes) -> Void
}

/// A space with a repository, and what it keeps home or sends against the defaults.
struct FleetExcludeSpace: Identifiable, Equatable {
    var id: SpaceID
    var name: String
    var excludes: FleetSnapshotExcludes
}

extension FleetUncommittedChanges {
    /// The words of the popup.
    var title: String {
        switch self {
        case .sendThem: "Send them along"
        case .leaveBehind: "Leave them behind"
        }
    }
}

extension FleetSettings {
    static let codeFootnote = "Work runs in a new worktree on its Mac and comes back as a pushed branch. Nothing is applied to your checkout on its own."
    /// FleetSettings' row, reworded: ignored files travel (Q8), only build caches that break when moved stay home.
    static let ignoredFilesDetail = "Files git ignores, like .env and node_modules, travel with the work. Build caches that break when moved stay home. A space can change that."

    /// The Code group: the two rows that exist (the clone row waits for cloning).
    @ViewBuilder var codeGroup: some View {
        if let code {
            SettingsGroup(title: "Code", footnote: Self.codeFootnote) {
                SettingsRow(title: "Uncommitted changes", subtitle: "When a thread sends work from a checkout with edits that aren't committed.") {
                    SHPopupMenu(code.uncommitted.title, minWidth: AppLayout.settingsPopupWidth) {
                        ForEach(FleetUncommittedChanges.allCases, id: \.self) { choice in
                            Button(choice.title) { code.setUncommitted(choice) }
                        }
                    }
                    .accessibilityLabel("Uncommitted changes")
                }
                SettingsRow(title: "Ignored files", subtitle: Self.ignoredFilesDetail) {
                    Button("Per space…") { excluding = true }
                        .buttonStyle(.sh(.secondary))
                        .disabled(code.spaces.isEmpty)
                }
            }
        }
    }
}

/// Ignored files · Per space…: one space at a time, the paths it keeps home beyond the defaults and the ones it sends although a default
/// would keep them. A path with a "/" names that folder or file; a bare name matches at any depth.
struct FleetExcludesSheet: View {
    let spaces: [FleetExcludeSpace]
    let save: (SpaceID, FleetSnapshotExcludes) -> Void
    let done: () -> Void

    @State private var selection: SpaceID?
    @State private var home = ""
    @State private var send = ""

    private var current: FleetExcludeSpace? { spaces.first { $0.id == selection } ?? spaces.first }

    var body: some View {
        DialogSheet(title: "Ignored files, per space",
                    subtitle: "Always kept home: Swift .build, Xcode DerivedData, Python virtualenvs, CMake build trees and a Cargo target. List more below, or name one of those to send it anyway. One path or name per line.",
                    actions: [DialogAction("Done", kind: .prominent) { commit(); done() }]) {
            VStack(alignment: .leading, spacing: SH.Space.l) {
                SHPopupMenu(current?.name ?? "", minWidth: AppLayout.settingsPopupWidth) {
                    ForEach(spaces) { space in Button(space.name) { commit(); choose(space) } }
                }
                .accessibilityLabel("Space")
                field("Keep home", text: $home, example: "packages/web/dist")
                field("Send anyway", text: $send, example: ".build")
            }
            .dialogInset()
        }
        .onAppear { if let first = spaces.first { choose(first) } }
    }

    private func field(_ label: String, text: Binding<String>, example: String) -> some View {
        VStack(alignment: .leading, spacing: SH.Space.xs) {
            Text(label).font(.sh(.ui, weight: .medium)).foregroundStyle(Color.sh.textPrimary)
            TextEditor(text: text)
                .font(.sh(.mono))
                .scrollContentBackground(.hidden)
                .foregroundStyle(Color.sh.textSecondary)
                .padding(SH.Space.m)
                .frame(height: AppLayout.fleetExcludeEditorHeight)
                .background(Color.sh.bgBase, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                .shBorder(Color.sh.lineSubtle, radius: SH.Radius.m)
                .accessibilityLabel(label)
                .accessibilityHint("One path or name per line, like \(example)")
        }
    }

    private func choose(_ space: FleetExcludeSpace) {
        selection = space.id
        home = space.excludes.excluded.joined(separator: "\n")
        send = space.excludes.included.joined(separator: "\n")
    }

    /// The text boxes as the space's lists, written when the space changes or the sheet closes.
    private func commit() {
        guard let space = current else { return }
        func lines(_ text: String) -> [String] {
            text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let excludes = FleetSnapshotExcludes(excluded: lines(home), included: lines(send))
        if excludes != space.excludes { save(space.id, excludes) }
    }
}
