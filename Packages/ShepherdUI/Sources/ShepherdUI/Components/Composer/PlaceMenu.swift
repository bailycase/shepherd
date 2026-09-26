import SwiftUI

// The workplace chip's menu (NavNewThread): where a new thread runs, as the composer's menus
// look (radius 12, raised, the popover shadow, 28pt rows). One section per host with its
// projects, each section ending in "Add folder…"; then the worktree option.

/// A project the menu offers: its name and path, on a host.
public struct NWPlaceOption: Identifiable, Equatable, Sendable {
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
public struct NWPlaceSection: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var options: [NWPlaceOption]
    /// "Add folder…" at the section's end; nil where the host cannot add one.
    public var addTitle: String?

    public init(id: String, title: String, options: [NWPlaceOption], addTitle: String? = "Add folder…") {
        self.id = id
        self.title = title
        self.options = options
        self.addTitle = addTitle
    }
}

/// The worktree option under the projects: a switch with what it does.
public struct NWPlaceWorktree: Equatable, Sendable {
    public var isOn: Bool
    public var caption: String

    public init(isOn: Bool, caption: String) {
        self.isOn = isOn
        self.caption = caption
    }
}

public enum NWPlaceMenuMetrics {
    /// The menu's width: a project's name and its path side by side.
    public static let width: CGFloat = 320
}

/// The workplace menu: sections of projects (a check on the chosen one, its path trailing),
/// "Add folder…" per host, and the worktree switch. ↑↓ move, ⏎ chooses, esc closes. Each
/// project row carries `rowMenu` as its context menu.
public struct NWPlaceMenu<RowMenu: View>: View {
    let sections: [NWPlaceSection]
    let worktree: NWPlaceWorktree?
    let maxHeight: CGFloat?
    let onChoose: (NWPlaceOption) -> Void
    let onAdd: (NWPlaceSection) -> Void
    let onWorktree: (Bool) -> Void
    let onClose: () -> Void
    @ViewBuilder let rowMenu: (NWPlaceOption) -> RowMenu
    @State private var selection: Int
    @FocusState private var focused: Bool

    public init(sections: [NWPlaceSection], worktree: NWPlaceWorktree?, maxHeight: CGFloat? = nil,
                onChoose: @escaping (NWPlaceOption) -> Void, onAdd: @escaping (NWPlaceSection) -> Void,
                onWorktree: @escaping (Bool) -> Void, onClose: @escaping () -> Void,
                @ViewBuilder rowMenu: @escaping (NWPlaceOption) -> RowMenu) {
        self.sections = sections
        self.worktree = worktree
        self.maxHeight = maxHeight
        self.onChoose = onChoose
        self.onAdd = onAdd
        self.onWorktree = onWorktree
        self.onClose = onClose
        self.rowMenu = rowMenu
        let options = sections.flatMap(\.options)
        _selection = State(initialValue: options.firstIndex(where: \.isCurrent) ?? 0)
    }

    private var options: [NWPlaceOption] { sections.flatMap(\.options) }

    public var body: some View {
        let nw = Color.nw
        let indexByID = Dictionary(options.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(sections) { section in
                        NWMenuHeader(section.title)
                        ForEach(section.options) { option in
                            let index = indexByID[option.id] ?? 0
                            NWMenuRow(highlighted: index == selection, action: { onChoose(option) }, onHover: { selection = index }) {
                                Text(option.title).font(.nw(.ui, weight: .regular)).foregroundStyle(nw.textPrimary).lineLimit(1)
                                if let detail = option.detail {
                                    Text(detail).font(.nwMono(11)).foregroundStyle(nw.textTertiary).lineLimit(1)
                                        .truncationMode(.head)
                                }
                                Spacer(minLength: 0)
                                if option.isCurrent {
                                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(nw.running)
                                }
                            }
                            .contextMenu { rowMenu(option) }
                            .accessibilityLabel(option.title + (option.isCurrent ? ", current" : ""))
                        }
                        if let add = section.addTitle {
                            NWMenuRow(highlighted: false, action: { onAdd(section) }, onHover: {}) {
                                Image(systemName: "plus").font(.system(size: 11, weight: .medium)).foregroundStyle(nw.textSecondary)
                                Text(add).font(.nw(.ui, weight: .regular)).foregroundStyle(nw.textSecondary)
                                Spacer(minLength: 0)
                            }
                            .accessibilityLabel("\(add) on \(section.title)")
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: maxHeight.map { max(0, $0 - (worktree == nil ? 0 : NWComposerMetrics.menuRowHeight * 2)) })
            .fixedSize(horizontal: false, vertical: maxHeight == nil)
            if let worktree {
                NWHairline().padding(.vertical, NW.Space.xs)
                HStack(spacing: NW.Space.m) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("New worktree").font(.nw(.ui, weight: .regular)).foregroundStyle(nw.textPrimary)
                        Text(worktree.caption).font(.nwSans(11)).foregroundStyle(nw.textTertiary).lineLimit(2)
                    }
                    Spacer(minLength: NW.Space.m)
                    Toggle("New worktree", isOn: Binding(get: { worktree.isOn }, set: onWorktree))
                        .toggleStyle(.nwSwitch)
                        .labelsHidden()
                }
                .padding(.horizontal, NW.Space.m)
                .padding(.vertical, NW.Space.xs)
            }
        }
        .modifier(NWMenuSurface(width: NWPlaceMenuMetrics.width))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.downArrow) { selection = min(max(0, options.count - 1), selection + 1); return .handled }
        .onKeyPress(.upArrow) { selection = max(0, selection - 1); return .handled }
        .onKeyPress(.return) {
            if options.indices.contains(selection) { onChoose(options[selection]) }
            return .handled
        }
        .onKeyPress(.escape) { onClose(); return .handled }
        .onAppear { focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Where the thread runs")
    }
}

/// The workplace chip (NavNewThread): a repo glyph and the project in mono, a `textTertiary`
/// "·", a display glyph and the host in mono, and a chevron, as a composer chip.
public struct NWPlaceChipLabel: View {
    let project: String
    let host: String

    public init(project: String, host: String) {
        self.project = project
        self.host = host
    }

    public var body: some View {
        HStack(spacing: NW.Space.s) {
            Image(systemName: "folder").font(.system(size: 11, weight: .regular)).foregroundStyle(.nw.textSecondary)
            Text(project).font(.nwMono(12)).lineLimit(1)
            Text("·").foregroundStyle(.nw.textTertiary)
            Image(systemName: "display").font(.system(size: 11, weight: .regular)).foregroundStyle(.nw.textSecondary)
            Text(host).font(.nwMono(12)).lineLimit(1)
            NWChipChevron()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Where it runs: \(project) on \(host)")
    }
}
