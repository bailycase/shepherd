import Foundation
import ShepherdProtocol

/// Settings ▸ Skills in words, the same on the Mac, the iPhone and the iPad.
public enum SkillsPresentation {
    /// A day as the list shows it: "Sep 18".
    public static func date(_ seconds: Double) -> String {
        Date(timeIntervalSince1970: seconds).formatted(.dateTime.month(.abbreviated).day())
    }

    /// "Checked 2h ago", "Checked just now", "Not checked yet".
    public static func checkedLine(_ checkedAt: Double?, now: Date = Date()) -> String {
        guard let checkedAt else { return "Not checked yet" }
        let seconds = max(0, now.timeIntervalSince1970 - checkedAt)
        switch seconds {
        case ..<60: return "Checked just now"
        case ..<3_600: return "Checked \(Int(seconds / 60))m ago"
        case ..<86_400: return "Checked \(Int(seconds / 3_600))h ago"
        default: return "Checked \(Int(seconds / 86_400))d ago"
        }
    }

    /// The Source column: the repository, From your pi for a skill copied from the user's own pi,
    /// or Local for a folder copied in by hand.
    public static func source(_ skill: InstalledSkill) -> String {
        skill.source?.repo ?? (skill.copiedFrom != nil ? "From your pi" : "Local")
    }

    /// A skill with no repository, in its Source tooltip and its detail: where it came from, and
    /// that it never updates on its own.
    public static func unmanagedNote(_ skill: InstalledSkill) -> String {
        guard let from = skill.copiedFrom else { return "Copied into the skills folder by hand. It never updates." }
        return "Copied from your pi (\(tilde(from))). It changes only when you re-import skills in Settings ▸ Pi."
    }

    /// `path` with the user's home as `~`.
    static func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// The Use column: "Auto" or "/skill only".
    public static func use(_ invocation: SkillInvocation) -> String {
        invocation == .automatic ? "Auto" : "/skill only"
    }

    /// How the agent uses a skill, as a picker names it: "Automatically", "Only with /skill".
    public static func invocationTitle(_ invocation: SkillInvocation) -> String {
        invocation == .automatic ? "Automatically" : "Only with /skill"
    }

    /// Only with /skill's option in the detail: "Only when I type /skill:pdf".
    public static func slashOption(_ name: String) -> String {
        "Only when I type /skill:\(name)"
    }

    /// Automatically's note: what the skill's description costs in every prompt.
    public static func automaticNote(_ skill: InstalledSkill, directory: String = "~/.agents/skills") -> String {
        let tokens = SkillsText.rounded(SkillsText.promptTokens(name: skill.name, summary: skill.summary, directory: directory))
        return "The agent reads it when a task calls for it. Its description sits in every prompt, about \(tokens) tokens."
    }

    /// The version's installed line: "Installed 3f2a91c · Aug 30".
    public static func installed(_ source: SkillSource) -> (commit: String, date: String?) {
        (SkillsText.shortCommit(source.commit), source.committedAt.map(date))
    }

    /// The version's new line: "New 8c04e1d · Sep 22 · 3 files changed".
    public static func newer(_ update: SkillUpdate) -> (commit: String, detail: String) {
        let files = "\(update.filesChanged) \(update.filesChanged == 1 ? "file" : "files") changed"
        return (SkillsText.shortCommit(update.commit), [update.committedAt.map(date), files].compactMap { $0 }.joined(separator: " · "))
    }

    /// The In every prompt card's note: "6 automatic skills. Full files load only when used."
    public static func automaticCount(_ skills: [InstalledSkill]) -> String {
        automaticCount(skills.filter { $0.isOn && $0.invocation == .automatic }.count)
    }

    /// The same for a count of automatic skills the agent loads.
    public static func automaticCount(_ count: Int) -> String {
        guard count > 0 else { return "No automatic skills. Only /skill loads one." }
        return "\(count) automatic \(count == 1 ? "skill" : "skills"). Full files load only when used."
    }

    // MARK: pi's own skills

    /// A read-only group's title.
    public static func groupTitle(_ kind: PiSkillGroup.Kind) -> String {
        switch kind {
        case .setup: "From your pi setup"
        case .packages: "From pi packages"
        }
    }

    /// Why a group is read-only, for its tooltip.
    public static func groupNote(_ kind: PiSkillGroup.Kind) -> String {
        switch kind {
        case .setup: "In pi’s own folder or named in its settings. Shepherd lists them and never changes them."
        case .packages: "Brought by the packages in pi’s settings. pi installs and updates them."
        }
    }

    /// A pi skill's Source column: its package, or the folder that holds it ("~/.pi/agent/skills").
    public static func source(_ skill: PiSkill) -> String {
        skill.origin == .package ? (skill.package ?? "package") : folder(of: skill.path)
    }

    /// Why a skill is listed but not used: "Not used: pi uses the one in ~/.pi/agent/skills."
    public static func shadowNote(_ winner: String) -> String {
        "Not used: pi uses the one in \(folder(of: winner))."
    }

    /// The folder a skill sits in: SKILL.md's folder's parent, or a lone file's folder.
    public static func folder(of path: String) -> String {
        let file = path as NSString
        let folder = file.deletingLastPathComponent
        return file.lastPathComponent == "SKILL.md" ? (folder as NSString).deletingLastPathComponent : folder
    }

    /// Why pi's own skills couldn't be listed, from `PiSkills.problem`.
    public static func piProblem(_ problem: String) -> String {
        switch PiSkills.Problem(rawValue: problem) {
        case .piNotFound: "Couldn’t find pi, so the skills from your pi setup aren’t listed."
        case .nodeNotFound: "Couldn’t find node to ask pi for its skills."
        case .piUnsupported: "This pi is too old to list its skills here. Update pi in Settings ▸ Pi."
        case .timedOut: "pi took too long to list its skills."
        case .failed, nil: "Couldn’t read the skills from your pi setup."
        }
    }

    /// Under the list: why a repository's own skills aren't here.
    public static let repositorySkillsNote =
        "A repository’s own skills (.shepherd/skills, .pi/skills, .agents/skills) load only in that repository’s threads, so they aren’t listed here."

    /// One of pi's own skills under its name on the phone: "Not used: …" when pi passes it over,
    /// else "/skill only · …" or its description.
    public static func mobileSummary(_ skill: PiSkill) -> String {
        if let winner = skill.shadowedBy { return shadowNote(winner) }
        return skill.invocation == .slashOnly ? "/skill only · \(skill.summary)" : skill.summary
    }

    /// Under the phone's read-only groups: whose pi they come from, and where a repository's own
    /// skills are.
    public static func piFootnote(host: String) -> String {
        "Read-only: from \(host)’s own pi, which Shepherd never changes. " + repositorySkillsNote
    }

    /// A host that predates reporting pi's own skills.
    public static func piNotReported(_ host: String) -> String {
        "\(host)’s Shepherd doesn’t list the skills from its pi setup. Update it to see them here."
    }

    /// The Settings list's value on the iPhone and the iPad: "8 · 2 updates", "8", "None".
    public static func settingsValue(_ rows: [SkillRow]) -> String {
        guard !rows.isEmpty else { return "None" }
        let updates = rows.filter { $0.skill.update != nil }.count
        return updates == 0 ? "\(rows.count)" : "\(rows.count) · \(updates) \(updates == 1 ? "update" : "updates")"
    }

    /// A skill's line under its name on the phone: "/skill only · House style for…".
    public static func mobileSummary(_ skill: InstalledSkill) -> String {
        skill.invocation == .slashOnly ? "/skill only · \(skill.summary)" : skill.summary
    }

    /// A search's line over its results: "12 skills for “pdf”".
    public static func results(_ count: Int, for query: String) -> String {
        "\(count) \(count == 1 ? "skill" : "skills") for “\(query.trimmingCharacters(in: .whitespaces))”"
    }

    /// A result's line under its name on the phone: "anthropics/skills · 71K installs".
    public static func resultMeta(_ skill: DirectorySkill) -> String {
        "\(skill.source) · \(DirectoryPresentation.meta(skill))"
    }

    /// An install's headline: "Installing", "Installed", or why it failed.
    public static func installLine(_ install: SkillInstall) -> String {
        switch install.state {
        case .installing: "Installing"
        case .installed: "Installed"
        case .failed(let reason): reason
        }
    }

    /// A looked-up repository: "16 skills · main @ 8c04e1d".
    public static func repoLine(_ repo: RepoSkills) -> String {
        "\(repo.skills.count) \(repo.skills.count == 1 ? "skill" : "skills") · \(repo.branch) @ \(SkillsText.shortCommit(repo.commit))"
    }

    /// The picker's header: "3 of 13 new skills".
    public static func selection(_ picked: Int, new: Int) -> String {
        "\(picked) of \(new) new \(new == 1 ? "skill" : "skills")"
    }

    /// The install button: "Install 3 skills", "Install 1 skill".
    public static func installTitle(_ count: Int) -> String {
        "Install \(count) \(count == 1 ? "skill" : "skills")"
    }

    /// What a skill's scripts are, under its files: "3 scripts the agent can run: a.py, b.py,
    /// c.py", "4 scripts the agent can run, in Python.", "No scripts. Instructions and references
    /// only." `paths` are the skill's files, relative to its folder.
    public static func scriptsNote(paths: [String]) -> String {
        let scripts = paths.filter { $0.hasPrefix("scripts/") }
        guard !scripts.isEmpty else { return "No scripts. Instructions and references only." }
        let names = scripts.map { ($0 as NSString).lastPathComponent }
        let count = "\(scripts.count) \(scripts.count == 1 ? "script" : "scripts") the agent can run"
        if names.count <= 3 { return "\(count): \(names.joined(separator: ", "))" }
        if let language = language(of: names) { return "\(count), in \(language)." }
        return "\(count)."
    }

    /// The same from a folder's top level, when only its folders' sizes are known.
    public static func scriptsNote(entries: [SkillFileEntry]) -> String {
        guard let scripts = entries.first(where: { $0.isDirectory && $0.name == "scripts" }), scripts.fileCount > 0 else {
            return "No scripts. Instructions and references only."
        }
        return "\(scripts.fileCount) \(scripts.fileCount == 1 ? "script" : "scripts") the agent can run."
    }

    /// A file chip's label: "SKILL.md", "scripts/".
    public static func chip(_ entry: SkillFileEntry) -> String {
        entry.isDirectory ? entry.name + "/" : entry.name
    }

    /// The Remove toast: "Removed pdf".
    public static func removed(_ removal: ClientSkills.Removal) -> String {
        "Removed \(removal.name)"
    }

    // MARK: Private

    private static func language(of names: [String]) -> String? {
        let languages = ["py": "Python", "sh": "shell", "js": "JavaScript", "mjs": "JavaScript", "ts": "TypeScript", "rb": "Ruby",
                         "go": "Go", "swift": "Swift"]
        var counts: [String: Int] = [:]
        for name in names {
            if let language = languages[(name as NSString).pathExtension.lowercased()] { counts[language, default: 0] += 1 }
        }
        guard let top = counts.max(by: { $0.value < $1.value }), top.value * 2 > names.count else { return nil }
        return top.key
    }
}
