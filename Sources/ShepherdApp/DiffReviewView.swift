import SwiftUI
import AppKit
import ShepherdDesign
import ShepherdCore
import ShepherdRemote

/// What the review pane can ask of its host (local agents and remote agents differ).
struct ReviewActions {
    var setPullRequest: (Bool) -> Void
    /// Send the overall and inline comments as the agent's next turn (queued if it is mid-turn).
    var requestChanges: () -> Void
    /// Ask the agent to commit what is under review.
    var commit: () -> Void
    var close: () -> Void
    /// Local reviews only: discard a file's changes (confirmed first), open it in an editor.
    var revert: ((DiffFile) -> Void)? = nil
    var open: ((DiffFile) -> Void)? = nil
    /// Return keyboard focus to the thread's composer (esc).
    var focusThread: () -> Void = {}
}

/// The review pane (spec §9): a companion docked right of the thread. Header with scope and
/// totals, a strip of file chips, sticky file headers over a colored unified diff with long
/// runs collapsed, inline comments, and a review composer.
struct ReviewPane: View {
    @Bindable var session: ReviewSession
    let actions: ReviewActions
    /// Files the running agent is editing right now: their chips pulse.
    var touchedPaths: Set<String> = []
    @State private var highlighted: [String: [AttributedString]] = [:]
    @State private var expandedRuns: Set<String> = []
    @State private var expandedFiles: Set<String> = []
    @State private var collapsed: Set<String> = []
    @State private var editing: ReviewSession.CommentKey?
    @State private var draft = ""
    @State private var reverting: DiffFile?
    @State private var currentFile: String?
    @State private var currentHunk: String?
    @FocusState private var paneFocused: Bool
    @FocusState private var summaryFocused: Bool
    @FocusState private var commentFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            if !session.files.isEmpty { fileStrip }
            content
            composer
        }
        .background(Tokens.bgSurface)
        .focusable()
        .focused($paneFocused)
        .focusEffectDisabled()
        .onKeyPress(characters: .init(charactersIn: "jknpvc")) { press in handleKey(press.characters) }
        .onKeyPress(.escape) { actions.focusThread(); return .handled }
        .confirmationDialog("Discard the changes to \(reverting?.displayPath ?? "this file")?",
                            isPresented: Binding(get: { reverting != nil }, set: { if !$0 { reverting = nil } })) {
            Button("Discard Changes", role: .destructive) {
                if let file = reverting { actions.revert?(file) }
                reverting = nil
            }
        } message: {
            Text(reverting?.isNew == true ? "The new file moves to the Trash." : "The file returns to its last committed version. This cannot be undone from Shepherd.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Review")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Review").font(Fonts.title).foregroundStyle(Tokens.text)
                Text(scopeLine).font(Fonts.micro).foregroundStyle(Tokens.textMuted).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            SegmentedControl(selection: Binding(get: { session.isPRMode }, set: { actions.setPullRequest($0) }),
                             options: [(false, "Local"), (true, prLabel)], size: .small)
                .disabled(session.isLoading)
            Menu {
                Button("Expand All Files") { collapsed = []; session.viewed = [] }
                Button("Collapse All Files") { collapsed = Set(session.files.map(\.id)) }
                Divider()
                Button("Copy Review as Text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(formatReview(files: session.files, comments: session.comments, summary: session.summary, reference: session.reference), forType: .string)
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium)).foregroundStyle(Tokens.text)
                    .frame(width: Metrics.buttonSmall, height: Metrics.buttonSmall)
                    .background(Tokens.bgSurface, in: RoundedRectangle(cornerRadius: Radius.button))
                    .overlay(RoundedRectangle(cornerRadius: Radius.button).strokeBorder(Tokens.borderStrong, lineWidth: 1))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Review options")
            Button(action: actions.close) { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle(bordered: false))
                .help("Close the review")
                .accessibilityLabel("Close review")
        }
        .padding(.horizontal, 14)
        .frame(height: Metrics.headerHeight)
        .overlay(alignment: .bottom) { Tokens.border.frame(height: 1) }
    }

    private var prLabel: String {
        guard session.isPRMode, let reference = session.reference else { return "PR" }
        return "PR · \(reference)"
    }

    /// "working tree vs HEAD · 4 files · +67 −58"
    private var scopeLine: String {
        let scope = session.isPRMode ? "branch vs \(session.reference ?? "PR base")" : (session.reference ?? "working tree vs HEAD")
        if session.isLoading { return "\(scope) · loading…" }
        let added = session.files.reduce(0) { $0 + $1.addedCount }
        let removed = session.files.reduce(0) { $0 + $1.removedCount }
        let count = session.files.count
        return "\(scope) · \(count) file\(count == 1 ? "" : "s") · \(nativeDiffText(added: added, removed: removed))"
    }

    // MARK: File strip

    private var fileStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(session.files) { file in
                        chip(file).id(file.id)
                    }
                }
                .padding(.horizontal, 10)
            }
            .onChange(of: currentFile) { _, id in if let id { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) } } }
        }
        .frame(height: Metrics.fileStripHeight)
        .background(Tokens.bgCanvas)
        .overlay(alignment: .bottom) { Tokens.border.frame(height: 1) }
    }

    private func chip(_ file: DiffFile) -> some View {
        let selected = currentFile == file.id
        let (letter, color) = Self.status(file)
        return Button {
            session.focusFile = file.id
            session.focusRequest = UUID()
        } label: {
            HStack(spacing: 6) {
                Text(letter).font(Fonts.mono(11, .semibold)).foregroundStyle(color)
                Text((file.displayPath as NSString).lastPathComponent).font(Fonts.mono(11.5)).foregroundStyle(Tokens.text).lineLimit(1)
                DiffStat(added: file.addedCount, removed: file.removedCount)
                if touchedPaths.contains(where: { reviewFile(matching: $0, in: [file]) != nil }) { PulsingDot() }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(selected ? Tokens.bgSelected : .clear, in: RoundedRectangle(cornerRadius: Radius.sm))
            .opacity(session.viewed.contains(file.id) ? 0.5 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(file.displayPath)
        .accessibilityLabel("\(file.displayPath), \(nativeDiffText(added: file.addedCount, removed: file.removedCount))")
    }

    /// M warning / A success / D danger / R accent.
    @MainActor static func status(_ file: DiffFile) -> (String, Color) {
        if file.isNew { return ("A", Tokens.successText) }
        if file.isDeleted { return ("D", Tokens.dangerText) }
        if file.isRenamed { return ("R", Tokens.accentText) }
        return ("M", Tokens.warningText)
    }

    // MARK: Diff

    @ViewBuilder private var content: some View {
        if let error = session.loadError {
            VStack { InlineError(error) }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if session.isLoading && session.files.isEmpty {
            HStack(spacing: 8) { Spinner(size: 12); Text("Loading the diff…").font(Fonts.caption).foregroundStyle(Tokens.textMuted) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if session.files.isEmpty {
            EmptyState(Text("No changes"), caption: session.isPRMode ? "This branch matches its PR base." : "The working tree matches HEAD.", framed: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(session.files) { file in
                            Section {
                                if !isCollapsed(file) { fileBody(file) }
                            } header: {
                                fileHeader(file)
                            }
                            .id(file.id)
                        }
                    }
                }
                .onChange(of: session.focusRequest) { _, _ in scrollToFocus(proxy) }
                .onChange(of: session.files.map(\.id)) { _, _ in scrollToFocus(proxy) }
                .onAppear { DispatchQueue.main.async { scrollToFocus(proxy) } }
                .onChange(of: currentHunk) { _, hunk in
                    if let hunk { proxy.scrollTo(hunk, anchor: .top) }
                }
            }
            .task(id: session.files.map(\.id)) { await highlightAll() }
            .onAppear { if currentFile == nil { currentFile = session.files.first?.id } }
        }
    }

    /// Scroll to the requested file, then clear the request. Tool rows may name it by an
    /// absolute or cwd-relative path, so match on path suffixes too.
    private func scrollToFocus(_ proxy: ScrollViewProxy) {
        guard let path = session.focusFile,
              let file = reviewFile(matching: path, in: session.files) else { return }
        session.focusFile = nil
        collapsed.remove(file.id)
        session.viewed.remove(file.id)
        currentFile = file.id
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.15)) {
            proxy.scrollTo(file.id, anchor: .top)
        }
    }

    private func isCollapsed(_ file: DiffFile) -> Bool {
        collapsed.contains(file.id) || session.viewed.contains(file.id)
    }

    private func fileHeader(_ file: DiffFile) -> some View {
        let folded = isCollapsed(file)
        let name = (file.displayPath as NSString).lastPathComponent
        let directory = (file.displayPath as NSString).deletingLastPathComponent
        return HStack(spacing: 8) {
            Button {
                if folded { collapsed.remove(file.id); session.viewed.remove(file.id) } else { collapsed.insert(file.id) }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Tokens.textMuted)
                    .rotationEffect(.degrees(folded ? -90 : 0)).frame(width: 14, height: 14).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(folded ? "Expand \(name)" : "Collapse \(name)")
            (Text(directory.isEmpty ? "" : directory + "/").foregroundStyle(Tokens.textTertiary) + Text(name).fontWeight(.semibold).foregroundStyle(Tokens.text))
                .font(Fonts.mono(12)).lineLimit(1).truncationMode(.head)
                .help(file.displayPath)
            Text("\(file.hunks.count) hunk\(file.hunks.count == 1 ? "" : "s")").font(Fonts.micro).foregroundStyle(Tokens.textMuted).fixedSize()
            if let count = session.commentCountByFile[file.id], count > 0 {
                Text("\(count) comment\(count == 1 ? "" : "s")").font(Fonts.micro).foregroundStyle(Tokens.accentText).fixedSize()
            }
            Spacer(minLength: 6)
            if let open = actions.open {
                Button { open(file) } label: { Image(systemName: "arrow.up.forward.square") }
                    .buttonStyle(IconButtonStyle(size: 26)).help("Open in Xcode").accessibilityLabel("Open \(name)")
            }
            if actions.revert != nil, !session.isPRMode {
                Button { reverting = file } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(IconButtonStyle(size: 26, tint: Tokens.dangerText)).help("Revert this file").accessibilityLabel("Revert \(name)")
            }
            Button {
                if session.viewed.contains(file.id) { session.viewed.remove(file.id) } else { session.viewed.insert(file.id) }
            } label: { Image(systemName: "checkmark") }
                .buttonStyle(IconButtonStyle(size: 26, tint: session.viewed.contains(file.id) ? Tokens.success : nil))
                .help(session.viewed.contains(file.id) ? "Mark unviewed" : "Mark viewed")
                .accessibilityLabel(session.viewed.contains(file.id) ? "Mark \(name) unviewed" : "Mark \(name) viewed")
        }
        .padding(.horizontal, 12)
        .frame(height: Metrics.fileHeaderHeight)
        .background(Tokens.bgMuted)
        .overlay(alignment: .bottom) { Tokens.borderSubtle.frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture { currentFile = file.id }
    }

    @ViewBuilder private func fileBody(_ file: DiffFile) -> some View {
        if file.isBinary {
            Text("Binary file").font(Fonts.caption).foregroundStyle(Tokens.textMuted).padding(12)
        } else {
            let rows = reviewRows(file, expandedRuns: expandedFiles.contains(file.id) ? nil : expandedRuns)
            ForEach(rows) { row in
                switch row.kind {
                case .hunk(let header):
                    Text(header).font(Fonts.mono(10.5)).foregroundStyle(Tokens.textTertiary).lineLimit(1)
                        .padding(.leading, Metrics.diffNumberWidth * 2 + Metrics.diffSignWidth + 8)
                        .frame(height: Metrics.diffCollapsedRunHeight).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Tokens.bgHover)
                        .id(row.id)
                case .line(let hunkID, let index, let line):
                    DiffLineRow(line: line, text: highlightedText(file: file, hunkID: hunkID, index: index, line: line),
                                comment: session.commentsByLine[.init(fileID: file.id, lineID: line.id)],
                                editing: editing == .init(fileID: file.id, lineID: line.id),
                                draft: $draft, commentFocused: $commentFocused,
                                startComment: { startComment(file: file, line: line) },
                                saveComment: { saveComment(file: file, line: line) },
                                cancelComment: { editing = nil },
                                deleteComment: { session.comments.removeAll { $0.fileID == file.id && $0.lineID == line.id } })
                case .collapsed(let key, let count, let kind, let range):
                    Button {
                        if NSEvent.modifierFlags.contains(.option) { expandedFiles.insert(file.id) } else { expandedRuns.insert(key) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus").font(.system(size: 9, weight: .semibold))
                            Text("\(count) more \(Self.word(kind)) line\(count == 1 ? "" : "s") · \(range)")
                        }
                        .font(Fonts.micro).foregroundStyle(Tokens.textTertiary)
                        .padding(.leading, Metrics.diffNumberWidth * 2 + 8)
                        .frame(height: Metrics.diffCollapsedRunHeight).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Tokens.bgMuted)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show these lines (⌥-click expands the whole file)")
                }
            }
        }
    }

    private static func word(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .added: "added"
        case .removed: "removed"
        case .context: "unchanged"
        }
    }

    private func highlightedText(file: DiffFile, hunkID: String, index: Int, line: DiffLine) -> AttributedString {
        if let hunk = highlighted["\(file.id)\u{0}\(hunkID)"], hunk.indices.contains(index) { return hunk[index] }
        return AttributedString(line.text)
    }

    private func highlightAll() async {
        for file in session.files where !file.isBinary {
            for hunk in file.hunks {
                let key = "\(file.id)\u{0}\(hunk.id)"
                guard highlighted[key] == nil else { continue }
                highlighted[key] = CodeHighlight.highlightLines(hunk.lines.map(\.text), path: file.displayPath, style: .theme)
                await Task.yield()
                if Task.isCancelled { return }
            }
        }
    }

    // MARK: Comments

    private func startComment(file: DiffFile, line: DiffLine) {
        let key = ReviewSession.CommentKey(fileID: file.id, lineID: line.id)
        draft = session.commentsByLine[key]?.text ?? ""
        editing = key
        commentFocused = true
    }

    private func saveComment(file: DiffFile, line: DiffLine) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        session.comments.removeAll { $0.fileID == file.id && $0.lineID == line.id }
        if !text.isEmpty {
            session.comments.append(ReviewComment(fileID: file.id, lineID: line.id, filePath: file.displayPath,
                                                  lineNumber: line.newLine ?? line.oldLine ?? 0, marker: line.kind.reviewMarker,
                                                  content: line.text, text: text))
        }
        editing = nil
        draft = ""
    }

    // MARK: Composer

    private var composer: some View {
        let inline = session.comments.count
        let hasReview = inline > 0 || !session.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 0) {
            TextField("Overall comment — inline comments are attached automatically", text: $session.summary, axis: .vertical)
                .lineLimit(1...5).textFieldStyle(.plain).font(Fonts.bodySmall).focused($summaryFocused)
                .padding(EdgeInsets(top: 12, leading: 14, bottom: 6, trailing: 14))
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    if hasReview { actions.requestChanges() }
                    return .handled
                }
            HStack(spacing: 8) {
                Text("\(inline) inline · ⌘⏎").font(Fonts.micro).foregroundStyle(Tokens.textMuted)
                Spacer()
                Button("Commit", action: actions.commit)
                    .buttonStyle(ShepherdButtonStyle(.secondary, size: .small, tint: Tokens.successText))
                    .disabled(session.isSubmitting || session.files.isEmpty || session.isPRMode)
                    .help("Ask the agent to commit these changes")
                Button("Request changes", action: actions.requestChanges)
                    .buttonStyle(ShepherdButtonStyle(.primary, size: .small))
                    .disabled(session.isSubmitting || !hasReview)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send the comments as the agent's next message")
            }
            .padding(EdgeInsets(top: 4, leading: 14, bottom: 8, trailing: 8))
        }
        .background(Tokens.bgRaised, in: RoundedRectangle(cornerRadius: Radius.xl))
        .overlay(RoundedRectangle(cornerRadius: Radius.xl).strokeBorder(summaryFocused ? Tokens.accent : Tokens.borderStrong, lineWidth: 1))
        .padding(12)
        .overlay(alignment: .top) { Tokens.border.frame(height: 1) }
    }

    // MARK: Keyboard

    /// j/k hunks, n/p files, v viewed, c comment on the current hunk's first changed line.
    private func handleKey(_ key: String) -> KeyPress.Result {
        guard !commentFocused, !summaryFocused else { return .ignored }
        let files = session.files
        guard !files.isEmpty else { return .ignored }
        let fileIndex = files.firstIndex { $0.id == currentFile } ?? 0
        switch key {
        case "n", "p":
            let next = min(files.count - 1, max(0, fileIndex + (key == "n" ? 1 : -1)))
            session.focusFile = files[next].id
            session.focusRequest = UUID()
        case "j", "k":
            let hunks = files.flatMap { file in file.hunks.map { "\(file.id)\u{0}\($0.id)" } }
            let current = currentHunk.flatMap(hunks.firstIndex(of:)) ?? -1
            let next = min(hunks.count - 1, max(0, current + (key == "j" ? 1 : -1)))
            guard hunks.indices.contains(next) else { return .handled }
            currentHunk = hunks[next]
            currentFile = String(hunks[next].split(separator: "\u{0}").first ?? "")
        case "v":
            let id = files[fileIndex].id
            if session.viewed.contains(id) { session.viewed.remove(id) } else { session.viewed.insert(id) }
        case "c":
            let file = files[fileIndex]
            let hunk = currentHunk.flatMap { key in file.hunks.first { "\(file.id)\u{0}\($0.id)" == key } } ?? file.hunks.first
            if let line = hunk?.lines.first(where: { $0.kind != .context }) ?? hunk?.lines.first {
                startComment(file: file, line: line)
            }
        default:
            return .ignored
        }
        return .handled
    }
}

/// One diff line (21pt): old · new line numbers, the sign, and the code, tail-truncated with the
/// full line on hover. A hover "+" opens an inline comment under the line.
private struct DiffLineRow: View {
    let line: DiffLine
    let text: AttributedString
    let comment: ReviewComment?
    let editing: Bool
    @Binding var draft: String
    var commentFocused: FocusState<Bool>.Binding
    let startComment: () -> Void
    let saveComment: () -> Void
    let cancelComment: () -> Void
    let deleteComment: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                number(line.oldLine)
                number(line.newLine)
                Text(sign).font(Fonts.output).foregroundStyle(signColor).frame(width: Metrics.diffSignWidth)
                Text(text).font(Fonts.output).lineLimit(1).truncationMode(.tail).help(line.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: startComment) {
                    Image(systemName: "plus").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 20, height: 20).background(Tokens.accent, in: RoundedRectangle(cornerRadius: Radius.xs))
                }
                .buttonStyle(.plain)
                .opacity(hovering && comment == nil && !editing ? 1 : 0)
                .padding(.trailing, 6)
                .accessibilityLabel("Comment on line \(line.newLine ?? line.oldLine ?? 0)")
            }
            .frame(height: Metrics.diffLineHeight)
            .background(background)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(count: 2, perform: startComment)
            if editing { editor } else if let comment { card(comment) }
        }
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "").font(Fonts.mono(11)).foregroundStyle(Tokens.textMuted)
            .frame(width: Metrics.diffNumberWidth, alignment: .trailing).padding(.trailing, 4)
    }

    private var sign: String {
        switch line.kind {
        case .added: "+"
        case .removed: "\u{2212}"
        case .context: " "
        }
    }

    private var signColor: Color {
        switch line.kind {
        case .added: Tokens.success
        case .removed: Tokens.danger
        case .context: Tokens.textMuted
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: Tokens.successBg
        case .removed: Tokens.dangerBg
        case .context: hovering ? Tokens.bgHover : .clear
        }
    }

    private var indent: CGFloat { Metrics.diffNumberWidth * 2 + 8 + Metrics.diffSignWidth }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Comment for the agent on this line", text: $draft, axis: .vertical)
                .lineLimit(1...8).textFieldStyle(.plain).font(Fonts.bodySmall)
                .focused(commentFocused)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { draft += "\n"; return .handled }
                    saveComment()
                    return .handled
                }
                .onKeyPress(.escape) { cancelComment(); return .handled }
            HStack(spacing: 6) {
                Spacer()
                Button("Cancel", action: cancelComment).buttonStyle(ShepherdButtonStyle(.ghost, size: .small))
                Button("Comment", action: saveComment).buttonStyle(ShepherdButtonStyle(.primary, size: .small))
            }
        }
        .padding(10)
        .background(Tokens.bgRaised, in: RoundedRectangle(cornerRadius: Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Tokens.accent, lineWidth: 1))
        .padding(EdgeInsets(top: 6, leading: indent, bottom: 8, trailing: 12))
    }

    private func card(_ comment: ReviewComment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Y").font(Fonts.sans(10, .bold)).foregroundStyle(.white)
                    .frame(width: 16, height: 16).background(Tokens.accent, in: Circle())
                Text("You").font(Fonts.sans(12, .semibold)).foregroundStyle(Tokens.text)
                Text("line \(comment.lineNumber) · \(Self.age(comment.createdAt))").font(Fonts.micro).foregroundStyle(Tokens.textMuted)
                Spacer()
                Button("Edit", action: startComment).buttonStyle(LinkButtonStyle(color: Tokens.textTertiary, font: Fonts.caption))
                Button("Delete", action: deleteComment).buttonStyle(LinkButtonStyle(color: Tokens.textTertiary, font: Fonts.caption))
            }
            Text(comment.text).font(Fonts.bodySmall).foregroundStyle(Tokens.text).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Tokens.bgRaised, in: RoundedRectangle(cornerRadius: Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Tokens.borderStrong, lineWidth: 1))
        .padding(EdgeInsets(top: 6, leading: indent, bottom: 8, trailing: 12))
    }

    private static func age(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        return nativeClockText(date.timeIntervalSince1970 * 1000)
    }
}

/// The review pane beside a thread: observes the agent's thread for the files it is editing.
struct ReviewPaneHost: View {
    let session: ReviewSession
    let actions: ReviewActions
    @ObservedObject var store: NativeThreadStore

    var body: some View {
        ReviewPane(session: session, actions: actions,
                   touchedPaths: nativeTouchedPaths(store.messages, running: store.snapshot?.running ?? false))
            .id(session.id)
    }
}

/// A small accent dot that pulses (a steady dot under Reduce Motion).
private struct PulsingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        Circle().fill(Tokens.accent).frame(width: 6, height: 6)
            .opacity(dim ? 0.3 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dim = true }
            }
            .accessibilityLabel("Being edited")
    }
}

// MARK: Rows

/// The diff file `path` names: exact, or either path ending in the other (tool calls report
/// absolute or cwd-relative paths; diff paths are repository-relative).
func reviewFile(matching path: String, in files: [DiffFile]) -> DiffFile? {
    files.first { $0.displayPath == path }
        ?? files.first { path.hasSuffix("/" + $0.displayPath) || $0.displayPath.hasSuffix("/" + path) }
}

/// One rendered row of a file's diff.
struct ReviewRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case hunk(String)
        /// A line, with its hunk and index there (for its syntax colors).
        case line(hunkID: String, index: Int, DiffLine)
        /// A folded run: its key, how many lines, their kind, and "20–32".
        case collapsed(key: String, count: Int, kind: DiffLine.Kind, range: String)
    }

    let id: String
    let kind: Kind
}

/// A file's rows with long runs folded (spec §9): more than eight same-kind lines in a row keep
/// a few at each end and fold the middle into one strip. `expandedRuns` nil expands everything.
func reviewRows(_ file: DiffFile, expandedRuns: Set<String>?, threshold: Int = Metrics.diffCollapseThreshold) -> [ReviewRow] {
    var rows: [ReviewRow] = []
    for hunk in file.hunks {
        let hunkKey = "\(file.id)\u{0}\(hunk.id)"
        rows.append(ReviewRow(id: hunkKey, kind: .hunk(hunk.header)))
        var index = 0
        let lines = hunk.lines
        while index < lines.count {
            var end = index
            while end + 1 < lines.count, lines[end + 1].kind == lines[index].kind { end += 1 }
            let run = index...end
            let key = "\(hunkKey)\u{0}\(index)"
            let head = lines[index].kind == .context ? 3 : 5
            let tail = lines[index].kind == .context ? 3 : 1
            if run.count > threshold, run.count > head + tail + 1, !(expandedRuns?.contains(key) ?? true) {
                for i in index..<(index + head) { rows.append(line(hunk: hunk, hunkKey: hunkKey, i)) }
                let folded = (index + head)...(end - tail)
                let numbers = folded.compactMap { lines[$0].newLine ?? lines[$0].oldLine }
                let range = numbers.first.map { first in "\(first)–\(numbers.last ?? first)" } ?? ""
                rows.append(ReviewRow(id: key, kind: .collapsed(key: key, count: folded.count, kind: lines[index].kind, range: range)))
                for i in (end - tail + 1)...end { rows.append(line(hunk: hunk, hunkKey: hunkKey, i)) }
            } else {
                for i in run { rows.append(line(hunk: hunk, hunkKey: hunkKey, i)) }
            }
            index = end + 1
        }
    }
    return rows

    func line(hunk: DiffHunk, hunkKey: String, _ i: Int) -> ReviewRow {
        ReviewRow(id: "\(hunkKey)\u{0}l\(hunk.lines[i].id)", kind: .line(hunkID: hunk.id, index: i, hunk.lines[i]))
    }
}
