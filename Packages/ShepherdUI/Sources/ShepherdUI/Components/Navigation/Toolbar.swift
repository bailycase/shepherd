import SwiftUI

/// The toolbar's and pane headers' fixed measures (Navigation board).
public enum SHToolbarMetrics {
    /// The thread toolbar and pane headers, unified with the title bar.
    public static let height: CGFloat = 44
    /// The thread toolbar's title sits 28pt in from the column (the boards' `.tbar`), its capsule 4pt from the edge.
    public static let leadingPadding: CGFloat = 28
    public static let trailingPadding: CGFloat = 4
    /// The trailing controls' capsule (the boards' `.cap`): 32pt tall, padded 4, its buttons 2pt apart.
    public static let capsuleHeight: CGFloat = 32
    public static let capsulePadding: CGFloat = 4
    public static let capsuleGap: CGFloat = 2
    /// Pane headers sit a little tighter.
    public static let paneLeadingPadding: CGFloat = 12
    public static let paneTrailingPadding: CGFloat = 6
}

/// The thread toolbar (the boards' `.tbar`): 44pt, no rule under it. The thread that started this
/// one (a link, when it is a sub-thread), the title in `title`, then its space in `textTertiary`
/// ("Speed up checkout CI  payments-api"), an accessory, and the trailing controls in a raised
/// capsule (the side-pane button and the options menu). While the sidebar is not docked, Show
/// sidebar and New thread lead; `leadingInset` clears the window controls. The space gives way
/// first when the toolbar narrows, then the parent, then the title truncates.
public struct SHThreadToolbar<Accessory: View, Trailing: View>: View {
    let title: String
    let project: String?
    let titleHelp: String?
    let parent: String?
    let openParent: (() -> Void)?
    let leadingInset: CGFloat
    let sidebar: (() -> Void)?
    let sidebarLabel: String
    let newThread: (() -> Void)?
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let trailing: () -> Trailing

    public init(_ title: String, project: String? = nil, titleHelp: String? = nil,
                parent: String? = nil, openParent: (() -> Void)? = nil,
                leadingInset: CGFloat = 0, sidebar: (() -> Void)? = nil, sidebarLabel: String = "Show sidebar",
                newThread: (() -> Void)? = nil,
                @ViewBuilder accessory: @escaping () -> Accessory,
                @ViewBuilder trailing: @escaping () -> Trailing) {
        self.newThread = newThread
        self.title = title
        self.project = project
        self.titleHelp = titleHelp
        self.parent = parent
        self.openParent = openParent
        self.leadingInset = leadingInset
        self.sidebar = sidebar
        self.sidebarLabel = sidebarLabel
        self.accessory = accessory
        self.trailing = trailing
    }

    public var body: some View {
        let _ = SHRenderProbe.tick("toolbar.thread")
        HStack(spacing: SH.Space.m) {
            if let sidebar {
                HStack(spacing: SHSidebarMetrics.topBarButtonGap) {
                    Button(action: sidebar) { Image(systemName: "sidebar.left") }
                        .buttonStyle(.shIcon)
                        .shHelp(sidebarLabel)
                        .accessibilityLabel(sidebarLabel)
                    if let newThread {
                        Button(action: newThread) { Image(systemName: "square.and.pencil") }
                            .buttonStyle(.shIcon)
                            .shHelp("New thread")
                            .accessibilityLabel("New thread")
                    }
                }
                .padding(.trailing, SH.Space.l)
            }
            // The space gives way first: it shows only while everything fits at full length.
            ViewThatFits(in: .horizontal) {
                breadcrumb(showsProject: project != nil, showsParent: parent != nil)
                breadcrumb(showsProject: false, showsParent: parent != nil)
                breadcrumb(showsProject: false, showsParent: false)
            }
            Spacer(minLength: SH.Space.l)
            if Trailing.self != EmptyView.self {
                SHToolbarCapsule { trailing() }
                    .layoutPriority(1)
            }
        }
        // Past the window controls the boards start the sidebar and New thread buttons 24pt on (GXSidebarHidden).
        .padding(.leading, (sidebar == nil ? SHToolbarMetrics.leadingPadding : SH.Space.xxl) + leadingInset)
        .padding(.trailing, SHToolbarMetrics.trailingPadding)
        .frame(height: SHToolbarMetrics.height)
        .frame(maxWidth: .infinity)
        .background(Color.sh.bgWindow)
    }

    private func breadcrumb(showsProject: Bool, showsParent: Bool) -> some View {
        HStack(spacing: SH.Space.m) {
            if showsParent, let parent {
                Group {
                    if let openParent {
                        Button(action: openParent) { Text(parent).foregroundStyle(.sh.running) }
                            .buttonStyle(.plain)
                            .shHelp("Open \(parent)")
                            .accessibilityLabel("Started by \(parent)")
                    } else {
                        Text(parent).foregroundStyle(.sh.textSecondary)
                            .accessibilityLabel("Started by \(parent)")
                    }
                }
                .lineLimit(1)
                Text("/")
                    .foregroundStyle(.sh.textTertiary)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.sh(.title))
                .foregroundStyle(.sh.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(titleHelp ?? title)
                .accessibilityAddTraits(.isHeader)
                // A rename or a settled name cross-fades.
                .shContentTransition(.crossFade)
                .shAnimation(.content, value: title)
            if showsProject, let project {
                Text(project)
                    .foregroundStyle(.sh.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityLabel("in \(project)")
            }
            accessory()
        }
        .font(.sh(.ui))
    }
}

/// The dot on a toolbar button (the side-pane button when pi opened something for the closed
/// pane), ringed in the toolbar's surface so it reads over the button's edge.
public struct SHToggleBadge: View {
    let visible: Bool

    public init(visible: Bool) { self.visible = visible }

    public var body: some View {
        if visible {
            Circle()
                .fill(Color.sh.running)
                .frame(width: 8, height: 8)
                .padding(SH.Space.xxs)
                .background(Color.sh.bgWindow, in: Circle())
                .offset(x: SH.Space.xxs, y: -SH.Space.xxs)
                .allowsHitTesting(false)
                .shTransition(.content)
        }
    }
}

extension SHThreadToolbar where Accessory == EmptyView, Trailing == EmptyView {
    /// A toolbar with only a title (no thread on screen).
    public init(_ title: String, leadingInset: CGFloat = 0, sidebar: (() -> Void)? = nil, sidebarLabel: String = "Show sidebar",
                newThread: (() -> Void)? = nil) {
        self.init(title, leadingInset: leadingInset, sidebar: sidebar, sidebarLabel: sidebarLabel, newThread: newThread,
                  accessory: { EmptyView() }, trailing: { EmptyView() })
    }
}

/// The toolbar's trailing controls in the boards' `.cap`: a 32pt capsule on `bgRaised` with a 1px
/// line and the `lift` shadow, its icon buttons 2pt apart. Nothing at all when it holds nothing.
public struct SHToolbarCapsule<Content: View>: View {
    @ViewBuilder let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) { self.content = content }

    public var body: some View {
        let shape = Capsule()
        HStack(spacing: SHToolbarMetrics.capsuleGap) { content() }
            .padding(.horizontal, SHToolbarMetrics.capsulePadding)
            .frame(height: SHToolbarMetrics.capsuleHeight)
            .shLift(shape)
            .overlay { shape.strokeBorder(Color.sh.lineStrong, lineWidth: 1).allowsHitTesting(false) }
            .fixedSize()
    }
}

/// The options (`⋯`) menu of a toolbar or pane header: a native menu on a 28pt icon button
/// (24pt in the queue's header).
public struct SHOptionsMenu<Content: View>: View {
    let label: String
    let size: CGFloat
    @ViewBuilder let content: () -> Content

    public init(_ label: String = "Options", size: CGFloat = SH.Height.controlM, @ViewBuilder content: @escaping () -> Content) {
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
        .buttonStyle(.shIcon(size: size))
        .fixedSize()
        .accessibilityLabel(label)
    }
}

/// A right pane's header (Navigation board, `SHPaneHeader`): a title with a mono subtitle,
/// controls on the right, close last. 44pt, like the thread toolbar beside it.
public struct SHPaneHeader<Subtitle: View, Controls: View>: View {
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
        HStack(spacing: SH.Space.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.shSans(13, .semibold))
                    .foregroundStyle(.sh.textPrimary)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                subtitle()
                    .font(.sh(.micro, weight: .regular))
                    .foregroundStyle(.sh.textTertiary)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: SH.Space.m)
            controls()
            if let close {
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.shIcon)
                    .shHelp(closeLabel)
                    .accessibilityLabel(closeLabel)
            }
        }
        .padding(.leading, SHToolbarMetrics.paneLeadingPadding)
        .padding(.trailing, SHToolbarMetrics.paneTrailingPadding)
        .frame(minHeight: SHToolbarMetrics.height)
        .background(Color.sh.bgWindow)
        .overlay(alignment: .bottom) { SHHairline() }
    }
}

extension SHPaneHeader where Subtitle == EmptyView {
    public init(_ title: String, closeLabel: String = "Close pane", close: (() -> Void)?,
                @ViewBuilder controls: @escaping () -> Controls) {
        self.init(title, closeLabel: closeLabel, close: close, subtitle: { EmptyView() }, controls: controls)
    }
}
