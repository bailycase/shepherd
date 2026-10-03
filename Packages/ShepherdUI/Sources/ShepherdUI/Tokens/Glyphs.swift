import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The glyphs a board names, each drawn one way: the SF Symbol and the fill variant the board
/// shows (`bolt` is not `bolt.fill`). A glyph that appears in more than one place (a chip, a row,
/// a menu, the iPhone and the Mac) is a case here, and a view draws it through `NWGlyph` (or the
/// component that wraps it, such as `NWFastBolt`) instead of naming the symbol again, so the
/// places cannot drift. `DesignRulesTests` fails when a registered symbol name appears as a raw
/// string anywhere else.
///
/// Add a case when a design introduces a glyph that more than one view draws, with the board it
/// comes from. A glyph the board draws that no SF Symbol matches is drawn as a shape beside this
/// enum, and its case says so.
public enum NWGlyph: CaseIterable, Sendable {
    /// A raised service tier (Fast): the filled bolt. The composer boards' bolt.
    case fastBolt
    /// An automation: the outline bolt. The sidebar, Automations and the iOS home's bolt.
    case automation
    /// A remote host: Settings and the command palette's outward radio waves.
    case remoteConnection

    /// The SF Symbol that draws it, fill variant included.
    public var symbolName: String {
        switch self {
        case .fastBolt: "bolt.fill"
        case .automation: "bolt"
        case .remoteConnection: "dot.radiowaves.left.and.right"
        }
    }

    public var image: Image { Image(systemName: symbolName) }

    /// Static outline artwork supplied with the Settings boards. Keep this native so controls
    /// retain their accessibility actions rather than mounting the board's HTML.
    public enum Settings: String, CaseIterable {
        case back, search, appearance, terminal, agents, subagents, worktrees, projects, pi
        case instructions, skills, mcp, remoteConnection, keyboard, advanced, experiments
        case next, folder, computer, browserSearch, globe, lock

        public var size: CGSize {
            switch self {
            case .back: CGSize(width: 10, height: 12)
            case .search: CGSize(width: 13, height: 13)
            case .next: CGSize(width: 8, height: 10)
            case .folder: CGSize(width: 16, height: 16)
            case .computer: CGSize(width: 12, height: 12)
            case .browserSearch, .globe, .lock: CGSize(width: 14, height: 14)
            default: CGSize(width: 15, height: 15)
            }
        }

        public var resourceURL: URL? { Bundle.module.url(forResource: rawValue, withExtension: "svg", subdirectory: "Glyphs") }

        @MainActor public var image: Image {
            #if os(macOS)
            Image(nsImage: Self.artwork[self]!).renderingMode(.template)
            #else
            Image(systemName: fallbackSymbol)
            #endif
        }

        #if os(macOS)
        @MainActor private static let artwork: [Settings: NSImage] = Dictionary(uniqueKeysWithValues: allCases.map { glyph in
            guard let url = glyph.resourceURL,
                  let image = NSImage(contentsOf: url) else {
                preconditionFailure("Missing Settings glyph: \(glyph.rawValue)")
            }
            image.isTemplate = true
            return (glyph, image)
        })
        #else
        private var fallbackSymbol: String {
            switch self {
            case .back: "chevron.left"
            case .search, .browserSearch: "magnifyingglass"
            case .appearance: "circle.lefthalf.filled"
            case .terminal: "terminal"
            case .agents: "person.2"
            case .subagents: "arrow.turn.down.right"
            case .worktrees: "arrow.branch"
            case .projects, .folder: "folder"
            case .pi: "function"
            case .instructions: "doc.text"
            case .skills: "graduationcap"
            case .mcp: "server.rack"
            case .remoteConnection: NWGlyph.remoteConnection.symbolName
            case .keyboard: "keyboard"
            case .advanced: "gearshape"
            case .experiments: "flask"
            case .next: "chevron.right"
            case .computer: "desktopcomputer"
            case .globe: "globe"
            case .lock: "lock"
            }
        }
        #endif
    }
}
