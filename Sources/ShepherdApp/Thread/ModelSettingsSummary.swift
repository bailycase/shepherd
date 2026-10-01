import ShepherdCore
import ShepherdRemote

/// What the composer's one model-settings button says, for a thread and for the New thread
/// page's draft: the model's name, the thinking level, and a bolt only while speed is Fast.
/// Standard draws no glyph, a model without thinking has no level, and a model without a raised
/// tier never shows the bolt, even when the agent's own tier is still Fast.
struct ModelSettingsSummary: Equatable {
    /// The model as the button draws it.
    var name: String
    /// The level as the button draws it; nil where the model takes none or the row is compact.
    var thinking: String?
    var fast: Bool
    /// What VoiceOver adds to the model's name: the level, even when the label dropped it, and Fast.
    var value: String

    /// `thinking` is the level's raw id; `thinkingOffered` and `speedOffered` say whether the
    /// model takes either. A narrow row (`shortenedName`) drops a release date from the name,
    /// and the compact size (`dropsThinking`) drops the level from the label.
    init(model: String, thinking: String?, thinkingOffered: Bool, speed: ServiceTier, speedOffered: Bool,
         shortenedName: Bool = false, dropsThinking: Bool = false) {
        name = shortenedName ? nativeModelCompactName(model) : nativeModelShortName(model)
        let title = thinkingOffered ? thinking.map(NativeThinkingLevel.title) : nil
        self.thinking = dropsThinking ? nil : title
        fast = speedOffered && speed != .standard
        value = [title, fast ? ServiceTier.fast.title : nil].compactMap { $0 }.joined(separator: ", ")
    }
}
