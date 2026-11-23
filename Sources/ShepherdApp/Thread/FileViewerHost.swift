import AppKit
import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdUI

// A file the agent edited, open over the window (OutsideFileE): a changes card's file row opens it, wherever the file is
// (the thread's folder, another repository, no repository at all). File reads it from disk now; Diff shows what changed:
// the turn as the host recorded it, else what git says about the file in its own repository.

/// What Diff shows for one file: the change and where it came from in the footer's words, or why there is none.
enum FileViewerDiff: Equatable {
    case ready(DiffFile, source: String)
    case none(String)
}

/// A file's text read for the viewer, or why it can't be shown.
enum FileViewerText: Equatable {
    case text(String)
    case failed(String)
}

/// How the viewer reads: set by the view model; tests pass their own, so nothing touches disk or git.
struct FileViewerLoader {
    var read: @Sendable (String) async -> FileViewerText
    var diff: @MainActor (String) async -> FileViewerDiff

    /// This Mac's disk, held to the Files tab's bounds (a regular text file of at most 2 MB).
    static let disk: @Sendable (String) async -> FileViewerText = { path in
        switch ThreadFileSystem.read(path: path, resolvedRoot: "/", maxSize: ThreadFileSystem.maxTextSize) {
        case .success(let data):
            guard let text = ThreadFileSystem.decodeText(data) else { return .failed("This is a binary file.") }
            return .text(text)
        case .failure(.notFound): return .failed("This file isn’t there any more.")
        case .failure(.tooLarge): return .failed("This file is too large to show here. Open it in your editor.")
        case .failure(let error): return .failed(error.localizedDescription)
        }
    }

    /// The footer's words for what git found.
    static func source(_ change: GitDiff.FileChange) -> String {
        switch change.source {
        case .uncommitted: "Uncommitted changes"
        case .untracked: "Not in git yet: the whole file"
        case .commit(let id, let subject): subject.isEmpty ? "Commit \(id)" : "Commit \(id) · \(subject)"
        }
    }
}

/// The viewer's state: the card's files, which one shows, File or Diff, and each file's text and diff as they load. The rows
/// the sheet draws are built here when something arrives, never in a view's body.
@MainActor @Observable
final class FileViewerState {
    enum Load<Value: Equatable>: Equatable {
        case loading
        case ready(Value)
        case failed(String)
    }

    struct Shown: Equatable {
        let file: DiffFile
        let source: String
        var colors: [Int: AttributedString]
        var rows: [SHChangesRow]
    }

    /// Absolute paths, in the card's order.
    let paths: [String]
    private(set) var index: Int
    var mode: SHFileViewer.Mode = .file
    private(set) var texts: [String: Load<[SHFileViewerLine]>] = [:]
    private(set) var diffs: [String: Load<Shown>] = [:]
    @ObservationIgnored private var lines: [String: [String]] = [:]
    @ObservationIgnored private var colored: [String: [AttributedString]] = [:]
    @ObservationIgnored private var revealed: [String: IndexSet] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let loader: FileViewerLoader
    @ObservationIgnored private let style: CodeHighlight.Style

    init(paths: [String], index: Int, loader: FileViewerLoader) {
        self.paths = paths
        self.index = paths.indices.contains(index) ? index : 0
        self.loader = loader
        style = .theme
        reach()
    }

    var path: String { paths[index] }
    var position: String? { paths.count > 1 ? "\(index + 1) of \(paths.count)" : nil }
    var hasPrevious: Bool { index > 0 }
    var hasNext: Bool { index + 1 < paths.count }

    func previous() { if hasPrevious { index -= 1; reach() } }
    func next() { if hasNext { index += 1; reach() } }
    func toggleMode() { mode = mode == .file ? .diff : .file }

    /// Stops what is still loading (the viewer closed).
    func close() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    /// A fold opened in the diff: every unchanged line came with it, so the rows are rebuilt with those lines shown.
    func reveal(_ foldID: String, _ direction: SHDiffReveal) {
        guard let span = ChangesRows.span(ofFold: foldID), case .ready(var shown)? = diffs[path] else { return }
        revealed[path, default: []].insert(integersIn: span.revealed(direction))
        shown.rows = ChangesRows.rows(shown.file, layout: .unified, revealed: revealed[path] ?? [], colors: shown.colors)
        diffs[path] = .ready(shown)
    }

    /// "+6 −1" for the header, once the diff is here.
    var stat: (added: Int, removed: Int)? {
        guard case .ready(let shown)? = diffs[path] else { return nil }
        return (shown.file.addedCount, shown.file.removedCount)
    }

    /// The footer: where Diff's text comes from, or in File what the marked lines are.
    var source: String {
        let diff: Shown? = if case .ready(let shown)? = diffs[path] { shown } else { nil }
        switch mode {
        case .diff: return diff?.source ?? ""
        case .file:
            if let diff, marks(path) != nil { return "On disk now · marked: \(diff.source)" }
            return "On disk now"
        }
    }

    var content: SHFileViewer.Content {
        switch mode {
        case .file:
            switch texts[path] {
            case .ready(let lines)?: return .file(lines)
            case .failed(let message)?: return .message(message)
            case .loading?, nil: return .loading
            }
        case .diff:
            switch diffs[path] {
            case .ready(let shown)?: return .diff(shown.rows, reveal: { [weak self] in self?.reveal($0, $1) })
            case .failed(let message)?: return .message(message)
            case .loading?, nil: return .loading
            }
        }
    }

    /// The new lines' numbers the diff added, only while the diff's new side is the file on disk: a file changed since
    /// gets no marks rather than wrong ones.
    func marks(_ path: String) -> Set<Int>? {
        guard case .ready(let shown)? = diffs[path], let disk = lines[path] else { return nil }
        let newSide = shown.file.hunks.flatMap(\.lines).filter { $0.kind != .removed }
        guard newSide.map(\.text) == disk else { return nil }
        return Set(newSide.compactMap { $0.kind == .added ? $0.newLine : nil })
    }

    /// The text's lines as the viewer numbers them: a final newline ends the last line rather than starting another.
    nonisolated static func lines(_ text: String) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.count > 1, lines.last == "" { lines.removeLast() }
        return lines
    }

    private func rebuildFileLines(_ path: String) {
        guard let colored = colored[path] else { return }
        let marks = marks(path) ?? []
        texts[path] = .ready(colored.enumerated().map { SHFileViewerLine(number: $0 + 1, text: $1, added: marks.contains($0 + 1)) })
    }

    /// Loads the shown file, then the next, so stepping forward finds it ready.
    private func reach() {
        for path in [index, index + 1].compactMap({ paths.indices.contains($0) ? paths[$0] : nil }) where tasks[path] == nil && texts[path] == nil {
            texts[path] = .loading
            diffs[path] = .loading
            let loader = loader, style = style
            tasks[path] = Task { [weak self] in
                // Git (or the host) works while the file is read: the text shows first, its marks once the diff is here.
                let diffLoad = Task { await loader.diff(path) }
                defer { diffLoad.cancel() }
                let text = await loader.read(path)
                guard !Task.isCancelled, let self else { return }
                switch text {
                case .text(let text):
                    let lines = Self.lines(text)
                    let colored = await Task.detached(priority: .userInitiated) {
                        CodeHighlight.highlightLines(lines, path: path, style: style)
                    }.value
                    guard !Task.isCancelled else { return }
                    self.lines[path] = lines
                    self.colored[path] = colored.count == lines.count ? colored : lines.map(AttributedString.init)
                case .failed(let message):
                    self.texts[path] = .failed(message)
                }
                self.rebuildFileLines(path)
                let diff = await diffLoad.value
                guard !Task.isCancelled else { return }
                switch diff {
                case .ready(let file, let source):
                    let colors = await Task.detached(priority: .userInitiated) { reviewHighlight(file, style: style) }.value
                    guard !Task.isCancelled else { return }
                    self.diffs[path] = .ready(Shown(file: file, source: source, colors: colors,
                                                    rows: ChangesRows.rows(file, layout: .unified, colors: colors)))
                case .none(let why):
                    self.diffs[path] = .failed(why)
                }
                self.rebuildFileLines(path)
            }
        }
    }

    /// `path` as the card names it, absolute: `~` expanded, a relative one against `base` (the folder the card's paths are
    /// relative to: the repository's top level for a turn the host recorded, else the thread's folder).
    nonisolated static func absolute(_ path: String, base: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let joined = expanded.hasPrefix("/") ? expanded : (base as NSString).appendingPathComponent(expanded)
        return (joined as NSString).standardizingPath
    }
}

extension ShepherdViewModel {
    /// A changes card's file row: the viewer over the window on `path`, stepping through the card's `paths`. A recorded turn
    /// (`turnID`) names its paths from the repository's top level, a turn without one as the agent's calls did.
    func openFileViewer(_ agentID: AgentID, turnID: UUID?, path: String, paths: [String]) {
        guard let agent = state.agents.first(where: { $0.id == agentID }) else { return }
        let cwd = agentCwd(agent)
        let all = paths.contains(path) ? paths : [path] + paths
        Task { [weak self] in
            let root = turnID == nil ? nil : await Task.detached { GitDiff.repositoryRoot(cwd: cwd) }.value
            guard let self else { return }
            let absolute = all.map { FileViewerState.absolute($0, base: root ?? cwd) }
            self.closeFileViewer()
            self.fileViewer = FileViewerState(paths: absolute, index: all.firstIndex(of: path) ?? 0,
                                              loader: FileViewerLoader(read: FileViewerLoader.disk, diff: { [weak self] path in
                                                  await self?.fileViewerDiff(agentID, cwd: cwd, turnID: turnID, root: root, path: path)
                                                      ?? .none("Shepherd is closing.")
                                              }))
        }
    }

    func closeFileViewer() {
        fileViewer?.close()
        fileViewer = nil
    }

    /// The turn's own change to a file in the thread's repository, as the host recorded it; else what git says about the
    /// file in the repository that holds it.
    private func fileViewerDiff(_ agentID: AgentID, cwd: String, turnID: UUID?, root: String?, path: String) async -> FileViewerDiff {
        if let turnID, let root, path.hasPrefix(root.hasSuffix("/") ? root : root + "/") {
            let relative = String(path.dropFirst(root.hasSuffix("/") ? root.count : root.count + 1))
            let engine = makeChangesEngine(agentID, cwd)
            let options = ChangesOptions(fullFiles: true)
            if let list = try? await engine.list(.turn(id: turnID), options), let file = list.files.first(where: { $0.path == relative }),
               let diff = try? await engine.file(list.revision, file, options), !diff.truncated {
                return .ready(diff.file, source: "This turn’s edits")
            }
        }
        guard let change = await Task.detached(priority: .userInitiated, operation: { GitDiff.fileChange(path: path) }).value else {
            return .none("No diff to show: this file isn’t in a git repository, or git has no change for it.")
        }
        return .ready(change.file, source: FileViewerLoader.source(change))
    }
}

/// The viewer over the window: a click on the scrim, the close button or Esc closes it; ← and → step through the card's
/// files and D switches between File and Diff.
struct FileViewerOverlay: View {
    var vm: ShepherdViewModel
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            if let state = vm.fileViewer {
                let path = state.path
                let directory = ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
                SHFileViewer(
                    directory: directory.hasSuffix("/") ? directory : directory + "/", name: (path as NSString).lastPathComponent,
                    stat: state.stat, position: state.position, mode: Binding(get: { state.mode }, set: { state.mode = $0 }),
                    content: state.content, source: state.source,
                    previous: state.hasPrevious ? { state.previous() } : nil,
                    next: state.hasNext ? { state.next() } : nil,
                    openInEditor: { [vm] in
                        let url = URL(fileURLWithPath: path)
                        ShepherdViewModel.openInEditor(url, editor: vm.settings.editor(for: url))
                    },
                    close: { vm.closeFileViewer() })
                // Keys go to a hidden focus target of their own, as the image viewer's do, so no control draws a focus ring.
                .background {
                    Color.clear
                        .focusable()
                        .focusEffectDisabled()
                        .focused($focused)
                        .onAppear { focused = true }
                        .onKeyPress(.escape) { vm.closeFileViewer(); return .handled }
                        .onKeyPress(.leftArrow) { state.previous(); return .handled }
                        .onKeyPress(.rightArrow) { state.next(); return .handled }
                        .onKeyPress(characters: .init(charactersIn: "dD"), phases: .down) { press in
                            guard press.modifiers.intersection([.command, .option, .control]).isEmpty else { return .ignored }
                            state.toggleMode()
                            return .handled
                        }
                        .accessibilityHidden(true)
                }
                .shTransition(.overlay)
            }
        }
        .allowsHitTesting(vm.fileViewer != nil)
        .shAnimation(.overlay, value: vm.fileViewer != nil)
    }
}
