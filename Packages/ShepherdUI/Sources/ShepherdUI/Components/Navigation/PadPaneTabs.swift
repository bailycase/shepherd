import SwiftUI

/// The iPad side pane's head (iPadPaneBrowser, iPadPaneArtifacts, iPadPaneFiles): the pane's tabs as a segmented control on a `bgSunken`
/// track with a hairline `lineSubtle` line, the open one on `bgWindow` and semibold with its glyph, the others `textSecondary` and medium,
/// a count after a tab's name in mono `textTertiary`; Close pane trailing. The Mac's strip is `SHSidePaneTabs`.
public struct SHPadPaneTab: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let count: Int?

    public init(id: String, title: String, systemImage: String, count: Int? = nil) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.count = count
    }
}

public enum SHPadPaneMetrics {
    /// The head: 76pt on the board (a 52pt bar beside the status bar's inset), with a 12pt leading and 10pt trailing inset.
    public static let headHeight: CGFloat = 52
    public static let leading: CGFloat = SH.Space.l
    public static let trailing: CGFloat = SH.Space.m + SH.Space.xxs
    /// The track: radius 10 (the nearest is 12), 3pt inset, 36pt tabs at radius 8, 7pt apart.
    public static let trackInset: CGFloat = 3
    public static let tabHeight: CGFloat = 36
    public static let tabGap: CGFloat = SH.Space.s
    public static let tabGlyph: CGFloat = 15
    public static let tabFont: CGFloat = 13.5
}

public struct SHPadPaneHead<Options: View>: View {
    let tabs: [SHPadPaneTab]
    let selection: String
    let select: (String) -> Void
    let close: () -> Void
    /// What the open tab offers beside Close pane (Changes' ⋯ menu).
    @ViewBuilder let options: () -> Options

    public init(_ tabs: [SHPadPaneTab], selection: String, select: @escaping (String) -> Void, close: @escaping () -> Void,
                @ViewBuilder options: @escaping () -> Options) {
        self.tabs = tabs
        self.selection = selection
        self.select = select
        self.close = close
        self.options = options
    }

    public var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.m) {
            HStack(spacing: SHPadPaneMetrics.tabGap) {
                ForEach(tabs) { tab in
                    let selected = tab.id == selection
                    Button { select(tab.id) } label: {
                        HStack(spacing: SH.Space.s) {
                            Image(systemName: tab.systemImage).font(.system(size: SHPadPaneMetrics.tabGlyph, weight: .medium))
                            Text(tab.title).font(.shSans(SHPadPaneMetrics.tabFont, selected ? .semibold : .medium)).lineLimit(1)
                            if let count = tab.count {
                                Text("\(count)").font(.sh(.micro, weight: .regular)).foregroundStyle(sh.textTertiary)
                            }
                        }
                        .foregroundStyle(selected ? sh.textPrimary : sh.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: SHPadPaneMetrics.tabHeight)
                        .background(selected ? sh.bgWindow : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                        .contentShape(RoundedRectangle(cornerRadius: SH.Radius.m))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.title)
                    .accessibilityValue(tab.count.map { "\($0)" } ?? "")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(SHPadPaneMetrics.trackInset)
            .background(sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.l))
            .shBorder(sh.lineSubtle, radius: SH.Radius.l)
            options()
            Button(action: close) { Image(systemName: "xmark") }
                .buttonStyle(.shIcon(size: SH.Height.touch - SH.Space.xs))
                .accessibilityLabel("Close pane")
        }
        .padding(.leading, SHPadPaneMetrics.leading)
        .padding(.trailing, SHPadPaneMetrics.trailing)
        .frame(minHeight: SHPadPaneMetrics.headHeight)
        .background(sh.bgWindow)
        .overlay(alignment: .bottom) { SHHairline() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Side pane tabs")
    }
}

extension SHPadPaneHead where Options == EmptyView {
    public init(_ tabs: [SHPadPaneTab], selection: String, select: @escaping (String) -> Void, close: @escaping () -> Void) {
        self.init(tabs, selection: selection, select: select, close: close) { EmptyView() }
    }
}

#Preview("Pad pane head") {
    SHPreviewBoth {
        SHPadPaneHead([SHPadPaneTab(id: "changes", title: "Changes", systemImage: "plus.forwardslash.minus", count: 2),
                       SHPadPaneTab(id: "artifacts", title: "Artifacts", systemImage: SHGlyph.artifact.symbolName, count: 3)],
                      selection: "artifacts", select: { _ in }, close: {})
            .frame(width: 520)
    }
}
