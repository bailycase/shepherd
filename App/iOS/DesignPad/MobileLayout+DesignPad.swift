import SwiftUI
import ShepherdUI

/// The iPad Design tool's own measures (iPadDesign, iPadSplitView).
extension MobileLayout {
    /// The chat pane beside the canvas (iPadDesign's 360pt).
    static let padDesignChatWidth: CGFloat = 360
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
    static let padDesignHeaderInset: CGFloat = NW.Space.l
    /// The chat button in a narrow window's header (iPadSplitView's 40pt).
    static let padDesignHeaderButton: CGFloat = 40
    /// The design agent's latest word over a narrow window's canvas (iPadSplitView): 360pt wide.
    static let padDesignReplyCardWidth: CGFloat = 360
    static let padDesignReplyCardPaddingVertical: CGFloat = NW.Space.l
    static let padDesignReplyCardPaddingHorizontal: CGFloat = 14
    /// The Comments tab's cards: 16pt in, 12 apart.
    static let padDesignCommentsPadding: CGFloat = NW.Space.xl
    static let padDesignCommentsSpacing: CGFloat = NW.Space.l
    /// A Tweak prop's text field.
    static let padDesignTweakFieldWidth: CGFloat = 140
    /// The Designs list's cards: at least this wide, in as many columns as fit.
    static let padDesignCardMinWidth: CGFloat = 260
}

extension EnvironmentValues {
    /// The thread shown is a design's chat (iPadDesign): its composer is one field with Send, and
    /// its transcript sits 16pt in (`ThreadComposer`, `ThreadTranscript`).
    @Entry var composerDesignChat = false
}
