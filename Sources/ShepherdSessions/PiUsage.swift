import Foundation

/// How much of a subscription's limits are used: one entry per window
/// the provider reports ("5-hour", "Week").
public struct PiUsageWindow: Equatable, Sendable {
    public var name: String
    /// 0–100.
    public var usedPercent: Double
    public var resetsAt: Date?

    public init(name: String, usedPercent: Double, resetsAt: Date?) {
        self.name = name
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

/// Reads a subscription's usage from the provider with the credential in Shepherd's pi's
/// `auth.json`, the same requests Claude Code's `/usage` and Codex's `/status` make. Only Anthropic
/// and OpenAI Codex publish one. Read-only: an expired token is skipped, never refreshed (pi
/// owns refreshing, and its refresh tokens rotate).
public enum PiUsage {
    public static let providers = ["anthropic", "openai-codex"]

    /// The request for `provider`'s usage, or nil without a live OAuth credential.
    public static func request(_ provider: String, credential: [String: Any], now: Date = Date()) -> URLRequest? {
        guard credential["type"] as? String == "oauth", let access = credential["access"] as? String, !access.isEmpty,
              (credential["expires"] as? Double).map({ Date(timeIntervalSince1970: $0 / 1000) > now }) ?? true else { return nil }
        var request: URLRequest
        switch provider {
        case "anthropic":
            request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        case "openai-codex":
            guard let account = credential["accountId"] as? String else { return nil }
            request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
            request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        default:
            return nil
        }
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        return request
    }

    /// The windows in a usage response; empty when it has none.
    public static func parse(_ provider: String, _ data: Data) -> [PiUsageWindow] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        switch provider {
        case "anthropic":
            let names = [("five_hour", "5-hour"), ("seven_day", "Week"), ("seven_day_opus", "Week, Opus"),
                         ("seven_day_sonnet", "Week, Sonnet")]
            return names.compactMap { key, name in
                guard let window = root[key] as? [String: Any], let used = window["utilization"] as? Double else { return nil }
                // "2025-10-13T19:00:00.123456+00:00": the fraction (any length) is dropped.
                let resets = (window["resets_at"] as? String).flatMap {
                    try? Date($0.replacing(#/\.\d+/#, with: "", maxReplacements: 1), strategy: .iso8601)
                }
                return PiUsageWindow(name: name, usedPercent: used, resetsAt: resets)
            }
        case "openai-codex":
            guard let limit = root["rate_limit"] as? [String: Any] else { return [] }
            return ["primary_window", "secondary_window"].compactMap { key in
                guard let window = limit[key] as? [String: Any], let used = window["used_percent"] as? Double else { return nil }
                let seconds = window["limit_window_seconds"] as? Double ?? 0
                return PiUsageWindow(name: windowName(seconds), usedPercent: used,
                                     resetsAt: (window["reset_at"] as? Double).map { Date(timeIntervalSince1970: $0) })
            }
        default:
            return []
        }
    }

    static func windowName(_ seconds: Double) -> String {
        let hours = Int((seconds / 3600).rounded())
        if hours == 24 * 7 { return "Week" }
        if hours >= 24, hours % 24 == 0 { return "\(hours / 24)-day" }
        return "\(hours)-hour"
    }

    /// One credential's usage; nil without a live OAuth token or when the request fails.
    static func fetch(_ provider: String, _ credential: [String: Any], session: URLSession) async -> [PiUsageWindow]? {
        guard let request = request(provider, credential: credential),
              let (body, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(provider, body)
    }

    /// An Anthropic account's email, from `/api/oauth/profile` (what Claude Code asks): its token
    /// doesn't carry one. OpenAI Codex's is in its token (`PiAccounts.tokenEmail`).
    static func anthropicEmail(_ credential: [String: Any], session: URLSession) async -> String? {
        guard var request = request("anthropic", credential: credential) else { return nil }
        request.url = URL(string: "https://api.anthropic.com/api/oauth/profile")
        guard let (body, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return profileEmail(body)
    }

    static func profileEmail(_ data: Data) -> String? {
        let account = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["account"] as? [String: Any]
        return account?["email"] as? String ?? account?["email_address"] as? String
    }

    /// Every subscription's usage in `home`, by provider (the active credential's), and each saved
    /// account's, saved with it (`PiAccounts.saveUsage`) so an account whose token has expired
    /// still shows what it last read. Only tokens still live are used: nothing is refreshed.
    public static func read(home: PiHome, session: URLSession = .shared) async -> [String: [PiUsageWindow]] {
        let accounts = PiAccounts(home: home)
        let lists = accounts.lists()
        guard let data = try? Data(contentsOf: home.directory.appendingPathComponent("auth.json")),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var usage: [String: [PiUsageWindow]] = [:]
        for provider in providers {
            let list = lists[provider]
            if let credential = auth[provider] as? [String: Any], let windows = await fetch(provider, credential, session: session) {
                usage[provider] = windows
                if list != nil {
                    let email = provider == "anthropic" && list?.activeAccount?.email == nil
                        ? await anthropicEmail(credential, session: session) : nil
                    try? accounts.saveUsage(provider, nil, windows, email: email)
                }
            }
            for (id, credential) in accounts.inactiveCredentials(provider) {
                guard let windows = await fetch(provider, credential, session: session) else { continue }
                let known = list?.accounts.first { $0.id == id }?.email
                let email = provider == "anthropic" && known == nil ? await anthropicEmail(credential, session: session) : nil
                try? accounts.saveUsage(provider, id, windows, email: email)
            }
        }
        return usage
    }
}
