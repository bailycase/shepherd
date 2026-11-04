import CryptoKit
import Foundation

/// A hook's identity (docs/hooks.md › Identity and the off switch). The runtime computes the same values;
/// `Tests/Fixtures/hooks/hash-vectors.json` keeps the two equal.
public enum HookCanonical {
    /// The handler object as canonical JSON: what the hash covers.
    public static func canonical(_ handler: HookJSON) -> String { handler.canonical }

    /// `<file path>#<Event>/<group index>/<handler index>`.
    public static func slot(file: String, event: String, group: Int, handler: Int) -> String {
        "\(file)#\(event)/\(group)/\(handler)"
    }

    /// Lowercase hex SHA-256 of `<file>\n<Event>\n<matcher or "">\n<canonical handler>`.
    public static func hash(file: String, event: String, matcher: String, canonical: String) -> String {
        let text = file + "\n" + event + "\n" + matcher + "\n" + canonical
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func hash(file: String, event: String, matcher: String, handler: HookJSON) -> String {
        hash(file: file, event: event, matcher: matcher, canonical: handler.canonical)
    }
}
