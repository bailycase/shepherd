import SwiftUI

/// A changed file in a review's file list (MobileChanges, MobilePRChanges boards), 52pt: the
/// filename in mono over its directory (and "new" for an added file), the comment count, the diff
/// stat, "Viewed", and a chevron where the row opens the file's diff. Equal on its values.
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

    /// `showsViewed` says "Viewed" at the row's end (the phone's list); the iPad's list marks the
    /// selected file instead.
    public init(_ item: Item, showsViewed: Bool = true, showsChevron: Bool = true, selected: Bool = false) {
        self.item = item
        self.showsViewed = showsViewed
        self.showsChevron = showsChevron
        self.selected = selected
    }

    public var body: some View {
        let sh = Color.sh
        // At accessibility sizes the counts move under the name, so the name keeps the width.
        let stacked = typeSize.isAccessibilitySize
        HStack(spacing: SH.Space.l) {
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(item.name)
                    .font(.shMono(SHReviewFileRow.nameSize, .medium))
                    .foregroundStyle(sh.textPrimary)
                    .lineLimit(stacked ? 3 : 1)
                    .truncationMode(.tail)
                if let detail = item.detail {
                    Text(detail)
                        .font(.shSans(SHReviewFileRow.detailSize))
                        .foregroundStyle(sh.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if stacked { counts }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !stacked { counts }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.shSans(SHReviewFileRow.detailSize, .medium))
                    .foregroundStyle(sh.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, SH.Space.xl)
        .padding(.vertical, SH.Space.m + SH.Space.xxs)
        .frame(minHeight: SHReviewFileRow.height)
        .background(selected ? sh.bgSelected : .clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityText)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var counts: some View {
        HStack(spacing: SH.Space.m) {
            if item.comments > 0 {
                Label("\(item.comments)", systemImage: "text.bubble")
                    .labelStyle(SHCompactLabelStyle())
                    .font(.shSans(SHReviewFileRow.detailSize))
                    .foregroundStyle(Color.sh.textSecondary)
            }
            SHDiffStat(added: item.added, removed: item.removed, font: .shSans(SHReviewFileRow.detailSize))
            if showsViewed, item.viewed {
                Text("Viewed").font(.shSans(SHReviewFileRow.detailSize)).foregroundStyle(Color.sh.textTertiary)
            }
        }
    }

    /// The boards' file row: 52pt at least, the name at 14 in mono over the directory at 13.
    public static let height: CGFloat = 52
    static let nameSize: CGFloat = 14
    static let detailSize: CGFloat = 13
}

extension SHReviewFileRow.Item {
    /// "Tests/ShepherdAppTests/ · new": the directory, then how the file changed unless it only did.
    var detail: String? {
        let parts = [directory.isEmpty ? nil : directory, status.note].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }
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
            .foregroundStyle(primary ? sh.textOnPrimary : sh.textPrimary)
            .padding(.horizontal, SH.Space.l)
            .frame(maxWidth: .infinity, minHeight: SHReviewBarButtonStyle.height)
            .background(primary ? (configuration.isPressed && enabled ? sh.primaryPressed : sh.primary) : configuration.isPressed ? sh.bgSelected : sh.bgRaised,
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
