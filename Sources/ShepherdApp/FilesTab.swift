import SwiftUI
import AppKit
import ShepherdUI
import ShepherdCore
import ShepherdRemote
import ImageIO

// MARK: - Files tab (side pane)

/// The side pane's Files tab (PaneFiles board): the space's file tree on the left, an editor
/// for the open file on the right. A local thread's text files edit and save in place; a remote
/// thread's tree reads its host over `files.v1` (read-only), and a host without it shows an
/// unavailable message.
struct FilesTab: View {
    let model: FileTreeModel
    /// The file the thread's agent is editing now (absolute), for the tab and tree spinners.
    let agentPath: String?
    @State private var showTree = true
    @State private var treeWidth: CGFloat = AppLayout.Files.treeWidth
    @State private var liveTreeWidth: CGFloat?
    /// A tab with unsaved edits the person asked to close: confirmed first.
    @State private var closing: OpenFileTab?
    private let coordSpace = "files-panel-resize"

    /// `agentPath` as the agent's edit call names it: relative to the thread's folder, or absolute.
    init(model: FileTreeModel, agentPath: String? = nil, treeVisible: Bool = true) {
        self.model = model
        self.agentPath = agentPath.map {
            ($0.hasPrefix("/") ? $0 : (model.rootPath as NSString).appendingPathComponent($0) as String)
        }.map { ($0 as NSString).standardizingPath }
        _showTree = State(initialValue: treeVisible)
    }

    var body: some View {
        GeometryReader { geo in
            let maxTree = max(AppLayout.Files.treeMinWidth, geo.size.width - AppLayout.Files.viewerMinWidth - AppLayout.dividerWidth)
            let clampedTree = min(liveTreeWidth ?? treeWidth, maxTree)

            HStack(spacing: 0) {
                if showTree {
                    FileTreeContent(model: model, showHidden: Bindable(model).showHidden, agentPath: agentPath,
                                    hideTree: { showTree = false })
                        .frame(width: clampedTree)
                    treeResizeHandle(maxTree: maxTree)
                }
                fileViewer
                    .frame(width: showTree ? max(0, geo.size.width - clampedTree - AppLayout.dividerWidth) : geo.size.width,
                           height: geo.size.height, alignment: .topLeading)
                    .clipped()
            }
            .coordinateSpace(name: coordSpace)
        }
        .background(Color.sh.bgWindow)
        .overlay(alignment: .topLeading) {
            if !showTree && model.selectedPath == nil {
                Button { showTree = true } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: AppLayout.Files.showTreeIconSize))
                        .foregroundStyle(Color.sh.textTertiary)
                }
                .buttonStyle(.plain)
                .frame(width: AppLayout.Files.toggleTreeSize, height: AppLayout.Files.toggleTreeSize)
                .padding(AppLayout.Files.showTreePadding)
                .help("Show file tree")
                .accessibilityLabel("Show file tree")
            }
        }
        .task(id: model.rootPath) { await model.loadRoot() }
        // Changes on disk reach an open editor: a clean one takes them, a dirty one holds them as a conflict.
        .task(id: model.selectedPath) {
            guard model.canEdit else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: AppLayout.Files.diskCheckInterval)
                guard !Task.isCancelled else { return }
                await model.checkDisk()
            }
        }
        .onChange(of: agentPath) { Task { await model.checkDisk() } }
        .confirmationDialog("Close \(closing?.name ?? "") without saving?",
                            isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }),
                            presenting: closing) { tab in
            Button("Discard Changes", role: .destructive) { Task { await model.closeTab(tab.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Your unsaved edits will be lost.")
        }
    }

    private func treeResizeHandle(maxTree: CGFloat) -> some View {
        Color.sh.lineSubtle
            .frame(width: AppLayout.dividerWidth)
            .overlay {
                Color.clear
                    .frame(width: AppLayout.resizeHandleWidth)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named(coordSpace))
                            .onChanged { value in
                                liveTreeWidth = max(AppLayout.Files.treeMinWidth, min(value.location.x, maxTree))
                            }
                            .onEnded { _ in
                                if let live = liveTreeWidth { treeWidth = live }
                                liveTreeWidth = nil
                            }
                    )
            }
            .accessibilityElement()
            .accessibilityLabel("File tree width")
            .accessibilityValue("\(Int(treeWidth)) points")
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? AppLayout.paneAdjustStep : -AppLayout.paneAdjustStep
                treeWidth = min(maxTree, max(AppLayout.Files.treeMinWidth, treeWidth + step))
            }
    }

    // MARK: Viewer

    @ViewBuilder
    private var fileViewer: some View {
        VStack(spacing: 0) {
            // Tab strip
            if !model.openTabs.isEmpty {
                fileTabStrip
            }
            // Content
            if let path = model.selectedPath {
                FileViewerContent(model: model, path: path, showTree: showTree, toggleTree: { showTree.toggle() })
            } else {
                emptyState
            }
        }
    }

    private var fileTabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(model.openTabs) { tab in
                    FileTabView(
                        tab: tab,
                        isActive: model.selectedPath == tab.id,
                        isDirty: model.edits[tab.id]?.isDirty == true,
                        agentWorking: agentPath == tab.id,
                        select: { Task { await model.select(path: tab.id) } },
                        close: {
                            if model.edits[tab.id]?.isDirty == true { closing = tab }
                            else { Task { await model.closeTab(tab.id) } }
                        }
                    )
                }
            }
        }
        .frame(height: AppLayout.Files.tabHeight)
        .background(Color.sh.bgWindow)
        .overlay(alignment: .bottom) {
            Color.sh.lineSubtle.frame(height: 1)
        }
    }

    private var emptyState: some View {
        VStack(spacing: SH.Space.m) {
            Image(systemName: SHGlyph.document.symbolName)
                .font(.system(size: AppLayout.Files.emptyIconSize, weight: .light))
                .foregroundStyle(Color.sh.textTertiary)
            Text("Select a file to view")
                .font(.sh(.caption))
                .foregroundStyle(Color.sh.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - File tab

/// One open file: its name, then a lantern dot while it has unsaved edits, a spinner while the
/// agent edits it, else its close button (shown on hover for the first two too).
private struct FileTabView: View {
    let tab: OpenFileTab
    let isActive: Bool
    let isDirty: Bool
    let agentWorking: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: SH.Space.s) {
            Button(action: select) {
                HStack(spacing: SH.Space.s) {
                    Image(systemName: SHGlyph.document.symbolName)
                        .font(.system(size: AppLayout.Files.treeFileIconSize))
                        .foregroundStyle(Color.sh.textTertiary)
                    Text(tab.name)
                        .font(.sh(.code))
                        .foregroundStyle(isActive ? Color.sh.textPrimary : Color.sh.textSecondary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)

            ZStack {
                if hovering || !(isDirty || agentWorking) {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: AppLayout.Files.tabCloseFontSize, weight: .semibold))
                            .foregroundStyle(Color.sh.textTertiary)
                            .frame(width: AppLayout.Files.tabCloseSize, height: AppLayout.Files.tabCloseSize)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close \(tab.name)")
                } else if agentWorking {
                    ProgressView()
                        .progressViewStyle(.shSpinner(size: AppLayout.Files.tabCloseSize))
                        .accessibilityLabel("The agent is editing \(tab.name)")
                } else {
                    Circle()
                        .fill(Color.sh.lantern)
                        .frame(width: AppLayout.Files.dirtyDotSize, height: AppLayout.Files.dirtyDotSize)
                        .accessibilityLabel("Unsaved changes")
                }
            }
            .frame(width: AppLayout.Files.tabCloseSize, height: AppLayout.Files.tabCloseSize)
        }
        .padding(.horizontal, SH.Space.m)
        .frame(height: AppLayout.Files.tabHeight)
        .background(isActive ? Color.sh.bgBase : Color.clear)
        .overlay(alignment: .top) {
            if isActive {
                Color.sh.lantern.frame(height: AppLayout.Files.activeTabRule)
            }
        }
        .overlay(alignment: .trailing) {
            Color.sh.lineSubtle.frame(width: 1)
        }
        .onHover { hovering = $0 }
    }
}

// MARK: - File viewer content

private struct FileViewerContent: View {
    let model: FileTreeModel
    let path: String
    let showTree: Bool
    let toggleTree: () -> Void
    @Bindable private var settings = AppSettings.shared
    /// The caret's line and column (from 1), for the status bar.
    @State private var cursor = FileCursor(line: 1, column: 1)

    private var isMarkdown: Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
    }

    private var edit: FileEdit? { model.edits[path] }
    /// The open file edits: local, and text.
    private var editable: Bool {
        guard model.canEdit, edit != nil, case .text = model.selectedContent else { return false }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            fileHeader
            if let conflict = edit?.conflict, editable {
                conflictBanner(conflict)
            } else if let error = model.saveError, editable {
                SHBanner(.failed, title: "Couldn\u{2019}t save \((path as NSString).lastPathComponent)", message: error)
                    .padding(SH.Space.m)
            }
            contentArea
            if case .text = model.selectedContent {
                statusBar
            }
        }
    }

    private func conflictBanner(_ disk: String) -> some View {
        SHBanner(.attention, title: "\((path as NSString).lastPathComponent) changed on disk",
                 message: "Your edits aren\u{2019}t saved. Overwrite writes yours over the new version; Revert takes it and drops yours.") {
            Button("Revert") { model.revert() }
                .buttonStyle(SHButtonStyle(.ghost, size: .s))
            Button("Overwrite") { Task { await model.save(overwrite: true) } }
                .buttonStyle(SHButtonStyle(.secondary, size: .s))
                .disabled(model.saving)
        }
        .padding(SH.Space.m)
    }

    private var fileHeader: some View {
        HStack(spacing: SH.Space.m) {
            breadcrumb
            Spacer()
            viewerToolbar
            if editable, let edit {
                Button("Revert") { model.revert() }
                    .buttonStyle(SHButtonStyle(.ghost, size: .s))
                    .disabled(!edit.isDirty)
                    .help("Drop unsaved edits")
                Button { Task { await model.save() } } label: {
                    SHButtonTitle("Save", chord: KeybindingsStore.shared.display(.saveProjectFile))
                }
                .buttonStyle(SHButtonStyle(.secondary, size: .s))
                .disabled(!edit.isDirty || edit.conflict != nil || model.saving)
                .accessibilityLabel("Save")
            }
            // Tree toggle button
            Button(action: toggleTree) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: AppLayout.Files.showTreeIconSize))
                    .foregroundStyle(showTree ? Color.sh.textPrimary : Color.sh.textSecondary)
            }
            .buttonStyle(.plain)
            .frame(width: AppLayout.Files.toggleTreeSize, height: AppLayout.Files.toggleTreeSize)
            .background(showTree ? Color.sh.bgHover : Color.clear, in: RoundedRectangle(cornerRadius: SH.Radius.xs))
            .help(showTree ? "Hide file tree" : "Show file tree")
            .accessibilityLabel(showTree ? "Hide file tree" : "Show file tree")
            .focusable()
            .focusEffectDisabled()
        }
        .frame(height: AppLayout.Files.headerHeight)
        .padding(.horizontal, SH.Space.l)
        .background(Color.sh.bgWindow)
        .overlay(alignment: .bottom) {
            Color.sh.lineSubtle.frame(height: 1)
        }
    }

    @ViewBuilder
    private var viewerToolbar: some View {
        HStack(spacing: SH.Space.xs) {
            // Source wrapping is independent of Markdown's rendered layout.
            if case .text = model.selectedContent, !(isMarkdown && settings.filesMarkdownPreview) {
                Button { settings.filesWordWrap.toggle() } label: {
                    Image(systemName: "arrow.turn.down.left")
                        .font(.system(size: AppLayout.Files.toolbarIconSize))
                        .foregroundStyle(settings.filesWordWrap ? Color.sh.textPrimary : Color.sh.textTertiary)
                }
                .buttonStyle(.plain)
                .frame(width: AppLayout.Files.toolbarButtonSize, height: AppLayout.Files.toolbarButtonSize)
                .background(settings.filesWordWrap ? Color.sh.bgHover : Color.clear,
                            in: RoundedRectangle(cornerRadius: SH.Radius.xs))
                .help(settings.filesWordWrap ? "Disable word wrap" : "Enable word wrap")
                .accessibilityLabel("Word wrap")
                .accessibilityValue(settings.filesWordWrap ? "On" : "Off")
                .accessibilityAddTraits(.isToggle)
                .focusable()
                .shFocusRing(radius: SH.Radius.xs)
            }

            // Markdown preview toggle (only .md / .markdown files)
            if isMarkdown, case .text = model.selectedContent {
                Button { settings.filesMarkdownPreview.toggle() } label: {
                    Image(systemName: "doc.richtext")
                        .font(.system(size: AppLayout.Files.toolbarIconSize))
                        .foregroundStyle(settings.filesMarkdownPreview ? Color.sh.textPrimary : Color.sh.textTertiary)
                }
                .buttonStyle(.plain)
                .frame(width: AppLayout.Files.toolbarButtonSize, height: AppLayout.Files.toolbarButtonSize)
                .background(settings.filesMarkdownPreview ? Color.sh.bgHover : Color.clear,
                            in: RoundedRectangle(cornerRadius: SH.Radius.xs))
                .help(settings.filesMarkdownPreview ? "Show source" : "Preview Markdown")
                .accessibilityLabel("Markdown preview")
                .accessibilityValue(settings.filesMarkdownPreview ? "On" : "Off")
                .accessibilityAddTraits(.isToggle)
                .focusable()
                .shFocusRing(radius: SH.Radius.xs)
            }
        }
    }

    /// "src › components › Checkout.tsx", the folders of the path within the tree's root.
    private var breadcrumb: some View {
        let parts = relativePath(path, root: model.rootPath).split(separator: "/").map(String.init)
        return HStack(spacing: SH.Space.s) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: AppLayout.Files.treeChevronSize, weight: .semibold))
                        .foregroundStyle(Color.sh.textTertiary)
                }
                Text(part)
                    .font(.sh(.code))
                    .foregroundStyle(Color.sh.textTertiary)
                    .layoutPriority(index == parts.count - 1 ? 1 : 0)
            }
        }
        .lineLimit(1)
        .truncationMode(.head)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(relativePath(path, root: model.rootPath))
    }

    /// The marks' legend (an editable file), then the caret, the language and the indentation.
    private var statusBar: some View {
        HStack(spacing: SH.Space.l) {
            if editable {
                legend("yours, unsaved", color: Color.sh.lantern)
                legend("changed by the agent", color: Color.sh.running)
            }
            Spacer()
            Text([cursor.label, fileExtension(path)?.uppercased(), edit?.indentation]
                    .compactMap { $0 }.joined(separator: " \u{00B7} "))
                .lineLimit(1)
        }
        .font(.sh(.micro))
        .foregroundStyle(Color.sh.textTertiary)
        .padding(.horizontal, SH.Space.l)
        .frame(height: AppLayout.Files.statusBarHeight)
        .overlay(alignment: .top) {
            Color.sh.lineSubtle.frame(height: 1)
        }
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: SH.Space.s) {
            color.frame(width: AppLayout.Files.markWidth, height: AppLayout.Files.legendMarkHeight)
            Text(title)
                .font(.sh(.caption))
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var contentArea: some View {
        if let error = model.selectedError {
            VStack(spacing: SH.Space.m) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: AppLayout.Files.errorIconSize, weight: .light))
                    .foregroundStyle(Color.sh.textTertiary)
                Text(error)
                    .font(.sh(.caption))
                    .foregroundStyle(Color.sh.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, SH.Space.xxl)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let content = model.selectedContent {
            switch content {
            case .text(let lines, _):
                if isMarkdown && settings.filesMarkdownPreview {
                    FilesMarkdownPreview(lines: edit.map { $0.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) } ?? lines)
                        .id(path)
                } else {
                    CodeTextView(text: edit?.text ?? lines.joined(separator: "\n"), saved: editable ? edit?.saved : nil, before: edit?.before,
                                 path: path, editable: editable, wordWrap: settings.filesWordWrap,
                                 revision: model.textRevision, refreshGeneration: model.refreshGeneration,
                                 theme: ThemeStore.shared.theme, textScale: ThemeStore.shared.textScale,
                                 onEdit: { [model, path] in model.setText($0, for: path) },
                                 onSave: { [model] in Task { await model.save() } },
                                 onCursor: { cursor = $0 })
                }
            case .image(let data):
                ImagePreview(data: data)
            }
        } else if model.selectedLoading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The caret's line and column, from 1.
struct FileCursor: Equatable {
    var line: Int
    var column: Int
    var label: String { "Ln \(line), Col \(column)" }
}

// MARK: - NSTextView-backed code editor with find bar

/// NSTextView wrapper for code with:
/// - Editing a local text file (read-only for a remote host or an image), undo per document,
///   and Save on the Save chord while it has focus
/// - Real text selection and copy (⌘C)
/// - Native find bar (⌘F)
/// - Line numbers drawn beside the source, without changing its selectable text, and the marks
///   of the lines changed since the last save (lantern) and by the agent (running)
/// - Tree-sitter syntax highlighting via CodeHighlight, again after typing pauses
private struct CodeTextView: NSViewRepresentable {
    let text: String
    /// The version unsaved edits are measured against; nil when the file doesn't edit.
    let saved: String?
    /// The version before the agent's last change on disk, for the agent's marks.
    let before: String?
    let path: String
    let editable: Bool
    let wordWrap: Bool
    /// `FileTreeModel.textRevision`: the text was replaced from outside the editor.
    let revision: UInt
    let refreshGeneration: UInt
    let theme: ThemeDefinition
    let textScale: CGFloat
    let onEdit: (String) -> Void
    let onSave: () -> Void
    let onCursor: (FileCursor) -> Void
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = FilesScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        scroll.contentView.drawsBackground = false
        scroll.clipsToBounds = true
        scroll.contentView.clipsToBounds = true

        // Explicit TextKit 1 storage gives the gutter the same layout as the text.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let text = FilesTextView(frame: scroll.contentView.bounds, textContainer: container)
        text.isEditable = false
        text.isSelectable = true
        text.allowsUndo = true
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        text.smartInsertDeleteEnabled = false
        text.drawsBackground = false
        text.wantsLayer = true
        text.clipsToBounds = true
        text.textContainerInset = NSSize(width: SH.Space.m, height: SH.Space.m)
        text.isHorizontallyResizable = true
        text.isVerticallyResizable = true
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = []
        text.setAccessibilityLabel("File contents")
        text.delegate = context.coordinator
        scroll.documentView = text

        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(text, selector: #selector(FilesTextView.viewportChanged(_:)),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        context.coordinator.textView = text
        return scroll
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let text = coordinator.textView else { return }
        text.onSave = editable ? onSave : nil
        text.isEditable = editable
        let scale = textScale
        let wrap = wordWrap
        let key = ContentKey(path: path, revision: revision, generation: refreshGeneration,
                             theme: theme, scale: scale, dark: colorScheme == .dark, wordWrap: wrap)
        defer { coordinator.mark(text) }
        // Typing never resets the text: only another file, a replacement from outside, or a style change does.
        guard coordinator.currentKey != key else { return }
        let sameDocument = coordinator.currentKey?.path == path
        let replaced = coordinator.currentKey?.path != path || coordinator.currentKey?.revision != revision
        let selection = text.selectedRanges
        let origin = scroll.contentView.bounds.origin
        coordinator.currentKey = key
        coordinator.highlightTask?.cancel()

        SHFonts.register()
        let size = AppLayout.Files.codeFontSize * scale
        let font = NSFont(name: SHFonts.monoFamily, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = AppLayout.Files.lineHeight * scale
        style.maximumLineHeight = AppLayout.Files.lineHeight * scale
        style.tabStops = []
        style.defaultTabInterval = ("0" as NSString).size(withAttributes: [.font: font]).width * AppLayout.Files.tabColumns
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(Color.sh.textPrimary), .paragraphStyle: style]
        text.defaultParagraphStyle = style
        text.typingAttributes = attributes
        text.configureGutter(text: self.text, font: font)
        scroll.hasHorizontalScroller = !wrap
        // Configure wrapping: when on, the text container tracks the scroll view's width
        // and the text view is not horizontally resizable. When off, the container is unbounded.
        if let container = text.textContainer {
            container.widthTracksTextView = wrap
            if wrap {
                container.size = NSSize(width: max(0, scroll.contentSize.width - text.textContainerInset.width * 2),
                                        height: CGFloat.greatestFiniteMagnitude)
            } else {
                container.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            }
        }
        text.isHorizontallyResizable = !wrap
        text.textStorage?.setAttributedString(NSAttributedString(string: self.text, attributes: attributes))
        if replaced { text.undoManager?.removeAllActions() }
        text.sizeToFit()
        if wrap {
            // In wrap mode, width is constrained to the scroll view; only height grows.
            text.setFrameSize(NSSize(width: scroll.contentSize.width,
                                     height: max(scroll.contentSize.height, text.frame.height)))
        } else {
            text.setFrameSize(NSSize(width: max(scroll.contentSize.width, text.frame.width),
                                     height: max(scroll.contentSize.height, text.frame.height)))
        }
        if sameDocument {
            let valid = selection.filter { NSMaxRange($0.rangeValue) <= text.string.utf16.count }
            text.selectedRanges = valid.isEmpty ? [NSValue(range: NSRange(location: 0, length: 0))] : valid
            scroll.contentView.scroll(to: NSPoint(x: wrap ? 0 : origin.x, y: origin.y))
        } else {
            // scrollRangeToVisible(0) aligns the first glyph with the viewport's edge,
            // discarding the inset reserved for line numbers.
            scroll.contentView.scroll(to: .zero)
        }
        scroll.reflectScrolledClipView(scroll.contentView)
        coordinator.highlight(text, after: nil)
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        coordinator.highlightTask?.cancel()
        coordinator.marking?.cancel()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    struct ContentKey: Equatable {
        let path: String
        let revision: UInt
        let generation: UInt
        let theme: ThemeDefinition
        let scale: CGFloat
        let dark: Bool
        let wordWrap: Bool
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeTextView
        weak var textView: FilesTextView?
        var currentKey: ContentKey?
        var highlightTask: Task<Void, Never>?
        var marking: Task<Void, Never>?
        /// The text and versions the marks were last asked for.
        private var marked: (text: String, saved: String?, before: String?)?

        init(parent: CodeTextView) { self.parent = parent }
        deinit { highlightTask?.cancel(); marking?.cancel() }

        func textDidChange(_ notification: Notification) {
            guard let text = textView else { return }
            let string = text.string
            text.configureGutter(text: string, font: nil)
            parent.onEdit(string)
            mark(text)
            highlight(text, after: AppLayout.Files.rehighlightDelay)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let text = textView else { return }
            parent.onCursor(text.cursor())
        }

        /// The marks for the editor's text, diffed off the main thread: one diff at a time, the
        /// newest text next. A result for text the editor no longer holds never lands.
        func mark(_ text: FilesTextView) {
            let string = text.string, saved = parent.saved, before = parent.before
            if let marked, marked.text == string, marked.saved == saved, marked.before == before { return }
            marked = (string, saved, before)
            guard let saved, string != saved || before != nil else {
                marking?.cancel()
                marking = nil
                text.setMarks(unsaved: [], agent: [])
                return
            }
            guard marking == nil else { return }
            marking = Task { [weak self, weak text] in
                let (unsaved, agent) = await Task.detached(priority: .userInitiated) {
                    let unsaved = string == saved ? [] : InstructionsText.changedLines(saved: saved, draft: string)
                    let agent = before.map { InstructionsText.changedLines(saved: $0, draft: string).subtracting(unsaved) } ?? []
                    return (unsaved, agent)
                }.value
                guard let self, !Task.isCancelled else { return }
                self.marking = nil
                guard let text else { return }
                if text.string == string, self.parent.saved == saved, self.parent.before == before {
                    text.setMarks(unsaved: unsaved, agent: agent)
                } else {
                    // Superseded while it ran: mark the newest text.
                    self.marked = nil
                    self.mark(text)
                }
            }
        }

        /// Tree-sitter colors for the editor's text, `after` a pause in typing (nil: now).
        func highlight(_ text: FilesTextView, after delay: Duration?) {
            highlightTask?.cancel()
            let path = parent.path
            guard CodeHighlight.supports(path: path) else { return }
            let string = text.string
            let syntaxStyle = CodeHighlight.Style.theme
            highlightTask = Task { @MainActor [weak text] in
                if let delay {
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled else { return }
                }
                let lines = string.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                let work = Task.detached(priority: .userInitiated) {
                    CodeHighlight.highlightLines(lines, path: path, style: syntaxStyle) { Task.isCancelled }
                }
                let highlighted = await withTaskCancellationHandler {
                    await work.value
                } onCancel: {
                    work.cancel()
                }
                guard !Task.isCancelled, let text, text.string == string, let storage = text.textStorage else { return }
                storage.beginEditing()
                if delay != nil {
                    storage.addAttribute(.foregroundColor, value: NSColor(Color.sh.textPrimary),
                                         range: NSRange(location: 0, length: storage.length))
                }
                var offset = 0
                for line in highlighted {
                    // Tree-sitter produces SwiftUI Color attributes. Convert each run explicitly:
                    // Foundation's default AttributedString bridge can discard SwiftUI attributes.
                    for run in line.runs {
                        let count = String(line[run.range].characters).utf16.count
                        if let color = run.foregroundColor, offset + count <= storage.length {
                            storage.addAttribute(.foregroundColor, value: NSColor(color),
                                                 range: NSRange(location: offset, length: count))
                        }
                        offset += count
                    }
                    offset += 1
                }
                storage.endEditing()
            }
        }
    }
}

/// Native scroll-view layout can run after updateNSView; keep short files filling the viewport.
/// In wrap mode, a resize re-lays out the text to the new width.
private final class FilesScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let text = documentView as? FilesTextView else { return }
        let wrapping = text.textContainer?.widthTracksTextView == true
        if wrapping {
            // Re-constrain the container to the new scroll width so text reflows.
            let inset = text.textContainerInset.width
            let available = max(0, contentSize.width - inset * 2)
            if let container = text.textContainer, abs(container.size.width - available) > 1 {
                container.size.width = available
                text.layoutManager?.ensureLayout(for: container)
            }
            if let container = text.textContainer, let layout = text.layoutManager {
                layout.ensureLayout(for: container)
                let bottom = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
                let size = NSSize(width: contentSize.width,
                                  height: max(contentSize.height, ceil(bottom + text.textContainerInset.height * 2)))
                if text.frame.size != size { text.setFrameSize(size) }
            }
        } else {
            let size = NSSize(width: max(text.frame.width, contentSize.width),
                              height: max(text.frame.height, contentSize.height))
            if text.frame.size != size { text.setFrameSize(size) }
        }
    }
}

/// Native find stays in the viewer's responder chain, without a window-wide key monitor.
/// Draws the gutter: line numbers, and a bar beside each line changed since the last save
/// (lantern, with its tint across the line) or by the agent (running).
private final class FilesTextView: NSTextView {
    private var lineStarts = [0]
    private var gutterWidth: CGFloat = 0
    private var gutterFont: NSFont?
    private var unsavedLines: Set<Int> = []
    private var agentLines: Set<Int> = []
    /// Save, while the file edits.
    var onSave: (() -> Void)?
    // A window's shared undo stack outlives an editor whose file changes under it.
    private let documentUndoManager = UndoManager()
    override var undoManager: UndoManager? { documentUndoManager }

    /// Line starts of `text`, and the gutter's width for its line count (`font` nil: the last one).
    func configureGutter(text: String, font: NSFont?) {
        if let font { gutterFont = font }
        guard let font = gutterFont else { return }
        var starts = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 10 { starts.append(offset) }
        }
        let width = CGFloat(max(2, String(starts.count).count)) * ("0" as NSString).size(withAttributes: [.font: font]).width + SH.Space.m * 2
        lineStarts = starts
        if width != gutterWidth || textContainerInset.width != width + SH.Space.m {
            gutterWidth = width
            textContainerInset = NSSize(width: gutterWidth + SH.Space.m, height: SH.Space.m)
        }
        needsDisplay = true
    }

    func setMarks(unsaved: Set<Int>, agent: Set<Int>) {
        guard unsaved != unsavedLines || agent != agentLines else { return }
        unsavedLines = unsaved
        agentLines = agent
        needsDisplay = true
    }

    /// The caret's line and column, from 1.
    func cursor() -> FileCursor {
        let location = selectedRange().location
        let line = lineIndex(at: location)
        return FileCursor(line: line + 1, column: location - lineStarts[line] + 1)
    }

    /// The line (from 0) holding the UTF-16 offset `location`.
    private func lineIndex(at location: Int) -> Int {
        var low = 0, high = lineStarts.count
        while low < high {
            let mid = (low + high) / 2
            if lineStarts[mid] <= location { low = mid + 1 } else { high = mid }
        }
        return max(0, low - 1)
    }

    @objc func viewportChanged(_ notification: Notification) { needsDisplay = true }

    /// Each visible line's index and rect (in view coordinates), first row only.
    private func visibleLines() -> [(index: Int, rect: NSRect)] {
        guard let layout = layoutManager, let container = textContainer else { return [] }
        let origin = textContainerOrigin
        let visible = visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var index = lineIndex(at: characters.location)
        var result: [(Int, NSRect)] = []
        let length = textStorage?.length ?? 0
        while index < lineStarts.count, lineStarts[index] <= NSMaxRange(characters) {
            let position = lineStarts[index]
            var rect = position < length
                ? layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: position), effectiveRange: nil)
                : layout.extraLineFragmentRect
            // A wrapped line's mark spans all its rows.
            if position < length, index + 1 < lineStarts.count, lineStarts[index + 1] - 1 > position {
                let last = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: lineStarts[index + 1] - 1), effectiveRange: nil)
                rect = rect.union(last)
            }
            result.append((index, rect.offsetBy(dx: origin.x, dy: origin.y)))
            index += 1
        }
        return result
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard !unsavedLines.isEmpty else { return }
        NSColor(Color.sh.lanternTint).setFill()
        for line in visibleLines() where unsavedLines.contains(line.index) {
            NSRect(x: visibleRect.minX, y: line.rect.minY, width: visibleRect.width, height: line.rect.height).fill()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let visible = visibleRect
        let gutter = NSRect(x: visible.minX, y: visible.minY, width: gutterWidth, height: visible.height)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: gutter.maxX, y: visible.minY,
                                 width: max(0, visible.width - gutterWidth), height: visible.height)).addClip()
        super.draw(dirtyRect)
        NSGraphicsContext.restoreGraphicsState()
        guard let font = gutterFont else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: gutter.intersection(dirtyRect)).addClip()
        if !unsavedLines.isEmpty {
            NSColor(Color.sh.lanternTint).setFill()
            for line in visibleLines() where unsavedLines.contains(line.index) {
                NSRect(x: gutter.minX, y: line.rect.minY, width: gutter.width, height: line.rect.height).fill()
            }
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(Color.sh.textTertiary)]
        for line in visibleLines() {
            let number = "\(line.index + 1)" as NSString
            let size = number.size(withAttributes: attributes)
            number.draw(at: NSPoint(x: gutter.maxX - size.width - SH.Space.s, y: line.rect.minY), withAttributes: attributes)
            let mark: Color? = unsavedLines.contains(line.index) ? Color.sh.lantern
                : agentLines.contains(line.index) ? Color.sh.running : nil
            if let mark {
                NSColor(mark).setFill()
                NSRect(x: gutter.maxX - AppLayout.Files.markWidth, y: line.rect.minY,
                       width: AppLayout.Files.markWidth, height: line.rect.height).fill()
            }
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "f" {
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.showFindInterface.rawValue
            performFindPanelAction(item)
            return true
        }
        if let onSave, window?.firstResponder === self, KeybindingsStore.shared.chord(for: .saveProjectFile).matches(event) {
            onSave()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Markdown rendered preview

/// Renders Markdown source lines as formatted prose using the thread's own `Prose` view.
/// Parsing runs off the main actor to avoid blocking the UI with large files.
private struct FilesMarkdownPreview: View {
    let lines: [String]
    @State private var prose: NativeProse?

    var body: some View {
        Group {
            if let prose {
                ScrollView {
                    Prose(prose: prose, maxWidth: .infinity)
                        .padding(SH.Space.l)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.sh.bgWindow)
        // Explicit nil file root: no local image resolution from prose,
        // preventing path-traversal outside the space root.
        .environment(\.shProseFileRoot, nil)
        .task(id: lines) {
            let source = lines
            let work = Task.detached(priority: .userInitiated) {
                NativeProse(nativeMarkdownBlocks(source.joined(separator: "\n")))
            }
            let parsed = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard !Task.isCancelled else { return }
            prose = parsed
        }
    }
}

// MARK: - Image preview with ImageIO thumbnailing

private struct ImagePreview: View {
    let data: Data
    @State private var image: NSImage?
    @State private var loaded = false

    var body: some View {
        Group {
            if let image {
                GeometryReader { geometry in
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .accessibilityLabel("Image preview")
                }
            } else if loaded {
                Text("Cannot decode image")
                    .font(.sh(.caption))
                    .foregroundStyle(Color.sh.textTertiary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(SH.Space.l)
        .background(Color.sh.bgSunken)
        .task(id: data) {
            loaded = false
            image = nil
            let limit = AppLayout.Files.imageMaxDimension
            let thumbnail = await Task.detached(priority: .userInitiated) {
                thumbnailImage(data: data, maxDimension: limit)
            }.value
            guard !Task.isCancelled else { return }
            image = thumbnail.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            loaded = true
        }
    }
}

/// Decode to a bounded raster off-main, never to the source's full pixel dimensions.
private nonisolated func thumbnailImage(data: Data, maxDimension: CGFloat) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData,
        [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true
    ] as CFDictionary)
}

// MARK: - File tree content

/// The file tree panel: space name, filter field, show-hidden toggle, and the lazy tree.
private struct FileTreeContent: View {
    let model: FileTreeModel
    @Binding var showHidden: Bool
    /// The file the agent is editing now: its row shows a spinner.
    let agentPath: String?
    let hideTree: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            treeHeader
            filterField
            treeBody
            treeFooter
        }
        .background(Color.sh.bgWindow)
    }

    private var treeHeader: some View {
        HStack(spacing: SH.Space.s) {
            Text(model.root.name)
                .font(.shSans(AppLayout.Files.spaceNameFontSize, .semibold))
                .foregroundStyle(Color.sh.textPrimary)
                .lineLimit(1)
            Spacer()
            Text(abbreviatedPath(model.rootPath))
                .font(.sh(.micro))
                .foregroundStyle(Color.sh.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: AppLayout.Files.pathMaxWidth, alignment: .trailing)
            if model.selectedPath == nil {
                Button(action: hideTree) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: AppLayout.Files.showTreeIconSize))
                        .frame(width: AppLayout.Files.toggleTreeSize, height: AppLayout.Files.toggleTreeSize)
                }
                .buttonStyle(.plain)
                .help("Collapse file tree")
                .accessibilityLabel("Collapse file tree")
            }
        }
        .frame(height: AppLayout.Files.spaceHeaderHeight)
        .padding(.horizontal, SH.Space.m)
        .padding(.leading, SH.Space.xs)
    }

    private var filterField: some View {
        HStack(spacing: SH.Space.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: AppLayout.Files.filterIconSize))
                .foregroundStyle(Color.sh.textTertiary)
            TextField("Filter files", text: Bindable(model).filter)
                .help("Filters files in expanded folders")
                .textFieldStyle(.plain)
                .font(.shSans(AppLayout.Files.filterFontSize))
                .foregroundStyle(Color.sh.textPrimary)
        }
        .frame(height: AppLayout.Files.filterHeight)
        .padding(.horizontal, SH.Space.m)
        .background(Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: SH.Radius.m)
                .stroke(Color.sh.lineSubtle, lineWidth: 1)
        )
        .padding(.horizontal, SH.Space.m)
        .padding(.bottom, SH.Space.xs)
    }

    private var treeBody: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                let visible = model.visibleNodes()
                if model.root.error != nil {
                    HStack(spacing: SH.Space.s) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: AppLayout.Files.filterIconSize))
                            .foregroundStyle(Color.sh.textTertiary)
                        Text(model.root.error ?? "Failed to load")
                            .font(.sh(.caption))
                            .foregroundStyle(Color.sh.textSecondary)
                    }
                    .padding(SH.Space.m)
                } else if visible.isEmpty && !model.filter.isEmpty {
                    Text("No files match \u{201C}\(model.filter)\u{201D}")
                        .font(.sh(.caption))
                        .foregroundStyle(Color.sh.textTertiary)
                        .padding(SH.Space.m)
                } else if visible.isEmpty && model.root.isExpanded {
                    Text("Empty directory")
                        .font(.sh(.caption))
                        .foregroundStyle(Color.sh.textTertiary)
                        .padding(SH.Space.m)
                } else {
                    ForEach(visible, id: \.node.id) { item in
                        FileTreeRow(
                            node: item.node,
                            depth: item.depth,
                            isSelected: model.selectedPath == item.node.id,
                            agentWorking: agentPath == item.node.id,
                            action: {
                                if item.node.isDirectory {
                                    Task { await model.toggle(path: item.node.id) }
                                } else {
                                    Task { await model.select(path: item.node.id) }
                                }
                            }
                        )
                        .equatable()
                    }
                }
            }
            .padding(.horizontal, SH.Space.m)
            .padding(.bottom, SH.Space.m)
        }
    }

    private var treeFooter: some View {
        HStack(spacing: SH.Space.s) {
            Text(footerText)
                .font(.sh(.caption))
                .foregroundStyle(Color.sh.textTertiary)
                .lineLimit(1)
            Spacer()
            Button {
                showHidden.toggle()
            } label: {
                Image(systemName: showHidden ? "eye" : "eye.slash")
                    .font(.system(size: AppLayout.Files.refreshIconSize))
                    .foregroundStyle(showHidden ? Color.sh.textPrimary : Color.sh.textTertiary)
            }
            .buttonStyle(.plain)
            .help(showHidden ? "Hide hidden files" : "Show hidden files")
            .accessibilityLabel(showHidden ? "Hide hidden files" : "Show hidden files")
            .onChange(of: showHidden) {
                Task { await model.refresh() }
            }
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: AppLayout.Files.refreshIconSize))
                    .foregroundStyle(Color.sh.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Refresh")
            .accessibilityLabel("Refresh file tree")
        }
        .frame(height: AppLayout.Files.footerHeight)
        .padding(.horizontal, SH.Space.xl)
        .overlay(alignment: .top) {
            Color.sh.lineSubtle.frame(height: 1)
        }
    }

    private var footerText: String {
        let nodes = model.visibleNodes()
        let files = nodes.filter { !$0.node.isDirectory }.count
        let dirs = nodes.filter { $0.node.isDirectory }.count
        if model.root.isLoading { return "Loading\u{2026}" }
        return "\(files) file\(files == 1 ? "" : "s"), \(dirs) folder\(dirs == 1 ? "" : "s")"
    }
}

// MARK: - Tree row

private struct FileTreeRow: View, Equatable {
    let node: FileNode
    let depth: Int
    let isSelected: Bool
    let agentWorking: Bool
    let action: () -> Void

    /// A selection change redraws the two rows it touches, not every realized row.
    static func == (a: FileTreeRow, b: FileTreeRow) -> Bool {
        a.node == b.node && a.depth == b.depth && a.isSelected == b.isSelected && a.agentWorking == b.agentWorking
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: SH.Space.s) {
                if depth > 0 {
                    Spacer()
                        .frame(width: CGFloat(depth) * AppLayout.Files.treeIndent)
                }

                if node.isDirectory {
                    Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: AppLayout.Files.treeChevronSize, weight: .semibold))
                        .foregroundStyle(Color.sh.textTertiary)
                        .frame(width: AppLayout.Files.treeIconSize, height: AppLayout.Files.treeIconSize)
                } else {
                    Image(systemName: fileIcon(for: node.name))
                        .font(.system(size: AppLayout.Files.treeFileIconSize))
                        .foregroundStyle(Color.sh.textTertiary)
                        .frame(width: AppLayout.Files.treeIconSize, height: AppLayout.Files.treeIconSize)
                }

                Text(node.name)
                    .font(.shSans(AppLayout.Files.treeRowFontSize))
                    .foregroundStyle(isSelected ? Color.sh.textPrimary : Color.sh.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                if node.isSymlink {
                    Image(systemName: "link")
                        .font(.system(size: AppLayout.Files.symlinkIconSize))
                        .foregroundStyle(Color.sh.textTertiary)
                }

                if node.error != nil {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Color.sh.textSecondary)
                }
                if node.isLoading {
                    ProgressView()
                        .controlSize(.mini)
                }
                if agentWorking {
                    ProgressView()
                        .progressViewStyle(.shSpinner(size: AppLayout.Files.tabCloseSize))
                }
            }
            .frame(height: AppLayout.Files.treeRowHeight)
            .padding(.horizontal, SH.Space.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: SH.Radius.s)
                .fill(isSelected ? Color.sh.bgSelected : Color.clear)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(node.name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityValue(node.error ?? (node.isDirectory ? (node.isExpanded ? "expanded" : "collapsed") : agentWorking ? "the agent is editing it" : ""))
        .help(node.error ?? node.id)
    }
}

// MARK: - Unavailable remote files

/// A remote thread whose host has no `files.v1` (an older Shepherd), or one this Mac isn't connected to.
struct FilesUnavailableView: View {
    let host: String?

    var body: some View {
        VStack(spacing: SH.Space.m) {
            Image(systemName: SHGlyph.document.symbolName)
                .font(.system(size: AppLayout.Files.emptyIconSize, weight: .light))
                .foregroundStyle(Color.sh.textTertiary)
            Text("Files unavailable")
                .font(.sh(.headline))
                .foregroundStyle(Color.sh.textPrimary)
            Text("Files needs a newer Shepherd on \(host ?? "this thread's host").")
                .font(.sh(.caption))
                .foregroundStyle(Color.sh.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: AppLayout.Files.messageMaxWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.sh.bgWindow)
    }
}

// MARK: - Helpers

private func relativePath(_ path: String, root: String) -> String {
    let normalizedRoot = root.hasSuffix("/") ? root : root + "/"
    if path.hasPrefix(normalizedRoot) {
        return String(path.dropFirst(normalizedRoot.count))
    }
    return (path as NSString).lastPathComponent
}

private func abbreviatedPath(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path.hasPrefix(home) {
        return "~" + path.dropFirst(home.count)
    }
    return path
}

private func fileExtension(_ path: String) -> String? {
    let ext = (path as NSString).pathExtension
    return ext.isEmpty ? nil : ext
}

private func fileIcon(for name: String) -> String {
    let ext = (name as NSString).pathExtension.lowercased()
    if FileTreeModel.imageExtensions.contains(ext) { return "photo" }
    if CodeHighlight.supports(path: name) { return SHGlyph.document.symbolName }
    return "doc"
}

private func findNodeInTree(path: String, root: FileNode) -> FileNode? {
    if root.id == path { return root }
    guard let children = root.children else { return nil }
    for child in children {
        if let found = findNodeInTree(path: path, root: child) { return found }
    }
    return nil
}
