import SwiftUI

// The commit from review's parts (MobileCommit and iPadCommit boards, and the Mac's review pane
// sheet): the message card, a file row with its checkbox, and an option row with its switch.
// Each sheet composes them with its own chrome: a phone sheet, an iPad popover, a Mac dialog.

public enum NWCommitFormMetrics {
    /// A file row: a touch target on iOS, a list row on the Mac.
    @MainActor public static var fileRowHeight: CGFloat {
        #if os(iOS)
        NW.Height.touch
        #else
        NW.Height.row
        #endif
    }

    /// An option row: the boards' 52pt on iOS, a dialog row on the Mac.
    @MainActor public static var optionRowHeight: CGFloat {
        #if os(iOS)
        NW.Height.scaled(52)
        #else
        NWDialogMetrics.rowMinHeight
        #endif
    }
}

/// The commit's message as a card: the summary line in semibold over the description, and a note
/// saying where it came from ("Drafted from the diff · edit anything"), or a spinner while the
/// host drafts it. Once an edited message may mention files since left out, the note says so
/// instead. Both fields edit in place.
public struct NWCommitMessageEditor: View {
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
                radius: CGFloat = NW.Radius.m, fill: Color? = nil) {
        _title = title
        _message = message
        self.source = source
        self.mentionsUntickedFiles = mentionsUntickedFiles
        self.radius = radius
        self.fill = fill
    }

    public var body: some View {
        let nw = Color.nw
        // Both fields take their ideal height: a sheet sized to its content proposes a field the
        // height it had, so text set from outside (the host's message, a draft) stayed clipped to it.
        VStack(alignment: .leading, spacing: NW.Space.s) {
            TextField("Summary", text: $title, prompt: Text("Summary").foregroundStyle(nw.textTertiary), axis: .vertical)
                .lineLimit(1...3)
                .fixedSize(horizontal: false, vertical: true)
                .font(.nw(.body, weight: .semibold))
                .foregroundStyle(nw.textPrimary)
                .accessibilityLabel("Commit summary")
            TextField("Description", text: $message, prompt: Text("Description (optional)").foregroundStyle(nw.textTertiary), axis: .vertical)
                .lineLimit(1...8)
                .fixedSize(horizontal: false, vertical: true)
                .font(.nw(.ui, weight: .regular))
                .foregroundStyle(nw.textSecondary)
                .accessibilityLabel("Commit description")
            HStack(spacing: NW.Space.s) {
                if source == .drafting && !mentionsUntickedFiles {
                    ProgressView().progressViewStyle(.nwSpinner).controlSize(.mini)
                } else {
                    Image(systemName: mentionsUntickedFiles ? "exclamationmark.circle" : source == .drafted ? "sparkle" : "list.bullet")
                        .font(.nw(.micro))
                        .accessibilityHidden(true)
                }
                Text(note)
                    .font(.nw(.caption))
            }
            .foregroundStyle(nw.textTertiary)
            .nwContentTransition(.crossFade)
            .nwComponentAnimation(.content, value: source)
            .nwComponentAnimation(.content, value: mentionsUntickedFiles)
            .accessibilityElement(children: .combine)
        }
        .textFieldStyle(.plain)
        .tint(nw.lantern)
        .padding(.horizontal, NW.Space.l + NW.Space.xxs)
        .padding(.vertical, NW.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nwCard(radius: radius, fill: fill, line: nw.lineStrong)
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
public struct NWCommitFileRow: View, Equatable {
    public struct Item: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let directory: String
        public let status: NWFileStatus
        public let added: Int
        public let removed: Int
        public let selected: Bool

        public init(id: String, name: String, directory: String, status: NWFileStatus, added: Int, removed: Int, selected: Bool) {
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
        let nw = Color.nw
        Button(action: toggle) {
            HStack(spacing: NW.Space.m) {
                Toggle(item.name, isOn: .constant(item.selected))
                    .toggleStyle(.nwCheckbox)
                    .labelsHidden()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                // At accessibility sizes the directory and stat move under the name.
                let stacked = typeSize.isAccessibilitySize
                let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: NW.Space.xxs))
                    : AnyLayout(HStackLayout(spacing: NW.Space.s))
                layout {
                    Text(item.name)
                        .font(.nw(.code))
                        .foregroundStyle(item.selected ? nw.textPrimary : nw.textSecondary)
                        .lineLimit(stacked ? 3 : 1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    if showsDirectory && !item.directory.isEmpty {
                        Text(item.directory)
                            .font(.nw(.micro, weight: .regular))
                            .foregroundStyle(nw.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    if stacked { NWDiffStat(added: item.added, removed: item.removed, font: .nw(.micro, weight: .regular)) }
                }
                Spacer(minLength: NW.Space.s)
                if !stacked { NWDiffStat(added: item.added, removed: item.removed, font: .nw(.micro, weight: .regular)) }
            }
            .padding(.horizontal, NW.Space.l + NW.Space.xxs)
            .padding(.vertical, NW.Space.xs)
            .frame(minHeight: NWCommitFormMetrics.fileRowHeight)
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
public struct NWCommitOptionRow: View {
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
        let nw = Color.nw
        HStack(spacing: NW.Space.l) {
            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                Text(title).font(.nw(.ui, weight: .regular)).foregroundStyle(nw.textPrimary)
                if let detail {
                    Text(detail)
                        .font(monoDetail ? .nw(.mono) : .nw(.caption))
                        .foregroundStyle(nw.textTertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: $isOn)
                .toggleStyle(.nwSwitch)
                .labelsHidden()
        }
        .padding(.horizontal, NW.Space.l + NW.Space.xxs)
        .padding(.vertical, NW.Space.m)
        .frame(minHeight: NWCommitFormMetrics.optionRowHeight)
        .contentShape(Rectangle())
        #if os(iOS)
        .onTapGesture { if enabled { isOn.toggle() } }
        #endif
        .nwEnabledOpacity(enabled)
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
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.l) {
            NWCommitMessageEditor(title: $title, message: $message, source: .drafted)
            NWCommitMessageEditor(title: .constant("Update 3 files in App/iOS"), message: .constant(""), source: .drafting)
            NWCommitMessageEditor(title: .constant("Show tool rows' commands"), message: .constant("Also covers FleetView."), source: .drafted,
                                  mentionsUntickedFiles: true)
            VStack(spacing: 0) {
                NWCommitFileRow(.init(id: "a", name: "DesktopNativeThreadView.swift", directory: "Sources/ShepherdApp/", status: .modified,
                                      added: 58, removed: 41, selected: true)) {}
                NWHairline()
                NWCommitFileRow(.init(id: "b", name: "FleetView.swift", directory: "App/iOS/", status: .modified,
                                      added: 9, removed: 7, selected: false)) {}
            }
            .nwCard()
            VStack(spacing: 0) {
                NWCommitOptionRow("Push after commit", detail: "origin/main", monoDetail: true, isOn: $push)
                NWHairline()
                NWCommitOptionRow("Open a pull request instead", detail: "pushes a branch and opens the PR", isOn: $pr)
            }
            .nwCard()
        }
        .frame(width: 400)
    }
}
