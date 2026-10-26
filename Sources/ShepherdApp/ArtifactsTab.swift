import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// What the Artifacts tab does outside itself: which artifact is open, showing one (nil is the list), where a thread that runs on this
/// Mac keeps its file, and what to say when a copy cannot be saved. The workspace builds it from the view model; a preview from literals.
struct ArtifactsActions {
    var selection: String?
    var show: (String?) -> Void
    var editorURL: (NativeArtifact) -> URL?
    /// The editor chosen in Settings ▸ Advanced (a bundle identifier); nil is the default text editor.
    var editor: String? = nil
    var failed: (String) -> Void
}

/// The side pane's Artifacts tab (PaneArtifacts): the files the agent made in this thread, as a list ("This thread · 4") and, once one
/// is opened, the file itself under a 44pt bar. `actions.selection` says which is open, so the thread's "Open" and a
/// row do the same thing. The rows are derived once per change of the thread (`NativeThreadStore.artifacts`), never in `body`.
struct ArtifactsTab: View {
    var store: NativeThreadStore
    let actions: ArtifactsActions

    var body: some View {
        // An artifact that is no longer in the thread (a pane left open over one that went) shows the list.
        let open = actions.selection.flatMap { path in store.artifacts.first { $0.path == path } }
        if let open {
            ArtifactView(store: store, actions: actions, artifact: open)
                .id(open.path)
        } else if store.artifacts.isEmpty {
            SHArtifactEmpty(store.snapshot == nil ? "Loading the thread…" : "No artifacts", line: "Files the agent makes in this thread show up here.")
        } else {
            // Ages are coarse ("6m ago"): the list redraws once a minute, and whenever the thread changes.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                SHArtifactList(store.artifacts.map { ArtifactRows.row($0, now: context.date) }, selection: actions.selection, open: { actions.show($0) })
            }
        }
    }
}

/// An artifact as a row or a card says it.
enum ArtifactRows {
    static func row(_ artifact: NativeArtifact, now: Date = Date()) -> SHArtifactRow {
        SHArtifactRow(id: artifact.path, name: artifact.name, detail: artifact.detail(now: now), symbol: artifact.kind.symbol)
    }
}

/// One open artifact: the bar, then the file in Preview or Source. The file is fetched from the thread's host, or read from this Mac's
/// disk by the host handler for a local thread, and parsed off the main thread; the bytes are held by the store, so a tab flip back is at once.
private struct ArtifactView: View {
    var store: NativeThreadStore
    let actions: ArtifactsActions
    let artifact: NativeArtifact
    @State private var mode: SHArtifactMode = .preview
    @State private var state = Loaded.loading
    @State private var attempt = 0

    enum Loaded: Equatable {
        case loading
        case ready(NativeArtifactDocument, data: Data)
        case unavailable
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            SHArtifactBar(name: artifact.name, symbol: artifact.kind.symbol, hasPreview: artifact.kind.hasPreview, mode: $mode,
                          back: { actions.show(nil) }) {
                HStack(spacing: SH.Space.xxs) {
                    if let editor = editorURL {
                        Button { ArtifactEditor.open(editor, editor: actions.editor) } label: { Image(systemName: "arrow.up.forward.square") }
                            .buttonStyle(.shIcon)
                            .shHelp("Open in your editor")
                            .accessibilityLabel("Open in your editor")
                    }
                    Button(action: saveCopy) { Image(systemName: "square.and.arrow.down") }
                        .buttonStyle(.shIcon)
                        .disabled(data == nil)
                        .shHelp("Save a copy")
                        .accessibilityLabel("Save a copy")
                }
            }
            content
        }
        .background(Color.sh.bgWindow)
        .task(id: attempt) { await load() }
        // A rewrite of the file while it is open reads it again.
        .task(id: artifact.createdAt) { if case .ready = state { await load() } }
    }

    private var data: Data? {
        if case .ready(_, let data) = state { return data }
        return nil
    }

    /// Where the file is on this Mac, for a thread that runs here. A remote thread's file is on its host.
    private var editorURL: URL? { actions.editorURL(artifact) }

    @ViewBuilder private var content: some View {
        switch state {
        case .loading:
            SHArtifactNotice(.loading)
        case .unavailable:
            SHArtifactNotice(.unavailable)
        case .failed(let message):
            SHArtifactNotice(.failed(message)) { attempt += 1 }
        case .ready(let document, _):
            ArtifactBody(document: document, mode: mode)
        }
    }

    private func load() async {
        if case .loading = state {} else if case .ready = state {} else { state = .loading }
        switch await store.artifactFiles.open(artifact) {
        case .document(let document, let data): state = .ready(document, data: data)
        case .unavailable: state = .unavailable
        case .failed(let message): state = .failed(message)
        case .cancelled: break
        }
    }

    /// Save a copy… (issue 296): the bytes as the host served them, under the file's own name, wherever the user says.
    private func saveCopy() {
        guard let data else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = artifact.name
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let failed = actions.failed
        let done: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: .atomic) } catch {
                failed("Couldn’t save \(url.lastPathComponent): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: done) } else { panel.begin(completionHandler: done) }
    }
}

/// An artifact's content by kind and mode.
struct ArtifactBody: View {
    let document: NativeArtifactDocument
    let mode: SHArtifactMode

    var body: some View {
        switch (document, mode) {
        case (.markdown(let blocks, _), .preview):
            // Shepherd Design colors, so it follows light and dark; the thread's own prose renderer.
            ScrollView {
                Prose(blocks: blocks, maxWidth: .infinity)
                    .padding(SHArtifactMetrics.documentInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.sh.bgWindow)
        case (.html(let html), .preview):
            // Its own styles on its own background (the web view's white where the page sets none).
            SHArtifactWebView(html: html)
        case (.svg(let svg), .preview):
            SHArtifactWebView(svg: svg)
        case (.text(let text), _):
            SHArtifactSource(text)
        default:
            SHArtifactSource(document.source)
        }
    }
}

/// Opens an artifact in a text editor, never in a browser: an HTML file the agent wrote would run its scripts there.
enum ArtifactEditor {
    @MainActor static func open(_ url: URL, editor chosen: String?) {
        let workspace = NSWorkspace.shared
        let editor = chosen.flatMap { $0.isEmpty ? nil : workspace.urlForApplication(withBundleIdentifier: $0) }
            ?? workspace.urlForApplication(toOpen: .plainText)
        if let editor {
            workspace.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } else {
            workspace.activateFileViewerSelecting([url])
        }
    }
}

extension EnvironmentValues {
    /// Opens an artifact (by its path) in the thread's side pane: the "Made an artifact" line and its card. nil where there is no pane
    /// to open it in (a transcript beside nothing), and the line then expands to its call as any other.
    @Entry var openArtifact: ((String) -> Void)? = nil
}

/// The card where the agent made a file (PaneArtifacts › In the thread). A value that compares by the artifact, so a turn streaming below it
/// leaves it alone; its age is as of the last time its turn changed.
struct ArtifactCardItem: View, Equatable {
    let artifact: NativeArtifact
    @Environment(\.openArtifact) private var openArtifact

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.artifact == rhs.artifact }

    var body: some View {
        SHArtifactCard(ArtifactRows.row(artifact), open: openArtifact.map { open in { open(artifact.path) } })
            .frame(maxWidth: AppLayout.proseMaxWidth, alignment: .leading)
    }
}
