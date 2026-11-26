import SwiftUI

// Implement in a thread (ImplementInThreadSheet; RefImplementSheet, RefImplementBoard): a sheet
// over the canvas that hands the selected piece to a thread, an existing one picked from a
// searchable list or a new one in a project, with an optional message. Its footer says exactly
// what goes.

/// The sheet's own measures (.gdz-sheet, .gdz-head, .gdz-li, .gdz-sf2).
public enum SHImplementMetrics {
    public static let width: CGFloat = 560
    public static let radius: CGFloat = 16
    public static let paddingTop: CGFloat = 18
    public static let paddingHorizontal: CGFloat = 20
    public static let paddingBottom: CGFloat = 16
    public static let headerSpacing: CGFloat = 12
    public static let picture = CGSize(width: 72, height: 46)
    public static let pictureRadius: CGFloat = 6
    public static let titleSize: CGFloat = 15
    public static let subtitleSize: CGFloat = 12
    public static let subtitleTop: CGFloat = 2
    public static let closeSize: CGFloat = 24
    public static let closeGlyph: CGFloat = 11
    /// Under the header, and above each labelled part.
    public static let sectionTop: CGFloat = 16
    public static let searchTop: CGFloat = 12
    public static let listTop: CGFloat = 8
    public static let fieldSpacing: CGFloat = 6
    public static let labelSize: CGFloat = 12
    public static let fieldTextSize: CGFloat = 13
    public static let fieldPaddingVertical: CGFloat = 8
    public static let fieldPaddingHorizontal: CGFloat = 10
    public static let fieldMinHeight: CGFloat = 76
    public static let fieldLineSpacing: CGFloat = 3
    public static let checkTop: CGFloat = 10
    public static let rowHeight: CGFloat = 34
    public static let rowPadding: CGFloat = 8
    public static let rowSpacing: CGFloat = 10
    public static let rowNameSize: CGFloat = 13
    public static let rowMetaSize: CGFloat = 12
    public static let rowAge: CGFloat = 56
    /// The list shows this many threads; more scroll.
    public static let visibleRows: CGFloat = 5
    public static let projectHeight: CGFloat = 32
    public static let projectTextSize: CGFloat = 13
    public static let branchSize: CGFloat = 12
    public static let hintTop: CGFloat = 6
    public static let footerTop: CGFloat = 16
    public static let footerPaddingTop: CGFloat = 14
    public static let footerSpacing: CGFloat = 18
    public static let footerTextSize: CGFloat = 12
    public static let footerLineSpacing: CGFloat = 2
    // The segmented choice (.gdz-seg) and the pill (.sbtn)
    public static let segmentHeight: CGFloat = 26
    public static let segmentTrackRadius: CGFloat = 8
    public static let segmentRadius: CGFloat = 6
    public static let segmentPadding: CGFloat = 10
    public static let segmentSize: CGFloat = 12
    public static let pillHeight: CGFloat = 26
    public static let pillPadding: CGFloat = 11
    public static let pillSize: CGFloat = 12
    public static let linkSize: CGFloat = 13
}

/// Where the piece goes: a thread that exists, or a new one.
public enum SHImplementMode: Hashable, Sendable {
    case existing
    case new
}

/// The sheet (ImplementInThreadSheet): the piece's picture with "Implement <piece>" and where it
/// is (design › board · v23), a close button; Existing thread | New thread; what `content` holds
/// for the mode; then the footer: what gets sent, Cancel and Send. 560pt at radius 16 on the
/// raised fill with the popover's line and shadow. Center it over `Color.sh.sheetScrim`.
public struct SHImplementSheet<Content: View>: View {
    let picture: SHReferenceImage?
    let title: String
    let crumbs: [String]
    let version: String?
    @Binding var mode: SHImplementMode
    let sends: Text
    let canSend: Bool
    let sending: Bool
    let close: () -> Void
    let send: () -> Void
    @ViewBuilder let content: () -> Content

    public init(picture: SHReferenceImage?, title: String, crumbs: [String], version: String?, mode: Binding<SHImplementMode>,
                sends: Text, canSend: Bool, sending: Bool = false, close: @escaping () -> Void, send: @escaping () -> Void,
                @ViewBuilder content: @escaping () -> Content) {
        self.picture = picture
        self.title = title
        self.crumbs = crumbs
        self.version = version
        _mode = mode
        self.sends = sends
        self.canSend = canSend
        self.sending = sending
        self.close = close
        self.send = send
        self.content = content
    }

    /// "Checkout funnel dashboard › A · Funnel first · v23".
    private var subtitle: String {
        [crumbs.isEmpty ? nil : crumbs.joined(separator: " › "), version].compactMap { $0 }.joined(separator: " · ")
    }

    public var body: some View {
        let sh = Color.sh
        let M = SHImplementMetrics.self
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: M.headerSpacing) {
                SHReferenceThumbnail(picture, size: M.picture, radius: M.pictureRadius)
                VStack(alignment: .leading, spacing: M.subtitleTop) {
                    Text(title).font(.shSans(M.titleSize, .semibold)).foregroundStyle(sh.textPrimary).lineLimit(1)
                    Text(subtitle).font(.shSans(M.subtitleSize)).foregroundStyle(sh.textSecondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: SH.Space.m)
                Button(action: close) { Image(systemName: "xmark").font(.system(size: M.closeGlyph)) }
                    .buttonStyle(.shIcon(size: M.closeSize))
                    .help("Close")
                    .accessibilityLabel("Close")
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .fixedSize(horizontal: false, vertical: true)
            SHImplementSegments(mode: $mode).padding(.top, M.sectionTop)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            HStack(spacing: M.footerSpacing) {
                sends
                    .font(.shSans(M.footerTextSize))
                    .foregroundStyle(sh.textTertiary)
                    .lineSpacing(M.footerLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Cancel", action: close)
                    .buttonStyle(.shLink(color: sh.textSecondary, font: .shSans(M.linkSize)))
                    .keyboardShortcut(.cancelAction)
                Button(sending ? "Sending…" : "Send", action: send)
                    .buttonStyle(SHPillButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSend || sending)
            }
            .padding(.top, M.footerPaddingTop)
            .overlay(alignment: .top) { SHHairline() }
            .padding(.top, M.footerTop)
        }
        .padding(EdgeInsets(top: M.paddingTop, leading: M.paddingHorizontal, bottom: M.paddingBottom, trailing: M.paddingHorizontal))
        .frame(width: M.width)
        .background(sh.bgRaised, in: RoundedRectangle(cornerRadius: M.radius))
        .shPopover(radius: M.radius)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel(title)
    }

    /// The footer's words: `before`, then the system's name in mono, then `after`.
    public static func sends(_ before: String, mono: String?, after: String) -> Text {
        guard let mono else { return Text(before + after) }
        return Text("\(before)\(Text(mono).font(.shMono(SHImplementMetrics.footerTextSize)).foregroundColor(Color.sh.textSecondary))\(after)")
    }
}

/// The ink pill the design tool's sheets end on (.sbtn): 26pt, a capsule on the primary fill, its
/// label 12 medium. Dim while it can't be pressed.
public struct SHPillButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        SHPillButton(configuration: configuration)
    }
}

private struct SHPillButton: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        let sh = Color.sh
        let M = SHImplementMetrics.self
        configuration.label
            .font(.shSans(M.pillSize, .medium))
            .foregroundStyle(sh.textOnPrimary)
            .lineLimit(1)
            .padding(.horizontal, M.pillPadding)
            .frame(height: M.pillHeight)
            .background(configuration.isPressed ? sh.primaryPressed : hovering && enabled ? sh.primaryHover : sh.primary, in: Capsule())
            .offset(y: configuration.isPressed ? 0.5 : 0)
            .shEnabledOpacity(enabled)
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .shAnimation(.hover, value: hovering)
            .shFocusRing(radius: M.pillHeight / 2)
    }
}

/// Existing thread | New thread (.gdz-seg): 26pt on a faint track at radius 8, the chosen one
/// lifted on the raised fill.
struct SHImplementSegments: View {
    @Binding var mode: SHImplementMode

    var body: some View {
        let M = SHImplementMetrics.self
        let sh = Color.sh
        HStack(spacing: SH.Space.xxs) {
            ForEach([(SHImplementMode.existing, "Existing thread"), (.new, "New thread")], id: \.0) { option in
                let selected = option.0 == mode
                let shape = RoundedRectangle(cornerRadius: M.segmentRadius)
                Button { mode = option.0 } label: {
                    Text(option.1)
                        .font(.shSans(M.segmentSize, selected ? .medium : .regular))
                        .foregroundStyle(selected ? sh.textPrimary : sh.textSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, M.segmentPadding)
                        .frame(height: M.segmentHeight - 2 * SH.Space.xxs)
                        .background { shape.fill(.clear).shLift(shape, fill: sh.bgRaised).opacity(selected ? 1 : 0) }
                        .contentShape(shape)
                }
                .buttonStyle(.plain)
                .shAnimation(.hover, value: selected)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(SH.Space.xxs)
        .background(sh.bgHover, in: RoundedRectangle(cornerRadius: M.segmentTrackRadius))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Where it goes")
    }
}

/// A labelled part of the sheet: "Message", "Space". The label sits 16pt under what is above it.
public struct SHImplementField<Content: View>: View {
    let label: String?
    @ViewBuilder let content: () -> Content

    public init(_ label: String?, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SHImplementMetrics.fieldSpacing) {
            if let label {
                Text(label).font(.shSans(SHImplementMetrics.labelSize)).foregroundStyle(Color.sh.textSecondary)
            }
            content()
        }
        .padding(.top, SHImplementMetrics.sectionTop)
    }
}

/// The message field (.fld.ta): several lines on the raised fill with a line, at least 76pt, its
/// placeholder in `textTertiary`.
public struct SHImplementMessageField: View {
    @Binding var text: String
    let placeholder: String
    var focused: FocusState<Bool>.Binding?

    public init(text: Binding<String>, placeholder: String = "Anything the agent should know (optional)",
                focused: FocusState<Bool>.Binding? = nil) {
        _text = text
        self.placeholder = placeholder
        self.focused = focused
    }

    public var body: some View {
        let M = SHImplementMetrics.self
        let field = TextField(text: $text, prompt: Text(placeholder).foregroundStyle(Color.sh.textTertiary), axis: .vertical) {
            Text("Message")
        }
        .textFieldStyle(.plain)
        .font(.shSans(M.fieldTextSize))
        .foregroundStyle(Color.sh.textPrimary)
        .lineSpacing(M.fieldLineSpacing)
        .lineLimit(3...8)
        .padding(.vertical, M.fieldPaddingVertical)
        .padding(.horizontal, M.fieldPaddingHorizontal)
        .frame(minHeight: M.fieldMinHeight, alignment: .topLeading)
        .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.m))
        .shBorder(Color.sh.lineStrong, radius: SH.Radius.m)
        if let focused {
            field.focused(focused)
        } else {
            field
        }
    }
}

/// A thread the sheet can send to.
public struct SHImplementThread: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// Its project's name ("dashboard-web").
    public var project: String?
    /// Its host's name, on another host.
    public var host: String?
    /// "4m", "yesterday".
    public var age: String?

    public init(id: String, name: String, project: String? = nil, host: String? = nil, age: String? = nil) {
        self.id = id
        self.name = name
        self.project = project
        self.host = host
        self.age = age
    }
}

/// The threads to pick from (.gdz-list): 34pt rows divided by a hairline, the chosen one on
/// `bgSelected`, reaching 8pt past the sheet's text on each side. Past five they scroll.
public struct SHImplementThreadList: View {
    let threads: [SHImplementThread]
    @Binding var selection: String?

    public init(threads: [SHImplementThread], selection: Binding<String?>) {
        self.threads = threads
        _selection = selection
    }

    public var body: some View {
        let M = SHImplementMetrics.self
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(threads) { thread in
                        SHImplementThreadRow(thread: thread, selected: thread.id == selection) {
                            selection = thread.id
                        }
                        .equatable()
                        .id(thread.id)
                    }
                }
            }
            .scrollDisabled(CGFloat(threads.count) <= M.visibleRows)
            .frame(height: M.rowHeight * min(max(CGFloat(threads.count), 1), M.visibleRows))
            .onAppear { if let selection { proxy.scrollTo(selection) } }
        }
        .padding(.horizontal, -M.rowPadding)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Threads")
    }
}

/// One thread in the list. Equatable on what it draws.
struct SHImplementThreadRow: View, Equatable {
    let thread: SHImplementThread
    let selected: Bool
    let choose: () -> Void

    static func == (a: Self, b: Self) -> Bool { a.thread == b.thread && a.selected == b.selected }

    /// "dashboard-web", or "analytics-ingest on demo-mac" on another host.
    static func place(_ thread: SHImplementThread) -> String? {
        switch (thread.project, thread.host) {
        case (let project?, let host?): "\(project) on \(host)"
        case (let project?, nil): project
        case (nil, let host?): "on \(host)"
        case (nil, nil): nil
        }
    }

    var body: some View {
        let sh = Color.sh
        let M = SHImplementMetrics.self
        let shape = RoundedRectangle(cornerRadius: SH.Radius.s)
        Button(action: choose) {
            HStack(spacing: M.rowSpacing) {
                Text(thread.name)
                    .font(.shSans(M.rowNameSize))
                    .foregroundStyle(sh.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let place = Self.place(thread) {
                    Text(place).font(.shSans(M.rowMetaSize)).foregroundStyle(sh.textTertiary).lineLimit(1).layoutPriority(1)
                }
                Text(thread.age ?? "")
                    .font(.shSans(M.rowMetaSize))
                    .foregroundStyle(sh.textTertiary)
                    .lineLimit(1)
                    .frame(width: M.rowAge, alignment: .trailing)
            }
            .padding(.horizontal, M.rowPadding)
            .frame(height: M.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? sh.bgSelected : .clear, in: shape)
            .overlay(alignment: .bottom) { SHHairline().padding(.horizontal, M.rowPadding).opacity(selected ? 0 : 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel([thread.name, thread.project, thread.host, thread.age].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// The New thread tab's space field's label (.fld): the folder glyph and the space, the host
/// after it in `textTertiary` ("on This Mac"), and a chevron. The app puts it in a menu of its spaces.
public struct SHImplementProjectLabel: View {
    let project: String
    let host: String

    public init(project: String, host: String) {
        self.project = project
        self.host = host
    }

    public var body: some View {
        let sh = Color.sh
        let M = SHImplementMetrics.self
        HStack(spacing: SH.Space.m) {
            Image(systemName: "folder").font(.system(size: M.projectTextSize)).foregroundStyle(sh.textSecondary)
            Text(project).font(.shSans(M.projectTextSize)).foregroundStyle(sh.textPrimary).lineLimit(1)
            Text("on \(host)").font(.shSans(M.projectTextSize)).foregroundStyle(sh.textTertiary).lineLimit(1)
            Spacer(minLength: SH.Space.m)
            Image(systemName: "chevron.down").font(.system(size: M.projectTextSize - 3, weight: .semibold)).foregroundStyle(sh.textSecondary)
        }
        .padding(.horizontal, M.fieldPaddingHorizontal)
        .frame(height: M.projectHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.m))
        .shBorder(sh.lineStrong, radius: SH.Radius.m)
        .contentShape(Rectangle())
    }
}

/// Where a new thread starts (.cap2): "Starts on a new worktree, agent/implement-funnel-first", or
/// why it can't take one.
public struct SHImplementBranchLine: View {
    let words: String
    let branch: String?

    public init(_ words: String, branch: String? = nil) {
        self.words = words
        self.branch = branch
    }

    public var body: some View {
        let M = SHImplementMetrics.self
        HStack(spacing: SH.Space.xs) {
            Text(words)
            if let branch { Text(branch).font(.shMono(M.branchSize)).lineLimit(1) }
        }
        .font(.shSans(M.branchSize))
        .foregroundStyle(Color.sh.textTertiary)
        .padding(.top, M.hintTop - M.fieldSpacing)
    }
}
