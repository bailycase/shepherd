import CryptoKit
import Foundation

/// The providers Settings ▸ Pi ▸ Sign-in offers (DESIGN.md › Pi ▸ Sign-in): the account
/// sign-ins the pi Shepherd ships has, in the boards' order, and every provider that takes a key.
/// Names and words only; pi's own login does the signing in (`PiSignInBridge`).
public enum PiSignInCatalog {
    public struct Subscription: Equatable, Sendable, Identifiable {
        /// pi's provider id.
        public var id: String
        /// "Kimi" (pi calls its provider "Kimi For Coding").
        public var name: String
        /// What the provider sells: "Claude Pro or Max".
        public var plan: String
        /// The sheet's second line: "With your Claude Pro or Max subscription".
        public var sheetSubtitle: String
        /// How it signs in first.
        public var flow: PiSignInFlow
        /// Where the browser or code goes, for the sheet's words: "claude.ai", "GitHub".
        public var site: String
        /// Its refresh tokens rotate, so signing in here and in the terminal's pi can sign one out.
        public var sharedLogin: Bool
    }

    public static let subscriptions: [Subscription] = [
        Subscription(id: "anthropic", name: "Anthropic", plan: "Claude Pro or Max", sheetSubtitle: "With your Claude Pro or Max subscription",
                     flow: .browser, site: "claude.ai", sharedLogin: true),
        Subscription(id: "openai-codex", name: "OpenAI Codex", plan: "ChatGPT Plus or Pro", sheetSubtitle: "With your ChatGPT Plus or Pro subscription",
                     flow: .browser, site: "chatgpt.com", sharedLogin: true),
        Subscription(id: "github-copilot", name: "GitHub Copilot", plan: "Copilot Pro or Business",
                     sheetSubtitle: "With your Copilot Pro or Business plan", flow: .device, site: "GitHub", sharedLogin: false),
        Subscription(id: "xai", name: "xAI", plan: "Grok subscription", sheetSubtitle: "With your Grok subscription",
                     flow: .device, site: "x.ai", sharedLogin: false),
        Subscription(id: "kimi-coding", name: "Kimi", plan: "Kimi For Coding", sheetSubtitle: "With your Kimi For Coding subscription",
                     flow: .device, site: "Kimi", sharedLogin: true),
        Subscription(id: "radius", name: "Radius", plan: "pi’s model gateway", sheetSubtitle: "With your Radius account",
                     flow: .browser, site: "Radius", sharedLogin: true),
    ]

    public static func subscription(_ id: String) -> Subscription? {
        subscriptions.first { $0.id == id }
    }

    /// A provider's name as Sign-in shows it.
    public static func name(_ id: String) -> String {
        subscription(id)?.name ?? PiProviders.name(id)
    }

    /// Two letters for its badge: "An", "Cx", "Gh", "xA"; a custom provider's first two.
    public static func badge(_ id: String) -> String {
        if let known = badges[id] { return known }
        let letters = name(id).filter { $0.isLetter || $0.isNumber }
        guard let first = letters.first else { return "?" }
        return String(first).uppercased() + (letters.dropFirst().first.map { String($0).lowercased() } ?? "")
    }

    private static let badges: [String: String] = [
        "anthropic": "An", "openai-codex": "Cx", "github-copilot": "Gh", "google": "Go", "xai": "xA", "kimi-coding": "Ki",
        "radius": "Ra", "openai": "Oa", "openrouter": "Or", "deepseek": "Ds", "vercel-ai-gateway": "Ve",
    ]

    /// Providers that take a key, by name: every provider pi knows but those that sign in with
    /// cloud credentials pi doesn't store.
    public static var keyProviders: [String] {
        PiProviders.names.keys.filter { !PiProviders.ambient.contains($0) && $0 != "openai-codex" && $0 != "github-copilot" && $0 != "radius" }
            .sorted { (PiProviders.name($0).lowercased(), $0) < (PiProviders.name($1).lowercased(), $1) }
    }

    /// Where to get a key, for "No key yet? Get one on …".
    public static let keyPages: [String: String] = [
        "anthropic": "console.anthropic.com", "openai": "platform.openai.com", "deepseek": "platform.deepseek.com",
        "openrouter": "openrouter.ai", "groq": "console.groq.com", "mistral": "console.mistral.ai", "google": "aistudio.google.com",
        "xai": "console.x.ai", "together": "api.together.ai", "fireworks": "fireworks.ai", "cerebras": "cloud.cerebras.ai",
        "huggingface": "huggingface.co", "moonshotai": "platform.moonshot.ai", "zai": "z.ai",
    ]
}

/// How Settings shows a key: its prefix, "••••" and its last four ("sk-proj-••••3kQz"). Nothing
/// else of a key's value is ever drawn, logged or put in a tooltip.
public enum PiKeyMask {
    public static func mask(_ key: String) -> String {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count >= 12 else { return "••••" }
        // The leading word groups ending in "-" or "_", at most 8 characters: "sk-proj-", "sk-", "gsk_".
        var prefix = ""
        var group = ""
        for character in key {
            if character.isASCII, character.isLetter { group.append(character); continue }
            if (character == "-" || character == "_"), !group.isEmpty, prefix.count + group.count + 1 <= 8 {
                prefix += group + String(character)
                group = ""
                continue
            }
            break
        }
        return prefix + "••••" + key.suffix(4)
    }
}

/// What Settings shows of a key in Shepherd's pi: a literal's mask, the variables a `$NAME`
/// reads, or that it runs a command. Never a value.
public struct PiKeyDisplay: Equatable, Sendable {
    public var masked: String?
    public var variables: [String]
    /// A `!command`: pi runs it when the key is first needed.
    public var runsCommand: Bool
    /// The command, for a custom provider's key in models.json (configuration, as SettingsPiSignIn
    /// draws it); never for one in auth.json, whose command may carry a secret inline.
    public var command: String?

    public init(masked: String? = nil, variables: [String] = [], runsCommand: Bool = false, command: String? = nil) {
        self.masked = masked
        self.variables = variables
        self.runsCommand = runsCommand || command != nil
        self.command = command
    }

    /// auth.json's `key` (or, with `showingCommand`, models.json's `apiKey`), as Settings shows it.
    public static func of(_ key: String, showingCommand: Bool = false) -> PiKeyDisplay {
        switch YourPiFiles.keySource(key) {
        case .command:
            PiKeyDisplay(runsCommand: true, command: showingCommand ? String(key.dropFirst()).trimmingCharacters(in: .whitespaces) : nil)
        case .environment(let names): PiKeyDisplay(variables: names)
        case .literal: PiKeyDisplay(masked: PiKeyMask.mask(key.replacingOccurrences(of: "$$", with: "$")))
        }
    }
}

/// One of models.json's custom providers, as Sign-in shows it.
public struct PiCustomProvider: Equatable, Sendable, Identifiable {
    public var id: String
    /// Its `apiKey`, as shown; nil when it needs none.
    public var key: PiKeyDisplay?
    public var baseURL: String?

    public init(id: String, key: PiKeyDisplay? = nil, baseURL: String? = nil) {
        self.id = id
        self.key = key
        self.baseURL = baseURL
    }

    /// models.json's providers, sorted; throws when it isn't a JSON object.
    public static func parse(_ data: Data) throws -> [PiCustomProvider] {
        let root = try YourPiFiles.object(data, file: "models.json")
        guard let table = root["providers"] as? [String: Any] else { return [] }
        return table.keys.sorted().map { id in
            let entry = table[id] as? [String: Any]
            let key = (entry?["apiKey"] as? String).flatMap { $0.isEmpty ? nil : PiKeyDisplay.of($0, showingCommand: true) }
            return PiCustomProvider(id: id, key: key, baseURL: entry?["baseUrl"] as? String)
        }
    }
}

/// How Shepherd's copy of something stands against the user's pi (DESIGN.md › Pi ▸ From your pi).
public enum PiFreshness: String, Equatable, Sendable {
    case sameAsYourPi
    case newerInYourPi
    case changedHere

    /// Compares by digests taken when Shepherd copied it (`copied`), never by values: unchanged
    /// here and changed there is newer in your pi; anything else that differs changed here.
    /// `theirsNewer` breaks a tie where both changed (a subscription's later expiry).
    public static func compare(ours: String?, theirs: String?, copied: String?, theirsNewer: Bool = false) -> PiFreshness? {
        guard let theirs else { return nil }
        guard let ours else { return .newerInYourPi }
        if ours == theirs { return .sameAsYourPi }
        if let copied, ours == copied { return .newerInYourPi }
        if let copied, theirs == copied { return .changedHere }
        return theirsNewer ? .newerInYourPi : .changedHere
    }
}

/// A short digest of a JSON value (a credential, a file), for telling copies apart without keeping
/// them: never a value.
public enum PiDigest {
    public static func of(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value) || value is String,
              let data = value is String ? Data((value as! String).utf8) : try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        else { return nil }
        return bytes(data)
    }

    public static func bytes(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
