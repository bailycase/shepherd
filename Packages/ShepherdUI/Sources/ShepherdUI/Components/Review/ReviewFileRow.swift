import SwiftUI

/// A changed file in a review's file list (MobileChanges, iPadReviewSplit boards), 58pt: the
/// viewed mark (a done check, or an empty ring), the status letter, the filename in semibold mono
/// over its directory, the comment count, the diff stat, and a chevron where the row opens the
/// file's diff. Equal on its values.
public struct NWReviewFileRow: View, Equatable {
    public struct Item: Equatable, Sendable {
        public let name: String
        public let directory: String
        public let status: NWFileStatus
        public let added: Int
        public let removed: Int
        public let comments: Int
        public let viewed: Bool

        public init(name: String, directory: String, status: NWFileStatus, added: Int, removed: Int, comments: Int = 0, viewed: Bool = false) {
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
        let nw = Color.nw
        HStack(spacing: NW.Space.m) {
            if showsViewed {
                NWViewedMark(viewed: item.viewed)
            }
            Text(item.status.letter)
                .font(.nw(.mono, weight: .bold))
                .foregroundStyle(item.status.color)
            // At accessibility sizes the counts move under the name, so the name keeps the width.
            let stacked = typeSize.isAccessibilitySize
            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                Text(item.name)
                    .font(.nw(.code, weight: .semibold))
                    .foregroundStyle(nw.textPrimary)
                    .lineLimit(stacked ? 3 : 1)
                    .truncationMode(.middle)
                if !item.directory.isEmpty {
                    Text(item.directory)
                        .font(.nw(.micro, weight: .regular))
                        .foregroundStyle(nw.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if stacked { counts }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !stacked { counts }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.nw(.caption, weight: .semibold))
                    .foregroundStyle(nw.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, NW.Space.l)
        .padding(.vertical, NW.Space.m)
        .frame(minHeight: NWReviewFileRow.height)
        .background(selected ? nw.bgSelected : .clear, in: RoundedRectangle(cornerRadius: NW.Radius.l))
        .contentShape(Rectangle())
        .opacity(item.viewed && !showsViewed ? 0.6 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityText)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var counts: some View {
        HStack(spacing: NW.Space.m) {
            if item.comments > 0 {
                Label("\(item.comments)", systemImage: "text.bubble")
                    .labelStyle(NWCompactLabelStyle())
                    .font(.nw(.caption))
                    .foregroundStyle(Color.nw.running)
            }
            NWDiffStat(added: item.added, removed: item.removed, font: .nw(.micro, weight: .regular))
        }
    }

    /// The boards' 58pt file row.
    public static let height: CGFloat = 58
}

/// A file's viewed mark: a done check once viewed, an empty ring before.
public struct NWViewedMark: View {
    let viewed: Bool

    public init(viewed: Bool) { self.viewed = viewed }

    public var body: some View {
        Group {
            if viewed {
                Image(systemName: "checkmark")
                    .font(.nw(.caption, weight: .bold))
                    .foregroundStyle(.nw.done)
            } else {
                Circle().strokeBorder(Color.nw.lineStrong, lineWidth: 1.3)
            }
        }
        .frame(width: NWViewedMark.size, height: NWViewedMark.size)
        .accessibilityHidden(true)
    }

    static let size: CGFloat = 14
}

/// Icon then title, 4pt apart, the icon a step smaller.
private struct NWCompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: NW.Space.xs) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// The phone's bottom-bar buttons (MobileChanges board): 48pt, full width, radius 12, the
/// body size. Primary is the lantern fill; secondary is raised with a strong line.
public struct NWReviewBarButtonStyle: ButtonStyle {
    public enum Kind: Sendable { case primary, secondary }

    let kind: Kind

    public init(_ kind: Kind = .secondary) { self.kind = kind }

    public func makeBody(configuration: Configuration) -> some View {
        NWReviewBarButton(configuration: configuration, kind: kind)
    }

    /// The boards' 48pt bar button.
    public static let height: CGFloat = 48
}

private struct NWReviewBarButton: View {
    let configuration: ButtonStyleConfiguration
    let kind: NWReviewBarButtonStyle.Kind
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let nw = Color.nw
        let shape = RoundedRectangle(cornerRadius: NW.Radius.l)
        let primary = kind == .primary
        configuration.label
            .font(.nw(.body, weight: primary ? .semibold : .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(primary ? nw.textOnLantern : nw.textPrimary)
            .padding(.horizontal, NW.Space.l)
            .frame(maxWidth: .infinity, minHeight: NWReviewBarButtonStyle.height)
            .background(primary ? nw.lantern.mix(with: .black, by: configuration.isPressed ? 0.1 : 0) : configuration.isPressed ? nw.bgSelected : nw.bgRaised,
                        in: shape)
            .nwBorder(primary ? .clear : nw.lineStrong, radius: NW.Radius.l)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(shape)
    }
}

extension ButtonStyle where Self == NWReviewBarButtonStyle {
    /// `.buttonStyle(.nwReviewBar(.primary))`.
    public static func nwReviewBar(_ kind: NWReviewBarButtonStyle.Kind = .secondary) -> NWReviewBarButtonStyle { NWReviewBarButtonStyle(kind) }
}

#Preview("Review file rows") {
    NWPreviewBoth {
        VStack(spacing: NW.Space.l) {
            VStack(spacing: 0) {
                NWReviewFileRow(.init(name: "DesktopNativeThreadView.swift", directory: "Sources/ShepherdApp/", status: .modified,
                                      added: 58, removed: 41, viewed: true))
                NWHairline()
                NWReviewFileRow(.init(name: "FleetView.swift", directory: "App/iOS/", status: .modified, added: 9, removed: 7, comments: 1))
                NWHairline()
                NWReviewFileRow(.init(name: "NativePresentationTests.swift", directory: "Tests/ShepherdAppTests/", status: .added,
                                      added: 30, removed: 0))
            }
            .nwCard(radius: NW.Radius.l)
            NWReviewFileRow(.init(name: "FleetView.swift", directory: "App/iOS/", status: .modified, added: 9, removed: 7, comments: 1),
                            showsViewed: false, showsChevron: false, selected: true)
            HStack(spacing: NW.Space.l) {
                Button("Request changes") {}.buttonStyle(.nwReviewBar(.secondary))
                Button("Commit") {}.buttonStyle(.nwReviewBar(.primary))
            }
        }
        .frame(width: 360)
    }
}
