import SwiftUI

/// The toolbar's and pane headers' fixed measures (Navigation board).
public enum NWToolbarMetrics {
    /// The thread toolbar and pane headers, unified with the title bar.
    public static let height: CGFloat = 44
    public static let leadingPadding: CGFloat = 14
    public static let trailingPadding: CGFloat = 8
    /// Pane headers sit a little tighter.
    public static let paneLeadingPadding: CGFloat = 12
    public static let paneTrailingPadding: CGFloat = 6
}

/// A pane toggle in a toolbar: an icon button that lights up in lantern tint while its pane is
/// open.
public struct NWPaneToggle: Equatable, Sendable {
    public let systemImage: String
    public let label: String
    public let shortcut: String?
    public let isOn: Bool

    public init(systemImage: String, label: String, shortcut: String? = nil, isOn: Bool) {
        self.systemImage = systemImage
        self.label = label
        self.shortcut = shortcut
        self.isOn = isOn
    }
}

/// The thread toolbar (Navigation board, `NWThreadToolbar`): 44pt, the title, then counters in
/// mono and the pane toggles and options menu at the trailing end. Nothing sits beside the title:
/// the thread and the sidebar already say what an agent is doing. A sidebar button leads
/// while the sidebar is not docked; `leadingInset` clears the window controls.
public struct NWThreadToolbar<Options: View>: View {
    let title: String
    let titleHelp: String?
    let counters: String?
    let countersHelp: String?
    let leadingInset: CGFloat
    let sidebar: (() -> Void)?
    let sidebarLabel: String
    let toggles: [(toggle: NWPaneToggle, action: () -> Void)]
    @ViewBuilder let options: () -> Options

    public init(_ title: String, titleHelp: String? = nil, counters: String? = nil, countersHelp: String? = nil,
                leadingInset: CGFloat = 0, sidebar: (() -> Void)? = nil, sidebarLabel: String = "Show sidebar",
                toggles: [(NWPaneToggle, () -> Void)] = [],
                @ViewBuilder options: @escaping () -> Options) {
        self.title = title
        self.titleHelp = titleHelp
        self.counters = counters
        self.countersHelp = countersHelp
        self.leadingInset = leadingInset
        self.sidebar = sidebar
        self.sidebarLabel = sidebarLabel
        self.toggles = toggles.map { (toggle: $0.0, action: $0.1) }
        self.options = options
    }

    public var body: some View {
        let _ = NWRenderProbe.tick("toolbar.thread")
        HStack(spacing: 10) {
            if let sidebar {
                Button(action: sidebar) { Image(systemName: "sidebar.left") }
                    .buttonStyle(.nwIcon)
                    .nwHelp(sidebarLabel)
                    .accessibilityLabel(sidebarLabel)
            }
            Text(title)
                .font(.nwSans(13, .semibold))
                .foregroundStyle(.nw.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(titleHelp ?? title)
                .accessibilityAddTraits(.isHeader)
                // A rename or a settled name cross-fades.
                .nwContentTransition(.crossFade)
                .nwAnimation(.content, value: title)
            Spacer(minLength: NW.Space.l)
            HStack(spacing: NW.Space.xxs) {
                if let counters {
                    Text(counters)
                        .font(.nw(.micro, weight: .regular))
                        .foregroundStyle(.nw.textTertiary)
                        .lineLimit(1)
                        .fixedSize()
                        .help(countersHelp ?? counters)
                        .padding(.trailing, NW.Space.m)
                        // Turns, context, and subagents roll as the thread reports them.
                        .nwContentTransition(.numeric())
                        .nwTransition(.content)
                }
                // Keyed by icon: a toggle that comes and goes never shifts the others' identity.
                ForEach(toggles, id: \.toggle.systemImage) { item in
                    Button(action: item.action) { Image(systemName: item.toggle.systemImage) }
                        .buttonStyle(.nwIcon(isOn: item.toggle.isOn))
                        .nwAnimation(.hover, value: item.toggle.isOn)
                        .nwHelp(item.toggle.label, shortcut: item.toggle.shortcut)
                        .accessibilityLabel(item.toggle.label)
                        .accessibilityAddTraits(item.toggle.isOn ? .isSelected : [])
                        .nwTransition(.list, edge: .trailing)
                }
                options()
            }
            .nwAnimation(.content, value: counters)
            .nwAnimation(.list, value: toggles.map(\.toggle.systemImage))
            .layoutPriority(1)
        }
        .padding(.leading, NWToolbarMetrics.leadingPadding + leadingInset)
        .padding(.trailing, NWToolbarMetrics.trailingPadding)
        .frame(height: NWToolbarMetrics.height)
        .frame(maxWidth: .infinity)
        .background(Color.nw.bgWindow)
        .overlay(alignment: .bottom) { NWHairline() }
    }
}

extension NWThreadToolbar where Options == EmptyView {
    /// A toolbar with only a title (no thread on screen).
    public init(_ title: String, leadingInset: CGFloat = 0, sidebar: (() -> Void)? = nil, sidebarLabel: String = "Show sidebar") {
        self.init(title, leadingInset: leadingInset, sidebar: sidebar, sidebarLabel: sidebarLabel,
                  options: { EmptyView() })
    }
}

/// The options (`⋯`) menu of a toolbar or pane header: a native menu on a 28pt icon button
/// (24pt in the queue's header).
public struct NWOptionsMenu<Content: View>: View {
    let label: String
    let size: CGFloat
    @ViewBuilder let content: () -> Content

    public init(_ label: String = "Options", size: CGFloat = NW.Height.controlM, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.size = size
        self.content = content
    }

    public var body: some View {
        Menu(content: content) {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.nwIcon(size: size))
        .fixedSize()
        .accessibilityLabel(label)
    }
}

/// A right pane's header (Navigation board, `NWPaneHeader`): a title with a mono subtitle,
/// controls on the right, close last. 44pt, like the thread toolbar beside it.
public struct NWPaneHeader<Subtitle: View, Controls: View>: View {
    let title: String
    let closeLabel: String
    let close: (() -> Void)?
    @ViewBuilder let subtitle: () -> Subtitle
    @ViewBuilder let controls: () -> Controls

    public init(_ title: String, closeLabel: String = "Close pane", close: (() -> Void)?,
                @ViewBuilder subtitle: @escaping () -> Subtitle,
                @ViewBuilder controls: @escaping () -> Controls) {
        self.title = title
        self.closeLabel = closeLabel
        self.close = close
        self.subtitle = subtitle
        self.controls = controls
    }

    public var body: some View {
        HStack(spacing: NW.Space.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.nwSans(13, .semibold))
                    .foregroundStyle(.nw.textPrimary)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                subtitle()
                    .font(.nw(.micro, weight: .regular))
                    .foregroundStyle(.nw.textTertiary)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: NW.Space.m)
            controls()
            if let close {
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.nwIcon)
                    .nwHelp(closeLabel)
                    .accessibilityLabel(closeLabel)
            }
        }
        .padding(.leading, NWToolbarMetrics.paneLeadingPadding)
        .padding(.trailing, NWToolbarMetrics.paneTrailingPadding)
        .frame(minHeight: NWToolbarMetrics.height)
        .background(Color.nw.bgWindow)
        .overlay(alignment: .bottom) { NWHairline() }
    }
}

extension NWPaneHeader where Subtitle == EmptyView {
    public init(_ title: String, closeLabel: String = "Close pane", close: (() -> Void)?,
                @ViewBuilder controls: @escaping () -> Controls) {
        self.init(title, closeLabel: closeLabel, close: close, subtitle: { EmptyView() }, controls: controls)
    }
}
