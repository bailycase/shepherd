import Foundation
import ShepherdProtocol

/// A skill listed on skills.sh, the open directory of agent skills.
public struct DirectorySkill: Identifiable, Hashable, Codable, Sendable {
    /// Its name in its repository ("find-skills"): what a host installs.
    public var slug: String
    public var name: String
    /// "owner/repo".
    public var source: String
    public var installs: Int
    /// On skills.sh's curated list of first-party publishers.
    public var official: Bool

    public init(slug: String, name: String, source: String, installs: Int, official: Bool = false) {
        self.slug = slug
        self.name = name
        self.source = source
        self.installs = installs
        self.official = official
    }

    public var id: String { "\(source)/\(slug)" }
}

/// One file of a skill as skills.sh serves it, relative to the skill's folder.
public struct DirectoryFile: Hashable, Sendable {
    public var path: String
    public var contents: String

    public init(path: String, contents: String) {
        self.path = path
        self.contents = contents
    }
}

/// A skill from skills.sh, ready to preview before it's installed: its SKILL.md, what it says it
/// does, what it costs when the agent reads it, and its files.
public struct DirectoryPreview: Equatable, Sendable {
    public let skill: DirectorySkill
    /// The SKILL.md, empty when skills.sh sent none.
    public let instructions: String
    /// Its frontmatter's description.
    public let summary: String?
    public let tokens: Int
    /// Every file's path, relative to the skill's folder.
    public let paths: [String]
    public let entries: [SkillFileEntry]

    public init(skill: DirectorySkill, files: [DirectoryFile]) {
        self.skill = skill
        instructions = files.first { $0.path == "SKILL.md" || $0.path.lowercased().hasSuffix("/skill.md") }?.contents ?? ""
        summary = SkillsText.frontmatter(instructions).description
        tokens = SkillsText.tokens(instructions)
        paths = files.map(\.path)
        entries = SkillsText.entries(paths: paths)
    }
}

/// The lists skills.sh ranks: the same as its site's tabs.
public enum DirectoryRanking: String, CaseIterable, Sendable {
    case trending
    case allTime = "all-time"
    case hot
    case official

    public var title: String {
        switch self {
        case .trending: "Trending"
        case .allTime: "All time"
        case .hot: "Hot"
        case .official: "Official"
        }
    }

    /// The column's label over a ranked list.
    public var heading: String {
        switch self {
        case .trending: "Trending · last 24 hours"
        case .allTime: "All time"
        case .hot: "Hot · last hour"
        case .official: "Official publishers"
        }
    }
}

public enum SkillsDirectoryError: Error, Equatable, CustomStringConvertible {
    /// skills.sh's ranked lists need an API key.
    case needsKey
    case unavailable(String)

    public var description: String {
        switch self {
        case .needsKey: "skills.sh’s rankings need an API key. Search and install work without one."
        case .unavailable(let reason): reason
        }
    }
}

/// skills.sh over HTTPS: search and a skill's files need no key (as the `skills` CLI uses them);
/// the ranked lists (`/api/v1`) need one, sent as a bearer token.
public struct SkillsDirectory: Sendable {
    public static let home = URL(string: "https://skills.sh")!

    /// Topics narrow a list: each is a search.
    public static let topics: [(title: String, query: String)] = [
        ("React", "react"), ("Next.js", "next.js"), ("Design & UI", "design"), ("Databases", "database"),
        ("Testing", "testing"), ("Docs & files", "docs"), ("Agent workflows", "workflow"),
    ]

    public var base: URL
    public var key: String?

    public init(base: URL = SkillsDirectory.home, key: String? = nil) {
        self.base = base
        self.key = key.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    /// Skills matching `query`, most installed first.
    public func search(_ query: String, limit: Int = 50) async throws -> [DirectorySkill] {
        var components = URLComponents(url: base.appendingPathComponent("api/search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: String(limit))]
        return try Self.decodeSearch(try await get(components.url!))
    }

    /// A ranked list, a page at a time. Throws `needsKey` without a key, or when skills.sh refuses it.
    public func ranked(_ ranking: DirectoryRanking, page: Int = 1, perPage: Int = 50) async throws -> [DirectorySkill] {
        guard key != nil else { throw SkillsDirectoryError.needsKey }
        let path = ranking == .official ? "api/v1/skills/curated" : "api/v1/skills"
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "per_page", value: String(perPage)), URLQueryItem(name: "page", value: String(page))]
        if ranking != .official { items.append(URLQueryItem(name: "view", value: ranking.rawValue)) }
        components.queryItems = items
        let skills = try Self.decodeRanked(try await get(components.url!))
        return ranking == .official ? skills.map { var skill = $0; skill.official = true; return skill } : skills
    }

    /// A skill's files, for its preview.
    public func files(of skill: DirectorySkill) async throws -> [DirectoryFile] {
        let parts = skill.source.split(separator: "/").map(String.init)
        guard parts.count == 2 else { throw SkillsDirectoryError.unavailable("skills.sh has no files for \(skill.source).") }
        let url = base.appendingPathComponent("api/download").appendingPathComponent(parts[0])
            .appendingPathComponent(parts[1]).appendingPathComponent(skill.slug)
        return try Self.decodeFiles(try await get(url))
    }

    /// The skill's page on skills.sh.
    public static func page(of skill: DirectorySkill) -> URL {
        home.appendingPathComponent(skill.source).appendingPathComponent(skill.slug)
    }

    // MARK: Decoding

    private struct SearchReply: Decodable {
        struct Item: Decodable {
            var id: String
            var name: String?
            var source: String?
            var installs: Int?
        }
        var skills: [Item]
    }

    private struct RankedReply: Decodable {
        struct Item: Decodable {
            var id: String?
            var slug: String?
            var name: String?
            var source: String?
            var installs: Int?
        }
        var data: [Item]
    }

    private struct FilesReply: Decodable {
        var files: [DirectoryFile]
    }

    static func decodeSearch(_ data: Data) throws -> [DirectorySkill] {
        let reply = try JSONDecoder().decode(SearchReply.self, from: data)
        return reply.skills.compactMap { item in
            guard let source = item.source, !source.isEmpty else { return nil }
            return DirectorySkill(slug: item.id, name: item.name ?? item.id, source: source, installs: item.installs ?? 0)
        }
        .sorted { $0.installs > $1.installs }
    }

    static func decodeRanked(_ data: Data) throws -> [DirectorySkill] {
        let reply = try JSONDecoder().decode(RankedReply.self, from: data)
        return reply.data.compactMap { item in
            guard let slug = item.slug ?? item.id, let source = item.source, !source.isEmpty else { return nil }
            return DirectorySkill(slug: slug, name: item.name ?? slug, source: source, installs: item.installs ?? 0)
        }
    }

    static func decodeFiles(_ data: Data) throws -> [DirectoryFile] {
        try JSONDecoder().decode(FilesReply.self, from: data).files
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SkillsDirectoryError.unavailable("Couldn't reach skills.sh.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        if status == 401 || status == 403 { throw SkillsDirectoryError.needsKey }
        guard (200..<300).contains(status) else { throw SkillsDirectoryError.unavailable("skills.sh answered \(status).") }
        return data
    }
}

extension DirectoryFile: Decodable {
    private enum CodingKeys: String, CodingKey { case path, contents }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        contents = try c.decodeIfPresent(String.self, forKey: .contents) ?? ""
    }
}

/// Install counts as skills.sh writes them: "3.6M", "312K", "8.4K", "980".
public enum DirectoryPresentation {
    public static func installs(_ count: Int) -> String {
        switch count {
        case ..<1_000: return "\(count)"
        case ..<10_000: return trimmed(Double(count) / 1_000) + "K"
        case ..<1_000_000: return "\(Int((Double(count) / 1_000).rounded()))K"
        default: return trimmed(Double(count) / 1_000_000) + "M"
        }
    }

    /// "71K installs · updated Sep 16", without the date when skills.sh doesn't say.
    public static func meta(_ skill: DirectorySkill) -> String {
        "\(installs(skill.installs)) installs"
    }

    /// The parts of a name that match a search, for highlighting ("supabase-[postgres]-best…").
    public static func matches(of query: String, in name: String) -> [Range<String.Index>] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var start = name.startIndex
        while start < name.endIndex, let found = name.range(of: needle, options: [.caseInsensitive], range: start..<name.endIndex) {
            ranges.append(found)
            start = found.upperBound
        }
        return ranges
    }

    private static func trimmed(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }
}
