import SwiftUI

/// A changed file in a review's file list (MobileChanges, iPadReviewSplit boards), 58pt: the
/// viewed mark (a done check, or an empty ring), the status letter, the filename in semibold mono
/// over its directory, the comment count, the diff stat, and a chevron where the row opens the
/// file's diff. Equal on its values.
public struct SHReviewFileRow: View, Equatable {
    public struct Item: Equatable, Sendable {
        public let name: String
        public let directory: String
        public let status: SHFileStatus
        public let added: Int
        public let removed: Int
        public let comments: Int
        public let viewed: Bool

        public init(name: String, directory: String, status: SHFileStatus, added: Int, removed: Int, comments: Int = 0, viewed: Bool = false) {
            self.name = name
            self.directory = directory
            self.status = status
            self.added = added
            self.removed = removed
            self.comments = comments
            self.viewed = viewed
        }

        /// "FleetView.swift, in App/iOS/, modified, 9 added, 7 removed, 1 comment, viewed".
        public var accessibilityText: String {
            var parts = [name]
            if !directory.isEmpty { parts.append("in \(directory)") }
            parts += [status.label, "\(added) added, \(removed) removed"]
            if comments > 0 { parts.append("\(comments) comment\(comments == 1 ? "" : "s")") }
            if viewed { parts.append("viewed") }
            return parts.joined(separator: ", ")
        }
    }

    let item: Item
    let showsViewed: Bool
    let showsChevron: Bool
    let selected: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item && lhs.showsViewed == rhs.showsViewed && lhs.showsChevron == rhs.showsChevron && lhs.selected == rhs.selected
    }

    /// `showsViewed` draws the viewed mark at the row's start (the phone's list); the iPad's
    /// list marks the selected file instead.
    public init(_ item: Item, showsViewed: Bool = true, showsChevron: Bool = true, selected: Bool = false) {
        self.item = item
        self.showsViewed = showsViewed
        self.showsChevron = showsChevron
        self.selected = selected
    }

    public var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.m) {
            if showsViewed {
                SHViewedMark(viewed: item.viewed)
            }
            Text(item.status.letter)
                .font(.sh(.mono, weight: .bold))
                .foregroundStyle(item.status.color)
            // At accessibility sizes the counts move under the name, so the name keeps the width.
            let stacked = typeSize.isAccessibilitySize
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(item.name)
                    .font(.sh(.code, weight: .semibold))
                    .foregroundStyle(sh.textPrimary)
                    .lineLimit(stacked ? 3 : 1)
                    .truncationMode(.middle)
                if !item.directory.isEmpty {
                    Text(item.directory)
                        .font(.sh(.micro, weight: .regular))
                        .foregroundStyle(sh.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if stacked { counts }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !stacked { counts }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.sh(.caption, weight: .semibold))
                    .foregroundStyle(sh.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, SH.Space.l)
        .padding(.vertical, SH.Space.m)
        .frame(minHeight: SHReviewFileRow.height)
        .background(selected ? sh.bgSelected : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.l))
        .contentShape(Rectangle())
        .opacity(item.viewed && !showsViewed ? 0.6 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityText)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var counts: some View {
        HStack(spacing: SH.Space.m) {
            if item.comments > 0 {
                Label("\(item.comments)", systemImage: "text.bubble")
                    .labelStyle(SHCompactLabelStyle())
                    .font(.sh(.caption))
                    .foregroundStyle(Color.sh.running)
            }
            SHDiffStat(added: item.added, removed: item.removed, font: .sh(.micro, weight: .regular))
        }
    }

    /// The boards' 58pt file row.
    public static let height: CGFloat = 58
}

/// A file's viewed mark: a done check once viewed, an empty ring before.
public struct SHViewedMark: View {
    let viewed: Bool

    public init(viewed: Bool) { self.viewed = viewed }

    public var body: some View {
        Group {
            if viewed {
                Image(systemName: "checkmark")
                    .font(.sh(.caption, weight: .bold))
                    .foregroundStyle(.sh.done)
            } else {
                Circle().strokeBorder(Color.sh.lineStrong, lineWidth: 1.3)
            }
        }
        .frame(width: SHViewedMark.size, height: SHViewedMark.size)
        .accessibilityHidden(true)
    }

    static let size: CGFloat = 14
}

/// Icon then title, 4pt apart, the icon a step smaller.
private struct SHCompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: SH.Space.xs) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// The phone's bottom-bar buttons (MobileChanges board): 48pt, full width, radius 12, the
/// body size. Primary is the lantern fill; secondary is raised with a strong line.
public struct SHReviewBarButtonStyle: ButtonStyle {
    public enum Kind: Sendable { case primary, secondary }

    let kind: Kind

    public init(_ kind: Kind = .secondary) { self.kind = kind }

    public func makeBody(configuration: Configuration) -> some View {
        SHReviewBarButton(configuration: configuration, kind: kind)
    }

    /// The boards' 48pt bar button.
    public static let height: CGFloat = 48
}

private struct SHReviewBarButton: View {
    let configuration: ButtonStyleConfiguration
    let kind: SHReviewBarButtonStyle.Kind
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let sh = Color.sh
        let shape = RoundedRectangle(cornerRadius: SH.Radius.l)
        let primary = kind == .primary
        configuration.label
            .font(.sh(.body, weight: primary ? .semibold : .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(primary ? sh.textOnLantern : sh.textPrimary)
            .padding(.horizontal, SH.Space.l)
            .frame(maxWidth: .infinity, minHeight: SHReviewBarButtonStyle.height)
            .background(primary ? (configuration.isPressed && enabled ? sh.lanternPressed : sh.lantern) : configuration.isPressed ? sh.bgSelected : sh.bgRaised,
                        in: shape)
            .shBorder(primary ? .clear : sh.lineStrong, radius: SH.Radius.l)
            .opacity(enabled ? 1 : SHControlMetrics.disabledOpacity)
            .contentShape(shape)
    }
}

extension ButtonStyle where Self == SHReviewBarButtonStyle {
    /// `.buttonStyle(.shReviewBar(.primary))`.
    public static func shReviewBar(_ kind: SHReviewBarButtonStyle.Kind = .secondary) -> SHReviewBarButtonStyle { SHReviewBarButtonStyle(kind) }
}

#Preview("Review file rows") {
    SHPreviewBoth {
        VStack(spacing: SH.Space.l) {
            VStack(spacing: 0) {
                SHReviewFileRow(.init(name: "DesktopNativeThreadView.swift", directory: "Sources/ShepherdApp/", status: .modified,
                                      added: 58, removed: 41, viewed: true))
                SHHairline()
                SHReviewFileRow(.init(name: "FleetView.swift", directory: "App/iOS/", status: .modified, added: 9, removed: 7, comments: 1))
                SHHairline()
                SHReviewFileRow(.init(name: "NativePresentationTests.swift", directory: "Tests/ShepherdAppTests/", status: .added,
                                      added: 30, removed: 0))
            }
            .shCard(radius: SH.Radius.l)
            SHReviewFileRow(.init(name: "FleetView.swift", directory: "App/iOS/", status: .modified, added: 9, removed: 7, comments: 1),
                            showsViewed: false, showsChevron: false, selected: true)
            HStack(spacing: SH.Space.l) {
                Button("Request changes") {}.buttonStyle(.shReviewBar(.secondary))
                Button("Commit") {}.buttonStyle(.shReviewBar(.primary))
            }
        }
        .frame(width: 360)
    }
}
