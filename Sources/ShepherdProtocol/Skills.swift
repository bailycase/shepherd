import Foundation

// Settings ▸ Skills: the agent skills (Agent Skills: a folder with a SKILL.md) every pi session on a
// host can use. Skills are global: they live in the host's ~/.agents/skills, which pi reads at
// startup, and Shepherd keeps every host's set the same. A skill that is off waits in Shepherd's
// support directory instead, out of pi's sight; a skill used only through /skill:name carries
// `disable-model-invocation: true` in its installed SKILL.md. A host installs a skill from its
// git repository itself (`RemoteSkillsRequest.install`), so a skill's files never cross the
// remote protocol, except a folder copied from another Mac (`installFiles`). Remote clients read
// and change a host's skills over `RemoteRequest.skills` (`RemoteProtocol.skillsCapability`).
// docs/skills.md has the whole design.

/// How the agent may use a skill.
public enum SkillInvocation: String, Codable, Hashable, Sendable, CaseIterable {
    /// The agent sees its name and description in every prompt and reads it when a task calls
    /// for it.
    case automatic
    /// Out of the agent's prompt until someone types /skill:name
    /// (`disable-model-invocation: true`).
    case slashOnly
}

/// Where an installed skill came from: its folder in a git repository, at one commit.
public struct SkillSource: Codable, Hashable, Sendable {
    /// "anthropics/skills" for a GitHub repository, else the repository's URL.
    public var repo: String
    /// The skill's folder in the repository ("skills/pdf"); empty when the repository is the skill.
    public var path: String
    public var commit: String
    /// When that commit was made, in seconds since 1970.
    public var committedAt: Double?

    public init(repo: String, path: String, commit: String, committedAt: Double? = nil) {
        self.repo = repo
        self.path = path
        self.commit = commit
        self.committedAt = committedAt
    }
}

/// A newer commit of an installed skill's folder, waiting to be installed.
public struct SkillUpdate: Codable, Hashable, Sendable {
    public var commit: String
    public var committedAt: Double?
    /// Files that differ in the skill's folder between the installed commit and this one.
    public var filesChanged: Int

    public init(commit: String, committedAt: Double? = nil, filesChanged: Int) {
        self.commit = commit
        self.committedAt = committedAt
        self.filesChanged = filesChanged
    }
}

/// One entry at the top of a skill's folder: "SKILL.md", or "scripts/" holding 8 files.
public struct SkillFileEntry: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var isDirectory: Bool
    /// The files inside a directory, at any depth; 1 for a file.
    public var fileCount: Int

    public init(name: String, isDirectory: Bool = false, fileCount: Int = 1) {
        self.name = name
        self.isDirectory = isDirectory
        self.fileCount = fileCount
    }

    public var id: String { name }
}

/// A skill on a host, on or off.
public struct InstalledSkill: Codable, Hashable, Sendable, Identifiable {
    /// Its folder's name, which names it everywhere (`/skill:name`).
    public var name: String
    /// SKILL.md's `description`: what the agent matches tasks against.
    public var summary: String
    public var isOn: Bool
    public var invocation: SkillInvocation
    /// nil for a Local skill: one copied into the folder by hand, which never updates.
    public var source: SkillSource?
    /// When it last changed on the host (installed, updated, or its folder modified), in seconds
    /// since 1970.
    public var updatedAt: Double
    public var files: [SkillFileEntry]
    /// A newer commit of its folder, once an update check found one.
    public var update: SkillUpdate?

    public init(name: String, summary: String, isOn: Bool = true, invocation: SkillInvocation = .automatic,
                source: SkillSource? = nil, updatedAt: Double, files: [SkillFileEntry] = [], update: SkillUpdate? = nil) {
        self.name = name
        self.summary = summary
        self.isOn = isOn
        self.invocation = invocation
        self.source = source
        self.updatedAt = updatedAt
        self.files = files
        self.update = update
    }

    public var id: String { name }
}

/// A host's skills (`RemoteSkillsResult.skills`).
public struct SkillsSnapshot: Codable, Hashable, Sendable {
    /// Where the host's skills live, with its home as `~` ("~/.agents/skills").
    public var directory: String
    /// By name.
    public var skills: [InstalledSkill]
    /// When the host last checked its skills' repositories for newer commits, in seconds since
    /// 1970.
    public var checkedAt: Double?
    /// The host installs a newer commit as soon as a check finds one (Update automatically).
    public var autoUpdate: Bool

    public init(directory: String, skills: [InstalledSkill] = [], checkedAt: Double? = nil, autoUpdate: Bool = false) {
        self.directory = directory
        self.skills = skills
        self.checkedAt = checkedAt
        self.autoUpdate = autoUpdate
    }

    private enum CodingKeys: String, CodingKey {
        case directory, skills, checkedAt, autoUpdate
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        directory = try c.decode(String.self, forKey: .directory)
        skills = try c.decodeIfPresent([InstalledSkill].self, forKey: .skills) ?? []
        checkedAt = try c.decodeIfPresent(Double.self, forKey: .checkedAt)
        autoUpdate = try c.decodeIfPresent(Bool.self, forKey: .autoUpdate) ?? false
    }

    public func skill(_ name: String) -> InstalledSkill? {
        skills.first { $0.name == name }
    }
}

/// A skill found in a repository (Add from repo).
public struct RepoSkill: Codable, Hashable, Sendable, Identifiable {
    /// Its folder in the repository ("skills/docx"); empty when the repository is the skill.
    public var path: String
    public var name: String
    public var summary: String
    /// SKILL.md's text, cut short for a preview.
    public var instructions: String
    public var files: [SkillFileEntry]

    public init(path: String, name: String, summary: String, instructions: String = "", files: [SkillFileEntry] = []) {
        self.path = path
        self.name = name
        self.summary = summary
        self.instructions = instructions
        self.files = files
    }

    public var id: String { path }
}

/// A repository looked up for its skills (`RemoteSkillsResult.repo`).
public struct RepoSkills: Codable, Hashable, Sendable {
    /// As the user named it, normalized: "anthropics/skills", or its URL.
    public var repo: String
    public var branch: String
    public var commit: String
    public var skills: [RepoSkill]

    public init(repo: String, branch: String, commit: String, skills: [RepoSkill] = []) {
        self.repo = repo
        self.branch = branch
        self.commit = commit
        self.skills = skills
    }
}

/// One file of a skill copied from another Mac's folder (`RemoteSkillsRequest.installFiles`).
public struct SkillFile: Codable, Hashable, Sendable {
    /// The most a copied folder may hold in all: its files travel base64 in one request, under
    /// the 1 MiB frame cap.
    public static let maxTotalBytes = 640 * 1024

    /// Relative to the skill's folder ("scripts/run.sh").
    public var path: String
    public var contents: Data
    public var executable: Bool

    public init(path: String, contents: Data, executable: Bool = false) {
        self.path = path
        self.contents = contents
        self.executable = executable
    }
}

/// Settings ▸ Skills on a host (`RemoteProtocol.skillsCapability`). Every request answers with
/// the host's skills as they are afterwards, except `lookUp`, which answers with the repository's.
public enum RemoteSkillsRequest: Codable, Hashable, Sendable {
    case fetch
    /// The skills in a repository ("anthropics/skills", a GitHub URL, any git URL) at its
    /// default branch's newest commit.
    case lookUp(repo: String)
    /// Installs the skills at `paths` in a repository, at `commit` (nil: the newest on its
    /// default branch), replacing a skill of the same name where it is (on or off).
    /// `invocation` nil keeps an installed skill's choice (automatic for a new one).
    case install(repo: String, paths: [String], commit: String?, invocation: SkillInvocation?)
    /// Installs a skill from its files: a folder copied from another Mac.
    case installFiles(name: String, files: [SkillFile], invocation: SkillInvocation)
    case setOn(name: String, on: Bool)
    case setInvocation(name: String, invocation: SkillInvocation)
    /// Takes a skill off the host; `restore` puts it back.
    case remove(name: String)
    case restore(name: String)
    /// Looks for newer commits of every skill's folder in its repository.
    case checkUpdates
    /// Update automatically: install a newer commit as soon as a check finds one.
    case configure(autoUpdate: Bool)
}

extension RemoteSkillsRequest {
    /// Whether the request can change the host's skills (a read or a look-up can't).
    public var changesSkills: Bool {
        switch self {
        case .fetch, .lookUp: false
        default: true
        }
    }
}

/// A skills request's answer (`RemoteReply.skills`).
public enum RemoteSkillsResult: Codable, Hashable, Sendable {
    case skills(SkillsSnapshot)
    case repo(RepoSkills)
}
