import SwiftUI
import ShepherdSessions
import ShepherdUI

// Settings › Hooks (HooksSettings, HooksSources boards): Hooks lists every hook by event with the
// rail of events; Sources lists the readers and every file read. Both open Edit.

struct HooksSettings: View {
    @Bindable var model: HooksModel

    var body: some View {
        SettingsPage(title: "Hooks",
                     explanation: "Commands that run at set points in a thread, in the format Claude Code and Codex use. Shepherd also reads the hooks you already have there. Every hook that matches runs.") {
            Button { model.add(spaceRoot: model.spaceFilter) } label: { Label("Add hook", systemImage: "plus") }
                .buttonStyle(.sh(.secondary, size: .m))
        } content: {
            VStack(alignment: .leading, spacing: SH.Space.xl) {
                tabs
                if let problem = model.problem {
                    SHInlineProblem(problem)
                }
                if model.snapshot == nil {
                    Text("Reading hooks files…").font(.sh(.ui)).foregroundStyle(Color.sh.textTertiary)
                } else if model.tab == .hooks {
                    hooksTab
                } else {
                    HookSourcesView(model: model)
                }
            }
        }
        .hookSheets(model)
        .onAppear { model.reload() }
    }

    private var tabs: some View {
        HStack(spacing: SH.Space.xs) {
            HookTabButton(title: "Hooks", count: nil, selected: model.tab == .hooks) { model.tab = .hooks }
            HookTabButton(title: "Sources", count: model.fileCount == 1 ? "1 file" : "\(model.fileCount) files", selected: model.tab == .sources) { model.tab = .sources }
            Spacer(minLength: 0)
        }
        .padding(.bottom, SH.Space.m)
        .overlay(alignment: .bottom) { SHHairline() }
    }

    @ViewBuilder private var hooksTab: some View {
        if let root = model.spaceFilter {
            HStack(spacing: SH.Space.m) {
                Text("This Mac’s hooks and \((root as NSString).lastPathComponent)’s").font(.sh(.ui)).foregroundStyle(Color.sh.textSecondary)
                Button("Show every space") { model.spaceFilter = nil }.buttonStyle(.shLink)
            }
        }
        if model.groups.isEmpty {
            HookEmptyState(text: "No hooks yet. Add one, or ask an agent to propose one; Shepherd also reads the hooks in Claude Code’s and Codex’s files.") {
                model.add(spaceRoot: model.spaceFilter)
            }
        } else {
            HStack(alignment: .top, spacing: SH.Space.xxl) {
                VStack(alignment: .leading, spacing: SH.Space.xxs) {
                    ForEach(model.rail) { item in
                        HookRailRow(item: item, selected: model.filter == item.event) { model.filter = item.event }
                    }
                    if model.emptyEvents > 0 {
                        HookHelp("\(model.emptyEvents) more \(model.emptyEvents == 1 ? "event has" : "events have") no hooks. Add hook lists all \(HookEvent.allCases.count).")
                            .padding(.horizontal, SH.Space.m).padding(.top, SH.Space.m)
                    }
                }
                .frame(width: AppLayout.hooksRailWidth)
                LazyVStack(alignment: .leading, spacing: SH.Space.l) {
                    ForEach(model.groups) { group in
                        HookGroupView(group: group, sourceWidth: AppLayout.hooksSourceWidth, model: model)
                    }
                }
            }
        }
    }
}

extension View {
    /// The Edit sheet a hooks page opens.
    func hookSheets(_ model: HooksModel) -> some View {
        modifier(HookSheets(model: model))
    }
}

private struct HookSheets: ViewModifier {
    @Bindable var model: HooksModel

    func body(content: Content) -> some View {
        content
            .sheet(item: $model.editor) { editor in
                HookEditSheet(editor: editor, model: model) { model.editor = nil }
            }
    }
}

/// The Hooks / Sources tabs.
struct HookTabButton: View {
    let title: String
    let count: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: SH.Space.s) {
                Text(title).font(.sh(.ui)).foregroundStyle(selected ? Color.sh.textPrimary : Color.sh.textSecondary)
                if let count { Text(count).font(.sh(.mono)).foregroundStyle(Color.sh.textTertiary) }
            }
            .padding(.horizontal, SH.Space.m).frame(height: SH.Height.controlM).contentShape(Rectangle())
        }
        .buttonStyle(.shRow(selected: selected, focusColor: .sh.running))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The boards' fold chevron: down, turned over while open.
struct HookChevron: View {
    let open: Bool
    var body: some View {
        Image(systemName: "chevron.down").font(.sh(.micro)).foregroundStyle(Color.sh.textTertiary)
            .rotationEffect(.degrees(open ? 180 : 0))
            .shAnimation(.disclosure, value: open)
            .accessibilityHidden(true)
    }
}

struct HookEmptyState: View {
    let text: String
    let add: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.m) {
            Text(text).font(.sh(.ui)).foregroundStyle(Color.sh.textSecondary).fixedSize(horizontal: false, vertical: true)
            Button("Add hook", action: add).buttonStyle(.sh(.secondary, size: .s))
        }
        .padding(SH.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shBorder(Color.sh.lineSubtle, radius: SHCardRowMetrics.settingsCardRadius)
    }
}

struct HookRailRow: View {
    let item: HookRailItem
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: SH.Space.m) {
                Text(item.label).font(.sh(.ui)).foregroundStyle(selected ? Color.sh.textPrimary : Color.sh.textSecondary).lineLimit(1)
                Spacer(minLength: 0)
                Text("\(item.count)").font(.sh(.micro)).foregroundStyle(Color.sh.textTertiary)
            }
            .padding(.horizontal, SH.Space.m).frame(height: AppLayout.hooksRailRowHeight).contentShape(Rectangle())
        }
        .buttonStyle(.shRow(selected: selected, focusColor: .sh.running))
        .accessibilityLabel("\(item.label), \(item.count)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// An event's heading and its hooks' card.
struct HookGroupView: View {
    let group: HookEventGroup
    let sourceWidth: CGFloat
    let model: HooksModel

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
                Text(group.label).font(.sh(.ui, weight: .semibold)).foregroundStyle(Color.sh.textPrimary).accessibilityAddTraits(.isHeader)
                Text(group.event).font(.sh(.mono)).foregroundStyle(Color.sh.textTertiary)
            }
            .padding(.horizontal, SH.Space.xs)
            SHGroupCard(fill: Color.sh.bgWindow, radius: SHCardRowMetrics.settingsCardRadius) {
                ForEach(group.rows) { row in
                    HookRow(row: row, sourceWidth: sourceWidth) {
                        if let entry = model.entry(slot: row.id) { model.edit(entry) }
                    } setOn: { model.setOn(row, $0) }
                }
            }
        }
    }
}

/// One hook: matcher chip, command (opens Edit), where it's from, and its switch.
struct HookRow: View, Equatable {
    let row: HookRowValue
    let sourceWidth: CGFloat
    let open: () -> Void
    let setOn: (Bool) -> Void
    @State private var hovered = false

    static func == (a: Self, b: Self) -> Bool { a.row == b.row && a.sourceWidth == b.sourceWidth }

    var body: some View {
        HStack(spacing: SH.Space.l) {
            HookMatcherChip(text: row.matcher, any: row.matcherIsAny)
            Button(action: open) {
                Text(row.command).font(.sh(.mono)).foregroundStyle(Color.sh.textPrimary).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(row.command)
            .accessibilityLabel("Edit hook: \(row.command)")
            Text(row.source).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).lineLimit(1).truncationMode(.middle)
                .frame(width: sourceWidth, alignment: .trailing)
            Toggle(row.on ? "Turn off \(row.command)" : "Turn on \(row.command)", isOn: Binding(get: { row.on }, set: setOn))
                .labelsHidden().toggleStyle(.shSwitch)
                .disabled(row.locked)
                .help(row.lockHelp ?? "")
        }
        .padding(.leading, SH.Space.xl).padding(.trailing, SH.Space.l)
        .frame(minHeight: AppLayout.hooksRowHeight)
        .background(hovered ? Color.sh.bgHover : Color.clear)
        .onHover { hovered = $0 }
    }
}

struct HookMatcherChip: View {
    let text: String
    let any: Bool

    var body: some View {
        Text(text).font(.sh(.micro)).foregroundStyle(any ? Color.sh.textTertiary : Color.sh.textPrimary).lineLimit(1)
            .padding(.horizontal, SH.Space.s).frame(height: AppLayout.hooksChipHeight)
            .background(Color.sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.xs))
            .shBorder(Color.sh.lineStrong, in: RoundedRectangle(cornerRadius: SH.Radius.xs), dash: any ? [SH.Space.xs, SH.Space.xxs] : [])
            .fixedSize()
            .help("Matcher")
            .accessibilityLabel("Matcher \(text)")
    }
}

// MARK: Sources

struct HookSourcesView: View {
    @Bindable var model: HooksModel

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.xl) {
            SHGroupCard(fill: Color.sh.bgWindow, radius: SHCardRowMetrics.settingsCardRadius) {
                HookReaderRow(title: "Read hooks from Claude Code", paths: "~/.claude/settings.json and each space’s .claude/settings.json",
                              isOn: Binding(get: { model.readers.claude }, set: { model.setReader(.claude, $0) }))
                HookReaderRow(title: "Read hooks from Codex", paths: "~/.codex/hooks.json, ~/.codex/config.toml and each space’s .codex/",
                              isOn: Binding(get: { model.readers.codex }, set: { model.setReader(.codex, $0) }))
            }
            ForEach(model.sections) { section in
                VStack(alignment: .leading, spacing: SH.Space.s) {
                    HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
                        Text(section.name).font(.sh(.ui, weight: .semibold)).foregroundStyle(Color.sh.textPrimary).accessibilityAddTraits(.isHeader)
                        Text(section.note).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).lineLimit(1).truncationMode(.middle)
                    }
                    .padding(.horizontal, SH.Space.xs)
                    SHGroupCard(fill: Color.sh.bgWindow, radius: SHCardRowMetrics.settingsCardRadius) {
                        if section.files.isEmpty {
                            Text("No hooks files on this Mac yet.").font(.sh(.ui)).foregroundStyle(Color.sh.textTertiary)
                                .frame(maxWidth: .infinity, minHeight: AppLayout.hooksFileRowHeight, alignment: .leading)
                                .padding(.horizontal, SH.Space.xl)
                        }
                        ForEach(section.files) { file in
                            HookFileRowView(row: file) { model.act($0, on: file, root: section.root) }
                        }
                    }
                }
            }
            Text("Hooks from every file run together: a space’s hooks add to yours, they never replace them. Pi extensions that handle tool calls run as extensions, not hooks; switch those in Extensions.")
                .shText(size: AppLayout.settingsFootnoteSize, lineHeight: AppLayout.settingsFootnoteLineHeight)
                .foregroundStyle(Color.sh.textTertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct HookReaderRow: View {
    let title: String
    let paths: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: SH.Space.l) {
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(title).font(.sh(.ui)).foregroundStyle(Color.sh.textPrimary)
                Text(paths).font(.sh(.mono)).foregroundStyle(Color.sh.textTertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            SettingsSwitch(label: title, isOn: $isOn)
        }
        .padding(.leading, SH.Space.xl).padding(.trailing, SH.Space.l)
        .frame(minHeight: AppLayout.hooksReaderRowHeight)
    }
}

/// A file: path, format, count, state (a dot in its color and the words), its action.
struct HookFileRowView: View {
    let row: HookFileRow
    let act: (HookFileRow.Action) -> Void

    var body: some View {
        HStack(spacing: SH.Space.l) {
            Text(row.shownPath).font(.sh(.mono)).foregroundStyle(Color.sh.textPrimary).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading).help(row.path)
            Text(row.format).font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary).frame(width: AppLayout.hooksFormatWidth, alignment: .leading)
            Text(row.count).font(.sh(.mono)).foregroundStyle(Color.sh.textSecondary).frame(width: AppLayout.hooksCountWidth, alignment: .leading)
            HStack(spacing: SH.Space.s) {
                Circle().fill(Self.color(row.tone)).frame(width: AppLayout.hooksDotSize, height: AppLayout.hooksDotSize)
                Text(row.state).font(.sh(.caption)).foregroundStyle(Self.color(row.tone)).lineLimit(1).truncationMode(.tail).help(row.state)
            }
            .frame(width: AppLayout.hooksStateWidth, alignment: .leading)
            Group {
                if let action = row.action {
                    Button(Self.title(action)) { act(action) }.buttonStyle(.shLink)
                        .accessibilityLabel("\(Self.title(action)): \(row.shownPath)")
                }
            }
            .frame(width: AppLayout.hooksActionWidth, alignment: .trailing)
        }
        .opacity(row.dimmed ? AppLayout.hooksOffOpacity : 1)
        .padding(.leading, SH.Space.xl).padding(.trailing, SH.Space.l)
        .frame(minHeight: AppLayout.hooksFileRowHeight)
        .accessibilityElement(children: .contain)
    }

    @MainActor static func color(_ tone: HookFileRow.Tone) -> Color {
        switch tone {
        case .ok: Color.sh.done
        case .off: Color.sh.textTertiary
        case .failed: Color.sh.failed
        }
    }

    static func title(_ action: HookFileRow.Action) -> String {
        switch action {
        case .openFile: "Open file"
        }
    }
}

// MARK: A space's Hooks tab (HooksSpace board)

struct HooksSpacePage: View {
    @Bindable var model: HooksModel
    let root: String
    var openSettings: () -> Void

    var body: some View {
        // ponytail: one space's rows are filtered here per render (a handful of hooks); cache per root in the model if a space grows long.
        let space = model.space(root)
        VStack(alignment: .leading, spacing: SH.Space.xl) {
            VStack(alignment: .leading, spacing: SH.Space.s) {
                HStack {
                    Text("Files in this space").font(.sh(.ui, weight: .semibold)).foregroundStyle(Color.sh.textPrimary)
                    Spacer(minLength: 0)
                    Button { model.add(spaceRoot: root) } label: { Label("Add hook", systemImage: "plus") }.buttonStyle(.sh(.secondary, size: .m))
                }
                HStack(alignment: .top, spacing: SH.Space.l) {
                    ForEach(space.files) { file in
                        VStack(alignment: .leading, spacing: SH.Space.xxs) {
                            Text(file.shownPath).font(.sh(.mono)).foregroundStyle(Color.sh.textPrimary).lineLimit(1)
                            Text(file.format + " · " + (file.state == "Loaded" ? file.count : file.state))
                                .font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).lineLimit(2)
                            if let action = file.action {
                                Button(HookFileRowView.title(action)) { model.act(action, on: file, root: root) }.buttonStyle(.shLink)
                            }
                        }
                        .padding(.horizontal, SH.Space.l).padding(.vertical, SH.Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                        .shBorder(Color.sh.lineSubtle, radius: SH.Radius.m)
                        .opacity(file.dimmed ? AppLayout.hooksOffOpacity : 1)
                    }
                }
            }
            if model.snapshot == nil {
                Text("Reading hooks files…").font(.sh(.ui)).foregroundStyle(Color.sh.textTertiary)
            } else if space.groups.isEmpty {
                Text("No hooks in this space.").font(.sh(.ui)).foregroundStyle(Color.sh.textTertiary)
            }
            ForEach(space.groups) { group in
                HookGroupView(group: group, sourceWidth: AppLayout.hooksSpaceSourceWidth, model: model)
            }
            if space.macCount > 0 {
                HStack(spacing: SH.Space.xs) {
                    Text(space.macCount == 1 ? "1 hook on this Mac also runs in this space." : "\(space.macCount) hooks on this Mac also run in this space.")
                        .font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                    Button("See them in Settings › Hooks", action: openSettings).buttonStyle(.shLink(font: .sh(.caption)))
                }
            }
        }
        .hookSheets(model)
        .onAppear { model.reload() }
    }
}
