import SwiftUI

/// A changed file's status letter (Review board): M modified in lantern, A added in done, D
/// deleted in failed, R renamed in running.
public enum NWFileStatus: Sendable, Hashable, CaseIterable {
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
        let nw = Color.nw
        return switch self {
        case .modified: nw.lantern
        case .added: nw.done
        case .deleted: nw.failed
        case .renamed: nw.running
        }
    }
}

/// A file's header in the Changes pane (FileHeader): 36pt on `bgRaised` between hairlines, pinned
/// while its file scrolls. A chevron folds the file; the status letter, the path in mono 12 with
/// its directory in tertiary and the filename semibold, and the file's diff stat; then Viewed
/// (a checkbox with its label: ticking it folds the file), comment on the file, and open in your
/// editor as 26pt circles.
public struct NWFileHeader: View {
    let path: String
    let status: NWFileStatus
    let added: Int
    let removed: Int
    let isExpanded: Bool
    let isViewed: Bool
    let toggle: () -> Void
    let toggleViewed: () -> Void
    let comment: (() -> Void)?
    let open: (() -> Void)?
    let openLabel: String

    /// `comment` and `open` are left out where they cannot work (a binary file, a remote review).
    /// `openLabel` names what open does ("Open in your editor").
    public init(path: String, status: NWFileStatus, added: Int, removed: Int, isExpanded: Bool, isViewed: Bool,
                toggle: @escaping () -> Void, toggleViewed: @escaping () -> Void,
                comment: (() -> Void)? = nil, open: (() -> Void)? = nil, openLabel: String = "Open in your editor") {
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
    }

    /// "App/iOS/" and "FleetView.swift".
    public static func split(_ path: String) -> (directory: String, name: String) {
        guard let slash = path.lastIndex(of: "/") else { return ("", path) }
        return (String(path[...slash]), String(path[path.index(after: slash)...]))
    }

    public var body: some View {
        let _ = NWRenderProbe.tick("review.fileHeader")
        let nw = Color.nw
        let (directory, name) = Self.split(path)
        HStack(spacing: NW.Space.m) {
            Button(action: toggle) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(nw.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    .nwAnimation(.disclosure, value: isExpanded)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse \(name)" : "Expand \(name)")
            Text(status.letter).font(.nwMono(11, .bold)).foregroundStyle(status.color).accessibilityHidden(true)
            Text("\(Text(directory).foregroundStyle(nw.textTertiary))\(Text(name).font(.nw(.code, weight: .semibold)).foregroundStyle(nw.textPrimary))")
                .font(.nw(.code))
                .lineLimit(1)
                .truncationMode(.head)
                .help(path)
                .accessibilityLabel(directory.isEmpty ? "\(name), \(status.label)" : "\(name), in \(directory), \(status.label)")
                .accessibilityAddTraits(.isHeader)
            NWDiffStat(added: added, removed: removed, font: .nwMono(11))
            Spacer(minLength: NW.Space.s)
            NWViewedCheckbox(isViewed: isViewed, name: name, toggle: toggleViewed)
            HStack(spacing: 0) {
                if let comment {
                    Button(action: comment) { Image(systemName: "text.bubble") }
                        .buttonStyle(.nwIcon(size: NWFileHeader.actionSize))
                        .help("Comment on the file")
                        .accessibilityLabel("Comment on \(name)")
                }
                if let open {
                    Button(action: open) { Image(systemName: "arrow.up.forward.square") }
                        .buttonStyle(.nwIcon(size: NWFileHeader.actionSize))
                        .help(openLabel)
                        .accessibilityLabel("\(openLabel): \(name)")
                }
            }
        }
        .padding(.leading, NWFileHeader.leadingInset)
        .padding(.trailing, NW.Space.m)
        .frame(height: NWFileHeader.height)
        .background(nw.bgRaised)
        .overlay(alignment: .top) { NWHairline() }
        .overlay(alignment: .bottom) { NWHairline() }
        .accessibilityElement(children: .contain)
    }

    static let leadingInset: CGFloat = 10
    public static let height: CGFloat = 36
    static let actionSize: CGFloat = 26
}

/// Viewed, as a checkbox and its label (FileHeader · viewed / not): a 14pt box, radius 4, a 1.5pt
/// strong line, lantern with a check once ticked. The box pops as it is ticked.
public struct NWViewedCheckbox: View {
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
        let nw = Color.nw
        Button(action: toggle) {
            HStack(spacing: NW.Space.s) {
                ZStack {
                    RoundedRectangle(cornerRadius: NW.Radius.xs)
                        .fill(isViewed ? nw.lantern : nw.bgRaised)
                    RoundedRectangle(cornerRadius: NW.Radius.xs)
                        .strokeBorder(isViewed ? nw.lantern : nw.lineStrong, lineWidth: 1.5)
                    if isViewed {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(nw.textOnLantern)
                    }
                }
                .frame(width: 14, height: 14)
                .nwPop(trigger: pops)
                Text("Viewed").font(.nw(.caption)).foregroundStyle(nw.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .nwAnimation(.content, value: isViewed)
        .onChange(of: isViewed) { _, viewed in if viewed { pops += 1 } }
        .help(isViewed ? "Mark unviewed (V)" : "Mark viewed (V)")
        .accessibilityLabel("Viewed \(name)")
        .accessibilityValue(isViewed ? "checked" : "unchecked")
        .accessibilityAddTraits(.isToggle)
    }
}
