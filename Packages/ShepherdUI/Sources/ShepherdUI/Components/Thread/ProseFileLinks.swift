import SwiftUI

// A Markdown link to a local file in agent prose (`[plan](temporal/PLAN.md)`, `./x`, `~/x`, `/abs`, `file://`). It resolves against
// the agent's working directory (`shProseFileRoot`); where that is nil (a remote host's agent, the iOS client) the link is drawn as
// plain words and opens nothing, so a same-named file on this device is never opened. Where the app supplies `shProseFileLinks`,
// each link's words carry an invisible button over them (found from the text's own layout, as task chips are): a click opens the
// file in the configured editor, a right-click offers that editor, Open With, Reveal in Finder and Copy Path. Web links are untouched.

/// An app that can open a file: its identifier (a bundle identifier on the Mac) and its name.
public struct SHFileEditor: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// What a local file link does, supplied by the app.
public struct SHProseFileLinks: Equatable {
    /// The name of the app `open(url, nil)` uses for `url`.
    public var editorName: (URL) -> String
    /// The other apps Open With lists.
    public var editors: () -> [SHFileEditor]
    /// Open `url` in the editor with this id, or the configured one when nil.
    public var open: (URL, String?) -> Void
    public var reveal: (URL) -> Void
    private let id = UUID()

    public init(editorName: @escaping (URL) -> String, editors: @escaping () -> [SHFileEditor],
                open: @escaping (URL, String?) -> Void, reveal: @escaping (URL) -> Void) {
        self.editorName = editorName; self.editors = editors; self.open = open; self.reveal = reveal
    }

    public static func == (a: Self, b: Self) -> Bool { a.id == b.id }

    /// The file `link` names, on this device: nil for a web or other-scheme link, and for every link where the agent's files are not
    /// here (`root` nil).
    public static func resolve(_ link: URL, root: URL?) -> URL? {
        guard let root, isLocal(link) else { return nil }
        if link.scheme != nil { return link.standardizedFileURL }
        let path = link.path(percentEncoded: false)
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        if path == "~" || path.hasPrefix("~/") { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL }
        return root.appending(path: path).standardizedFileURL
    }

    /// A link to a file path (no scheme, or `file:`), wherever the file is.
    public static func isLocal(_ link: URL) -> Bool {
        guard let scheme = link.scheme?.lowercased() else { return true }
        return scheme == "file"
    }

    static func hasLocalLink(_ text: AttributedString) -> Bool {
        text.runs.contains { $0.link.map(isLocal) ?? false }
    }

    /// `text` with every local link reduced to its plain words: the files are not on this device.
    static func inert(_ text: AttributedString) -> AttributedString {
        var text = text
        for run in text.runs where run.link.map(isLocal) ?? false {
            text[run.range].link = nil
            text[run.range].foregroundColor = nil
        }
        return text
    }

    /// Prose `text` as one `Text`: with the app's actions, each local link carries its file for `SHFileLinkTargets`; where the
    /// agent's files are not here, local links are only words; otherwise (no actions) the text as it is.
    static func prose(_ text: AttributedString, root: URL?, actions: SHProseFileLinks?) -> Text {
        guard hasLocalLink(text) else { return Text(text) }
        guard let root else { return Text(inert(text)) }
        return actions == nil ? Text(text) : Self.text(text, root: root)
    }

    /// Whether `text` gets press targets: it has a local link, the files are here and the app acts on them.
    static func targets(_ text: AttributedString, root: URL?, actions: SHProseFileLinks?) -> SHProseFileLinks? {
        root != nil && hasLocalLink(text) ? actions : nil
    }

    /// The paragraph as one `Text`: each local link's words keep the link color but lose the link (the press target is an overlay,
    /// not the system's link handling) and carry the resolved file.
    static func text(_ source: AttributedString, root: URL?) -> Text {
        var result = Text(verbatim: "")
        for run in source.runs {
            var piece = AttributedString(source[run.range])
            guard let link = run.link, isLocal(link) else {
                result = Text("\(result)\(Text(piece))")
                continue
            }
            piece.link = nil
            guard let file = resolve(link, root: root) else {
                piece.foregroundColor = nil
                result = Text("\(result)\(Text(piece))")
                continue
            }
            result = Text("\(result)\(Text(piece).customAttribute(SHFileLinkAttribute(url: file)))")
        }
        return result
    }
}

extension EnvironmentValues {
    /// nil where the app offers no file actions (previews, the iOS client): a local link stays a system link where its files are here.
    @Entry public var shProseFileLinks: SHProseFileLinks? = nil
}

struct SHFileLinkAttribute: TextAttribute {
    let url: URL
}

/// One local link's box on one line of the laid-out paragraph. A link that wraps has a box per line; only its first is an
/// accessibility element (`repeat`), as is a second mention of the same file in the paragraph.
struct SHFileLinkBox: Identifiable {
    let url: URL
    let rect: CGRect
    let `repeat`: Bool
    var id: String { "\(url.path)#\(rect.minX)#\(rect.minY)" }

    static func boxes(in layout: Text.Layout) -> [SHFileLinkBox] {
        var found: [SHFileLinkBox] = []
        for line in layout {
            var open: (url: URL, rect: CGRect)?
            func finish() {
                guard let (url, rect) = open else { return }
                open = nil
                found.append(SHFileLinkBox(url: url, rect: rect, repeat: found.contains { $0.url == url }))
            }
            for run in line {
                if let link = run[SHFileLinkAttribute.self] {
                    if let current = open, current.url != link.url { finish() }
                    let bounds = run.typographicBounds.rect
                    open = (link.url, open?.rect.union(bounds) ?? bounds)
                } else {
                    finish()
                }
            }
            finish()
        }
        return found
    }
}

/// The links' press targets and menus, over each link's box; nothing without actions.
struct SHFileLinkTargets: ViewModifier {
    let actions: SHProseFileLinks?

    @ViewBuilder func body(content: Content) -> some View {
        if let actions { targets(content, actions) } else { content }
    }

    private func targets(_ content: Content, _ actions: SHProseFileLinks) -> some View {
        content.overlayPreferenceValue(Text.LayoutKey.self) { anchored in
            GeometryReader { proxy in
                ForEach(Array(anchored.enumerated()), id: \.offset) { _, item in
                    let origin = proxy[item.origin]
                    ForEach(SHFileLinkBox.boxes(in: item.layout)) { box in
                        Button { actions.open(box.url, nil) } label: { Color.clear.contentShape(Rectangle()) }
                            .buttonStyle(.plain)
                            .frame(width: box.rect.width, height: box.rect.height)
                            .position(x: origin.x + box.rect.midX, y: origin.y + box.rect.midY)
                            #if os(macOS)
                            .pointerStyle(.link)
                            #endif
                            .help(box.url.path)
                            .contextMenu { SHFileLinkMenu(url: box.url, actions: actions) }
                            .accessibilityLabel("Open \(box.url.lastPathComponent)")
                            .accessibilityHidden(box.repeat)
                    }
                }
            }
        }
    }
}

/// Open in <editor>, Open With, Reveal in Finder, Copy Path.
struct SHFileLinkMenu: View {
    let url: URL
    let actions: SHProseFileLinks

    var body: some View {
        Button("Open in \(actions.editorName(url))") { actions.open(url, nil) }
        Menu("Open With") {
            ForEach(actions.editors()) { editor in
                Button(editor.name) { actions.open(url, editor.id) }
            }
        }
        Divider()
        Button("Reveal in Finder") { actions.reveal(url) }
        Button("Copy Path") { SHPasteboard.copy(url.path) }
    }
}
