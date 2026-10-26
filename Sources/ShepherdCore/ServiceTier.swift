/// How fast a thread asks its provider to answer: the composer's Speed control. Standard sends
/// nothing (the provider's default); Fast asks for the provider's priority processing
/// (`service_tier: "priority"`), which is billed at a higher rate. Another tier (Flex) is a new
/// case here and a row in `ServiceTierSupport.rules`.
public enum ServiceTier: String, Codable, Hashable, Sendable, CaseIterable {
    case standard
    case fast

    public var title: String {
        switch self {
        case .standard: "Standard"
        case .fast: "Fast"
        }
    }

    /// What "Toggle fast mode" switches to: back to Standard from a raised tier, else the first
    /// raised tier the model offers; nil when it offers none (there is nothing to toggle).
    public static func toggled(from current: ServiceTier, offered: [ServiceTier]) -> ServiceTier? {
        if current != .standard { return offered.contains(.standard) ? .standard : nil }
        return offered.first { $0 != .standard }
    }

    /// The menu's one line under the title.
    public var summary: String {
        switch self {
        case .standard: "Default speed and price"
        case .fast: "Faster responses, billed at a higher rate"
        }
    }
}

/// One model as the support table sees it: what pi calls its provider and API.
public struct ServiceTierModel: Hashable, Sendable {
    /// pi's provider id ("openai", "openai-codex").
    public var provider: String
    /// pi's model id, as the provider is asked for it ("gpt-6-luna").
    public var id: String
    /// pi's API for the model ("openai-responses"), nil when not known.
    public var api: String?

    public init(provider: String, id: String, api: String? = nil) {
        self.provider = provider
        self.id = id
        self.api = api
    }
}

/// Which service tiers a model takes, and what a request carries for each: the one table the
/// composer's Speed control, the host's snapshot and the new-thread default read.
/// `Extensions/shepherd-service-tier.ts` holds the same table for its request-time check, and
/// both are tested against `Tests/Extensions/service-tier-support.json`, so they cannot drift.
///
/// A model offers no tier unless a rule names its provider and API: a request is never changed
/// for a provider that is not known to accept the field (Anthropic, Gemini and every provider
/// not listed are untouched).
public enum ServiceTierSupport {
    public struct Rule: Hashable, Sendable {
        public var provider: String
        /// The APIs the provider takes the field on.
        public var apis: [String]
        /// What the request carries for each tier other than Standard (which sends nothing).
        public var wire: [ServiceTier: String]

        public var tiers: [ServiceTier] { [.standard] + ServiceTier.allCases.filter { wire[$0] != nil } }
    }

    /// OpenAI's API and the ChatGPT backend Codex signs in to.
    public static let rules: [Rule] = [
        Rule(provider: "openai", apis: ["openai-responses", "openai-completions"], wire: [.fast: "priority"]),
        Rule(provider: "openai-codex", apis: ["openai-codex-responses"], wire: [.fast: "priority"]),
    ]

    /// Models that are not chat models: images, audio, realtime, embeddings.
    static let excludedWords = ["image", "realtime", "audio", "tts", "transcribe", "whisper", "embedding", "moderation", "dall-e"]

    /// The rule for `model`, nil when the model offers no tier.
    public static func rule(for model: ServiceTierModel) -> Rule? {
        guard let rule = rules.first(where: { $0.provider == model.provider }) else { return nil }
        if let api = model.api {
            guard rule.apis.contains(api) else { return nil }
        }
        let name = baseName(model.id)
        guard !excludedWords.contains(where: { name.contains($0) }) else { return nil }
        return rule
    }

    /// The tiers `model` offers: empty when it takes none (no control), else Standard first.
    public static func tiers(for model: ServiceTierModel) -> [ServiceTier] {
        rule(for: model)?.tiers ?? []
    }

    /// What a request to `model` carries for `tier`: nil for Standard, and for a model that
    /// offers no such tier.
    public static func wireValue(_ tier: ServiceTier, for model: ServiceTierModel) -> String? {
        rule(for: model)?.wire[tier]
    }

    /// The last path component of a routed model id.
    static func baseName(_ id: String) -> String {
        let last = id.split(separator: "/").last.map(String.init) ?? id
        return normalized(last)
    }

    private static func normalized(_ text: String) -> String {
        var scalars = Substring(text.lowercased())
        while let first = scalars.first, first.isWhitespace { scalars.removeFirst() }
        while let last = scalars.last, last.isWhitespace { scalars.removeLast() }
        return String(scalars)
    }
}
