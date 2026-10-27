import SwiftUI

/// The iPad and iPhone Duo side pane's head (DuoOpenSidePane, DuoSidePaneTabs): one row of tabs, level with the thread's title, then the
/// pane's ⋯ trailing. The open tab shows its glyph, its label and its count (Changes' files) on `bgSelected`, semibold; the others
/// are their glyph alone in `textSecondary`, as the Mac's strip drops labels in a narrow pane (`SHSidePaneTabs`). A tab whose work runs
/// (Terminal, Subagents) carries a dot in its state's color. The pane closes from the thread's side-pane button.
public struct SHPadPaneTab: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let count: Int?
    /// What the tab's work is doing, as a dot on its glyph (running); nil draws none.
    public let status: AgentState?

    public init(id: String, title: String, systemImage: String, count: Int? = nil, status: AgentState? = nil) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.count = count
        self.status = status
    }
}

public enum SHPadPaneMetrics {
    /// The head: as tall as the thread's title bar beside it, with a 12pt leading and 10pt trailing inset.
    public static let headHeight: CGFloat = 52
    public static let leading: CGFloat = SH.Space.l
    public static let trailing: CGFloat = SH.Space.m + SH.Space.xxs
    /// A tab's pill: 36pt at radius 8 inside its 44pt target, its glyph 15pt.
    public static let tabHeight: CGFloat = 36
    public static let tabGlyph: CGFloat = 15
    public static let tabFont: CGFloat = 13.5
    /// The status dot, its center on the glyph's top trailing corner.
    public static let dot: CGFloat = 6
}

public struct SHPadPaneHead<Options: View>: View {
    let tabs: [SHPadPaneTab]
    let selection: String
    let select: (String) -> Void
    /// The pane's ⋯: the open tab's options, and Hide side pane.
    @ViewBuilder let options: () -> Options

    public init(_ tabs: [SHPadPaneTab], selection: String, select: @escaping (String) -> Void,
                @ViewBuilder options: @escaping () -> Options) {
        self.tabs = tabs
        self.selection = selection
        self.select = select
        self.options = options
    }

    public var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.xs) {
            ForEach(tabs) { tab in
                let selected = tab.id == selection
                Button { select(tab.id) } label: {
                    HStack(spacing: SH.Space.s) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: SHPadPaneMetrics.tabGlyph, weight: .medium))
                            .overlay(alignment: .topTrailing) {
                                if let status = tab.status {
                                    Circle().fill(status.color)
                                        .frame(width: SHPadPaneMetrics.dot, height: SHPadPaneMetrics.dot)
                                        .offset(x: SHPadPaneMetrics.dot / 2, y: -SHPadPaneMetrics.dot / 2)
                                }
                            }
                        if selected {
                            Text(tab.title).font(.shSans(SHPadPaneMetrics.tabFont, .semibold)).lineLimit(1).fixedSize()
                            if let count = tab.count {
                                Text("\(count)").font(.sh(.micro, weight: .regular)).foregroundStyle(sh.textTertiary)
                                    .shContentTransition(.numeric())
                            }
                        }
                    }
                    .foregroundStyle(selected ? sh.textPrimary : sh.textSecondary)
                    .fixedSize()
                    .padding(.horizontal, SH.Space.m)
                    .frame(minWidth: SH.Height.touch, minHeight: SHPadPaneMetrics.tabHeight)
                    .background(selected ? sh.bgSelected : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                    .frame(minHeight: SH.Height.touch)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityValue([tab.count.map { "\($0)" }, tab.status?.label].compactMap { $0 }.joined(separator: ", "))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: SH.Space.s)
            SHOptionsMenu("Pane options", size: SH.Height.touch, content: options)
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

#Preview("Pad pane head") {
    SHPreviewBoth {
        SHPadPaneHead([SHPadPaneTab(id: "changes", title: "Changes", systemImage: "plus.forwardslash.minus", count: 3),
                       SHPadPaneTab(id: "files", title: "Files", systemImage: "folder"),
                       SHPadPaneTab(id: "terminal", title: "Terminal", systemImage: "apple.terminal"),
                       SHPadPaneTab(id: "subagents", title: "Subagents", systemImage: SHGlyph.gitBranch.symbolName, status: .running),
                       SHPadPaneTab(id: "browser", title: "Browser", systemImage: "globe")],
                      selection: "changes", select: { _ in }) {
            Button("Hide side pane", systemImage: "sidebar.right") {}
        }
        .frame(width: 400)
    }
}
