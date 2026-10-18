import SwiftUI

/// The iPad side pane's head (iPadPaneBrowser, iPadPaneArtifacts, iPadPaneFiles): the pane's tabs as a segmented control on a `bgSunken`
/// track with a hairline `lineSubtle` line, the open one on `bgWindow` and semibold with its glyph, the others `textSecondary` and medium,
/// a count after a tab's name in mono `textTertiary`; Close pane trailing. The Mac's strip is `NWSidePaneTabs`.
public struct NWPadPaneTab: Identifiable, Equatable, Sendable {
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

public enum NWPadPaneMetrics {
    /// The head: 76pt on the board (a 52pt bar beside the status bar's inset), with a 12pt leading and 10pt trailing inset.
    public static let headHeight: CGFloat = 52
    public static let leading: CGFloat = NW.Space.l
    public static let trailing: CGFloat = NW.Space.m + NW.Space.xxs
    /// The track: radius 10 (the nearest is 12), 3pt inset, 36pt tabs at radius 8, 7pt apart.
    public static let trackInset: CGFloat = 3
    public static let tabHeight: CGFloat = 36
    public static let tabGap: CGFloat = NW.Space.s
    public static let tabGlyph: CGFloat = 15
    public static let tabFont: CGFloat = 13.5
}

public struct NWPadPaneHead<Options: View>: View {
    let tabs: [NWPadPaneTab]
    let selection: String
    let select: (String) -> Void
    let close: () -> Void
    /// What the open tab offers beside Close pane (Changes' ⋯ menu).
    @ViewBuilder let options: () -> Options

    public init(_ tabs: [NWPadPaneTab], selection: String, select: @escaping (String) -> Void, close: @escaping () -> Void,
                @ViewBuilder options: @escaping () -> Options) {
        self.tabs = tabs
        self.selection = selection
        self.select = select
        self.close = close
        self.options = options
    }

    public var body: some View {
        let nw = Color.nw
        HStack(spacing: NW.Space.m) {
            HStack(spacing: NWPadPaneMetrics.tabGap) {
                ForEach(tabs) { tab in
                    let selected = tab.id == selection
                    Button { select(tab.id) } label: {
                        HStack(spacing: NW.Space.s) {
                            Image(systemName: tab.systemImage).font(.system(size: NWPadPaneMetrics.tabGlyph, weight: .medium))
                            Text(tab.title).font(.nwSans(NWPadPaneMetrics.tabFont, selected ? .semibold : .medium)).lineLimit(1)
                            if let count = tab.count {
                                Text("\(count)").font(.nw(.micro, weight: .regular)).foregroundStyle(nw.textTertiary)
                            }
                        }
                        .foregroundStyle(selected ? nw.textPrimary : nw.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: NWPadPaneMetrics.tabHeight)
                        .background(selected ? nw.bgWindow : .clear, in: RoundedRectangle(cornerRadius: NW.Radius.m))
                        .contentShape(RoundedRectangle(cornerRadius: NW.Radius.m))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.title)
                    .accessibilityValue(tab.count.map { "\($0)" } ?? "")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(NWPadPaneMetrics.trackInset)
            .background(nw.bgSunken, in: RoundedRectangle(cornerRadius: NW.Radius.l))
            .nwBorder(nw.lineSubtle, radius: NW.Radius.l)
            options()
            Button(action: close) { Image(systemName: "xmark") }
                .buttonStyle(.nwIcon(size: NW.Height.touch - NW.Space.xs))
                .accessibilityLabel("Close pane")
        }
        .padding(.leading, NWPadPaneMetrics.leading)
        .padding(.trailing, NWPadPaneMetrics.trailing)
        .frame(minHeight: NWPadPaneMetrics.headHeight)
        .background(nw.bgWindow)
        .overlay(alignment: .bottom) { NWHairline() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Side pane tabs")
    }
}

extension NWPadPaneHead where Options == EmptyView {
    public init(_ tabs: [NWPadPaneTab], selection: String, select: @escaping (String) -> Void, close: @escaping () -> Void) {
        self.init(tabs, selection: selection, select: select, close: close) { EmptyView() }
    }
}

#Preview("Pad pane head") {
    NWPreviewBoth {
        NWPadPaneHead([NWPadPaneTab(id: "changes", title: "Changes", systemImage: "plus.forwardslash.minus", count: 2),
                       NWPadPaneTab(id: "artifacts", title: "Artifacts", systemImage: NWGlyph.artifact.symbolName, count: 3)],
                      selection: "artifacts", select: { _ in }, close: {})
            .frame(width: 520)
    }
}
