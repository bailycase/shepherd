import SwiftUI

// The workplace chip's menu (NavNewThread): where a new thread runs, as the composer's menus
// look (radius 12, raised, the popover shadow, 28pt rows). A search field, then one section per
// host with its projects as a tree (nested ones fold under their parent), each section ending in
// "Add folder…"; then the worktree option.

/// A project the menu offers: its name and path, on a host.
public struct SHPlaceOption: Identifiable, Equatable, Sendable {
    public var id: String
    /// The section (host) it belongs to.
    public var section: String
    public var title: String
    /// Its path, in mono `textTertiary`.
    public var detail: String?
    public var isCurrent: Bool
    /// The ids of the options it nests under, outermost first; they come before it in the section.
    public var ancestors: [String]

    public init(id: String, section: String, title: String, detail: String? = nil, isCurrent: Bool = false,
                ancestors: [String] = []) {
        self.id = id
        self.section = section
        self.title = title
        self.detail = detail
        self.isCurrent = isCurrent
        self.ancestors = ancestors
    }
}

/// A host's projects.
public struct SHPlaceSection: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var options: [SHPlaceOption]
    /// "Add folder…" at the section's end; nil where the host cannot add one.
    public var addTitle: String?

    public init(id: String, title: String, options: [SHPlaceOption], addTitle: String? = "Add folder…") {
        self.id = id
        self.title = title
        self.options = options
        self.addTitle = addTitle
    }
}

/// The worktree option under the projects: a switch with what it does, and while it is on a Base
/// row naming the branch it starts from ("Default" until one is picked). `base` nil draws no row.
public struct SHPlaceWorktree: Equatable, Sendable {
    public var isOn: Bool
    public var caption: String
    public var base: String?

    public init(isOn: Bool, caption: String, base: String? = nil) {
        self.isOn = isOn
        self.caption = caption
        self.base = base
    }
}

public enum SHPlaceMenuMetrics {
    /// The menu's width: a project's name and its path side by side.
    public static let width: CGFloat = 320
    /// The Base row's branch (as the project rows' paths) and its chevron (as All models…).
    static let baseFont: CGFloat = 11
    static let baseChevron: CGFloat = 10
    /// A nested project's indent per level, and its disclosure chevron's box.
    static let indent: CGFloat = 14
    static let disclosure: CGFloat = 10
    /// The search row's glyph and text, as the model picker's (ModelPicker).
    static let searchGlyph: CGFloat = 12
    static let searchFont: CGFloat = 13
}

/// The workplace menu: a search field, sections of projects as trees (a check on the chosen one,
/// its path trailing), "Add folder…" per host, and the worktree switch. Typing filters every
/// project, nested or not, by name or path. ↑↓ move, → opens a parent, ← closes it (or goes to its
/// parent), ⏎ chooses, esc closes. Each project row carries `rowMenu` as its context menu.
public struct SHPlaceMenu<RowMenu: View>: View {
    let sections: [SHPlaceSection]
    let worktree: SHPlaceWorktree?
    let maxHeight: CGFloat?
    let onChoose: (SHPlaceOption) -> Void
    let onAdd: (SHPlaceSection) -> Void
    let onWorktree: (Bool) -> Void
    let onChooseBase: () -> Void
    let onClose: () -> Void
    @ViewBuilder let rowMenu: (SHPlaceOption) -> RowMenu
    @State private var selection: Int
    @State private var query = ""
    /// The parents shown open; the chosen project's ancestors start open.
    @State private var expanded: Set<String>
    @FocusState private var focused: Bool

    public init(sections: [SHPlaceSection], worktree: SHPlaceWorktree?, maxHeight: CGFloat? = nil,
                onChoose: @escaping (SHPlaceOption) -> Void, onAdd: @escaping (SHPlaceSection) -> Void,
                onWorktree: @escaping (Bool) -> Void, onChooseBase: @escaping () -> Void = {}, onClose: @escaping () -> Void,
                @ViewBuilder rowMenu: @escaping (SHPlaceOption) -> RowMenu) {
        self.sections = sections
        self.worktree = worktree
        self.maxHeight = maxHeight
        self.onChoose = onChoose
        self.onAdd = onAdd
        self.onWorktree = onWorktree
        self.onChooseBase = onChooseBase
        self.onClose = onClose
        self.rowMenu = rowMenu
        let all = sections.flatMap(\.options)
        let open = Set(all.first(where: \.isCurrent)?.ancestors ?? [])
        _expanded = State(initialValue: open)
        let shown = Self.visible(sections, query: "", expanded: open).flatMap(\.options)
        _selection = State(initialValue: shown.firstIndex(where: \.isCurrent) ?? 0)
    }

    /// What the menu lists: with a query, every project whose name or path holds it, flat, and
    /// only the sections with one; without, each project whose ancestors are all open.
    public static func visible(_ sections: [SHPlaceSection], query: String, expanded: Set<String>) -> [SHPlaceSection] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard query.isEmpty else {
            return sections.compactMap { section in
                var section = section
                section.options = section.options.filter {
                    $0.title.localizedCaseInsensitiveContains(query) || $0.detail?.localizedCaseInsensitiveContains(query) == true
                }.map { var option = $0; option.ancestors = []; return option }
                section.addTitle = nil
                return section.options.isEmpty ? nil : section
            }
        }
        return sections.map { section in
            var section = section
            section.options = section.options.filter { $0.ancestors.allSatisfy(expanded.contains) }
            return section
        }
    }

    private var shown: [SHPlaceSection] { Self.visible(sections, query: query, expanded: expanded) }

    public var body: some View {
        let sh = Color.sh
        let shown = shown
        let options = shown.flatMap(\.options)
        let parents = Set(sections.flatMap(\.options).compactMap(\.ancestors.last))
        // Rows line up with their siblings' chevrons once any project nests.
        let disclosures = query.isEmpty && !parents.isEmpty
        let showsBase = worktree?.isOn == true && worktree?.base != nil
        let rowCount = options.count + (showsBase ? 1 : 0)
        let indexByID = Dictionary(options.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: SH.Space.m) {
                Image(systemName: "magnifyingglass").font(.system(size: SHPlaceMenuMetrics.searchGlyph, weight: .medium)).foregroundStyle(sh.textTertiary)
                TextField(text: $query, prompt: Text("Search spaces").foregroundStyle(sh.textTertiary)) { Text("Search spaces") }
                    .textFieldStyle(.plain)
                    .font(.shSans(SHPlaceMenuMetrics.searchFont))
                    .foregroundStyle(sh.textPrimary)
                    .focused($focused)
                    .onKeyPress(.downArrow) { selection = min(max(0, rowCount - 1), selection + 1); return .handled }
                    .onKeyPress(.upArrow) { selection = max(0, selection - 1); return .handled }
                    .onKeyPress(.rightArrow) {
                        guard query.isEmpty, options.indices.contains(selection), parents.contains(options[selection].id) else { return .ignored }
                        expanded.insert(options[selection].id)
                        return .handled
                    }
                    .onKeyPress(.leftArrow) {
                        guard query.isEmpty, options.indices.contains(selection) else { return .ignored }
                        let option = options[selection]
                        if expanded.contains(option.id) {
                            expanded.remove(option.id)
                        } else if let parent = option.ancestors.last, let index = indexByID[parent] {
                            selection = index
                        } else {
                            return .ignored
                        }
                        return .handled
                    }
                    .onKeyPress(.return) {
                        if options.indices.contains(selection) { onChoose(options[selection]) }
                        else if showsBase, selection == options.count { onChooseBase() }
                        return .handled
                    }
                    .onKeyPress(.escape) { onClose(); return .handled }
                    .accessibilityLabel("Search spaces")
            }
            .padding(.horizontal, SH.Space.m)
            .frame(height: SHComposerMetrics.modelSearchHeight)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if shown.isEmpty {
                        Text("No matching spaces").font(.sh(.caption)).foregroundStyle(sh.textTertiary)
                            .padding(.horizontal, SH.Space.m)
                            .frame(height: SHComposerMetrics.menuRowHeight)
                    }
                    ForEach(shown) { section in
                        SHMenuHeader(section.title)
                        ForEach(section.options) { option in
                            let index = indexByID[option.id] ?? 0
                            let isParent = parents.contains(option.id)
                            let isOpen = expanded.contains(option.id)
                            SHMenuRow(highlighted: index == selection, action: { onChoose(option) }, onHover: { selection = index }) {
                                if disclosures {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: SHPlaceMenuMetrics.baseChevron, weight: .semibold))
                                        .foregroundStyle(sh.textTertiary)
                                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                                        .frame(width: SHPlaceMenuMetrics.disclosure)
                                        .opacity(isParent ? 1 : 0)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            guard isParent else { return onChoose(option) }
                                            if isOpen { expanded.remove(option.id) } else { expanded.insert(option.id) }
                                        }
                                        .accessibilityHidden(true)
                                        .padding(.leading, CGFloat(option.ancestors.count) * SHPlaceMenuMetrics.indent)
                                }
                                Text(option.title).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textPrimary).lineLimit(1)
                                if let detail = option.detail {
                                    Text(detail).font(.shMono(11)).foregroundStyle(sh.textTertiary).lineLimit(1)
                                        .truncationMode(.head)
                                }
                                Spacer(minLength: 0)
                                if option.isCurrent {
                                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(sh.running)
                                }
                            }
                            .contextMenu { rowMenu(option) }
                            .accessibilityLabel(option.title + (option.isCurrent ? ", current" : "") + (isParent ? (isOpen ? ", expanded" : ", collapsed") : ""))
                            .accessibilityActions {
                                if isParent {
                                    Button(isOpen ? "Collapse" : "Expand") {
                                        if isOpen { expanded.remove(option.id) } else { expanded.insert(option.id) }
                                    }
                                }
                            }
                        }
                        if let add = section.addTitle {
                            SHMenuRow(highlighted: false, action: { onAdd(section) }, onHover: {}) {
                                Image(systemName: "plus").font(.system(size: 11, weight: .medium)).foregroundStyle(sh.textSecondary)
                                Text(add).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textSecondary)
                                Spacer(minLength: 0)
                            }
                            .accessibilityLabel("\(add) on \(section.title)")
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: maxHeight.map {
                max(0, $0 - SHComposerMetrics.modelSearchHeight - (worktree == nil ? 0 : SHComposerMetrics.menuRowHeight * 2))
            })
            .fixedSize(horizontal: false, vertical: maxHeight == nil)
            if let worktree {
                SHHairline().padding(.vertical, SH.Space.xs)
                HStack(spacing: SH.Space.m) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("New worktree").font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textPrimary)
                        Text(worktree.caption).font(.shSans(11)).foregroundStyle(sh.textTertiary).lineLimit(2)
                    }
                    Spacer(minLength: SH.Space.m)
                    Toggle("New worktree", isOn: Binding(get: { worktree.isOn }, set: onWorktree))
                        .toggleStyle(.shSwitch)
                        .labelsHidden()
                }
                .padding(.horizontal, SH.Space.m)
                .padding(.vertical, SH.Space.xs)
                if worktree.isOn, let base = worktree.base {
                    SHMenuRow(highlighted: selection == options.count, action: onChooseBase, onHover: { selection = options.count }) {
                        Text("Base").font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textPrimary)
                        Spacer(minLength: SH.Space.m)
                        Text(base).font(.shMono(SHPlaceMenuMetrics.baseFont)).foregroundStyle(sh.textTertiary).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "chevron.right").font(.system(size: SHPlaceMenuMetrics.baseChevron, weight: .semibold)).foregroundStyle(sh.textTertiary)
                    }
                    .accessibilityLabel("Base branch: \(base)")
                }
            }
        }
        .modifier(SHMenuSurface(width: SHPlaceMenuMetrics.width))
        .task {
            // As the model picker: let the chip's focus release finish before claiming the field.
            await Task.yield()
            guard !Task.isCancelled else { return }
            focused = true
        }
        .onChange(of: query) { _, _ in selection = 0 }
        .onChange(of: rowCount) { _, count in selection = min(selection, max(0, count - 1)) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Where the thread runs")
    }
}

/// The workplace chip (NavNewThread): a repo glyph and the project in mono, a `textTertiary`
/// "·", a display glyph and the host in mono, and a chevron, as a composer chip.
public struct SHPlaceChipLabel: View {
    let project: String
    let host: String

    public init(project: String, host: String) {
        self.project = project
        self.host = host
    }

    public var body: some View {
        HStack(spacing: SH.Space.s) {
            Image(systemName: "folder").font(.system(size: 11, weight: .regular)).foregroundStyle(.sh.textSecondary)
            Text(project).font(.shMono(12)).lineLimit(1)
            Text("·").foregroundStyle(.sh.textTertiary)
            Image(systemName: "display").font(.system(size: 11, weight: .regular)).foregroundStyle(.sh.textSecondary)
            Text(host).font(.shMono(12)).lineLimit(1)
            SHChipChevron()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Where it runs: \(project) on \(host)")
    }
}
