import Foundation
import ShepherdProtocol

/// A SKILL.md's frontmatter as pi reads it: its `name`, its `description` (what the agent matches
/// tasks against), and whether only /skill:name loads it.
public struct SkillFrontmatter: Hashable, Sendable {
    public var name: String?
    public var description: String?
    /// `disable-model-invocation: true` (a YAML boolean; pi ignores a quoted "true").
    public var disableModelInvocation: Bool

    public init(name: String? = nil, description: String? = nil, disableModelInvocation: Bool = false) {
        self.name = name
        self.description = description
        self.disableModelInvocation = disableModelInvocation
    }

    public var invocation: SkillInvocation {
        disableModelInvocation ? .slashOnly : .automatic
    }
}

/// A repository named in Add from repo: "owner/repo", a GitHub URL (a folder's too), a skills.sh
/// page, or any git URL.
public struct SkillRepoReference: Hashable, Sendable {
    /// What the page shows and a host records: "anthropics/skills" for GitHub, else the URL.
    public var repo: String
    /// What git clones.
    public var cloneURL: String
    /// The folder a GitHub tree URL points at ("skills/pdf"), to pick first.
    public var path: String?
    /// The skill a skills.sh page names ("pdf"), to pick first.
    public var skill: String?

    public init(repo: String, cloneURL: String, path: String? = nil, skill: String? = nil) {
        self.repo = repo
        self.cloneURL = cloneURL
        self.path = path
        self.skill = skill
    }

    /// "owner/repo" when the repository is on GitHub.
    public var gitHub: String? {
        cloneURL.hasPrefix("https://github.com/") ? repo : nil
    }
}

/// The text rules Settings ▸ Skills shares between the Mac, the iPhone and the iPad and the hosts:
/// reading and rewriting a SKILL.md's frontmatter, naming a skill's folder, what skills cost in
/// every prompt, and reading a repository someone typed.
public enum SkillsText {
    // MARK: Frontmatter

    /// The frontmatter at the top of a SKILL.md, read the way pi reads it: between a first line
    /// of `---` and the next line that starts with `---`. A file without one has no fields.
    public static func frontmatter(_ text: String) -> SkillFrontmatter {
        guard let block = frontmatterLines(normalized(text).text) else { return SkillFrontmatter() }
        let fields = yamlFields(block.lines)
        var result = SkillFrontmatter()
        if case .string(let name)? = fields["name"] { result.name = name.trimmingCharacters(in: .whitespacesAndNewlines) }
        if case .string(let description)? = fields["description"] {
            result.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if case .bool(let disabled)? = fields["disable-model-invocation"] { result.disableModelInvocation = disabled }
        return result
    }

    public static func invocation(_ text: String) -> SkillInvocation {
        frontmatter(text).invocation
    }

    /// The SKILL.md with `disable-model-invocation` set for `invocation`: added (or made `true`)
    /// for Only with /skill, taken out for Automatically. The rest of the file is kept as it was,
    /// its line endings included.
    public static func setting(_ invocation: SkillInvocation, in text: String) -> String {
        let (plain, bom, crlf) = normalized(text)
        var lines = plain.components(separatedBy: "\n")
        let key = "disable-model-invocation"
        if let block = frontmatterLines(plain) {
            // Lines 1..<block.end are the frontmatter's; 0 and block.end are its fences.
            var index = 1
            var found: Range<Int>?
            while index < block.end {
                if topLevelKey(lines[index]) == key {
                    var next = index + 1
                    while next < block.end, isContinuation(lines[next]) { next += 1 }
                    found = index..<next
                    break
                }
                index += 1
            }
            switch (invocation, found) {
            case (.slashOnly, let range?):
                lines.replaceSubrange(range, with: ["\(key): true"])
            case (.slashOnly, nil):
                lines.insert("\(key): true", at: block.end)
            case (.automatic, let range?):
                lines.removeSubrange(range)
            case (.automatic, nil):
                return text
            }
        } else {
            guard invocation == .slashOnly else { return text }
            lines.insert(contentsOf: ["---", "\(key): true", "---"], at: 0)
        }
        var result = lines.joined(separator: "\n")
        if crlf { result = result.replacingOccurrences(of: "\n", with: "\r\n") }
        return bom ? "\u{FEFF}" + result : result
    }

    // MARK: Names

    /// A name the Agent Skills spec allows: lowercase letters, digits and single hyphens between
    /// them, at most 64 characters.
    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64, !name.hasPrefix("-"), !name.hasSuffix("-"), !name.contains("--") else { return false }
        return name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// `text` as a valid name: lowercased, spaces and underscores as hyphens, anything else
    /// dropped ("PDF Tools" → "pdf-tools"); empty when nothing is left.
    public static func slug(_ text: String) -> String {
        var result = ""
        for scalar in text.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                result.unicodeScalars.append(scalar)
            } else if scalar == "-" || scalar == "_" || CharacterSet.whitespaces.contains(scalar) {
                if !result.isEmpty, !result.hasSuffix("-") { result.append("-") }
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return String(result.prefix(64)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// The folder a skill installs into, which names it everywhere: its frontmatter `name`, else
    /// its folder in the repository, else the repository's own name.
    public static func folderName(for frontmatter: SkillFrontmatter, path: String, repo: String) -> String {
        let candidates = [frontmatter.name ?? "", path.split(separator: "/").last.map(String.init) ?? "",
                          repo.split(separator: "/").last.map(String.init) ?? ""]
        for candidate in candidates {
            if isValidName(candidate) { return candidate }
            let slug = slug(candidate)
            if !slug.isEmpty { return slug }
        }
        return "skill"
    }

    // MARK: Tokens

    /// What pi puts before its list of skills in every prompt while at least one skill is
    /// automatic, in tokens (about four characters a token, as Instructions counts).
    public static let promptPreambleTokens = estimate(characters: preamble.count)

    /// What one automatic skill adds to every prompt: its name, description and SKILL.md's path,
    /// in pi's `<skill>` block. `directory` is where the host keeps skills ("~/.agents/skills").
    public static func promptTokens(name: String, summary: String, directory: String = "~/.agents/skills") -> Int {
        let home = directory.hasPrefix("~") ? "/Users/shepherd" + directory.dropFirst() : directory
        let location = "\(home)/\(name)/SKILL.md"
        let block = "  <skill>\n    <name>\(escaped(name))</name>\n    <description>\(escaped(summary))</description>\n"
            + "    <location>\(escaped(location))</location>\n  </skill>\n"
        return estimate(characters: block.count)
    }

    /// What every automatic skill that is on costs in every prompt, the preamble included.
    public static func promptTokens(_ skills: [InstalledSkill], directory: String = "~/.agents/skills") -> Int {
        let automatic = skills.filter { $0.isOn && $0.invocation == .automatic }
        guard !automatic.isEmpty else { return 0 }
        return promptPreambleTokens + automatic.reduce(0) { $0 + promptTokens(name: $1.name, summary: $1.summary, directory: directory) }
    }

    /// A whole file when the agent reads it, in tokens.
    public static func tokens(_ text: String) -> Int {
        let characters = text.trimmingCharacters(in: .whitespacesAndNewlines).count
        return characters == 0 ? 0 : estimate(characters: characters)
    }

    /// A count as the page says it: exact under a hundred, then tens, then hundreds ("~610",
    /// "~1,900").
    public static func rounded(_ tokens: Int) -> Int {
        switch tokens {
        case ..<100: tokens
        case ..<1_000: Int((Double(tokens) / 10).rounded()) * 10
        default: Int((Double(tokens) / 100).rounded()) * 100
        }
    }

    /// "~610 tokens", "~1,900 tokens", "~1 token"; "none" for nothing.
    public static func tokenNote(_ tokens: Int) -> String {
        guard tokens > 0 else { return "none" }
        let value = rounded(tokens)
        return "~\(value.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))) \(value == 1 ? "token" : "tokens")"
    }

    // MARK: Repositories

    /// The repository someone typed, or nil for anything that isn't one (a local folder, words).
    public static func reference(_ input: String) -> SkillRepoReference? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        while text.hasSuffix("/") { text.removeLast() }
        // owner/repo
        let parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 2, isGitHubOwner(parts[0]), isGitHubRepoName(stripGit(parts[1])) {
            return gitHub(owner: parts[0], name: stripGit(parts[1]))
        }
        // git@github.com:owner/repo(.git)
        if text.hasPrefix("git@github.com:") {
            let path = text.dropFirst("git@github.com:".count).split(separator: "/").map(String.init)
            guard path.count == 2, isGitHubOwner(path[0]), isGitHubRepoName(stripGit(path[1])) else { return nil }
            return gitHub(owner: path[0], name: stripGit(path[1]))
        }
        var rest = text
        for scheme in ["https://", "http://"] where rest.lowercased().hasPrefix(scheme) {
            rest = String(rest.dropFirst(scheme.count))
        }
        if rest.lowercased().hasPrefix("www.") { rest = String(rest.dropFirst(4)) }
        let host = rest.split(separator: "/").first.map { $0.lowercased() } ?? ""
        let segments = rest.split(separator: "/").dropFirst().map(String.init)
        if host == "github.com", segments.count >= 2, isGitHubOwner(segments[0]), isGitHubRepoName(stripGit(segments[1])) {
            var reference = gitHub(owner: segments[0], name: stripGit(segments[1]))
            // …/tree/<branch>/<folder>: the folder is picked first.
            if segments.count >= 5, segments[2] == "tree" || segments[2] == "blob" {
                var folder = segments[4...].joined(separator: "/")
                if folder.hasSuffix("/SKILL.md") || folder == "SKILL.md" { folder = String(folder.dropLast("SKILL.md".count)) }
                while folder.hasSuffix("/") { folder.removeLast() }
                reference.path = folder
            }
            return reference
        }
        // skills.sh/<owner>/<repo>/<skill>
        if host == "skills.sh", segments.count >= 2, isGitHubOwner(segments[0]), isGitHubRepoName(segments[1]) {
            var reference = gitHub(owner: segments[0], name: segments[1])
            if segments.count >= 3 { reference.skill = segments[2] }
            return reference
        }
        // Any other git URL, kept as written.
        let lowered = text.lowercased()
        if ["https://", "http://", "ssh://", "git://", "file://"].contains(where: lowered.hasPrefix) {
            guard !host.isEmpty || lowered.hasPrefix("file://") else { return nil }
            return SkillRepoReference(repo: text, cloneURL: text)
        }
        if let at = text.firstIndex(of: "@"), let colon = text.firstIndex(of: ":"), at < colon, !text.hasPrefix("/") {
            return SkillRepoReference(repo: text, cloneURL: text)
        }
        return nil
    }

    /// The page on GitHub listing what changed between two commits of a repository.
    public static func compareURL(repo: String, from old: String, to new: String) -> URL? {
        guard let reference = reference(repo), let gitHub = reference.gitHub else { return nil }
        return URL(string: "https://github.com/\(gitHub)/compare/\(old)...\(new)")
    }

    /// A commit as the page shows it: its first seven characters.
    public static func shortCommit(_ commit: String) -> String {
        String(commit.prefix(7))
    }

    // MARK: Files

    /// A skill's top-level entries from its files' paths, relative to its folder: SKILL.md first,
    /// then files by name, then folders with how many files each holds. Hidden ones are left out.
    public static func entries(paths: [String]) -> [SkillFileEntry] {
        var top: [String: SkillFileEntry] = [:]
        for path in paths {
            let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
            guard let first = parts.first, !first.hasPrefix(".") else { continue }
            if parts.count == 1 {
                top[first] = SkillFileEntry(name: first)
            } else {
                top[first, default: SkillFileEntry(name: first, isDirectory: true, fileCount: 0)].fileCount += 1
            }
        }
        return top.values.sorted { a, b in
            if (a.name == "SKILL.md") != (b.name == "SKILL.md") { return a.name == "SKILL.md" }
            if a.isDirectory != b.isDirectory { return !a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    // MARK: Private

    private static let preamble = "The following skills provide specialized instructions for specific tasks.\n"
        + "Read the full skill file when the task matches its description.\n"
        + "When a skill file references a relative path, resolve it against the skill directory (parent of SKILL.md / "
        + "dirname of the path) and use that absolute path in tool commands.\n\n<available_skills>\n</available_skills>"

    private static func estimate(characters: Int) -> Int {
        characters == 0 ? 0 : max(1, (characters + 2) / 4)
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func gitHub(owner: String, name: String) -> SkillRepoReference {
        SkillRepoReference(repo: "\(owner)/\(name)", cloneURL: "https://github.com/\(owner)/\(name).git")
    }

    private static func stripGit(_ name: String) -> String {
        name.hasSuffix(".git") ? String(name.dropLast(4)) : name
    }

    private static func isGitHubOwner(_ owner: String) -> Bool {
        guard !owner.isEmpty, owner.count <= 39, !owner.hasPrefix("-") else { return false }
        return owner.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" }
    }

    private static func isGitHubRepoName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 100, name != ".", name != ".." else { return false }
        return name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "-_.".unicodeScalars.contains($0) }
    }

    /// The text without a byte-order mark, with `\n` line endings, and what it had.
    private static func normalized(_ text: String) -> (text: String, bom: Bool, crlf: Bool) {
        var plain = text
        let bom = plain.hasPrefix("\u{FEFF}")
        if bom { plain.removeFirst() }
        let crlf = plain.contains("\r\n")
        plain = plain.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return (plain, bom, crlf)
    }

    /// The frontmatter's lines, and the index of its closing fence among all the file's lines.
    private static func frontmatterLines(_ text: String) -> (lines: [String], end: Int)? {
        guard text.hasPrefix("---") else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard lines.count > 1, let end = lines.indices.dropFirst().first(where: { lines[$0].hasPrefix("---") }) else { return nil }
        return (Array(lines[1..<end]), end)
    }

    private enum Value: Equatable {
        case string(String)
        case bool(Bool)
        case other
    }

    /// The name of a top-level `key: value` line, nil for anything else.
    private static func topLevelKey(_ line: String) -> String? {
        guard let first = line.first, first != " ", first != "\t", first != "#", first != "-",
              let colon = line.firstIndex(of: ":") else { return nil }
        let after = line.index(after: colon)
        guard after == line.endIndex || line[after] == " " || line[after] == "\t" else { return nil }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : key.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private static func isContinuation(_ line: String) -> Bool {
        line.isEmpty || line.first == " " || line.first == "\t"
    }

    /// The top-level scalars of a small YAML map: plain, quoted, block (`|`, `>`) and multi-line
    /// plain values. A nested map or list reads as `.other`.
    private static func yamlFields(_ lines: [String]) -> [String: Value] {
        var fields: [String: Value] = [:]
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            guard let key = topLevelKey(line), let colon = line.firstIndex(of: ":") else { continue }
            var continuation: [String] = []
            while index < lines.count, isContinuation(lines[index]) {
                continuation.append(lines[index])
                index += 1
            }
            while continuation.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { continuation.removeLast() }
            let raw = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if fields[key] == nil { fields[key] = value(raw, continuation) }
        }
        return fields
    }

    private static func value(_ raw: String, _ continuation: [String]) -> Value {
        if raw.hasPrefix("|") || raw.hasPrefix(">") {
            let indicator = raw.prefix { !$0.isWhitespace && $0 != "#" }
            return .string(block(continuation, folded: raw.hasPrefix(">"), stripsEnd: indicator.contains("-")))
        }
        if raw.hasPrefix("\"") || raw.hasPrefix("'") {
            let joined = ([raw] + continuation.map { $0.trimmingCharacters(in: .whitespaces) }).joined(separator: " ")
            return quoted(joined).map(Value.string) ?? .other
        }
        if raw.isEmpty {
            guard let first = continuation.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return .other }
            let trimmed = first.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") || trimmed == "-" || topLevelKey(trimmed) != nil { return .other }
            return plain(continuation.map { $0.trimmingCharacters(in: .whitespaces) })
        }
        return plain([raw] + continuation.map { $0.trimmingCharacters(in: .whitespaces) })
    }

    /// A plain scalar: its lines folded with spaces, a trailing comment dropped; `true`/`false`
    /// are booleans and `null` or `~` nothing.
    private static func plain(_ lines: [String]) -> Value {
        var folded = ""
        for line in lines {
            if line.isEmpty {
                folded += "\n"
            } else {
                if !folded.isEmpty, !folded.hasSuffix("\n") { folded += " " }
                folded += line
            }
        }
        if let comment = folded.range(of: " #") { folded = String(folded[..<comment.lowerBound]) }
        folded = folded.trimmingCharacters(in: .whitespacesAndNewlines)
        switch folded {
        case "true", "True", "TRUE": return .bool(true)
        case "false", "False", "FALSE": return .bool(false)
        case "", "null", "Null", "NULL", "~": return .other
        default: return .string(folded)
        }
    }

    /// A quoted scalar up to its closing quote: `"…"` with backslash escapes, `'…'` with `''`.
    private static func quoted(_ text: String) -> String? {
        guard let quote = text.first else { return nil }
        var result = ""
        var iterator = text.dropFirst().makeIterator()
        while let character = iterator.next() {
            if character == quote {
                if quote == "'", let next = iterator.next() {
                    if next == "'" { result.append("'"); continue }
                    return result
                }
                return result
            }
            if quote == "\"", character == "\\", let escape = iterator.next() {
                switch escape {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "\"", "\\", "/": result.append(escape)
                case "u":
                    var hex = ""
                    for _ in 0..<4 { if let digit = iterator.next() { hex.append(digit) } }
                    if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) { result.unicodeScalars.append(scalar) }
                default: result.append(escape)
                }
                continue
            }
            result.append(character)
        }
        return nil
    }

    /// A block scalar's lines without their common indent: kept line by line (`|`) or folded
    /// into a paragraph (`>`), ending in one line break unless it strips it (`|-`, `>-`).
    private static func block(_ lines: [String], folded: Bool, stripsEnd: Bool) -> String {
        let indent = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
        let body = lines.map { $0.count >= indent ? String($0.dropFirst(indent)) : "" }
        var text: String
        if folded {
            text = ""
            for line in body {
                if line.isEmpty {
                    text += "\n"
                } else {
                    if !text.isEmpty, !text.hasSuffix("\n") { text += " " }
                    text += line
                }
            }
        } else {
            text = body.joined(separator: "\n")
        }
        return stripsEnd ? text : text + "\n"
    }
}
