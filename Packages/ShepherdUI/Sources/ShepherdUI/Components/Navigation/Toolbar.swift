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

/// The thread toolbar (`NWThreadToolbar`; Main, Review, QuestionAsk boards): 44pt, the space and
/// the title as a breadcrumb ("Shepherd / Investigate…"), an accessory beside them (the branch
/// chip), and the trailing controls (the side-pane button and the options menu). No status sits
/// beside the title: the thread and the sidebar already say what an agent is doing. A sidebar
/// button leads while the sidebar is not docked; `leadingInset` clears the window controls. The
/// space gives way first when the toolbar narrows, then the chip's branch and the title truncate.
public struct NWThreadToolbar<Accessory: View, Trailing: View>: View {
    let title: String
    let project: String?
    let titleHelp: String?
    let leadingInset: CGFloat
    let sidebar: (() -> Void)?
    let sidebarLabel: String
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let trailing: () -> Trailing

    public init(_ title: String, project: String? = nil, titleHelp: String? = nil,
                leadingInset: CGFloat = 0, sidebar: (() -> Void)? = nil, sidebarLabel: String = "Show sidebar",
                @ViewBuilder accessory: @escaping () -> Accessory,
                @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.project = project
        self.titleHelp = titleHelp
        self.leadingInset = leadingInset
        self.sidebar = sidebar
        self.sidebarLabel = sidebarLabel
        self.accessory = accessory
        self.trailing = trailing
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
            // The space gives way first: it shows only while everything fits at full length.
            ViewThatFits(in: .horizontal) {
                breadcrumb(showsProject: project != nil)
                breadcrumb(showsProject: false)
            }
            Spacer(minLength: NW.Space.l)
            HStack(spacing: NW.Space.xs) {
                trailing()
            }
            .fixedSize()
            .layoutPriority(1)
        }
        .padding(.leading, NWToolbarMetrics.leadingPadding + leadingInset)
        .padding(.trailing, NWToolbarMetrics.trailingPadding)
        .frame(height: NWToolbarMetrics.height)
        .frame(maxWidth: .infinity)
        .background(Color.nw.bgWindow)
        .overlay(alignment: .bottom) { NWHairline() }
    }

    private func breadcrumb(showsProject: Bool) -> some View {
        HStack(spacing: NW.Space.m) {
            if showsProject, let project {
                Text(project)
                    .foregroundStyle(.nw.textSecondary)
                    .lineLimit(1)
                    .accessibilityHidden(true)
                Text("/")
                    .foregroundStyle(.nw.textTertiary)
                    .accessibilityHidden(true)
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
            accessory()
        }
        .font(.nwSans(13))
    }
}

/// The dot on a toolbar button (the side-pane button when pi opened something for the closed
/// pane), ringed in the toolbar's surface so it reads over the button's edge.
public struct NWToggleBadge: View {
    let visible: Bool

    public init(visible: Bool) { self.visible = visible }

    public var body: some View {
        if visible {
            Circle()
                .fill(Color.nw.running)
                .frame(width: 8, height: 8)
                .padding(NW.Space.xxs)
                .background(Color.nw.bgWindow, in: Circle())
                .offset(x: NW.Space.xxs, y: -NW.Space.xxs)
                .allowsHitTesting(false)
                .nwTransition(.content)
        }
    }
}

extension NWThreadToolbar where Accessory == EmptyView, Trailing == EmptyView {
    /// A toolbar with only a title (no thread on screen).
    public init(_ title: String, leadingInset: CGFloat = 0, sidebar: (() -> Void)? = nil, sidebarLabel: String = "Show sidebar") {
        self.init(title, leadingInset: leadingInset, sidebar: sidebar, sidebarLabel: sidebarLabel,
                  accessory: { EmptyView() }, trailing: { EmptyView() })
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
