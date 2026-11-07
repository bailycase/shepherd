import Foundation

/// One open text file in a Files editor (the Mac's local or the iPad's remote one): what it was
/// read as, what the person typed, and what changed on disk under them.
public struct FileEdit: Equatable, Sendable {
    /// The file as last read or saved: unsaved edits are measured against it.
    public var saved: String
    /// The editor's text.
    public var text: String
    /// The file before the last change on disk the editor took in: the agent's lines are those
    /// that differ from it. nil until the file changes under the editor, and again after a save.
    public var before: String?
    /// The file changed on disk under unsaved edits: its new text. Nothing is written or
    /// replaced until the person chooses (Overwrite saves theirs, Revert takes the disk's).
    public var conflict: String?
    /// The status bar's indentation, read once from the file as it was taken in.
    public var indentation: String?

    public init(saved: String, text: String, before: String? = nil) {
        self.saved = saved
        self.text = text
        self.before = before
        self.indentation = Self.indentation(saved)
    }

    public var isDirty: Bool { text != saved }

    /// What the file on disk now holds, folded in. A clean editor takes it (the lines that
    /// changed are marked as the agent's); an editor with unsaved edits keeps them and holds the
    /// disk's text as a conflict, so neither side is lost. True when the editor's text was replaced.
    public mutating func take(disk text: String) -> Bool {
        if text == saved {
            conflict = nil
        } else if !isDirty {
            self = FileEdit(saved: text, text: text, before: before ?? saved)
            return true
        } else if text == self.text {
            // The disk caught up with the editor (saved elsewhere): nothing is unsaved now.
            saved = text
            conflict = nil
        } else {
            conflict = text
        }
        return false
    }

    /// Drops the unsaved edits: the editor takes the file as it is on disk (the newer text when
    /// it changed under them). False when there was nothing to drop.
    public mutating func revert() -> Bool {
        guard isDirty || conflict != nil else { return false }
        let disk = conflict ?? saved
        self = FileEdit(saved: disk, text: disk, before: conflict == nil ? before : (before ?? saved))
        return true
    }

    /// A save of `text` went through: the marks were the agent's lines in the version the
    /// person just made their own.
    public mutating func didSave(_ text: String) {
        saved = text
        conflict = nil
        before = nil
    }

    /// The status bar's indentation: "Tabs", or "Spaces: n" for the narrowest indented line.
    public static func indentation(_ text: String) -> String? {
        var narrowest: Int?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.first == "\t" { return "Tabs" }
            let spaces = line.prefix { $0 == " " }.count
            if spaces > 0, spaces < line.count { narrowest = min(narrowest ?? spaces, spaces) }
        }
        return narrowest.map { "Spaces: \($0)" }
    }
}
