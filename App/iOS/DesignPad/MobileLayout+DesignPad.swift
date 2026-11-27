import SwiftUI
import ShepherdUI

/// The iPad Design tool's own measures (iPadDesign, iPadSplitView).
extension MobileLayout {
    /// The chat pane beside the canvas (iPadDesign's 380pt).
    static let padDesignChatWidth: CGFloat = 380
    /// The header over the canvas, and the chat pane's tab row beside it.
    static let padDesignHeaderHeight: CGFloat = 52
    /// Below this width (Split View, a narrow Stage Manager window) the chat leaves the canvas's
    /// side for its button in the header (iPadSplitView), so the canvas keeps a useful width.
    static let padDesignSideBySideMinWidth: CGFloat = 760
    /// The design chat's composer: 14pt in, 10pt over the field (iPadDesign).
    static let padDesignComposerInset: CGFloat = 14
    static let padDesignComposerTop: CGFloat = 10
    static let padDesignComposerPlaceholder = "Describe a change, or draw on a board…"
    /// The header's back label and title: 16pt, the title 17 in a narrow window (iPadSplitView).
    static let padDesignHeaderText: CGFloat = 16
    /// The header's leading and trailing insets (iPadDesign's 12pt; iPadSplitView's 16 and 14).
    static let padDesignHeaderInset: CGFloat = SH.Space.l
    /// The chat button in a narrow window's header (iPadSplitView's 40pt).
    static let padDesignHeaderButton: CGFloat = 40
    /// The header's page popup: at most this wide (a longer name truncates), narrower over a canvas
    /// narrower than `padDesignSideBySideMinWidth`, and over one narrower than
    /// `padDesignPageLabelMinWidth` only its glyph, so the header never overflows.
    static let padDesignPageMenuMaxWidth: CGFloat = 180
    static let padDesignPageMenuNarrowMaxWidth: CGFloat = 120
    static let padDesignPageLabelMinWidth: CGFloat = 440
    /// The design agent's latest word over a narrow window's canvas (iPadSplitView): 360pt wide.
    static let padDesignReplyCardWidth: CGFloat = 360
    static let padDesignReplyCardPaddingVertical: CGFloat = SH.Space.l
    static let padDesignReplyCardPaddingHorizontal: CGFloat = 14
    /// The Comments tab's cards: 16pt in, 12 apart.
    static let padDesignCommentsPadding: CGFloat = SH.Space.xl
    static let padDesignCommentsSpacing: CGFloat = SH.Space.l
    /// A Tweak prop's text field.
    static let padDesignTweakFieldWidth: CGFloat = 140
    /// The Designs list's cards: at least this wide, in as many columns as fit.
    static let padDesignCardMinWidth: CGFloat = 260

    /// The wide header's glass pills (iPadDesign): 42pt tall, "‹ Designs" in 17 medium, the name in
    /// 18 semibold over 12pt secondary, a three-swatch mark of the design system.
    static let padDesignPill: CGFloat = 42
    static let padDesignPillInset: CGFloat = SH.Space.l
    static let padDesignBackGlyph: CGFloat = 19
    static let padDesignBackText: CGFloat = 17
    static let padDesignTitle: CGFloat = 18
    static let padDesignSubtitle: CGFloat = 12
    static let padDesignSwatch = CGSize(width: 6, height: 10)
    /// Over a canvas narrower than this (iPhone Duo's half beside the fold) the pills shrink, so "‹ Designs",
    /// the name and Export keep their room: 36pt tall, the labels in 15, the name in 17.
    static let padDesignCompactCanvasWidth: CGFloat = 640
    static let padDesignPillCompact: CGFloat = 36
    static let padDesignBackGlyphCompact: CGFloat = 16
    static let padDesignBackTextCompact: CGFloat = 15
    static let padDesignTitleCompact: CGFloat = 17
    /// The chat pane is a card at radius 20 on the lift, 8pt in from the screen's edge (iPadDesign).
    static let padDesignPaneRadius: CGFloat = 20
    static let padDesignPaneInset: CGFloat = SH.Space.m
    /// A comment's words and its Resolve in the Comments tab.
    static let padDesignCommentText: CGFloat = 15
    static let padDesignCommentAction: CGFloat = 14
    /// The card starts below the status bar (iPadDesign: 30pt down).
    static let padDesignPaneTop: CGFloat = 30
    static let padDesignScribbleHint = "Handwriting in the chat box works too: Scribble turns it into text."
}

extension EnvironmentValues {
    /// The thread shown is a design's chat (iPadDesign): its composer is the iPad's card at the
    /// compact size, without "/" and with the model's short name, and its transcript sits 16pt in
    /// (`ThreadComposer`, `ThreadTranscript`).
    @Entry var composerDesignChat = false

}
