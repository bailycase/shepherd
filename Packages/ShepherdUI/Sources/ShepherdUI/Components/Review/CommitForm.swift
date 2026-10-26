import SwiftUI

// The commit from review's parts (MobileCommit and iPadCommit boards, and the Mac's review pane
// sheet): the message card, a file row with its checkbox, and an option row with its switch.
// Each sheet composes them with its own chrome: a phone sheet, an iPad popover, a Mac dialog.

public enum SHCommitFormMetrics {
    /// A file row: a touch target on iOS, a list row on the Mac.
    @MainActor public static var fileRowHeight: CGFloat {
        #if os(iOS)
        SH.Height.touch
        #else
        SH.Height.row
        #endif
    }

    /// An option row: the boards' 52pt on iOS, a dialog row on the Mac.
    @MainActor public static var optionRowHeight: CGFloat {
        #if os(iOS)
        SH.Height.scaled(52)
        #else
        SHDialogMetrics.rowMinHeight
        #endif
    }
}

/// The commit's message as a card: the summary line in semibold over the description, and a note
/// saying where it came from ("Drafted from the diff · edit anything"), or a spinner while the
/// host drafts it. Once an edited message may mention files since left out, the note says so
/// instead. Both fields edit in place.
public struct SHCommitMessageEditor: View {
    public enum Source: Sendable, Equatable {
        /// The host is drafting it from the diff.
        case drafting
        /// Drafted from the diff by a model.
        case drafted
        /// Written from the file list.
        case written
    }

    @Binding var title: String
    @Binding var message: String
    let source: Source
    let mentionsUntickedFiles: Bool
    let radius: CGFloat
    let fill: Color?

    public init(title: Binding<String>, message: Binding<String>, source: Source, mentionsUntickedFiles: Bool = false,
                radius: CGFloat = SH.Radius.m, fill: Color? = nil) {
        _title = title
        _message = message
        self.source = source
        self.mentionsUntickedFiles = mentionsUntickedFiles
        self.radius = radius
        self.fill = fill
    }

    public var body: some View {
        let sh = Color.sh
        // Both fields take their ideal height: a sheet sized to its content proposes a field the
        // height it had, so text set from outside (the host's message, a draft) stayed clipped to it.
        VStack(alignment: .leading, spacing: SH.Space.s) {
            TextField("Summary", text: $title, prompt: Text("Summary").foregroundStyle(sh.textTertiary), axis: .vertical)
                .lineLimit(1...3)
                .fixedSize(horizontal: false, vertical: true)
                .font(.sh(.body, weight: .semibold))
                .foregroundStyle(sh.textPrimary)
                .accessibilityLabel("Commit summary")
            TextField("Description", text: $message, prompt: Text("Description (optional)").foregroundStyle(sh.textTertiary), axis: .vertical)
                .lineLimit(1...8)
                .fixedSize(horizontal: false, vertical: true)
                .font(.sh(.ui, weight: .regular))
                .foregroundStyle(sh.textSecondary)
                .accessibilityLabel("Commit description")
            HStack(spacing: SH.Space.s) {
                if source == .drafting && !mentionsUntickedFiles {
                    ProgressView().progressViewStyle(.shSpinner).controlSize(.mini)
                } else {
                    Image(systemName: mentionsUntickedFiles ? "exclamationmark.circle" : source == .drafted ? "sparkle" : "list.bullet")
                        .font(.sh(.micro))
                        .accessibilityHidden(true)
                }
                Text(note)
                    .font(.sh(.caption))
            }
            .foregroundStyle(sh.textTertiary)
            .shContentTransition(.crossFade)
            .shComponentAnimation(.content, value: source)
            .shComponentAnimation(.content, value: mentionsUntickedFiles)
            .accessibilityElement(children: .combine)
        }
        .textFieldStyle(.plain)
        .tint(sh.lantern)
        .padding(.horizontal, SH.Space.l + SH.Space.xxs)
        .padding(.vertical, SH.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shCard(radius: radius, fill: fill, line: sh.lineStrong)
    }

    private var note: String {
        // An edited message keeps what was typed, whatever a draft brings.
        if mentionsUntickedFiles { return "May mention files you unticked" }
        return switch source {
        case .drafting: "Drafting from the diff…"
        case .drafted: "Drafted from the diff · edit anything"
        case .written: "Written from the file list · edit anything"
        }
    }
}

/// A file the commit can take: its checkbox (lantern when it goes in), the filename in mono with
/// its directory, and the diff stat. The whole row toggles. Equal on its values.
public struct SHCommitFileRow: View, Equatable {
    public struct Item: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let directory: String
        public let status: SHFileStatus
        public let added: Int
        public let removed: Int
        public let selected: Bool

        public init(id: String, name: String, directory: String, status: SHFileStatus, added: Int, removed: Int, selected: Bool) {
            self.id = id
            self.name = name
            self.directory = directory
            self.status = status
            self.added = added
            self.removed = removed
            self.selected = selected
        }
    }

    let item: Item
    let showsDirectory: Bool
    let toggle: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    /// `showsDirectory` draws the directory after the name (the Mac); the phone and iPad boards
    /// show the name alone, and VoiceOver reads the directory either way.
    public init(_ item: Item, showsDirectory: Bool = true, toggle: @escaping () -> Void) {
        self.item = item
        self.showsDirectory = showsDirectory
        self.toggle = toggle
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.item == rhs.item && lhs.showsDirectory == rhs.showsDirectory }

    public var body: some View {
        let sh = Color.sh
        Button(action: toggle) {
            HStack(spacing: SH.Space.m) {
                Toggle(item.name, isOn: .constant(item.selected))
                    .toggleStyle(.shCheckbox)
                    .labelsHidden()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                // At accessibility sizes the directory and stat move under the name.
                let stacked = typeSize.isAccessibilitySize
                let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: SH.Space.xxs))
                    : AnyLayout(HStackLayout(spacing: SH.Space.s))
                layout {
                    Text(item.name)
                        .font(.sh(.code))
                        .foregroundStyle(item.selected ? sh.textPrimary : sh.textSecondary)
                        .lineLimit(stacked ? 3 : 1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    if showsDirectory && !item.directory.isEmpty {
                        Text(item.directory)
                            .font(.sh(.micro, weight: .regular))
                            .foregroundStyle(sh.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    if stacked { SHDiffStat(added: item.added, removed: item.removed, font: .sh(.micro, weight: .regular)) }
                }
                Spacer(minLength: SH.Space.s)
                if !stacked { SHDiffStat(added: item.added, removed: item.removed, font: .sh(.micro, weight: .regular)) }
            }
            .padding(.horizontal, SH.Space.l + SH.Space.xxs)
            .padding(.vertical, SH.Space.xs)
            .frame(minHeight: SHCommitFormMetrics.fileRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityValue(item.selected ? "Selected" : "Not selected")
        .accessibilityHint(item.selected ? "Leaves the file out of the commit" : "Puts the file in the commit")
        .accessibilityAddTraits(.isToggle)
    }

    private var accessibilityText: String {
        var parts = [item.name]
        if !item.directory.isEmpty { parts.append("in \(item.directory)") }
        parts += [item.status.label, "\(item.added) added, \(item.removed) removed"]
        return parts.joined(separator: ", ")
    }
}

/// An option of the commit ("Push after commit" over "origin/main") with its switch. On iOS the
/// whole row toggles.
public struct SHCommitOptionRow: View {
    let title: String
    let detail: String?
    let monoDetail: Bool
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var enabled

    public init(_ title: String, detail: String? = nil, monoDetail: Bool = false, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self.monoDetail = monoDetail
        _isOn = isOn
    }

    public var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.l) {
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(title).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textPrimary)
                if let detail {
                    Text(detail)
                        .font(monoDetail ? .sh(.mono) : .sh(.caption))
                        .foregroundStyle(sh.textTertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: $isOn)
                .toggleStyle(.shSwitch)
                .labelsHidden()
        }
        .padding(.horizontal, SH.Space.l + SH.Space.xxs)
        .padding(.vertical, SH.Space.m)
        .frame(minHeight: SHCommitFormMetrics.optionRowHeight)
        .contentShape(Rectangle())
        #if os(iOS)
        .onTapGesture { if enabled { isOn.toggle() } }
        #endif
        .shEnabledOpacity(enabled)
        .accessibilityRepresentation {
            Toggle(isOn: $isOn) {
                Text(title)
                if let detail { Text(detail) }
            }
        }
    }
}

#Preview("Commit form") {
    @Previewable @State var title = "Show commands and paths in tool rows"
    @Previewable @State var message = "Tool rows now preview the command or path instead of \u{201C}complete\u{201D}."
    @Previewable @State var push = true
    @Previewable @State var pr = false
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: SH.Space.l) {
            SHCommitMessageEditor(title: $title, message: $message, source: .drafted)
            SHCommitMessageEditor(title: .constant("Update 3 files in App/iOS"), message: .constant(""), source: .drafting)
            SHCommitMessageEditor(title: .constant("Show tool rows' commands"), message: .constant("Also covers FleetView."), source: .drafted,
                                  mentionsUntickedFiles: true)
            VStack(spacing: 0) {
                SHCommitFileRow(.init(id: "a", name: "DesktopNativeThreadView.swift", directory: "Sources/ShepherdApp/", status: .modified,
                                      added: 58, removed: 41, selected: true)) {}
                SHHairline()
                SHCommitFileRow(.init(id: "b", name: "FleetView.swift", directory: "App/iOS/", status: .modified,
                                      added: 9, removed: 7, selected: false)) {}
            }
            .shCard()
            VStack(spacing: 0) {
                SHCommitOptionRow("Push after commit", detail: "origin/main", monoDetail: true, isOn: $push)
                SHHairline()
                SHCommitOptionRow("Open a pull request instead", detail: "pushes a branch and opens the PR", isOn: $pr)
            }
            .shCard()
        }
        .frame(width: 400)
    }
}
