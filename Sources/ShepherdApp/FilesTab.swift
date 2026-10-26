import SwiftUI
import AppKit
import ShepherdUI
import ShepherdCore
import ShepherdRemote
import ImageIO

// MARK: - Files tab (side pane)

/// The side pane's Files tab (FileOpenSplit board): the space's file tree on the right,
/// a code/image viewer on the left. Read-only browser of the local workspace.
/// Remote threads show an unavailable message — the transport for arbitrary file reads
/// is not wired (gap: remote file browsing).
struct FilesTab: View {
    let model: FileTreeModel
    @State private var showTree = true
    @State private var treeWidth: CGFloat = AppLayout.Files.treeWidth
    @State private var liveTreeWidth: CGFloat?
    private let coordSpace = "files-panel-resize"

    init(model: FileTreeModel, treeVisible: Bool = true) {
        self.model = model
        _showTree = State(initialValue: treeVisible)
    }

    var body: some View {
        GeometryReader { geo in
            let maxTree = max(AppLayout.Files.treeMinWidth, geo.size.width - AppLayout.Files.viewerMinWidth - AppLayout.dividerWidth)
            let clampedTree = min(liveTreeWidth ?? treeWidth, maxTree)

            HStack(spacing: 0) {
                // Viewer (left)
                fileViewer
                    .frame(width: showTree ? max(0, geo.size.width - clampedTree - AppLayout.dividerWidth) : geo.size.width,
                           height: geo.size.height, alignment: .topLeading)
                    .clipped()

                if showTree {
                    treeResizeHandle(panelWidth: geo.size.width, maxTree: maxTree)
                    FileTreeContent(model: model, showHidden: Bindable(model).showHidden, hideTree: { showTree = false })
                        .frame(width: clampedTree)
                }
            }
            .coordinateSpace(name: coordSpace)
        }
        .background(Color.sh.bgWindow)
        .overlay(alignment: .topTrailing) {
            if !showTree && model.selectedPath == nil {
                Button { showTree = true } label: {
                    Image(systemName: "sidebar.right")
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
    }

    private func treeResizeHandle(panelWidth: CGFloat, maxTree: CGFloat) -> some View {
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
                                let proposed = panelWidth - value.location.x
                                liveTreeWidth = max(AppLayout.Files.treeMinWidth, min(proposed, maxTree))
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
                        select: { Task { await model.select(path: tab.id) } },
                        close: { Task { await model.closeTab(tab.id) } }
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

private struct FileTabView: View {
    let tab: OpenFileTab
    let isActive: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: SH.Space.s) {
            Button(action: select) {
                Text(tab.name)
                    .font(.sh(.code))
                    .foregroundStyle(isActive ? Color.sh.textPrimary : Color.sh.textSecondary)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: AppLayout.Files.tabCloseFontSize, weight: .semibold))
                    .foregroundStyle(Color.sh.textTertiary)
                    .frame(width: AppLayout.Files.tabCloseSize, height: AppLayout.Files.tabCloseSize)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(tab.name)")
        }
        .padding(.horizontal, SH.Space.m)
        .frame(height: AppLayout.Files.tabHeight)
        .background(isActive ? Color.sh.bgBase : Color.clear)
        .overlay(alignment: .bottom) {
            if isActive {
                Color.sh.running.frame(height: 2)
            }
        }
        .overlay(alignment: .trailing) {
            Color.sh.lineSubtle.frame(width: 1)
        }
    }
}

// MARK: - File viewer content

private struct FileViewerContent: View {
    let model: FileTreeModel
    let path: String
    let showTree: Bool
    let toggleTree: () -> Void
    @Bindable private var settings = AppSettings.shared

    private var isMarkdown: Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
    }

    var body: some View {
        VStack(spacing: 0) {
            fileHeader
            metadataBar
            contentArea
        }
    }

    private var fileHeader: some View {
        HStack(spacing: SH.Space.m) {
            filePathLabel
            Spacer()
            viewerToolbar
            // Tree toggle button
            Button(action: toggleTree) {
                Image(systemName: "sidebar.right")
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

    @ViewBuilder
    private var filePathLabel: some View {
        let relative = relativePath(path, root: model.rootPath)
        let dir = (relative as NSString).deletingLastPathComponent
        let name = (relative as NSString).lastPathComponent
        HStack(spacing: 0) {
            if !dir.isEmpty && dir != "." {
                Text(dir + "/")
                    .font(.sh(.code))
                    .foregroundStyle(Color.sh.textSecondary)
            }
            Text(name)
                .font(.sh(.code))
                .fontWeight(.medium)
                .foregroundStyle(Color.sh.textPrimary)
                .layoutPriority(1)
        }
        .lineLimit(1)
        .truncationMode(.head)
    }

    @ViewBuilder
    private var metadataBar: some View {
        HStack(spacing: SH.Space.m) {
                if case .text(let lines, _) = model.selectedContent {
                    Text("\(lines.count) lines")
                }
                if let ext = fileExtension(path), !ext.isEmpty {
                    Text(ext.uppercased())
                }
                if let size = findNodeInTree(path: path, root: model.root)?.fileSize {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                }
            }
            .font(.sh(.caption))
            .foregroundStyle(Color.sh.textTertiary)
            .frame(height: AppLayout.Files.metadataHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SH.Space.l)
            .overlay(alignment: .bottom) {
                Color.sh.lineSubtle.frame(height: 1)
            }
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
                    FilesMarkdownPreview(lines: lines)
                        .id(path)
                } else {
                    CodeTextView(lines: lines, path: path, wordWrap: settings.filesWordWrap,
                                 refreshGeneration: model.refreshGeneration,
                                 theme: ThemeStore.shared.theme, textScale: ThemeStore.shared.textScale)
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

// MARK: - NSTextView-backed code view with find bar

/// NSTextView wrapper for read-only code display with:
/// - Real text selection and copy (⌘C)
/// - Native find bar (⌘F)
/// - Line numbers drawn beside the source, without changing its selectable text
/// - Tree-sitter syntax highlighting via CodeHighlight
private struct CodeTextView: NSViewRepresentable {
    let lines: [String]
    let path: String
    let wordWrap: Bool
    let refreshGeneration: UInt
    let theme: ThemeDefinition
    let textScale: CGFloat
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
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.drawsBackground = false
        text.wantsLayer = true
        text.clipsToBounds = true
        text.textContainerInset = NSSize(width: SH.Space.m, height: SH.Space.m)
        text.isHorizontallyResizable = true
        text.isVerticallyResizable = true
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = []
        text.setAccessibilityLabel("File contents")
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
        let scale = textScale
        let wrap = wordWrap
        let key = ContentKey(path: path, generation: refreshGeneration, lines: lines,
                             theme: theme, scale: scale, dark: colorScheme == .dark, wordWrap: wrap)
        guard coordinator.currentKey != key, let text = coordinator.textView else { return }
        let sameDocument = coordinator.currentKey?.path == path
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
        text.defaultParagraphStyle = style
        text.configureGutter(lines: lines, font: font)
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
        text.textStorage?.setAttributedString(NSAttributedString(
            string: lines.joined(separator: "\n"),
            attributes: [.font: font, .foregroundColor: NSColor(Color.sh.textPrimary), .paragraphStyle: style]
        ))
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

        guard CodeHighlight.supports(path: path) else { return }
        let syntaxStyle = CodeHighlight.Style.theme
        coordinator.highlightTask = Task { @MainActor [weak coordinator, weak text] in
            let work = Task.detached(priority: .userInitiated) {
                CodeHighlight.highlightLines(lines, path: path, style: syntaxStyle) { Task.isCancelled }
            }
            let highlighted = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard !Task.isCancelled, coordinator?.currentKey == key,
                  let storage = text?.textStorage else { return }
            storage.beginEditing()
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

    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        coordinator.highlightTask?.cancel()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    struct ContentKey: Equatable {
        let path: String
        let generation: UInt
        let lines: [String]
        let theme: ThemeDefinition
        let scale: CGFloat
        let dark: Bool
        let wordWrap: Bool
    }

    final class Coordinator {
        weak var textView: FilesTextView?
        var currentKey: ContentKey?
        var highlightTask: Task<Void, Never>?
        deinit { highlightTask?.cancel() }
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
private final class FilesTextView: NSTextView {
    private var lineStarts = [0]
    private var gutterWidth: CGFloat = 0
    private var gutterFont: NSFont?

    func configureGutter(lines: [String], font: NSFont) {
        gutterFont = font
        var offset = 0
        lineStarts = lines.map { line in
            defer { offset += line.utf16.count + 1 }
            return offset
        }
        let digits = max(2, String(lines.count).count)
        gutterWidth = CGFloat(digits) * ("0" as NSString).size(withAttributes: [.font: font]).width + SH.Space.m * 2
        textContainerInset = NSSize(width: gutterWidth + SH.Space.m, height: SH.Space.m)
        needsDisplay = true
    }

    @objc func viewportChanged(_ notification: Notification) { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let visible = visibleRect
        let gutter = NSRect(x: visible.minX, y: visible.minY, width: gutterWidth, height: visible.height)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: gutter.maxX, y: visible.minY,
                                 width: max(0, visible.width - gutterWidth), height: visible.height)).addClip()
        super.draw(dirtyRect)
        NSGraphicsContext.restoreGraphicsState()
        guard let layout = layoutManager, let container = textContainer, let font = gutterFont else { return }
        let origin = textContainerOrigin
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: gutter.intersection(dirtyRect)).addClip()
        let glyphs = layout.glyphRange(forBoundingRect: visible.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var low = 0, high = lineStarts.count
        while low < high {
            let mid = (low + high) / 2
            if lineStarts[mid] <= characters.location { low = mid + 1 } else { high = mid }
        }
        var index = max(0, low - 1)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(Color.sh.textTertiary)]
        while index < lineStarts.count, lineStarts[index] <= NSMaxRange(characters) {
            let position = lineStarts[index]
            let lineRect: NSRect
            if position < (textStorage?.length ?? 0) {
                lineRect = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: position), effectiveRange: nil)
            } else {
                lineRect = layout.extraLineFragmentRect
            }
            let number = "\(index + 1)" as NSString
            let size = number.size(withAttributes: attributes)
            number.draw(at: NSPoint(x: gutter.maxX - size.width - SH.Space.s,
                                   y: lineRect.minY + origin.y), withAttributes: attributes)
            index += 1
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
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Markdown rendered preview

/// Renders Markdown source lines as formatted prose using the thread's own `Prose` view.
/// Parsing runs off the main actor to avoid blocking the UI with large files.
private struct FilesMarkdownPreview: View {
    let lines: [String]
    @State private var blocks: [NativeMarkdownBlock]?

    var body: some View {
        Group {
            if let blocks {
                ScrollView {
                    Prose(blocks: blocks, maxWidth: .infinity)
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
                nativeMarkdownBlocks(source.joined(separator: "\n"))
            }
            let parsed = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard !Task.isCancelled else { return }
            blocks = parsed
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
                    Image(systemName: "sidebar.right")
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
                            action: {
                                if item.node.isDirectory {
                                    Task { await model.toggle(path: item.node.id) }
                                } else {
                                    Task { await model.select(path: item.node.id) }
                                }
                            }
                        )
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

private struct FileTreeRow: View {
    let node: FileNode
    let depth: Int
    let isSelected: Bool
    let action: () -> Void

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
        .accessibilityValue(node.error ?? (node.isDirectory ? (node.isExpanded ? "expanded" : "collapsed") : ""))
        .help(node.error ?? node.id)
    }
}

// MARK: - Unavailable remote files

struct FilesUnavailableView: View {
    var body: some View {
        VStack(spacing: SH.Space.m) {
            Image(systemName: SHGlyph.document.symbolName)
                .font(.system(size: AppLayout.Files.emptyIconSize, weight: .light))
                .foregroundStyle(Color.sh.textTertiary)
            Text("Files unavailable")
                .font(.sh(.headline))
                .foregroundStyle(Color.sh.textPrimary)
            Text("File browsing is available for local threads only. Remote file transport is not yet supported.")
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
