import Foundation

/// How far an extension works in Shepherd. Shepherd runs pi in RPC mode and draws the thread
/// itself, so what an extension draws in pi's terminal UI never shows. Two sources: what pi's
/// loader recorded the extension registering (`PiExtensionInventory`, exact), and a scan of its
/// code for terminal UI calls it can only make while an agent runs (a guess: "may not show").
/// What works and what doesn't follows pi's `rpc-extension-ui.md` and `RPCThreadState`'s handler.
public struct PiExtensionSupport: Equatable, Sendable {
    public enum Level: String, Equatable, Sendable {
        /// Everything it registered works in Shepherd.
        case works
        /// Some of it can't show in Shepherd (`notShown`, `mayNotShow`).
        case partly
    }

    /// The providers it registered, by id: they appear in Sign-in.
    public var providers: [String] = []
    /// What else it adds that works: "/acme-usage", "acme_search tool", "2 event hooks".
    public var adds: [String] = []
    /// What it registered that Shepherd can't show: "shortcut ctrl+x", "custom message display".
    public var notShown: [String] = []
    /// Terminal UI its code calls, found by a scan: may never appear.
    public var mayNotShow: [String] = []

    public var level: Level { notShown.isEmpty && mayNotShow.isEmpty ? .works : .partly }

    public init(providers: [String] = [], adds: [String] = [], notShown: [String] = [], mayNotShow: [String] = []) {
        self.providers = providers
        self.adds = adds
        self.notShown = notShown
        self.mayNotShow = mayNotShow
    }

    /// One extension's support from the inventories of its entry files and its scan.
    public static func make(_ inventories: [PiExtensionInventory], scanned: [String]) -> PiExtensionSupport {
        var support = PiExtensionSupport(mayNotShow: scanned)
        func unique(_ values: [String]) -> [String] { var seen = Set<String>(); return values.filter { seen.insert($0).inserted } }
        support.providers = unique(inventories.flatMap(\.providers))
        let commands = unique(inventories.flatMap(\.commands)).map { "/" + $0 }
        let tools = unique(inventories.flatMap(\.tools)).map { "\($0) tool" }
        let events = unique(inventories.flatMap(\.events))
        support.adds = commands + tools + (events.isEmpty ? [] : [events.count == 1 ? "1 event hook" : "\(events.count) event hooks"])
        let shortcuts = unique(inventories.flatMap(\.shortcuts))
        let flags = unique(inventories.flatMap(\.flags))
        let renderers = inventories.map(\.renderers).reduce(0, +)
        support.notShown = shortcuts.map { "shortcut \($0)" } + flags.map { "--\($0) flag" }
            + (renderers > 0 ? ["custom message display"] : [])
        return support
    }

    /// The inventories by extension copy (`YourPiCopy.destination`): an inventory belongs to the
    /// copy its path is inside. Copies pi didn't load (off, failed) have none.
    public static func byCopy(_ copies: [YourPiCopy], inventories: [PiExtensionInventory], home: URL) -> [String: [PiExtensionInventory]] {
        let paths = inventories.map { (PiHome.canonical($0.path), $0) }
        var result: [String: [PiExtensionInventory]] = [:]
        for copy in copies {
            let root = PiHome.canonical(home.appendingPathComponent(copy.destination).path)
            let mine = paths.filter { PiHome.isInside($0.0, root) }.map(\.1)
            if !mine.isEmpty { result[copy.destination] = mine }
        }
        return result
    }

    // MARK: The scan

    /// Terminal UI calls pi's RPC mode ignores, each with what a person would miss.
    static let terminalOnlyCalls: [(pattern: String, label: String)] = [
        (#"ui\s*\.\s*custom\s*\("#, "custom terminal UI"),
        (#"\.\s*set(Footer|Header)\s*\("#, "footer or header"),
        (#"\.\s*(setEditorComponent|addAutocompleteProvider|onTerminalInput)\s*\("#, "editor add-ons"),
        (#"\.\s*(setWorkingMessage|setWorkingIndicator|setWorkingVisible|setHiddenThinkingLabel)\s*\("#, "working indicator"),
        (#"\.\s*setStatus\s*\("#, "status line"),
        (#"\.\s*setTheme\s*\("#, "themes"),
    ]

    /// How much of an extension the scan reads: its own code, never `node_modules`.
    static let scanFiles = 400
    static let scanBytes = 8 << 20

    /// The terminal-only UI the code under `root` (a file or a folder) calls, in `terminalOnlyCalls`' order.
    public static func scan(_ root: URL) -> [String] {
        var found = Set<String>()
        var files = 0, bytes = 0
        func read(_ url: URL) {
            guard files < scanFiles, bytes < scanBytes, ["ts", "js", "mjs", "cjs", "mts", "cts"].contains(url.pathExtension),
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe), bytes + data.count <= scanBytes else { return }
            files += 1
            bytes += data.count
            let text = String(decoding: data, as: UTF8.self)
            for call in terminalOnlyCalls where !found.contains(call.label) && text.range(of: call.pattern, options: .regularExpression) != nil {
                found.insert(call.label)
            }
        }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isFolder) else { return [] }
        if !isFolder.boolValue {
            read(root)
        } else if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                               options: [.skipsHiddenFiles]) {
            for case let url as URL in walker {
                if url.lastPathComponent == "node_modules" { walker.skipDescendants(); continue }
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { read(url) }
                if files >= scanFiles || bytes >= scanBytes { break }
            }
        }
        return terminalOnlyCalls.map(\.label).filter(found.contains)
    }
}
