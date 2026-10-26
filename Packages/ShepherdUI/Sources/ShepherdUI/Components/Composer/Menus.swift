import SwiftUI

// The composer's popovers (SHComposer board, "Menus"): radius 12, raised, the popover shadow,
// 28pt rows, running-tint selection. ↑↓ move, ⏎ chooses, esc closes.

/// A section label in a composer menu (SHComposer › Menus: COMMANDS, RECENT, MODEL, THINKING,
/// SPEED): mono 10 medium, uppercase, tracked 6%, `textTertiary`, with an optional trailing count
/// in mono 11 `textTertiary` ("4 of 23").
public struct SHMenuHeader: View {
    let title: String
    let trailing: String?
    let inset: CGFloat

    public init(_ title: String, trailing: String? = nil, inset: CGFloat = SH.Space.m) {
        self.title = title
        self.trailing = trailing
        self.inset = inset
    }

    public var body: some View {
        HStack(spacing: SH.Space.m) {
            Text(title)
                .font(.shMono(10, .medium))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(.sh.textTertiary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing).font(.shMono(11)).foregroundStyle(.sh.textTertiary).monospacedDigit()
            }
        }
        .padding(.horizontal, inset)
        .frame(height: SHComposerMetrics.menuHeaderHeight)
    }
}

/// Debug builds count the menu rows they draw, so tests can pin how much of a long menu a change
/// redraws (opening, filtering, scrolling, a hover). Release builds declare it too, so the test
/// targets build for the release benchmarks; it stays zero there.
@MainActor public enum SHMenuDiagnostics {
    public static var rowBodies = 0
    /// How many times a menu's list was put back at its top (`SHMenuListStartsAtTop`).
    public static var listReturns = 0
}

/// A 28pt menu row: `runningTint` while highlighted, hovering highlights it, and a click (or
/// VoiceOver's press) chooses it. It is not a `Button`: each button brings an AppKit focus-ring
/// view, and a long menu scrolls rows in and out; the field or the menu keeps keyboard focus.
struct SHMenuRow<Label: View>: View {
    let highlighted: Bool
    /// 10pt between parts; the slash menu's columns sit 12pt apart.
    var spacing: CGFloat = 10
    /// Two-line rows (the Send menu's) align their parts to the top.
    var alignment: VerticalAlignment = .center
    var padding = EdgeInsets(top: 0, leading: SH.Space.m, bottom: 0, trailing: SH.Space.m)
    var height = SHComposerMetrics.menuRowHeight
    let action: () -> Void
    let onHover: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        #if DEBUG
        let _ = SHMenuDiagnostics.rowBodies += 1
        #endif
        HStack(alignment: alignment, spacing: spacing) { label() }
            .padding(padding)
            .frame(minHeight: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(highlighted ? Color.sh.runningTint : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.s))
            .contentShape(RoundedRectangle(cornerRadius: SH.Radius.s))
            .onTapGesture(perform: action)
            .onHover { if $0 { onHover() } }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(highlighted ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { action() }
    }
}

/// The popover a menu sits on: its board width, or narrower when that is all the room offered
/// (a composer beside a docked pane); with no width, as wide as it is offered (the slash menu
/// spans the composer card).
struct SHMenuSurface: ViewModifier {
    let width: CGFloat?
    var padding: CGFloat = SH.Space.s

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(idealWidth: width, maxWidth: width ?? .infinity)
            .shPopover()
    }
}

/// A menu's list starts at its top. While a composer menu grows from its bottom corner, the scale
/// moves its hosted scroll view's frame, and AppKit drifts the list a few points down (9pt for
/// eight rows); so for as long as the menu is growing, and until the reader or ↑↓ scroll it,
/// the list is put back at its top.
///
/// Under that scale AppKit also snaps the clip view to device pixels, so the list cannot sit at
/// exactly 0 until the menu stops growing: putting it back lands it a fraction of a point off,
/// which reports a new offset. Put back from inside that report, the two chased each other within
/// one display pass, and with the pointer over the window AppKit's cursor hit-testing kept the
/// chase going until it threw. So only a drift of a point or more counts, and the list is put
/// back once, on the main queue's next turn, however many offsets one pass reports.
private struct SHMenuListStartsAtTop: ViewModifier {
    /// The list's first row. (Not a zero-height marker: a lazy stack that starts with one
    /// misplaces every row a scroll aims at.)
    let top: String?
    let proxy: ScrollViewProxy
    let list: SHMenuListMotion

    /// Past the overlay motion's settle (about 1.7× its 180ms anchor), with room to spare.
    private static let growing = Duration.seconds(SH.Motion.overlay.duration * 3)
    /// Less than this is the growth's pixel snapping, not a drift.
    private static let drift: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { _, phase in if phase != .idle { list.moved = true } }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, offset in
                guard let top, !list.moved, !list.returning, abs(offset) >= Self.drift,
                      ContinuousClock.now - list.appeared < Self.growing else { return }
                list.returning = true
                Task { @MainActor in
                    list.returning = false
                    guard !list.moved else { return }
                    #if DEBUG
                    SHMenuDiagnostics.listReturns += 1
                    #endif
                    proxy.scrollTo(top, anchor: .top)
                }
            }
    }
}

/// When a menu's list appeared, whether it has been scrolled since, and whether it is about to be
/// put back at its top: bookkeeping, read and written as the list moves (never while drawing), so
/// a plain reference.
final class SHMenuListMotion {
    let appeared = ContinuousClock.now
    var moved = false
    var returning = false
}

// MARK: Slash menu

/// A command the slash menu offers: pi's registry, never hard-coded.
public struct SHSlashCommand: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var description: String?
    /// "[session]" after the name, in `textTertiary`.
    public var arguments: String?
    /// "prompt" for a prompt template, shown as a tag.
    public var tag: String?
    /// An argument row's command before it, in `textSecondary` ("/login" before "anthropic"): the
    /// name then shows without its slash.
    public var lead: String?
    /// A word trailing the row in caption, in its tone ("Not signed in", "Signed in").
    public var status: Status?

    public struct Status: Equatable, Sendable {
        public enum Tone: Sendable { case tertiary, secondary, attention, done }
        public var text: String
        public var tone: Tone
        public init(_ text: String, tone: Tone) {
            self.text = text
            self.tone = tone
        }
    }

    public init(name: String, description: String? = nil, arguments: String? = nil, tag: String? = nil, lead: String? = nil,
                status: Status? = nil) {
        self.name = name
        self.description = description
        self.arguments = arguments
        self.tag = tag
        self.lead = lead
        self.status = status
    }
}

/// The slash menu (SlashMenu board): as wide as the composer card, "Commands · n of m", then
/// one-line 36pt rows: the command in mono 12.5 with the typed prefix in semibold `textPrimary`,
/// the rest `textSecondary` and its argument hint `textTertiary` (a column at least 150pt wide,
/// never wrapping), its description truncating at the end, a tag for prompt templates and
/// skills, and ⏎ on the highlighted row. At most 8 rows show, fewer when `maxHeight` leaves less
/// room. The field keeps focus and drives the selection.
///
/// Rows are lazy and redraw only when their command, its typed prefix, or their highlight
/// changes. ↑↓ scroll the highlight into view; the pointer's highlight is already under the
/// pointer, so a hover (or the list scrolling under a still pointer) never scrolls it.
public struct SHSlashMenu: View {
    let commands: [SHSlashCommand]
    let total: Int
    let query: String
    let title: String
    @Binding var selection: Int
    let maxHeight: CGFloat?
    let onChoose: (SHSlashCommand) -> Void
    /// The row the pointer just highlighted, until the highlight's change is seen.
    @State private var pointed: Int?
    @State private var listMotion = SHMenuListMotion()

    /// `title` heads it: "Commands", or an argument list's ("Sign in to · opens Settings").
    public init(commands: [SHSlashCommand], total: Int, query: String, title: String = "Commands", selection: Binding<Int>,
                maxHeight: CGFloat? = nil, onChoose: @escaping (SHSlashCommand) -> Void) {
        self.commands = commands
        self.total = total
        self.query = query
        self.title = title
        _selection = selection
        self.maxHeight = maxHeight
        self.onChoose = onChoose
    }

    public var body: some View {
        let rows = CGFloat(min(max(commands.count, 1), Self.visibleRows(in: maxHeight)))
        VStack(alignment: .leading, spacing: 0) {
            SHMenuHeader(title, trailing: "\(commands.count) of \(total)")
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(commands.enumerated()), id: \.element.name) { index, command in
                            SHSlashRow(command: command, typed: typed(command), index: index, highlighted: index == selection, choose: onChoose,
                                       hover: { index in
                                           guard index != selection else { return }
                                           pointed = index
                                           selection = index
                                       })
                                .equatable()
                        }
                        if commands.isEmpty {
                            Text("No command matches “/\(query)”").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                                .padding(.horizontal, SH.Space.l)
                                .frame(height: SHComposerMetrics.slashRowHeight)
                        }
                    }
                }
                .modifier(SHMenuListStartsAtTop(top: commands.first?.name, proxy: proxy, list: listMotion))
                .frame(height: rows * SHComposerMetrics.slashRowHeight)
                .onChange(of: selection) { _, index in
                    // Each pointer move is seen once, so a later ↑↓ back to that row still shows it.
                    defer { pointed = nil }
                    guard index != pointed, commands.indices.contains(index) else { return }
                    listMotion.moved = true
                    proxy.scrollTo(commands[index].name)
                }
            }
        }
        .modifier(SHMenuSurface(width: nil))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    /// How many rows fit a menu at most `height` tall (at least one, at most the board's eight).
    static func visibleRows(in height: CGFloat?) -> Int {
        guard let height, height.isFinite else { return SHComposerMetrics.menuMaxRows }
        let room = height - SHComposerMetrics.menuHeaderHeight - 2 * SH.Space.s
        return max(1, min(SHComposerMetrics.menuMaxRows, Int((room / SHComposerMetrics.slashRowHeight).rounded(.down))))
    }

    /// How much of the command's name the query types: its whole length when it is a prefix.
    private func typed(_ command: SHSlashCommand) -> Int {
        command.name.lowercased().hasPrefix(query.lowercased()) ? query.count : 0
    }
}

/// One command in the slash menu. Equatable on what it draws (closures aside), so a highlight
/// moving redraws the two rows it moves between.
struct SHSlashRow: View, Equatable {
    let command: SHSlashCommand
    /// The length of the typed prefix, in semibold.
    let typed: Int
    let index: Int
    let highlighted: Bool
    let choose: (SHSlashCommand) -> Void
    let hover: (Int) -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.command == b.command && a.typed == b.typed && a.index == b.index && a.highlighted == b.highlighted
    }

    var body: some View {
        let sh = Color.sh
        SHMenuRow(highlighted: highlighted, spacing: SH.Space.l, padding: EdgeInsets(top: 0, leading: SH.Space.l, bottom: 0, trailing: SH.Space.l),
                  height: SHComposerMetrics.slashRowHeight, action: { choose(command) }, onHover: { hover(index) }) {
            // The whole command on one line: the description gives way first.
            name
                .lineLimit(1)
                .frame(minWidth: SHComposerMetrics.slashNameWidth, alignment: .leading)
                .layoutPriority(1)
            Text(command.description ?? "").font(.shSans(13)).foregroundStyle(sh.textSecondary)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let tag = command.tag { SHTag(tag) }
            if let status = command.status {
                Text(status.text).font(.sh(.caption)).foregroundStyle(Self.color(status.tone)).lineLimit(1).fixedSize()
            }
            if highlighted {
                Text("⏎").font(.shMono(11)).foregroundStyle(sh.running).accessibilityHidden(true)
            }
        }
        .help(command.lead.map { $0 + " " + command.name } ?? "/" + command.name + (command.arguments.map { " " + $0 } ?? ""))
        .accessibilityLabel((command.lead.map { $0 + " " + command.name } ?? "/\(command.name)") + (command.description.map { ", \($0)" } ?? "")
                            + (command.status.map { ", \($0.text)" } ?? ""))
    }

    static func color(_ tone: SHSlashCommand.Status.Tone) -> Color {
        switch tone {
        case .tertiary: .sh.textTertiary
        case .secondary: .sh.textSecondary
        case .attention: .sh.lanternText
        case .done: .sh.done
        }
    }

    private var name: Text {
        let sh = Color.sh
        if let lead = command.lead {
            // An argument row: "/login" quiet, then the argument with what's typed in semibold.
            let head = Text(lead + " ").foregroundStyle(sh.textSecondary)
            let typedPart = Text(String(command.name.prefix(typed))).fontWeight(.semibold).foregroundStyle(sh.textPrimary)
            let rest = Text(String(command.name.dropFirst(typed))).foregroundStyle(sh.textPrimary)
            return Text("\(head)\(typedPart)\(rest)").font(.shMono(12.5))
        }
        let head = Text("/" + command.name.prefix(typed)).fontWeight(.semibold).foregroundStyle(sh.textPrimary)
        let tail = Text(String(command.name.dropFirst(typed))).foregroundStyle(sh.textSecondary)
        let arguments = Text(command.arguments.map { " " + $0 } ?? "").foregroundStyle(sh.textTertiary)
        return Text("\(head)\(tail)\(arguments)").font(.shMono(12.5))
    }
}

// MARK: Model picker

/// A model the picker offers.
public struct SHModelOption: Identifiable, Equatable, Sendable {
    public var id: String
    /// The name the row shows ("claude-opus"), truncated in the middle when long.
    public var title: String
    /// The row's second line, truncated at its end: the model's thinking levels ("Off · Low ·
    /// Medium · High", "No thinking").
    public var subtitle: String?
    /// A trailing note in mono 11 (the context size, "200K").
    public var note: String?
    public var isCurrent: Bool
    /// The model offers a raised service tier (Fast): the picker tags its row "fast", and the
    /// model-settings popover marks it with a bolt.
    public var fast: Bool

    public init(id: String, title: String, subtitle: String? = nil, note: String? = nil, isCurrent: Bool = false, fast: Bool = false) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.note = note
        self.isCurrent = isCurrent
        self.fast = fast
    }
}

public struct SHModelSection: Identifiable, Equatable, Sendable {
    public var id: String { title }
    public var title: String
    public var options: [SHModelOption]

    public init(title: String, options: [SHModelOption]) {
        self.title = title
        self.options = options
    }
}

/// The model picker's list, flattened once from its sections rather than on every draw: one row
/// per section header and per model, each model's position among the models (what ↑↓ and the
/// highlight count in), and the list's height.
public struct SHModelList: Equatable, Sendable {
    public struct Row: Identifiable, Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case header(String)
            case option(SHModelOption, position: Int)
        }

        /// Unique in the list: a model can be in Recent and in its provider's section.
        public let id: String
        public let kind: Kind

        /// The model's position among the list's models; nil for a header.
        public var position: Int? {
            if case .option(_, let position) = kind { return position }
            return nil
        }
    }

    public let rows: [Row]
    /// Every model in order: `options[selection]` is the highlighted one.
    public let options: [SHModelOption]
    /// The row of each model in `options`.
    private let optionRows: [String]
    /// Every row at its fixed height: headers 24pt with 4pt above, models 40pt.
    public let height: CGFloat

    public init(sections: [SHModelSection]) {
        var rows: [Row] = []
        var options: [SHModelOption] = []
        var optionRows: [String] = []
        for section in sections where !section.options.isEmpty {
            rows.append(Row(id: "#" + section.title, kind: .header(section.title)))
            for option in section.options {
                let id = section.title + "/" + option.id
                rows.append(Row(id: id, kind: .option(option, position: options.count)))
                options.append(option)
                optionRows.append(id)
            }
        }
        self.rows = rows
        self.options = options
        self.optionRows = optionRows
        let headers = rows.count - options.count
        height = CGFloat(headers) * (SHComposerMetrics.menuHeaderHeight + SHComposerMetrics.modelSectionGap)
            + CGFloat(options.count) * SHComposerMetrics.modelRowHeight
    }

    /// The row that shows `options[position]`.
    public func rowID(ofOption position: Int) -> String? {
        optionRows.indices.contains(position) ? optionRows[position] : nil
    }
}

/// The model picker (ModelPicker board): 380pt, a search row ("Search models", the picker's
/// chord trailing) over Recent and one section per provider; two-line 40pt rows with a `running`
/// check on the current model, its name in mono 12.5 (truncated in the middle, so the provider
/// and the model's tail both show; the whole id in its tooltip), a second line, and its context
/// size trailing. The list is at most 360pt tall, and the whole picker at most `maxHeight`. The
/// search field takes focus and drives the selection.
///
/// A catalog runs to hundreds of models, so the list is lazy: only the rows on screen exist, and
/// a row redraws only when its model or its highlight changes. ↑↓ scroll the highlight into view;
/// the pointer passing over rows (or the list scrolling under it) moves the highlight without
/// scrolling the list.
public struct SHModelPicker: View {
    @Binding var query: String
    let list: SHModelList
    let loading: Bool
    @Binding var selection: Int
    let maxHeight: CGFloat?
    /// The chord that opens the picker ("⇧⌘M"), shown in the search row.
    let shortcut: String?
    let onChoose: (SHModelOption) -> Void
    let onClose: () -> Void
    @FocusState private var searching: Bool
    /// The model the pointer just highlighted, until the highlight's change is seen.
    @State private var pointed: Int?
    @State private var listMotion = SHMenuListMotion()

    public init(query: Binding<String>, list: SHModelList, loading: Bool = false, selection: Binding<Int>,
                maxHeight: CGFloat? = nil, shortcut: String? = nil, onChoose: @escaping (SHModelOption) -> Void,
                onClose: @escaping () -> Void) {
        _query = query
        self.list = list
        self.loading = loading
        _selection = selection
        self.maxHeight = maxHeight
        self.shortcut = shortcut
        self.onChoose = onChoose
        self.onClose = onClose
    }

    public init(query: Binding<String>, sections: [SHModelSection], loading: Bool = false, selection: Binding<Int>,
                maxHeight: CGFloat? = nil, shortcut: String? = nil, onChoose: @escaping (SHModelOption) -> Void,
                onClose: @escaping () -> Void) {
        self.init(query: query, list: SHModelList(sections: sections), loading: loading, selection: selection, maxHeight: maxHeight,
                  shortcut: shortcut, onChoose: onChoose, onClose: onClose)
    }

    /// The list's height limit: the board's 360pt, or what `maxHeight` leaves under the search.
    static func listMaxHeight(in height: CGFloat?) -> CGFloat {
        let chrome = SHComposerMetrics.modelSearchHeight + 2 * SH.Space.xs
        return max(SHComposerMetrics.modelRowHeight, min(SHComposerMetrics.modelPickerMaxHeight, (height ?? .infinity) - chrome))
    }

    private static let loadingRow = "loading"

    public var body: some View {
        let sh = Color.sh
        // Rows have fixed heights, so the list's height is known without laying any of them out.
        let height = min(list.height + (loading ? SHComposerMetrics.menuRowHeight : 0), Self.listMaxHeight(in: maxHeight))
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: SH.Space.m) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(sh.textTertiary)
                    TextField(text: $query, prompt: Text("Search models").foregroundStyle(sh.textTertiary)) { Text("Search models") }
                        .textFieldStyle(.plain)
                        .font(.shSans(13))
                        .foregroundStyle(sh.textPrimary)
                        .focused($searching)
                        .onKeyPress(.downArrow) { move(to: selection + 1); return .handled }
                        .onKeyPress(.upArrow) { move(to: selection - 1); return .handled }
                        .onKeyPress(.return) {
                            if list.options.indices.contains(selection) { onChoose(list.options[selection]) }
                            return .handled
                        }
                        .onKeyPress(.escape) { onClose(); return .handled }
                        .accessibilityLabel("Search models")
                    if let shortcut {
                        Text(shortcut).font(.shMono(11)).foregroundStyle(sh.textTertiary).accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, SH.Space.m)
                .frame(height: SHComposerMetrics.modelSearchHeight)
                .overlay(alignment: .bottom) { SHHairline() }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if loading {
                            HStack(spacing: SH.Space.m) {
                                ProgressView().progressViewStyle(.shSpinner(size: 12))
                                Text("Loading models…").font(.sh(.caption)).foregroundStyle(sh.textTertiary)
                            }
                            .padding(.horizontal, SH.Space.m)
                            .frame(height: SHComposerMetrics.menuRowHeight)
                            .id(Self.loadingRow)
                            .shTransition(.content)
                        }
                        ForEach(list.rows) { row in
                            SHModelListRow(row: row, highlighted: row.position == selection, choose: onChoose, hover: { position in
                                guard position != selection else { return }
                                pointed = position
                                selection = position
                            })
                            .equatable()
                        }
                    }
                    // The catalog arriving replaces "Loading models…"; filtering stays instant.
                    .shAnimation(.content, value: loading)
                }
                .modifier(SHMenuListStartsAtTop(top: top, proxy: proxy, list: listMotion))
                .frame(height: height)
                .padding(.horizontal, SH.Space.s)
                .padding(.vertical, SH.Space.xs)
                .onChange(of: selection) { _, position in
                    // Each pointer move is seen once, so a later ↑↓ back to that row still shows it.
                    defer { pointed = nil }
                    guard position != pointed, let row = list.rowID(ofOption: position) else { return }
                    listMotion.moved = true
                    proxy.scrollTo(row)
                }
                // A new query starts over at the top of its results.
                .onChange(of: query) { _, _ in
                    selection = 0
                    if let top { proxy.scrollTo(top, anchor: .top) }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .modifier(SHMenuSurface(width: SHComposerMetrics.modelPickerWidth, padding: 0))
        .task {
            // All models replaces a focused settings menu. Let its AppKit focus release
            // finish before claiming the search field, rather than losing this claim to it.
            await Task.yield()
            guard !Task.isCancelled else { return }
            searching = true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Choose a model")
    }

    /// The list's first row: "Loading models…" while the catalog loads.
    private var top: String? { loading ? Self.loadingRow : list.rows.first?.id }

    /// ↑↓: the highlight moves (and the list scrolls just enough to show it).
    private func move(to position: Int) {
        selection = min(max(0, list.options.count - 1), max(0, position))
    }
}

/// One row of the model list. Equatable on what it draws (closures aside), so a highlight moving
/// redraws the two rows it moves between and nothing else. One view whatever the row is, so the
/// lazy list never has to build a row to learn its shape.
struct SHModelListRow: View, Equatable {
    let row: SHModelList.Row
    let highlighted: Bool
    let choose: (SHModelOption) -> Void
    let hover: (Int) -> Void

    static func == (a: Self, b: Self) -> Bool { a.row == b.row && a.highlighted == b.highlighted }

    var body: some View {
        let sh = Color.sh
        VStack(spacing: 0) {
            switch row.kind {
            case .header(let title):
                SHMenuHeader(title, inset: SH.Space.m + SH.Space.xxs)
                    .padding(.top, SHComposerMetrics.modelSectionGap)
            case .option(let option, let position):
                SHMenuRow(highlighted: highlighted, padding: EdgeInsets(top: 0, leading: SH.Space.m + SH.Space.xxs, bottom: 0, trailing: SH.Space.m + SH.Space.xxs),
                          height: SHComposerMetrics.modelRowHeight, action: { choose(option) }, onHover: { hover(position) }) {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(sh.running)
                        .frame(width: 12)
                        .opacity(option.isCurrent ? 1 : 0)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(option.title).font(.shMono(12.5)).foregroundStyle(sh.textPrimary)
                            .lineLimit(1).truncationMode(.middle)
                        if let subtitle = option.subtitle {
                            Text(subtitle).font(.sh(.caption)).foregroundStyle(sh.textSecondary)
                                .lineLimit(1).truncationMode(.tail)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // The model has a Fast tier (SHComposer › Menus: "fast" beside claude-sonnet).
                    if option.fast {
                        Text("fast").font(.shMono(11)).foregroundStyle(sh.textTertiary).fixedSize()
                    }
                    if let note = option.note {
                        Text(note).font(.shMono(11)).foregroundStyle(sh.textTertiary).fixedSize()
                    }
                }
                .help(option.id)
                .accessibilityLabel(option.id + (option.isCurrent ? ", current" : "") + (option.fast ? ", offers Fast" : "")
                    + (option.subtitle.map { ", \($0)" } ?? ""))
            }
        }
    }
}

// MARK: Model settings choices

/// A thinking level the model-settings popover offers ("Low", note "quick").
public struct SHThinkingOption: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    /// What the level means ("quick"), a tooltip on its segment.
    public var note: String?

    public init(id: String, title: String, note: String? = nil) {
        self.id = id
        self.title = title
        self.note = note
    }
}

/// A speed the model-settings popover offers ("Fast", "Faster responses, billed at a higher rate").
public struct SHSpeedOption: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    /// What the tier does, a tooltip on its segment.
    public var detail: String
    /// A raised tier: its segment wears the Fast bolt (`SHFastBolt`).
    public var boosted: Bool

    public init(id: String, title: String, detail: String, boosted: Bool = false) {
        self.id = id
        self.title = title
        self.detail = detail
        self.boosted = boosted
    }
}
