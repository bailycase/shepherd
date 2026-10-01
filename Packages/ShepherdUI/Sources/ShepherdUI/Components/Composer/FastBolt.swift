import SwiftUI

/// The mark of a raised service tier (Fast): a filled bolt in `lantern`. Everywhere the composer
/// shows speed draws it through this view (the model-settings button while Fast is on, a
/// speed-capable model's row, the Fast segment), so the glyph, weight, size and colour cannot
/// drift. Standard draws nothing. The outline `bolt` belongs to automations.
///
/// It is hidden from VoiceOver: the control that wears it says "Fast" itself.
public struct NWFastBolt: View {
    /// The SF Symbol for a raised tier (`NWGlyph.fastBolt`).
    public static let symbol = NWGlyph.fastBolt.symbolName

    public init() {}

    public var body: some View {
        NWGlyph.fastBolt.image
            .font(.system(size: NWComposerMetrics.chipSymbol, weight: .medium))
            .foregroundStyle(Color.nw.lantern)
            .accessibilityHidden(true)
    }
}
