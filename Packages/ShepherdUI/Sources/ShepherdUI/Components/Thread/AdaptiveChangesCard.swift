import SwiftUI

/// The changes card at every text size (MobileThread board). At the usual sizes it is
/// `NWChangesCard`; at the accessibility sizes, where one line cannot hold "2 files changed",
/// its stat and Review, or a path beside its stat, the card stacks: the title and stat over
/// Review, and each file's path (up to two lines) over its stat, so nothing clips or widens the
/// thread.
public struct NWAdaptiveChangesCard: View {
    let title: String
    let added: Int
    let removed: Int
    let files: [NWChangedFile]
    let onReview: (() -> Void)?
    let onOpen: ((String) -> Void)?
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(title: String, added: Int, removed: Int, files: [NWChangedFile],
                onReview: (() -> Void)? = nil, onOpen: ((String) -> Void)? = nil) {
        self.title = title
        self.added = added
        self.removed = removed
        self.files = files
        self.onReview = onReview
        self.onOpen = onOpen
    }

    public var body: some View {
        if typeSize.isAccessibilitySize {
            stacked
        } else {
            NWChangesCard(title: title, added: added, removed: removed, files: files, onReview: onReview, onOpen: onOpen)
        }
    }

    private var stacked: some View {
        let nw = Color.nw
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: NW.Space.xs) {
                Text(title).font(.nw(.ui, weight: .semibold)).foregroundStyle(nw.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                NWDiffStat(added: added, removed: removed, font: .nw(.mono))
                if let onReview {
                    Button(action: onReview) { Label("Review", systemImage: "plus.forwardslash.minus") }
                        .buttonStyle(.nw(.ghost, size: .s))
                        .accessibilityLabel("Review \(title)")
                }
            }
            .padding(NW.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(nw.bgSunken)
            ForEach(files) { file in
                NWHairline()
                row(file)
            }
        }
        .frame(maxWidth: .infinity)
        .background(nw.bgWindow, in: RoundedRectangle(cornerRadius: NW.Radius.m))
        .clipShape(RoundedRectangle(cornerRadius: NW.Radius.m))
        .nwBorder(nw.lineSubtle, radius: NW.Radius.m)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func row(_ file: NWChangedFile) -> some View {
        let nw = Color.nw
        let content = VStack(alignment: .leading, spacing: NW.Space.xxs) {
            Text("\(Text(file.status.rawValue).foregroundStyle(statusColor(file.status)).bold())  \(Text(file.directory).foregroundStyle(nw.textTertiary))\(Text(file.name).foregroundStyle(nw.textPrimary))")
                .font(.nw(.mono)).lineLimit(2).truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
            NWDiffStat(added: file.added, removed: file.removed, font: .nw(.mono))
        }
        .padding(NW.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        let label = "\(file.path), \(statusWord(file.status)), \(file.added) added, \(file.removed) removed"
        if let onOpen {
            Button { onOpen(file.path) } label: { content }
                .buttonStyle(.nwRow(radius: 0))
                .accessibilityLabel(label)
                .accessibilityHint("Opens the file in review")
        } else {
            content.accessibilityElement(children: .ignore).accessibilityLabel(label)
        }
    }

    private func statusColor(_ status: NWChangedFile.Status) -> Color {
        switch status {
        case .modified: .nw.lantern
        case .added: .nw.done
        case .deleted: .nw.failed
        }
    }

    private func statusWord(_ status: NWChangedFile.Status) -> String {
        switch status {
        case .modified: "modified"
        case .added: "added"
        case .deleted: "deleted"
        }
    }
}

#Preview("Changes card, accessibility size") {
    NWPreviewBoth {
        NWAdaptiveChangesCard(title: "2 files changed", added: 58, removed: 45, files: [
            NWChangedFile(path: "Sources/ShepherdApp/DesktopNativeThreadView.swift", directory: "Sources/ShepherdApp/",
                          name: "DesktopNativeThreadView.swift", status: .modified, added: 58, removed: 41),
            NWChangedFile(path: "App/iOS/ThreadView.swift", directory: "App/iOS/", name: "ThreadView.swift", status: .modified,
                          added: 0, removed: 4),
        ], onReview: {}, onOpen: { _ in })
        .environment(\.dynamicTypeSize, .accessibility3)
        .frame(width: 360)
    }
}
