import SwiftUI

// Implement in a thread (ImplementInThreadSheet; RefImplementSheet, RefImplementBoard): a sheet
// over the canvas that hands the selected piece to a thread, an existing one picked from a
// searchable list or a new one in a project, with an optional message. Its footer says exactly
// what goes.

/// The sheet's own measures.
public enum SHImplementMetrics {
    public static let width: CGFloat = 540
    public static let radius: CGFloat = 14
    public static let headerPaddingTop: CGFloat = 20
    public static let headerPaddingLeading: CGFloat = 20
    public static let headerPaddingTrailing: CGFloat = 18
    public static let headerPaddingBottom: CGFloat = 16
    public static let headerSpacing: CGFloat = 14
    public static let picture = CGSize(width: 88, height: 56)
    public static let pictureRadius: CGFloat = 6
    public static let titleSize: CGFloat = 16
    public static let titleSpacing: CGFloat = 5
    public static let versionSize: CGFloat = 11
    public static let closeSize: CGFloat = 28
    public static let paddingHorizontal: CGFloat = 20
    public static let bodyPaddingTop: CGFloat = 14
    public static let bodyPaddingBottom: CGFloat = 16
    public static let bodySpacing: CGFloat = 14
    public static let fieldSpacing: CGFloat = 6
    public static let labelSize: CGFloat = 12
    public static let fieldTextSize: CGFloat = 13
    public static let fieldPaddingVertical: CGFloat = 9
    public static let fieldPaddingHorizontal: CGFloat = 11
    public static let fieldMinHeight: CGFloat = 58
    public static let rowHeight: CGFloat = 38
    public static let rowPadding: CGFloat = 12
    public static let rowSpacing: CGFloat = 10
    public static let rowDot: CGFloat = 7
    public static let rowDotRing: CGFloat = 1.5
    public static let rowNameSize: CGFloat = 13
    public static let rowMetaSize: CGFloat = 11.5
    public static let rowCheck: CGFloat = 13
    public static let listRadius: CGFloat = 9
    /// The list shows this many threads; more scroll.
    public static let visibleRows: CGFloat = 5
    public static let projectHeight: CGFloat = 34
    public static let projectTextSize: CGFloat = 12.5
    public static let branchSize: CGFloat = 12
    public static let branchMonoSize: CGFloat = 11.5
    public static let checkLabelSize: CGFloat = 12.5
    public static let footerPaddingTop: CGFloat = 12
    public static let footerPaddingBottom: CGFloat = 14
    public static let footerPaddingLeading: CGFloat = 20
    public static let footerPaddingTrailing: CGFloat = 16
    public static let footerSpacing: CGFloat = 8
    public static let footerTextSize: CGFloat = 11.5
    public static let footerMonoSize: CGFloat = 11
}

/// Where the piece goes: a thread that exists, or a new one.
public enum SHImplementMode: Hashable, Sendable {
    case existing
    case new
}

/// The sheet (ImplementInThreadSheet): the piece's picture with "Implement <piece>" and where it
/// is (design › board · v23), a close button; Existing thread | New thread; what `content` holds
/// for the mode; then the footer: what gets sent, Cancel and Send. 540pt at radius 14 on
/// `bgWindow` with the popover's line and shadow. Center it over `Color.sh.sheetScrim`.
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

    public var body: some View {
        let sh = Color.sh
        let M = SHImplementMetrics.self
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: M.headerSpacing) {
                SHReferenceThumbnail(picture, size: M.picture, radius: M.pictureRadius)
                VStack(alignment: .leading, spacing: M.titleSpacing) {
                    Text(title).font(.shSans(M.titleSize, .semibold)).foregroundStyle(sh.textPrimary).lineLimit(1)
                    HStack(spacing: SH.Space.s) {
                        HStack(spacing: SHReferenceMetrics.crumbSpacing) {
                            ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                                if index > 0 { Text("›").foregroundStyle(sh.textTertiary) }
                                Text(crumb).foregroundStyle(sh.textSecondary).lineLimit(1)
                            }
                        }
                        .font(.shSans(SHReferenceMetrics.crumbSize))
                        if let version {
                            Text("·").font(.shSans(SHReferenceMetrics.crumbSize)).foregroundStyle(sh.textTertiary)
                            Text(version).font(.shMono(M.versionSize)).foregroundStyle(sh.textTertiary).fixedSize()
                        }
                    }
                }
                Spacer(minLength: SH.Space.m)
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.shIcon(bordered: true, size: M.closeSize))
                    .help("Close")
                    .accessibilityLabel("Close")
            }
            .padding(EdgeInsets(top: M.headerPaddingTop, leading: M.headerPaddingLeading, bottom: M.headerPaddingBottom,
                                trailing: M.headerPaddingTrailing))
            SHSegmentedPicker("Where it goes", selection: $mode, options: [(.existing, "Existing thread"), (.new, "New thread")])
                .padding(.horizontal, M.paddingHorizontal)
            VStack(alignment: .leading, spacing: M.bodySpacing) {
                content()
            }
            .padding(EdgeInsets(top: M.bodyPaddingTop, leading: M.paddingHorizontal, bottom: M.bodyPaddingBottom, trailing: M.paddingHorizontal))
            HStack(spacing: M.footerSpacing) {
                sends
                    .font(.shSans(M.footerTextSize))
                    .foregroundStyle(sh.textTertiary)
                    .lineSpacing(SH.Space.xxs)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Cancel", action: close)
                    .buttonStyle(.sh(.ghost))
                    .keyboardShortcut(.cancelAction)
                Button(sending ? "Sending…" : "Send", systemImage: "arrow.up", action: send)
                    .buttonStyle(.sh(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSend || sending)
            }
            .padding(EdgeInsets(top: M.footerPaddingTop, leading: M.footerPaddingLeading, bottom: M.footerPaddingBottom,
                                trailing: M.footerPaddingTrailing))
            .background(sh.bgSunken)
            .overlay(alignment: .top) { SHHairline() }
        }
        .frame(width: M.width)
        .background(sh.bgWindow)
        .clipShape(RoundedRectangle(cornerRadius: M.radius))
        .shPopover(radius: M.radius)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel(title)
    }

    /// The footer's words: `before`, then the system's name in mono, then `after`.
    public static func sends(_ before: String, mono: String?, after: String) -> Text {
        guard let mono else { return Text(before + after) }
        return Text("\(before)\(Text(mono).font(.shMono(SHImplementMetrics.footerMonoSize)))\(after)")
    }
}

/// A labelled part of the sheet: "Message", "Project".
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
                Text(label).font(.shSans(SHImplementMetrics.labelSize, .medium)).foregroundStyle(Color.sh.textSecondary)
            }
            content()
        }
    }
}

/// The message field: several lines on `bgRaised` with a strong line, its placeholder in
/// `textTertiary`.
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
        .lineSpacing(SH.Space.xxs)
        .lineLimit(2...6)
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

/// The threads to pick from (ThreadPicker): 38pt rows in a bordered list, the chosen one on
/// `runningTint` with a filled dot and a check, the rest an open ring. Past five they scroll.
public struct SHImplementThreadList: View {
    let threads: [SHImplementThread]
    @Binding var selection: String?

    public init(threads: [SHImplementThread], selection: Binding<String?>) {
        self.threads = threads
        _selection = selection
    }

    public var body: some View {
        let M = SHImplementMetrics.self
        let shape = RoundedRectangle(cornerRadius: M.listRadius)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(threads.enumerated()), id: \.element.id) { index, thread in
                        SHImplementThreadRow(thread: thread, selected: thread.id == selection, first: index == 0) {
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
        .clipShape(shape)
        .shBorder(Color.sh.lineSubtle, in: shape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Threads")
    }
}

/// One thread in the list. Equatable on what it draws.
struct SHImplementThreadRow: View, Equatable {
    let thread: SHImplementThread
    let selected: Bool
    let first: Bool
    let choose: () -> Void

    static func == (a: Self, b: Self) -> Bool { a.thread == b.thread && a.selected == b.selected && a.first == b.first }

    var body: some View {
        let sh = Color.sh
        let M = SHImplementMetrics.self
        Button(action: choose) {
            HStack(spacing: M.rowSpacing) {
                Group {
                    if selected {
                        Circle().fill(sh.running)
                    } else {
                        Circle().strokeBorder(sh.textTertiary, lineWidth: M.rowDotRing)
                    }
                }
                .frame(width: M.rowDot, height: M.rowDot)
                Text(thread.name)
                    .font(.shSans(M.rowNameSize, selected ? .semibold : .medium))
                    .foregroundStyle(sh.textPrimary)
                    .lineLimit(1)
                if let project = thread.project {
                    HStack(spacing: SH.Space.xs) {
                        Image(systemName: "folder").font(.system(size: M.rowMetaSize - 1))
                        Text(project).font(.shMono(M.rowMetaSize - 0.5)).lineLimit(1)
                    }
                    .foregroundStyle(sh.textTertiary)
                }
                if let host = thread.host { SHReferenceHostTag(host) }
                Spacer(minLength: SH.Space.m)
                if let age = thread.age {
                    Text(age).font(.shSans(M.rowMetaSize)).foregroundStyle(sh.textTertiary).fixedSize()
                }
                Image(systemName: "checkmark")
                    .font(.system(size: M.rowCheck - 2, weight: .semibold))
                    .foregroundStyle(sh.running)
                    .frame(width: M.rowCheck)
                    .opacity(selected ? 1 : 0)
            }
            .padding(.horizontal, M.rowPadding)
            .frame(height: M.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? sh.runningTint : .clear)
            .overlay(alignment: .top) { if !first { SHHairline() } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel([thread.name, thread.project, thread.host, thread.age].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// The New thread tab's project field's label: the folder glyph and the project in mono, "·",
/// the host with its glyph, and a chevron. The app puts it in a menu of its projects.
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
            Text(project).font(.shMono(M.projectTextSize)).foregroundStyle(sh.textPrimary).lineLimit(1)
            Text("·").foregroundStyle(sh.textTertiary)
            Image(systemName: "desktopcomputer").font(.system(size: M.projectTextSize)).foregroundStyle(sh.textSecondary)
            Text(host).font(.shMono(M.projectTextSize)).foregroundStyle(sh.textPrimary).lineLimit(1)
            Spacer(minLength: SH.Space.m)
            Image(systemName: "chevron.down").font(.system(size: M.projectTextSize - 3, weight: .semibold)).foregroundStyle(sh.textTertiary)
        }
        .padding(.horizontal, SH.Space.l - 2)
        .frame(height: M.projectHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.m))
        .shBorder(sh.lineStrong, radius: SH.Radius.m)
        .contentShape(Rectangle())
    }
}

/// Where a new thread starts: "Starts on a new worktree, agent/implement-funnel-first", or why it
/// can't take one.
public struct SHImplementBranchLine: View {
    let words: String
    let branch: String?

    public init(_ words: String, branch: String? = nil) {
        self.words = words
        self.branch = branch
    }

    public var body: some View {
        let sh = Color.sh
        let M = SHImplementMetrics.self
        HStack(spacing: SH.Space.s) {
            Image(systemName: SHGlyph.gitBranch.symbolName).font(.system(size: M.branchSize - 1))
            Text(words)
            if let branch { Text(branch).font(.shMono(M.branchMonoSize)).foregroundStyle(sh.textSecondary).lineLimit(1) }
        }
        .font(.shSans(M.branchSize))
        .foregroundStyle(sh.textTertiary)
    }
}
