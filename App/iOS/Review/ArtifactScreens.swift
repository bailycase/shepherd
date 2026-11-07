import SwiftUI
import UniformTypeIdentifiers
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// The Artifacts tab on iPad (iPadPaneArtifacts) and the artifact sheet on iPhone: the files the agent made in a thread, fetched from the
/// host that holds them (`NativeThreadArtifacts`), drawn by kind, with the version the thread's calls give it.
extension EnvironmentValues {
    /// Opens an artifact (by its path) beside the thread on iPad, or in a sheet on iPhone: the "Made an artifact" line and its card. nil
    /// where nothing can show it (a subagent's transcript), and the line then expands to its call as any other.
    @Entry var openArtifact: ((String) -> Void)? = nil
    /// The thread's artifacts by path, so a line and a card made at an earlier version say the current one.
    @Entry var threadArtifacts: [String: NativeArtifact] = [:]
}

/// How the thread opens an artifact: beside it on iPad (the side pane's Artifacts tab), over it on iPhone.
@MainActor
enum ArtifactHooks {
    static func open(thread: AgentRef, path: String, navigator: MobileNavigator) {
        switch navigator.layout {
        case .pad:
            let store = ReviewStores.shared.store(for: thread)
            store.artifact = path
            store.padLayout = .docked
            if navigator.padSelection != thread { navigator.open(.thread(thread)) }
            navigator.sidePane.show(.artifacts)
        case .phone:
            navigator.present(.review(.artifact(thread, path: path)))
        }
    }

    static func rows(_ artifacts: [NativeArtifact], now: Date = Date()) -> [SHArtifactRow] {
        artifacts.map { SHArtifactRow(id: $0.path, name: $0.name, detail: $0.detail(now: now), symbol: $0.kind.symbol) }
    }
}

/// The pane's Artifacts tab: the list, or the open artifact.
struct PadArtifactsPane: View {
    let ref: AgentRef
    let store: ReviewStore
    let artifacts: [NativeArtifact]
    @Environment(ThreadStores.self) private var threads

    var body: some View {
        if let open = store.artifact.flatMap({ path in artifacts.first { $0.path == path } }) {
            let thread = threads.store(for: ref)
            ArtifactScreenBody(artifact: open, files: thread.artifactFiles, served: thread.supportedActions.contains("artifacts"), pad: true) {
                store.artifact = nil
            }
                .id(open.path)
        } else {
            // Ages are coarse ("6m ago"): the list redraws once a minute, and whenever the thread changes.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                SHArtifactList(ArtifactHooks.rows(artifacts, now: context.date), open: { store.artifact = $0 })
            }
        }
    }
}

/// The artifact on iPhone, as a sheet over the thread: its name, Preview | Source, Save a copy and Done.
struct PhoneArtifactScreen: View {
    let ref: AgentRef
    let path: String
    @Environment(ThreadStores.self) private var threads
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let store = threads.store(for: ref)
        Group {
            if let artifact = store.artifacts.first(where: { $0.path == path }) {
                ArtifactScreenBody(artifact: artifact, files: store.artifactFiles, served: store.supportedActions.contains("artifacts"),
                                   pad: false) { dismiss() }
            } else {
                SHFileNotice(.unavailable)
            }
        }
        .background(Color.sh.bgWindow)
    }
}

/// An artifact open: the bar, then its file. Fetched when it opens and again if the file was written again; held by the thread's store.
struct ArtifactScreenBody: View {
    let artifact: NativeArtifact
    let files: NativeThreadArtifacts
    /// The host serves this thread's files (`artifacts`, remotely `native.artifacts.v1`). An older host lists them but serves none: say
    /// so once, with nothing to try again.
    let served: Bool
    let pad: Bool
    let back: () -> Void
    @State private var mode: SHArtifactMode = .preview
    @State private var state = Loaded.loading
    @State private var attempt = 0

    enum Loaded: Equatable {
        case loading
        case ready(NativeArtifactDocument, data: Data)
        case unavailable
        case failed(String)
        case outdated
    }

    var body: some View {
        VStack(spacing: 0) {
            SHArtifactBar(name: artifact.name, version: artifact.versionAge(), symbol: artifact.kind.symbol, hasPreview: artifact.kind.hasPreview,
                          mode: $mode, pad: pad, back: back) {
                // Open in another app, or save to Files: the share sheet with the file as the host served it.
                if let data {
                    ShareLink(item: ArtifactFile(data: data, name: artifact.name), preview: SharePreview(artifact.name)) {
                        Image(systemName: "arrow.up.forward.square")
                    }
                    .buttonStyle(.shIcon(size: SH.Height.touch - SH.Space.xs))
                    .accessibilityLabel("Open in another app")
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

    @ViewBuilder private var content: some View {
        switch state {
        case .loading: SHFileNotice(.loading)
        case .unavailable: SHFileNotice(.unavailable)
        case .failed(let message): SHFileNotice(.failed(message)) { attempt += 1 }
        case .outdated: SHFileNotice(.failed("Update Shepherd on the host to open this thread's files."))
        case .ready(let document, _): ArtifactContent(document: document, mode: mode)
        }
    }

    private func load() async {
        guard served else {
            state = .outdated
            return
        }
        if case .loading = state {} else if case .ready = state {} else { state = .loading }
        switch await files.open(artifact) {
        case .document(let document, let data): state = .ready(document, data: data)
        case .unavailable: state = .unavailable
        case .failed(let message): state = .failed(message)
        case .cancelled: break
        }
    }
}

/// An artifact's content by kind and mode: Markdown through the thread's prose, HTML and SVG in the locked-down web view, the rest as source.
struct ArtifactContent: View {
    let document: NativeArtifactDocument
    let mode: SHArtifactMode

    var body: some View {
        switch (document, mode) {
        case (.markdown(let blocks, _), .preview):
            ScrollView {
                SHAgentProse(ProseView.proseBlocks(blocks), maxWidth: .infinity)
                    .padding(SHArtifactMetrics.documentInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.sh.bgWindow)
        case (.html(let html), .preview):
            SHArtifactWebView(html: html)
        case (.svg(let svg), .preview):
            SHArtifactWebView(svg: svg)
        case (.text(let text), _):
            SHFileSource(text)
        default:
            SHFileSource(document.source)
        }
    }
}

/// The bytes the share sheet hands on, under the file's own name.
struct ArtifactFile: Transferable {
    let data: Data
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { file in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(file.name)
            try file.data.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}
