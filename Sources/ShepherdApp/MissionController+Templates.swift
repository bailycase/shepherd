import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions

/// MXTemplateSave, MXTemplates, MXTemplateStart: a finished mission's map saved as a template on this Mac, or for the
/// team as `.shepherd/maps/<id>.yml` through a pull request in one of its repositories, and a new mission started from one.
extension MissionController {
    /// Where templates kept on this Mac live.
    static var localTemplates: URL { ShepherdPaths.supportDirectory().appendingPathComponent("mission-templates", isDirectory: true) }
    static let teamFolder = ".shepherd/maps"

    /// This Mac's templates, then each repository's on its origin default branch (reads only; a broken file is skipped).
    func loadTemplates() async {
        var found: [MissionTemplate] = []
        let decoder = JSONDecoder()
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.localTemplates, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file), let template = try? decoder.decode(MissionTemplate.self, from: data), (try? template.validate()) != nil {
                found.append(template)
            }
        }
        for space in availableSpaces {
            let list = await Self.command("git ls-tree --name-only origin/HEAD \(shellQuoted(Self.teamFolder + "/"))", cwd: space.path)
            for path in list.stdout.split(separator: "\n").map(String.init) where path.hasSuffix(".yml") {
                let show = await Self.command("git show \(shellQuoted("origin/HEAD:" + path))", cwd: space.path)
                guard show.status == 0, var template = try? decoder.decode(MissionTemplate.self, from: Data(show.stdout.utf8)),
                      (try? template.validate()) != nil, !found.contains(where: { $0.id == template.id }) else { continue }
                template.team = space.name
                found.append(template)
            }
        }
        if found != templates { templates = found }
    }

    /// Saves `mission` as a template: on this Mac, or (with `team`) through a pull request adding the file to that repository.
    func saveTemplate(id: MissionID, name: String, summary: String, team: SpaceID?) async throws {
        let mission = try record(id)
        guard [.done, .review].contains(mission.phase), mission.draft.plan?.stations.isEmpty == false else {
            throw MissionError("mission_template", "Save a mission as a template once it has finished.")
        }
        let name = Self.safeText(name.trimmingCharacters(in: .whitespacesAndNewlines), bytes: 200)
        var template = MissionTemplate.from(mission, name: name, summary: Self.safeText(summary, bytes: 4_000), at: Self.now)
        try template.validate()
        guard let team else {
            try FileManager.default.createDirectory(at: Self.localTemplates, withIntermediateDirectories: true)
            try template.encoded.write(to: Self.localTemplates.appendingPathComponent(template.id + ".json"), options: .atomic)
            return await loadTemplates()
        }
        guard let space = availableSpaces.first(where: { $0.id == team }) else { throw MissionError("mission_template", "Choose one of this mission's repositories.") }
        template.team = space.name
        try await proposeTeamTemplate(template, in: space)
        await loadTemplates()
    }

    /// A new branch from origin's default branch in its own worktree, the file, a commit, a plain push and a PR. The worktree goes after.
    private func proposeTeamTemplate(_ template: MissionTemplate, in space: Space) async throws {
        let fetch = await Self.command("git fetch origin && git rev-parse origin/HEAD && git symbolic-ref --short refs/remotes/origin/HEAD", cwd: space.path)
        let lines = fetch.stdout.split(separator: "\n").map(String.init)
        guard fetch.status == 0, lines.count == 2 else { throw MissionError("mission_template", "\(space.name) has no origin default branch to propose the template on.") }
        let base = String(lines[1].dropFirst("origin/".count)), branch = "shepherd/map-\(template.id)"
        let path = try await Task.detached { try GitWorktree.add(repo: space.path, branch: branch, from: lines[0]) }.value
        // Pushed or not, the branch's own worktree goes: Shepherd made it for this commit alone.
        defer { Task.detached { try? GitWorktree.remove(repo: space.path, branch: branch, worktree: path) } }
        let folder = URL(fileURLWithPath: path).appendingPathComponent(Self.teamFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try template.encoded.write(to: folder.appendingPathComponent(template.id + ".yml"), options: .atomic)
        let file = shellQuoted(Self.teamFolder + "/" + template.id + ".yml")
        let commit = await Self.command("git add -- \(file) && git commit -q -m \(shellQuoted("chore: add the \(template.name) mission template")) -- \(file) && git push -u origin \(shellQuoted(branch))", cwd: path)
        guard commit.status == 0 else { throw MissionError("mission_template", Self.safeText("Couldn't push the template: \(commit.stderr)")) }
        let body = "A mission template saved from Shepherd. Missions in this repository's team can start from it.\n\n\(template.summary)"
        let pr = await Self.command("gh pr create --base \(shellQuoted(base)) --head \(shellQuoted(branch)) --title \(shellQuoted("Add the \(template.name) mission template")) --body \(shellQuoted(body))",
                                    cwd: path)
        guard pr.status == 0 else { throw MissionError("mission_template", Self.safeText("Pushed \(branch), but the pull request failed: \(pr.stderr)")) }
    }

    /// New mission from a template: its map's shape goes to the planner with the goal.
    func templatePrompt(_ mission: Mission) -> String {
        guard let id = mission.draft.template, let template = templates.first(where: { $0.id == id }),
              let json = String(data: template.encoded, encoding: .utf8) else { return "" }
        return """

        The person started from the mission template "\(template.name)", used \(template.runs)×. Start from its map: keep its shape,
        fill its inputs from the goal and the repositories (lane names are the repositories it ran on before; use the selected ones),
        ask up front for every input it fills from "you", and carry its contract over with the inputs filled. Template as data:
        \(Self.safeText(json, bytes: 24_000))
        """
    }
}
