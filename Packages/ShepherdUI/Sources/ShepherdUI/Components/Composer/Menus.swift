import SwiftUI

// The composer's popovers (NWComposer board, "Menus"): radius 12, raised, the popover shadow,
// 28pt rows, running-tint selection. ↑↓ move, ⏎ chooses, esc closes.

/// A section label in a menu: mono 10 medium, uppercase, tracked, `textTertiary`, with an
/// optional trailing count ("4 of 23").
public struct NWMenuHeader: View {
    let title: String
    let trailing: String?

    public init(_ title: String, trailing: String? = nil) {
        self.title = title
        self.trailing = trailing
    }

    public var body: some View {
        HStack(spacing: NW.Space.m) {
            Text(title)
                .font(.nwMono(10, .medium))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(.nw.textTertiary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing).font(.nwMono(10.5)).foregroundStyle(.nw.textTertiary).monospacedDigit()
            }
        }
        .padding(.horizontal, NW.Space.m)
        .frame(height: NWComposerMetrics.menuHeaderHeight)
    }
}

#if DEBUG
/// Debug builds count the menu rows they draw, so tests can pin how much of a long menu a change
/// redraws (opening, filtering, scrolling, a hover).
@MainActor public enum NWMenuDiagnostics {
    public static var rowBodies = 0
}
#endif

/// A 28pt menu row: `runningTint` while highlighted, hovering highlights it, and a click (or
/// VoiceOver's press) chooses it. It is not a `Button`: each button brings an AppKit focus-ring
/// view, and a long menu scrolls rows in and out; the field or the menu keeps keyboard focus.
struct NWMenuRow<Label: View>: View {
    let highlighted: Bool
    /// 10pt between parts; the slash menu's columns sit 12pt apart.
    var spacing: CGFloat = 10
    let action: () -> Void
    let onHover: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        #if DEBUG
        let _ = NWMenuDiagnostics.rowBodies += 1
        #endif
        HStack(spacing: spacing) { label() }
            .padding(.horizontal, NW.Space.m)
            .frame(minHeight: NWComposerMetrics.menuRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(highlighted ? Color.nw.runningTint : .clear, in: RoundedRectangle(cornerRadius: NW.Radius.s))
            .contentShape(RoundedRectangle(cornerRadius: NW.Radius.s))
            .onTapGesture(perform: action)
            .onHover { if $0 { onHover() } }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(highlighted ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { action() }
    }
}

/// The popover a menu sits on: its board width, or narrower when that is all the room offered
/// (a composer beside a docked pane).
private struct NWMenuSurface: ViewModifier {
    let width: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(NW.Space.s)
            .frame(idealWidth: width, maxWidth: width)
            .nwPopover()
    }
}

/// A menu's list starts at its top. While a composer menu grows from its bottom corner, the scale
/// moves its hosted scroll view's frame, and AppKit drifts the list a few points down (9pt for
/// eight rows); so for as long as the menu is growing, and until the reader or ↑↓ scroll it,
/// the list is held at its top.
private struct NWMenuListStartsAtTop: ViewModifier {
    /// The list's first row. (Not a zero-height marker: a lazy stack that starts with one
    /// misplaces every row a scroll aims at.)
    let top: String?
    let proxy: ScrollViewProxy
    let list: NWMenuListMotion

    /// Past the overlay motion's settle (about 1.7× its 180ms anchor), with room to spare.
    private static let growing = Duration.seconds(NW.Motion.overlay.duration * 3)

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { _, phase in if phase != .idle { list.moved = true } }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, offset in
                guard let top, !list.moved, offset != 0, ContinuousClock.now - list.appeared < Self.growing else { return }
                proxy.scrollTo(top, anchor: .top)
            }
    }
}

/// When a menu's list appeared and whether it has been scrolled since: bookkeeping, read and
/// written as the list moves (never while drawing), so a plain reference.
final class NWMenuListMotion {
    let appeared = ContinuousClock.now
    var moved = false
}

// MARK: Slash menu

/// A command the slash menu offers: pi's registry, never hard-coded.
public struct NWSlashCommand: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var description: String?
    /// "[session]" after the name, in `textTertiary`.
    public var arguments: String?
    /// "prompt" for a prompt template, shown as a tag.
    public var tag: String?

    public init(name: String, description: String? = nil, arguments: String? = nil, tag: String? = nil) {
        self.name = name
        self.description = description
        self.arguments = arguments
        self.tag = tag
    }
}

/// The slash menu (NWComposer board): "Commands · n of m", then 28pt rows: the command in mono
/// 12 with the typed prefix in semibold `textPrimary` and the rest `textSecondary` (a 150pt
/// column), its description, and a tag for prompt templates. At most 8 rows show, fewer when
/// `maxHeight` leaves less room. The field keeps focus and drives the selection.
///
/// Rows are lazy and redraw only when their command, its typed prefix, or their highlight
/// changes. ↑↓ scroll the highlight into view; the pointer's highlight is already under the
/// pointer, so a hover (or the list scrolling under a still pointer) never scrolls it.
public struct NWSlashMenu: View {
    let commands: [NWSlashCommand]
    let total: Int
    let query: String
    @Binding var selection: Int
    let maxHeight: CGFloat?
    let onChoose: (NWSlashCommand) -> Void
    /// The row the pointer just highlighted, until the highlight's change is seen.
    @State private var pointed: Int?
    @State private var listMotion = NWMenuListMotion()

    public init(commands: [NWSlashCommand], total: Int, query: String, selection: Binding<Int>, maxHeight: CGFloat? = nil,
                onChoose: @escaping (NWSlashCommand) -> Void) {
        self.commands = commands
        self.total = total
        self.query = query
        _selection = selection
        self.maxHeight = maxHeight
        self.onChoose = onChoose
    }

    public var body: some View {
        let rows = CGFloat(min(max(commands.count, 1), Self.visibleRows(in: maxHeight)))
        VStack(alignment: .leading, spacing: 0) {
            NWMenuHeader("Commands", trailing: "\(commands.count) of \(total)")
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(commands.enumerated()), id: \.element.name) { index, command in
                            NWSlashRow(command: command, typed: typed(command), index: index, highlighted: index == selection, choose: onChoose,
                                       hover: { index in
                                           guard index != selection else { return }
                                           pointed = index
                                           selection = index
                                       })
                                .equatable()
                        }
                        if commands.isEmpty {
                            Text("No command matches “/\(query)”").font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
                                .padding(.horizontal, NW.Space.m)
                                .frame(height: NWComposerMetrics.menuRowHeight)
                        }
                    }
                }
                .modifier(NWMenuListStartsAtTop(top: commands.first?.name, proxy: proxy, list: listMotion))
                .frame(height: rows * NWComposerMetrics.menuRowHeight)
                .onChange(of: selection) { _, index in
                    // Each pointer move is seen once, so a later ↑↓ back to that row still shows it.
                    defer { pointed = nil }
                    guard index != pointed, commands.indices.contains(index) else { return }
                    listMotion.moved = true
                    proxy.scrollTo(commands[index].name)
                }
            }
        }
        .modifier(NWMenuSurface(width: NWComposerMetrics.slashMenuWidth))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Commands")
    }

    /// How many rows fit a menu at most `height` tall (at least one, at most the board's eight).
    static func visibleRows(in height: CGFloat?) -> Int {
        guard let height, height.isFinite else { return NWComposerMetrics.menuMaxRows }
        let room = height - NWComposerMetrics.menuHeaderHeight - 2 * NW.Space.s
        return max(1, min(NWComposerMetrics.menuMaxRows, Int((room / NWComposerMetrics.menuRowHeight).rounded(.down))))
    }

    /// How much of the command's name the query types: its whole length when it is a prefix.
    private func typed(_ command: NWSlashCommand) -> Int {
        command.name.lowercased().hasPrefix(query.lowercased()) ? query.count : 0
    }
}

/// One command in the slash menu. Equatable on what it draws (closures aside), so a highlight
/// moving redraws the two rows it moves between.
struct NWSlashRow: View, Equatable {
    let command: NWSlashCommand
    /// The length of the typed prefix, in semibold.
    let typed: Int
    let index: Int
    let highlighted: Bool
    let choose: (NWSlashCommand) -> Void
    let hover: (Int) -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.command == b.command && a.typed == b.typed && a.index == b.index && a.highlighted == b.highlighted
    }

    var body: some View {
        NWMenuRow(highlighted: highlighted, spacing: NW.Space.l, action: { choose(command) }, onHover: { hover(index) }) {
            name
                .frame(width: NWComposerMetrics.slashNameWidth, alignment: .leading)
            Text(command.description ?? "").font(.nw(.ui, weight: .regular)).foregroundStyle(Color.nw.textSecondary)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let tag = command.tag { NWTag(tag) }
        }
        .accessibilityLabel("/\(command.name)" + (command.description.map { ", \($0)" } ?? ""))
    }

    private var name: Text {
        let nw = Color.nw
        let head = Text("/" + command.name.prefix(typed)).fontWeight(.semibold).foregroundStyle(nw.textPrimary)
        let tail = Text(String(command.name.dropFirst(typed))).foregroundStyle(nw.textSecondary)
        let arguments = Text(command.arguments.map { " " + $0 } ?? "").foregroundStyle(nw.textTertiary)
        return Text("\(head)\(tail)\(arguments)").font(.nwMono(12))
    }
}

// MARK: Model picker

/// A model the picker offers.
public struct NWModelOption: Identifiable, Equatable, Sendable {
    public var id: String
    /// The name the row shows ("claude-opus").
    public var title: String
    /// A trailing note in mono 10.5 (context size, "fast").
    public var note: String?
    public var isCurrent: Bool

    public init(id: String, title: String, note: String? = nil, isCurrent: Bool = false) {
        self.id = id
        self.title = title
        self.note = note
        self.isCurrent = isCurrent
    }
}

public struct NWModelSection: Identifiable, Equatable, Sendable {
    public var id: String { title }
    public var title: String
    public var options: [NWModelOption]

    public init(title: String, options: [NWModelOption]) {
        self.title = title
        self.options = options
    }
}

/// The model picker's list, flattened once from its sections rather than on every draw: one row
/// per section header and per model, each model's position among the models (what ↑↓ and the
/// highlight count in), and the list's height.
public struct NWModelList: Equatable, Sendable {
    public struct Row: Identifiable, Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case header(String)
            case option(NWModelOption, position: Int)
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
    public let options: [NWModelOption]
    /// The row of each model in `options`.
    private let optionRows: [String]
    /// Every row at its fixed height: headers 24pt, models 28pt.
    public let height: CGFloat

    public init(sections: [NWModelSection]) {
        var rows: [Row] = []
        var options: [NWModelOption] = []
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
        height = CGFloat(headers) * NWComposerMetrics.menuHeaderHeight + CGFloat(options.count) * NWComposerMetrics.menuRowHeight
    }

    /// The row that shows `options[position]`.
    public func rowID(ofOption position: Int) -> String? {
        optionRows.indices.contains(position) ? optionRows[position] : nil
    }
}

/// The model picker (NWComposer board): 260pt, "Search models" on top, then Recent and one
/// section per provider; 28pt rows with the model in mono 12 and a check on the current one.
/// The list is at most 360pt tall, and the whole picker at most `maxHeight`. The search field
/// takes focus and drives the selection.
///
/// A catalog runs to hundreds of models, so the list is lazy: only the rows on screen exist, and
/// a row redraws only when its model or its highlight changes. ↑↓ scroll the highlight into view;
/// the pointer passing over rows (or the list scrolling under it) moves the highlight without
/// scrolling the list.
public struct NWModelPicker: View {
    @Binding var query: String
    let list: NWModelList
    let loading: Bool
    @Binding var selection: Int
    let maxHeight: CGFloat?
    let onChoose: (NWModelOption) -> Void
    let onClose: () -> Void
    @FocusState private var searching: Bool
    /// The model the pointer just highlighted, until the highlight's change is seen.
    @State private var pointed: Int?
    @State private var listMotion = NWMenuListMotion()

    public init(query: Binding<String>, list: NWModelList, loading: Bool = false, selection: Binding<Int>,
                maxHeight: CGFloat? = nil, onChoose: @escaping (NWModelOption) -> Void, onClose: @escaping () -> Void) {
        _query = query
        self.list = list
        self.loading = loading
        _selection = selection
        self.maxHeight = maxHeight
        self.onChoose = onChoose
        self.onClose = onClose
    }

    public init(query: Binding<String>, sections: [NWModelSection], loading: Bool = false, selection: Binding<Int>,
                maxHeight: CGFloat? = nil, onChoose: @escaping (NWModelOption) -> Void, onClose: @escaping () -> Void) {
        self.init(query: query, list: NWModelList(sections: sections), loading: loading, selection: selection, maxHeight: maxHeight,
                  onChoose: onChoose, onClose: onClose)
    }

    /// The list's height limit: the board's 360pt, or what `maxHeight` leaves under the search.
    static func listMaxHeight(in height: CGFloat?) -> CGFloat {
        let chrome = NWComposerMetrics.modelSearchHeight + NW.Space.xs + 2 * NW.Space.s
        return max(NWComposerMetrics.menuRowHeight, min(NWComposerMetrics.modelPickerMaxHeight, (height ?? .infinity) - chrome))
    }

    private static let loadingRow = "loading"

    public var body: some View {
        let nw = Color.nw
        // Rows have fixed heights, so the list's height is known without laying any of them out.
        let height = min(list.height + (loading ? NWComposerMetrics.menuRowHeight : 0), Self.listMaxHeight(in: maxHeight))
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: NW.Space.m) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(nw.textTertiary)
                    TextField(text: $query, prompt: Text("Search models").foregroundStyle(nw.textTertiary)) { Text("Search models") }
                        .textFieldStyle(.plain)
                        .font(.nw(.ui, weight: .regular))
                        .focused($searching)
                        .onKeyPress(.downArrow) { move(to: selection + 1); return .handled }
                        .onKeyPress(.upArrow) { move(to: selection - 1); return .handled }
                        .onKeyPress(.return) {
                            if list.options.indices.contains(selection) { onChoose(list.options[selection]) }
                            return .handled
                        }
                        .onKeyPress(.escape) { onClose(); return .handled }
                        .accessibilityLabel("Search models")
                }
                .padding(.horizontal, NW.Space.m)
                .frame(height: NWComposerMetrics.modelSearchHeight)
                .overlay(alignment: .bottom) { NWHairline() }
                .padding(.bottom, NW.Space.xs)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if loading {
                            HStack(spacing: NW.Space.m) {
                                ProgressView().progressViewStyle(.nwSpinner(size: 12))
                                Text("Loading models…").font(.nw(.caption)).foregroundStyle(nw.textTertiary)
                            }
                            .padding(.horizontal, NW.Space.m)
                            .frame(height: NWComposerMetrics.menuRowHeight)
                            .id(Self.loadingRow)
                            .nwTransition(.content)
                        }
                        ForEach(list.rows) { row in
                            NWModelListRow(row: row, highlighted: row.position == selection, choose: onChoose, hover: { position in
                                guard position != selection else { return }
                                pointed = position
                                selection = position
                            })
                            .equatable()
                        }
                    }
                    // The catalog arriving replaces "Loading models…"; filtering stays instant.
                    .nwAnimation(.content, value: loading)
                }
                .modifier(NWMenuListStartsAtTop(top: top, proxy: proxy, list: listMotion))
                .frame(height: height)
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
        .modifier(NWMenuSurface(width: NWComposerMetrics.modelPickerWidth))
        .onAppear { searching = true }
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
struct NWModelListRow: View, Equatable {
    let row: NWModelList.Row
    let highlighted: Bool
    let choose: (NWModelOption) -> Void
    let hover: (Int) -> Void

    static func == (a: Self, b: Self) -> Bool { a.row == b.row && a.highlighted == b.highlighted }

    var body: some View {
        let nw = Color.nw
        VStack(spacing: 0) {
            switch row.kind {
            case .header(let title):
                NWMenuHeader(title)
            case .option(let option, let position):
                NWMenuRow(highlighted: highlighted, action: { choose(option) }, onHover: { hover(position) }) {
                    Text(option.title).font(.nwMono(12)).foregroundStyle(nw.textPrimary).lineLimit(1)
                    Spacer(minLength: NW.Space.m)
                    if option.isCurrent {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(nw.running)
                    } else if let note = option.note {
                        Text(note).font(.nwMono(10.5)).foregroundStyle(nw.textTertiary)
                    }
                }
                .accessibilityLabel(option.id + (option.isCurrent ? ", current" : ""))
            }
        }
    }
}

// MARK: Thinking menu

/// A thinking level the menu offers ("Low", note "quick").
public struct NWThinkingOption: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var note: String?

    public init(id: String, title: String, note: String? = nil) {
        self.id = id
        self.title = title
        self.note = note
    }
}

/// The thinking menu (NWComposer board): 220pt, "Thinking", then one 28pt row per level with
/// its note in `textTertiary` and a check on the current level. It takes focus for ↑↓ ⏎ esc.
public struct NWThinkingMenu: View {
    let options: [NWThinkingOption]
    let current: String
    let onChoose: (NWThinkingOption) -> Void
    let onClose: () -> Void
    @State private var selection: Int
    @FocusState private var focused: Bool

    public init(options: [NWThinkingOption], current: String, onChoose: @escaping (NWThinkingOption) -> Void,
                onClose: @escaping () -> Void) {
        self.options = options
        self.current = current
        self.onChoose = onChoose
        self.onClose = onClose
        _selection = State(initialValue: options.firstIndex { $0.id == current } ?? 0)
    }

    public var body: some View {
        let nw = Color.nw
        VStack(alignment: .leading, spacing: 0) {
            NWMenuHeader("Thinking")
            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                NWMenuRow(highlighted: index == selection, action: { onChoose(option) }, onHover: { selection = index }) {
                    Text(option.title).font(.nw(.ui, weight: .regular)).foregroundStyle(nw.textPrimary)
                    if let note = option.note {
                        Text(note).font(.nwSans(12)).foregroundStyle(nw.textTertiary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if option.id == current {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(nw.running)
                    }
                }
                .accessibilityLabel(option.title + (option.id == current ? ", current" : ""))
            }
        }
        .modifier(NWMenuSurface(width: NWComposerMetrics.thinkingMenuWidth))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.downArrow) { selection = min(options.count - 1, selection + 1); return .handled }
        .onKeyPress(.upArrow) { selection = max(0, selection - 1); return .handled }
        .onKeyPress(.return) {
            if options.indices.contains(selection) { onChoose(options[selection]) }
            return .handled
        }
        .onKeyPress(.escape) { onClose(); return .handled }
        .onAppear { focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Thinking level")
    }
}
