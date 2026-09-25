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

    /// The Source column: the repository, or Local for a folder copied in by hand.
    public static func source(_ skill: InstalledSkill) -> String {
        skill.source?.repo ?? "Local"
    }

    /// The Use column: "Auto" or "/skill only".
    public static func use(_ invocation: SkillInvocation) -> String {
        invocation == .automatic ? "Auto" : "/skill only"
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

    /// Where one host is with a skill, in the detail's Hosts.
    public static func copy(_ state: SkillCopy.State) -> String {
        switch state {
        case .installed: "installed"
        case .updating: "updating"
        case .checking: "checking"
        case .missing: "not installed"
        case .owed: "offline · updates later"
        case .offline: "offline"
        case .unsupported: "needs a newer Shepherd"
        }
    }

    /// A host in the side rail: "up to date", "2 updates", "offline".
    public static func host(_ state: HostSkills, owed: Bool) -> String {
        switch state {
        case .offline: return owed ? "offline · catches up" : "offline"
        case .unsupported: return "needs a newer Shepherd"
        case .loading: return "checking"
        case .failed: return "couldn't read"
        case .loaded(let snapshot):
            let updates = snapshot.skills.filter { $0.update != nil }.count
            return updates == 0 ? "up to date" : "\(updates) \(updates == 1 ? "update" : "updates")"
        }
    }

    /// The In every prompt card's note: "6 automatic skills. Full files load only when used."
    public static func automaticCount(_ skills: [InstalledSkill]) -> String {
        let count = skills.filter { $0.isOn && $0.invocation == .automatic }.count
        guard count > 0 else { return "No automatic skills. Only /skill loads one." }
        return "\(count) automatic \(count == 1 ? "skill" : "skills"). Full files load only when used."
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

    /// An install's headline: "Installing · 1 of 3 hosts", "Installed on 3 hosts", "Installed ·
    /// horizon when it's back".
    public static func installLine(_ install: SkillInstall) -> String {
        let total = install.steps.count
        if install.isRunning { return "Installing · \(install.installed) of \(total) \(total == 1 ? "host" : "hosts")" }
        if let failure = install.failure, install.installed == 0 { return failure }
        let waiting = install.steps.filter { $0.state == .owed }.map(\.name)
        if !waiting.isEmpty { return "Installed · \(list(waiting)) when \(waiting.count == 1 ? "it's" : "they're") back" }
        return total == 1 ? "Installed" : "Installed on \(install.installed) of \(total) hosts"
    }

    /// One host's step in an install.
    public static func step(_ state: SkillInstall.Step.State) -> String {
        switch state {
        case .waiting: "waiting"
        case .copying: "copying files"
        case .installed: "installed · ready in new threads"
        case .owed: "offline · installs when it's back"
        case .failed(let reason): reason
        }
    }

    /// Where an install goes, beside its button: "This Mac, build-01 now · horizon when it's back".
    public static func destinations(_ hosts: [SkillsHost]) -> String {
        let now = hosts.filter(\.isConnected).map(\.name)
        let later = hosts.filter { !$0.isConnected }.map(\.name)
        var parts: [String] = []
        if !now.isEmpty { parts.append("\(list(now)) now") }
        if !later.isEmpty { parts.append("\(list(later)) when \(later.count == 1 ? "it's" : "they're") back") }
        return parts.joined(separator: " · ")
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

    /// The Remove toast: "Removed pdf from every host".
    public static func removed(_ removal: ClientSkills.Removal) -> String {
        removal.hosts.count > 1 ? "Removed \(removal.name) from every host" : "Removed \(removal.name)"
    }

    // MARK: Private

    private static func list(_ names: [String]) -> String {
        names.joined(separator: ", ")
    }

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
