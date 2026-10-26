import SwiftUI

/// A changed file's status letter (Review board): M modified in lantern, A added in done, D
/// deleted in failed, R renamed in running.
public enum SHFileStatus: Sendable, Hashable, CaseIterable {
    case modified
    case added
    case deleted
    case renamed

    public var letter: String {
        switch self {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        }
    }

    /// The word VoiceOver reads for the letter.
    public var label: String {
        switch self {
        case .modified: "modified"
        case .added: "added"
        case .deleted: "deleted"
        case .renamed: "renamed"
        }
    }

    @MainActor public var color: Color {
        let sh = Color.sh
        return switch self {
        case .modified: sh.lantern
        case .added: sh.done
        case .deleted: sh.failed
        case .renamed: sh.running
        }
    }
}

/// A file's header in the Changes pane (FileHeader): 36pt on `bgRaised` between hairlines, pinned
/// while its file scrolls. A chevron folds the file; the status letter, the path in mono 12 with
/// its directory in tertiary and the filename semibold, and the file's diff stat; then Viewed
/// (a checkbox with its label: ticking it folds the file), comment on the file, and open in your
/// editor as 26pt circles. Pinned at the top of the list, it casts a soft shadow onto the rows
/// scrolling under it (ChangesSplit).
public struct SHFileHeader: View {
    let path: String
    let status: SHFileStatus
    let added: Int
    let removed: Int
    let isExpanded: Bool
    let isViewed: Bool
    let toggle: () -> Void
    let toggleViewed: () -> Void
    let comment: (() -> Void)?
    let open: (() -> Void)?
    let openLabel: String
    let isPinned: Bool

    /// `comment` and `open` are left out where they cannot work (a binary file, a remote review).
    /// `openLabel` names what open does ("Open in your editor"). `isPinned` while the header sits at
    /// the top of the list, over its file's rows.
    public init(path: String, status: SHFileStatus, added: Int, removed: Int, isExpanded: Bool, isViewed: Bool,
                toggle: @escaping () -> Void, toggleViewed: @escaping () -> Void,
                comment: (() -> Void)? = nil, open: (() -> Void)? = nil, openLabel: String = "Open in your editor",
                isPinned: Bool = false) {
        self.path = path
        self.status = status
        self.added = added
        self.removed = removed
        self.isExpanded = isExpanded
        self.isViewed = isViewed
        self.toggle = toggle
        self.toggleViewed = toggleViewed
        self.comment = comment
        self.open = open
        self.openLabel = openLabel
        self.isPinned = isPinned
    }

    /// "App/iOS/" and "FleetView.swift".
    public static func split(_ path: String) -> (directory: String, name: String) {
        guard let slash = path.lastIndex(of: "/") else { return ("", path) }
        return (String(path[...slash]), String(path[path.index(after: slash)...]))
    }

    public var body: some View {
        let _ = SHRenderProbe.tick("review.fileHeader")
        let sh = Color.sh
        let (directory, name) = Self.split(path)
        HStack(spacing: SH.Space.m) {
            Button(action: toggle) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(sh.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    .shAnimation(.disclosure, value: isExpanded)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse \(name)" : "Expand \(name)")
            Text(status.letter).font(.shMono(11, .bold)).foregroundStyle(status.color).accessibilityHidden(true)
            Text("\(Text(directory).foregroundStyle(sh.textTertiary))\(Text(name).font(.sh(.code, weight: .semibold)).foregroundStyle(sh.textPrimary))")
                .font(.sh(.code))
                .lineLimit(1)
                .truncationMode(.head)
                .help(path)
                .accessibilityLabel(directory.isEmpty ? "\(name), \(status.label)" : "\(name), in \(directory), \(status.label)")
                .accessibilityAddTraits(.isHeader)
            SHDiffStat(added: added, removed: removed, font: .shMono(11))
            Spacer(minLength: SH.Space.s)
            SHViewedCheckbox(isViewed: isViewed, name: name, toggle: toggleViewed)
            HStack(spacing: 0) {
                if let comment {
                    Button(action: comment) { Image(systemName: "text.bubble") }
                        .buttonStyle(.shIcon(size: SHFileHeader.actionSize))
                        .help("Comment on the file")
                        .accessibilityLabel("Comment on \(name)")
                }
                if let open {
                    Button(action: open) { Image(systemName: "arrow.up.forward.square") }
                        .buttonStyle(.shIcon(size: SHFileHeader.actionSize))
                        .help(openLabel)
                        .accessibilityLabel("\(openLabel): \(name)")
                }
            }
        }
        .padding(.leading, SHFileHeader.leadingInset)
        .padding(.trailing, SH.Space.m)
        .frame(height: SHFileHeader.height)
        .shPinnedBackground(sh.bgRaised, pinned: isPinned)
        .overlay(alignment: .top) { SHHairline() }
        .overlay(alignment: .bottom) { SHHairline() }
        .accessibilityElement(children: .contain)
    }

    static let leadingInset: CGFloat = 10
    public static let height: CGFloat = 36
    static let actionSize: CGFloat = 26
}

/// Viewed, as a checkbox and its label (FileHeader · viewed / not): a 14pt box, radius 4, a 1.5pt
/// strong line, lantern with a check once ticked. The box pops as it is ticked.
public struct SHViewedCheckbox: View {
    let isViewed: Bool
    let name: String
    let toggle: () -> Void
    @State private var pops = 0

    public init(isViewed: Bool, name: String, toggle: @escaping () -> Void) {
        self.isViewed = isViewed
        self.name = name
        self.toggle = toggle
    }

    public var body: some View {
        let sh = Color.sh
        Button(action: toggle) {
            HStack(spacing: SH.Space.s) {
                ZStack {
                    RoundedRectangle(cornerRadius: SH.Radius.xs)
                        .fill(isViewed ? sh.lantern : sh.bgRaised)
                    RoundedRectangle(cornerRadius: SH.Radius.xs)
                        .strokeBorder(isViewed ? sh.lantern : sh.lineStrong, lineWidth: 1.5)
                    if isViewed {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(sh.textOnLantern)
                    }
                }
                .frame(width: 14, height: 14)
                .shPop(trigger: pops)
                Text("Viewed").font(.sh(.caption)).foregroundStyle(sh.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .shAnimation(.content, value: isViewed)
        .onChange(of: isViewed) { _, viewed in if viewed { pops += 1 } }
        .help(isViewed ? "Mark unviewed (V)" : "Mark viewed (V)")
        .accessibilityLabel("Viewed \(name)")
        .accessibilityValue(isViewed ? "checked" : "unchecked")
        .accessibilityAddTraits(.isToggle)
    }
}
