import SwiftUI

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
}
