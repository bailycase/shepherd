import SwiftUI

// The workplace chip's menu (NavNewThread): where a new thread runs, as the composer's menus
// look (radius 12, raised, the popover shadow, 28pt rows). One section per host with its
// projects, each section ending in "Add folder…"; then the worktree option.

/// A project the menu offers: its name and path, on a host.
public struct SHPlaceOption: Identifiable, Equatable, Sendable {
    public var id: String
    /// The section (host) it belongs to.
    public var section: String
    public var title: String
    /// Its path, in mono `textTertiary`.
    public var detail: String?
    public var isCurrent: Bool

    public init(id: String, section: String, title: String, detail: String? = nil, isCurrent: Bool = false) {
        self.id = id
        self.section = section
        self.title = title
        self.detail = detail
        self.isCurrent = isCurrent
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
}

/// The workplace menu: sections of projects (a check on the chosen one, its path trailing),
/// "Add folder…" per host, and the worktree switch. ↑↓ move, ⏎ chooses, esc closes. Each
/// project row carries `rowMenu` as its context menu.
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
        let options = sections.flatMap(\.options)
        _selection = State(initialValue: options.firstIndex(where: \.isCurrent) ?? 0)
    }

    private var options: [SHPlaceOption] { sections.flatMap(\.options) }

    public var body: some View {
        let sh = Color.sh
        let showsBase = worktree?.isOn == true && worktree?.base != nil
        let rowCount = options.count + (showsBase ? 1 : 0)
        let indexByID = Dictionary(options.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(sections) { section in
                        SHMenuHeader(section.title)
                        ForEach(section.options) { option in
                            let index = indexByID[option.id] ?? 0
                            SHMenuRow(highlighted: index == selection, action: { onChoose(option) }, onHover: { selection = index }) {
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
                            .accessibilityLabel(option.title + (option.isCurrent ? ", current" : ""))
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
            .frame(maxHeight: maxHeight.map { max(0, $0 - (worktree == nil ? 0 : SHComposerMetrics.menuRowHeight * 2)) })
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
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.downArrow) { selection = min(max(0, rowCount - 1), selection + 1); return .handled }
        .onKeyPress(.upArrow) { selection = max(0, selection - 1); return .handled }
        .onKeyPress(.return) {
            if options.indices.contains(selection) { onChoose(options[selection]) }
            else if showsBase, selection == options.count { onChooseBase() }
            return .handled
        }
        .onKeyPress(.escape) { onClose(); return .handled }
        .onAppear { focused = true }
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
