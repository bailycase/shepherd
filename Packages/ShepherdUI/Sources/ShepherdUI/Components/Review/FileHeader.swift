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

/// A file's header in the diff (Review board): 32pt on `bgSunken` with a 1px rule below. A
/// chevron folds the file; the path is mono with its directory in tertiary and the filename
/// bold; then the hunk count, the comment count, and 24pt circular actions: open in an editor,
/// revert, and mark viewed. Pin it as a `LazyVStack` section header.
public struct NWFileHeader: View {
    let path: String
    let hunkCount: Int
    let commentCount: Int
    let isExpanded: Bool
    let isViewed: Bool
    let toggle: () -> Void
    let toggleViewed: () -> Void
    let revert: (() -> Void)?
    let open: (() -> Void)?
    let openLabel: String

    /// `revert` and `open` are left out where the diff cannot change the files (a PR or a remote
    /// review). `openLabel` names the editor ("Open in Xcode").
    public init(path: String, hunkCount: Int, commentCount: Int = 0, isExpanded: Bool, isViewed: Bool,
                toggle: @escaping () -> Void, toggleViewed: @escaping () -> Void,
                revert: (() -> Void)? = nil, open: (() -> Void)? = nil, openLabel: String = "Open in Xcode") {
        self.path = path
        self.hunkCount = hunkCount
        self.commentCount = commentCount
        self.isExpanded = isExpanded
        self.isViewed = isViewed
        self.toggle = toggle
        self.toggleViewed = toggleViewed
        self.revert = revert
        self.open = open
        self.openLabel = openLabel
    }

    /// "App/iOS/" and "FleetView.swift".
    public static func split(_ path: String) -> (directory: String, name: String) {
        guard let slash = path.lastIndex(of: "/") else { return ("", path) }
        return (String(path[...slash]), String(path[path.index(after: slash)...]))
    }

    public var body: some View {
        let nw = Color.nw
        let (directory, name) = Self.split(path)
        HStack(spacing: NW.Space.m) {
            Button(action: toggle) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(nw.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse \(name)" : "Expand \(name)")
            Text("\(Text(directory).foregroundStyle(nw.textTertiary))\(Text(name).font(.nw(.code, weight: .semibold)).foregroundStyle(nw.textPrimary))")
                .font(.nw(.code))
                .lineLimit(1)
                .truncationMode(.head)
                .help(path)
                .accessibilityLabel(directory.isEmpty ? name : "\(name), in \(directory)")
                .accessibilityAddTraits(.isHeader)
            Text("\(hunkCount) hunk\(hunkCount == 1 ? "" : "s")")
                .font(.nw(.micro, weight: .regular))
                .foregroundStyle(nw.textTertiary)
                .fixedSize()
            if commentCount > 0 {
                Text("\(commentCount) comment\(commentCount == 1 ? "" : "s")")
                    .font(.nw(.micro, weight: .regular))
                    .foregroundStyle(nw.running)
                    .fixedSize()
            }
            Spacer(minLength: NW.Space.s)
            HStack(spacing: 0) {
                if let open {
                    Button(action: open) { Image(systemName: "arrow.up.forward.square") }
                        .buttonStyle(.nwIcon(size: NW.Height.controlS))
                        .help(openLabel)
                        .accessibilityLabel("\(openLabel): \(name)")
                }
                if let revert {
                    Button(action: revert) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.nwIcon(size: NW.Height.controlS))
                        .help("Revert this file")
                        .accessibilityLabel("Revert \(name)")
                }
                Button(action: toggleViewed) { Image(systemName: "checkmark") }
                    .buttonStyle(.nwIcon(size: NW.Height.controlS, tint: isViewed ? nw.done : nil))
                    .help(isViewed ? "Mark unviewed" : "Mark viewed")
                    .accessibilityLabel(isViewed ? "Mark \(name) unviewed" : "Mark \(name) viewed")
            }
        }
        .padding(.leading, NWFileHeader.leadingInset)
        .padding(.trailing, NW.Space.s)
        .frame(minHeight: NW.Height.controlL)
        .background(nw.bgSunken)
        .overlay(alignment: .bottom) { NWHairline() }
        .accessibilityElement(children: .contain)
    }

    static let leadingInset: CGFloat = 10
}
