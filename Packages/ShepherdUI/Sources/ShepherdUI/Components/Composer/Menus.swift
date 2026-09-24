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

/// A 28pt menu row: `runningTint` while highlighted. The row is a button; hovering highlights it.
struct NWMenuRow<Label: View>: View {
    let highlighted: Bool
    /// 10pt between parts; the slash menu's columns sit 12pt apart.
    var spacing: CGFloat = 10
    let action: () -> Void
    let onHover: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            HStack(spacing: spacing) { label() }
                .padding(.horizontal, NW.Space.m)
                .frame(minHeight: NWComposerMetrics.menuRowHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(highlighted ? Color.nw.runningTint : .clear, in: RoundedRectangle(cornerRadius: NW.Radius.s))
                .contentShape(RoundedRectangle(cornerRadius: NW.Radius.s))
        }
        .buttonStyle(.plain)
        .onHover { if $0 { onHover() } }
        .accessibilityAddTraits(highlighted ? .isSelected : [])
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
public struct NWSlashMenu: View {
    let commands: [NWSlashCommand]
    let total: Int
    let query: String
    @Binding var selection: Int
    let maxHeight: CGFloat?
    let onChoose: (NWSlashCommand) -> Void

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
                            NWMenuRow(highlighted: index == selection, spacing: NW.Space.l, action: { onChoose(command) }, onHover: { selection = index }) {
                                name(command)
                                    .frame(width: NWComposerMetrics.slashNameWidth, alignment: .leading)
                                Text(command.description ?? "").font(.nw(.ui, weight: .regular)).foregroundStyle(Color.nw.textSecondary)
                                    .lineLimit(1).truncationMode(.tail)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let tag = command.tag { NWTag(tag) }
                            }
                            .id(command.name)
                            .accessibilityLabel("/\(command.name)" + (command.description.map { ", \($0)" } ?? ""))
                        }
                        if commands.isEmpty {
                            Text("No command matches “/\(query)”").font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
                                .padding(.horizontal, NW.Space.m)
                                .frame(height: NWComposerMetrics.menuRowHeight)
                        }
                    }
                }
                .frame(height: rows * NWComposerMetrics.menuRowHeight)
                .onChange(of: selection) { _, index in
                    if commands.indices.contains(index) { proxy.scrollTo(commands[index].name) }
                }
            }
        }
        .modifier(NWMenuSurface(width: NWComposerMetrics.slashMenuWidth))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Commands")
    }

    /// How many rows fit a menu at most `height` tall (at least one, at most the board's eight).
    static func visibleRows(in height: CGFloat?) -> Int {
        guard let height else { return NWComposerMetrics.menuMaxRows }
        let room = height - NWComposerMetrics.menuHeaderHeight - 2 * NW.Space.s
        return max(1, min(NWComposerMetrics.menuMaxRows, Int((room / NWComposerMetrics.menuRowHeight).rounded(.down))))
    }

    private func name(_ command: NWSlashCommand) -> Text {
        let nw = Color.nw
        let typed = command.name.lowercased().hasPrefix(query.lowercased()) ? query.count : 0
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

/// The model picker (NWComposer board): 260pt, "Search models" on top, then Recent and one
/// section per provider; 28pt rows with the model in mono 12 and a check on the current one.
/// The list is at most 360pt tall, and the whole picker at most `maxHeight`. The search field
/// takes focus and drives the selection.
public struct NWModelPicker: View {
    @Binding var query: String
    let sections: [NWModelSection]
    let loading: Bool
    @Binding var selection: Int
    let maxHeight: CGFloat?
    let onChoose: (NWModelOption) -> Void
    let onClose: () -> Void
    @FocusState private var searching: Bool

    public init(query: Binding<String>, sections: [NWModelSection], loading: Bool = false, selection: Binding<Int>,
                maxHeight: CGFloat? = nil, onChoose: @escaping (NWModelOption) -> Void, onClose: @escaping () -> Void) {
        _query = query
        self.sections = sections
        self.loading = loading
        _selection = selection
        self.maxHeight = maxHeight
        self.onChoose = onChoose
        self.onClose = onClose
    }

    /// The list's height limit: the board's 360pt, or what `maxHeight` leaves under the search.
    static func listMaxHeight(in height: CGFloat?) -> CGFloat {
        let chrome = NWComposerMetrics.modelSearchHeight + NW.Space.xs + 2 * NW.Space.s
        return max(NWComposerMetrics.menuRowHeight, min(NWComposerMetrics.modelPickerMaxHeight, (height ?? .infinity) - chrome))
    }

    public var body: some View {
        let nw = Color.nw
        let flat = sections.flatMap(\.options)
        let positions = Dictionary(flat.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: NW.Space.m) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(nw.textTertiary)
                TextField(text: $query, prompt: Text("Search models").foregroundStyle(nw.textTertiary)) { Text("Search models") }
                    .textFieldStyle(.plain)
                    .font(.nw(.ui, weight: .regular))
                    .focused($searching)
                    .onKeyPress(.downArrow) { selection = min(max(0, flat.count - 1), selection + 1); return .handled }
                    .onKeyPress(.upArrow) { selection = max(0, selection - 1); return .handled }
                    .onKeyPress(.return) {
                        if flat.indices.contains(selection) { onChoose(flat[selection]) }
                        return .handled
                    }
                    .onKeyPress(.escape) { onClose(); return .handled }
                    .accessibilityLabel("Search models")
            }
            .padding(.horizontal, NW.Space.m)
            .frame(height: NWComposerMetrics.modelSearchHeight)
            .overlay(alignment: .bottom) { NWHairline() }
            .padding(.bottom, NW.Space.xs)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if loading {
                            HStack(spacing: NW.Space.m) {
                                ProgressView().progressViewStyle(.nwSpinner(size: 12))
                                Text("Loading models…").font(.nw(.caption)).foregroundStyle(nw.textTertiary)
                            }
                            .padding(NW.Space.m)
                            .nwTransition(.content)
                        }
                        ForEach(sections) { section in
                            NWMenuHeader(section.title)
                            ForEach(section.options) { option in
                                let position = positions[option.id] ?? 0
                                NWMenuRow(highlighted: position == selection, action: { onChoose(option) }, onHover: { selection = position }) {
                                    Text(option.title).font(.nwMono(12)).foregroundStyle(nw.textPrimary).lineLimit(1)
                                    Spacer(minLength: NW.Space.m)
                                    if option.isCurrent {
                                        Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(nw.running)
                                    } else if let note = option.note {
                                        Text(note).font(.nwMono(10.5)).foregroundStyle(nw.textTertiary)
                                    }
                                }
                                .id("\(section.title)/\(option.id)")
                                .accessibilityLabel(option.id + (option.isCurrent ? ", current" : ""))
                            }
                        }
                    }
                    // The catalog arriving replaces "Loading models…"; filtering stays instant.
                    .nwAnimation(.content, value: loading)
                }
                .frame(maxHeight: Self.listMaxHeight(in: maxHeight))
                .onChange(of: selection) { _, index in
                    guard flat.indices.contains(index) else { return }
                    let option = flat[index]
                    if let section = sections.first(where: { $0.options.contains(option) }) {
                        proxy.scrollTo("\(section.title)/\(option.id)")
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .modifier(NWMenuSurface(width: NWComposerMetrics.modelPickerWidth))
        .onAppear { searching = true }
        .onChange(of: query) { _, _ in selection = 0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Choose a model")
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
