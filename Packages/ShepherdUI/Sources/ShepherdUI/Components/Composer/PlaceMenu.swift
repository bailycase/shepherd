import SwiftUI

// The workplace chip's menu (GXNewPayments): where a new thread runs. A search field, then one section per
// host with its projects as a tree (nested ones fold under their parent; the one host's is headed "Space"),
// each section ending in "Add folder…"; then New Worktree… and Import Existing Worktree…, the worktree option,
// and, with another Mac paired, "Where it runs": each Mac, then Auto.

/// A project the menu offers: its name and path, on a host.
public struct SHPlaceOption: Identifiable, Equatable, Sendable {
    public var id: String
    /// The section (host) it belongs to.
    public var section: String
    public var title: String
    /// A quiet word after the name ("Own scratch folder"), in `textTertiary`.
    public var detail: String?
    /// Its path: what a search matches besides the name, and the row's tooltip.
    public var path: String?
    public var isCurrent: Bool
    /// The ids of the options it nests under, outermost first; they come before it in the section.
    public var ancestors: [String]

    public init(id: String, section: String, title: String, detail: String? = nil, path: String? = nil, isCurrent: Bool = false,
                ancestors: [String] = []) {
        self.id = id
        self.section = section
        self.title = title
        self.detail = detail
        self.path = path
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

/// The worktree option under the projects: a switch with what it does, and while it is on a
/// Branch row ("new from main", or the branch picked) and a Base row naming the branch it starts
/// from ("Default" until one is picked). `branch` or `base` nil draws no row.
public struct SHPlaceWorktree: Equatable, Sendable {
    public var isOn: Bool
    public var caption: String
    public var branch: String?
    public var base: String?

    public init(isOn: Bool, caption: String, branch: String? = nil, base: String? = nil) {
        self.isOn = isOn
        self.caption = caption
        self.branch = branch
        self.base = base
    }
}

public enum SHPlaceMenuMetrics {
    /// The menu's width (the board's 300): a project's name and its path side by side.
    public static let width: CGFloat = 300
    /// The tallest the menu grows before its list scrolls: the projects, the worktree rows and the Macs fit.
    public static let maxHeight: CGFloat = 560
    /// The search row's glyph.
    static let searchGlyph: CGFloat = 12
}

extension SHFleetPlaceRow {
    /// The board's words beside a Mac in the menu: "Has room", "Asleep"; Auto says what it does.
    var menuWord: String {
        if id == "auto" { return "Picks the Mac with room" }
        switch roomWord {
        case "asleep": return "Asleep"
        case "most", "some": return "Has room"
        case "little": return "Little room"
        case "full": return "No room"
        default: return roomWord
        }
    }
}

#if os(macOS)
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
    let onChooseBranch: () -> Void
    let onChooseBase: () -> Void
    /// "New Worktree…" and "Import Existing Worktree…" under the projects; nil draws no row.
    let onNewWorktree: (() -> Void)?
    let onImportWorktree: (() -> Void)?
    /// "Where it runs": the Macs a thread can start on, Auto last; empty draws no section.
    let runs: [SHFleetPlaceRow]
    let runsNote: String?
    let onRun: (SHFleetPlaceRow) -> Void
    let onClose: () -> Void
    @ViewBuilder let rowMenu: (SHPlaceOption) -> RowMenu
    @State private var selection: Int
    @State private var query = ""
    /// The parents shown open; the chosen project's ancestors start open.
    @State private var expanded: Set<String>
    @FocusState private var focused: Bool

    public init(sections: [SHPlaceSection], worktree: SHPlaceWorktree?, maxHeight: CGFloat? = nil,
                onChoose: @escaping (SHPlaceOption) -> Void, onAdd: @escaping (SHPlaceSection) -> Void,
                onWorktree: @escaping (Bool) -> Void, onChooseBranch: @escaping () -> Void = {}, onChooseBase: @escaping () -> Void = {},
                onNewWorktree: (() -> Void)? = nil, onImportWorktree: (() -> Void)? = nil,
                runs: [SHFleetPlaceRow] = [], runsNote: String? = nil, onRun: @escaping (SHFleetPlaceRow) -> Void = { _ in },
                onClose: @escaping () -> Void,
                @ViewBuilder rowMenu: @escaping (SHPlaceOption) -> RowMenu) {
        self.sections = sections
        self.worktree = worktree
        self.maxHeight = maxHeight
        self.onChoose = onChoose
        self.onAdd = onAdd
        self.onWorktree = onWorktree
        self.onChooseBranch = onChooseBranch
        self.onChooseBase = onChooseBase
        self.onNewWorktree = onNewWorktree
        self.onImportWorktree = onImportWorktree
        self.runs = runs.filter { $0.id != "auto" } + runs.filter { $0.id == "auto" }
        self.runsNote = runsNote
        self.onRun = onRun
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
                        || $0.path?.localizedCaseInsensitiveContains(query) == true
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
        let M = SHPlaceMenuMetrics.self
        let shown = shown
        let options = shown.flatMap(\.options)
        let parents = Set(sections.flatMap(\.options).compactMap(\.ancestors.last))
        // Rows line up with their siblings' chevrons once any project nests.
        let disclosures = query.isEmpty && !parents.isEmpty
        // The rows after the projects, in order, for ↑↓ and ⏎: the worktree commands, the Branch and Base, then the Macs.
        let commands: [(String, () -> Void)] = [onNewWorktree.map { ("New Worktree…", $0) }, onImportWorktree.map { ("Import Existing Worktree…", $0) }]
            .compactMap { $0 }
        let extras: [(String, String, () -> Void)] = worktree?.isOn == true
            ? [worktree?.branch.map { ("Branch", $0, onChooseBranch) }, worktree?.base.map { ("Base", $0, onChooseBase) }].compactMap { $0 }
            : []
        let commandBase = options.count
        let extraBase = commandBase + commands.count
        let runBase = extraBase + extras.count
        let rowCount = runBase + runs.count
        let indexByID = Dictionary(options.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let single = sections.count == 1
        SHPopMenu(width: runs.isEmpty ? SHPlaceMenuMetrics.width : SHFleetPlaceMetrics.width) {
            HStack(spacing: SH.Space.m) {
                Image(systemName: "magnifyingglass").font(.system(size: M.searchGlyph, weight: .medium)).foregroundStyle(sh.textTertiary)
                    .accessibilityHidden(true)
                TextField(text: $query, prompt: Text("Search spaces").foregroundStyle(sh.textTertiary)) { Text("Search spaces") }
                    .textFieldStyle(.plain)
                    .font(.sh(.ui, weight: .regular))
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
                        else if commands.indices.contains(selection - commandBase) { commands[selection - commandBase].1() }
                        else if extras.indices.contains(selection - extraBase) { extras[selection - extraBase].2() }
                        else if runs.indices.contains(selection - runBase), runs[selection - runBase].isEnabled { onRun(runs[selection - runBase]) }
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
                            .frame(height: SHPopMenuMetrics.rowHeight)
                    }
                    ForEach(shown) { section in
                        SHPopMenuHeader(single ? "Space" : section.title)
                        ForEach(section.options) { option in
                            let index = indexByID[option.id] ?? 0
                            let isParent = parents.contains(option.id)
                            let isOpen = expanded.contains(option.id)
                            SHPopMenuRow(option.title, lead: .check(option.isCurrent), trailing: option.detail, trailingStyle: .path,
                                         disclosure: disclosures ? SHPopMenuDisclosure(indent: option.ancestors.count, isParent: isParent, isOpen: isOpen) : nil,
                                         highlighted: index == selection, index: index, onHighlight: { selection = $0 },
                                         onDisclose: { if isOpen { expanded.remove(option.id) } else { expanded.insert(option.id) } },
                                         action: { onChoose(option) })
                                .contextMenu { rowMenu(option) }
                                .help(option.path ?? "")
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
                            SHPopMenuRow(add, lead: .glyph("plus"), quiet: true, highlighted: false) { onAdd(section) }
                                .accessibilityLabel("\(add) on \(section.title)")
                        }
                    }
                    if !commands.isEmpty || worktree != nil {
                        SHPopMenuSeparator()
                        ForEach(Array(commands.enumerated()), id: \.element.0) { offset, command in
                            let index = commandBase + offset
                            SHPopMenuRow(command.0, highlighted: selection == index, index: index, onHighlight: { selection = $0 }, action: command.1)
                        }
                    }
                    if let worktree {
                        SHPopMenuToggle("New worktree", caption: worktree.caption, isOn: Binding(get: { worktree.isOn }, set: onWorktree))
                        ForEach(Array(extras.enumerated()), id: \.element.0) { offset, row in
                            let index = extraBase + offset
                            SHPopMenuRow(row.0, trailing: row.1, trailingStyle: .code, chevron: true, highlighted: selection == index, index: index,
                                         onHighlight: { selection = $0 }, action: row.2)
                                .accessibilityLabel(row.0 == "Base" ? "Base branch: \(row.1)" : "\(row.0): \(row.1)")
                        }
                    }
                    if !runs.isEmpty {
                        SHPopMenuSeparator()
                        SHPopMenuHeader("Where it runs")
                        ForEach(Array(runs.enumerated()), id: \.element.id) { offset, run in
                            let index = runBase + offset
                            SHFleetPlaceMenuRow(run, word: run.roomWord, highlighted: selection == index, index: index,
                                                onHighlight: { selection = $0 }) { onRun(run) }
                                .equatable()
                        }
                        if let runsNote { SHPopMenuNote(runsNote) }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: maxHeight.map { max(0, $0 - SHComposerMetrics.modelSearchHeight) })
            .fixedSize(horizontal: false, vertical: maxHeight == nil)
        }
        .task {
            // As the model picker: let the chip's focus release finish before claiming the field.
            await Task.yield()
            guard !Task.isCancelled else { return }
            focused = true
        }
        .onChange(of: query) { _, _ in selection = 0 }
        .onChange(of: rowCount) { _, count in selection = min(selection, max(0, count - 1)) }
        .accessibilityLabel("Where the thread runs")
    }
}

#endif

/// The workplace chip (NavNewThread): a repo glyph and the project in mono, a `textTertiary`
/// "·", a display glyph and the host in mono, and a chevron, as a composer chip.
public struct SHPlaceChipLabel: View {
    let project: String
    let host: String?

    /// With another Mac paired `host` is the Mac the thread runs on ("Auto · Mac mini"); its menu's Where it runs section picks it.
    public init(project: String, host: String?) {
        self.project = project
        self.host = host
    }

    /// "Mac mini" as the boards name it after Auto: "mini".
    private static func shortName(_ name: String) -> String {
        name.hasPrefix("Mac ") && name.count > 4 ? String(name.dropFirst(4)).lowercased() : name
    }

    public var body: some View {
        #if os(macOS)
        // The boards' `.where`: the folder, the project in medium ink, "on This Mac" in `textSecondary`.
        HStack(spacing: SH.Space.xs + 1) {
            Image(systemName: "folder").font(.system(size: SH.Space.l + 1)).foregroundStyle(.sh.textSecondary)
            Text(project).font(.sh(.ui, weight: .medium)).foregroundStyle(.sh.textPrimary).lineLimit(1)
            if let host {
                // "Auto · Mac mini" reads "on Auto", then the Mac Auto picked in the quiet color (FleetNewThread).
                let place = host.components(separatedBy: " · ")
                Text("on \(place[0])").font(.sh(.ui)).foregroundStyle(.sh.textSecondary).lineLimit(1)
                if place.count > 1 {
                    Text(Self.shortName(place[1])).font(.sh(.ui)).foregroundStyle(.sh.textTertiary).lineLimit(1)
                }
            }
            SHChipChevron()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(host.map { "Where it runs: \(project) on \($0)" } ?? "Project: \(project)")
        #else
        HStack(spacing: SH.Space.s) {
            Image(systemName: "folder").font(.system(size: 11, weight: .regular)).foregroundStyle(.sh.textSecondary)
            Text(project).font(.shMono(12)).lineLimit(1)
            if let host {
                Text("·").foregroundStyle(.sh.textTertiary)
                Image(systemName: "display").font(.system(size: 11, weight: .regular)).foregroundStyle(.sh.textSecondary)
                Text(host).font(.shMono(12)).lineLimit(1)
            }
            SHChipChevron()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(host.map { "Where it runs: \(project) on \($0)" } ?? "Project: \(project)")
        #endif
    }
}
