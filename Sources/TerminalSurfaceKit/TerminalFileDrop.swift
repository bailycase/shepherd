import Foundation

/// Finder drop formatting matches Ghostty's macOS app: local file URLs become
/// absolute, shell-escaped paths and multiple items are separated by spaces.
enum TerminalFileDrop {
    private static let escapeCharacters = Set("\\ ()[]{}<>\"'`!#$&;|*?\t")

    static func text(for urls: [URL]) -> String? {
        let paths = urls.compactMap { url -> String? in
            guard url.isFileURL else { return nil }
            return shellEscape(url.path)
        }
        guard !paths.isEmpty else { return nil }
        // Trailing space: the user almost always types a prompt after the
        // path, and without it their first word joins the filename.
        return paths.joined(separator: " ") + " "
    }

    static func shellEscape(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.utf8.count)
        for character in value {
            if escapeCharacters.contains(character) {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }
}
