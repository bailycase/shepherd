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
            SettingsGroup(title: "Code", footnote: "Work runs in a new worktree on its Mac and comes back as a pushed branch.") {
                SettingsRow(title: "Uncommitted changes") {
                    SHPopupMenu(code.uncommitted.title, minWidth: 0) {
                        ForEach(FleetUncommittedChanges.allCases, id: \.self) { choice in
                            Button(choice.title) { code.setUncommitted(choice) }
                        }
                    }
                    .accessibilityLabel("Uncommitted changes")
                }
                SettingsRow(title: "Ignored files", subtitle: ".env and node_modules travel; build caches stay") {
                    Button("Per space…") { excluding = true }
                        .buttonStyle(.sh(.secondary, size: .s))
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
        SpaceSheet(title: "Ignored files, per space",
                   caption: AnyView(SpaceSheetCaption(text: "Always kept home: .build, DerivedData, virtualenvs, CMake and Cargo targets. One path or name per line.")),
                   width: AppLayout.fleetExcludesWidth) {
            VStack(alignment: .leading, spacing: 0) {
                SpaceSheetLabel("Space")
                Menu {
                    ForEach(spaces) { space in Button(space.name) { commit(); choose(space) } }
                } label: {
                    SpaceSheetField {
                        Text(current?.name ?? "").font(.sh(.ui)).foregroundStyle(Color.sh.textPrimary).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        SHGlyph.popupChevrons.image.font(.shSans(SHSettingsControlMetrics.popupChevronSize)).foregroundStyle(Color.sh.textTertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .accessibilityLabel("Space")
                field("Keep home", text: $home, example: "packages/web/dist")
                field("Send anyway", text: $send, example: ".build")
            }
        } actions: {
            Button("Done") { commit(); done() }.buttonStyle(SpaceBarStyle(kind: .primary)).keyboardShortcut(.defaultAction)
        }
        .onAppear { if let first = spaces.first { choose(first) } }
    }

    private func field(_ label: String, text: Binding<String>, example: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SpaceSheetLabel(text: label, trailing: {
                SettingsOpenIn(text: text, name: label == "Keep home" ? "keep-home.txt" : "send-anyway.txt").id(selection)
            })
            TextEditor(text: text)
                .font(.shMono(AppLayout.fleetExcludeTextSize))
                .scrollContentBackground(.hidden)
                .foregroundStyle(Color.sh.textPrimary)
                .padding(.horizontal, AppLayout.fleetExcludeEditorInset - SH.Space.xs).padding(.vertical, SH.Space.m - SH.Space.xs)
                .frame(height: Self.height(of: text.wrappedValue))
                .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                .overlay { RoundedRectangle(cornerRadius: SH.Radius.m).strokeBorder(Color.sh.lineSubtle) }
                .accessibilityLabel(label)
                .accessibilityHint("One path or name per line, like \(example)")
        }
    }

    /// A box holds its lines on 19pt rows with 17pt over and under: 72pt for two, 52 at least, and it stops growing at six.
    static func height(of text: String) -> CGFloat {
        let lines = min(max(text.split(separator: "\n", omittingEmptySubsequences: false).count, 1), AppLayout.fleetExcludeMaxLines)
        return max(AppLayout.fleetExcludeEditorHeight, CGFloat(lines) * AppLayout.fleetExcludeLine + AppLayout.fleetExcludeEditorPadding)
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
