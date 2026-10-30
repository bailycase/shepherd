import CryptoKit
import Foundation

/// Stock GitHub Spec Kit commands as the upstream `pi` integration installs them
/// (`.pi/prompts/speckit.<name>.md`). Shepherd only sends the invocation; pi expands the
/// project's own file, so upstream text, presets and customizations stay authoritative.
public enum SpecKitCommand: String, Codable, Sendable, CaseIterable {
    case constitution, specify, clarify, plan, tasks, analyze, checklist, implement, converge

    /// The four core commands a project must provide before a Spec Kit mission can run.
    public static let required: [SpecKitCommand] = [.specify, .plan, .tasks, .implement]

    public var promptPath: String { ".pi/prompts/speckit.\(rawValue).md" }

    /// The map station a planning step's receipt belongs to: plan and tasks have their own, analyze checks the
    /// task list, and everything before the spec is settled (constitution, specify, clarify) is the spec's.
    public var planningStation: String {
        switch self {
        case .plan: "plan"
        case .tasks, .analyze: "tasks"
        default: "specify"
        }
    }

    /// Upstream `IntegrationBase.build_command_invocation`: `/speckit.<stem>`, then a space and the arguments.
    public func invocation(_ arguments: String) -> String {
        let arguments = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        return arguments.isEmpty ? "/speckit.\(rawValue)" : "/speckit.\(rawValue) \(arguments)"
    }
}

/// Per-repository Spec Kit state. Each repository keeps its own stock project and feature;
/// Shepherd adds no cross-repository artifact.
public struct MissionSpecKitLane: Codable, Hashable, Sendable, Identifiable {
    public var spaceID: SpaceID
    /// Relative to the repository root, as upstream writes to `.specify/feature.json`.
    public var featureDirectory: String?
    /// The preflight fingerprint the owner explicitly consented to load. Any change voids it.
    public var consentFingerprint: String?
    /// Relative path → SHA-256 of the artifacts the owner approved at Launch: implement's authorized inputs.
    public var approvedArtifacts: [String: String]?
    /// The same artifacts as the host last observed them after an owned turn under that approval
    /// (approval itself, then a finished implement or converge). Implement legitimately writes into the
    /// feature (checks tasks off, fills contracts); those are its outputs and review evidence, not new
    /// authorization. Every later turn and resume requires the files to still match this observation, so a
    /// change made outside the mission's own turns fails closed. Nil on older records: approval is used.
    public var observedArtifacts: [String: String]?
    /// The persistent planning thread stock commands and replies go to.
    public var plannerAgentID: AgentID?
    /// The latest /speckit.converge result. Only the owner's explicit acceptance of the real report
    /// resolves it; acceptance is an acknowledgement, never test evidence.
    public var convergence: MissionSpecKitConvergence?
    public var id: SpaceID { spaceID }

    public init(spaceID: SpaceID, featureDirectory: String? = nil, consentFingerprint: String? = nil,
                approvedArtifacts: [String: String]? = nil, plannerAgentID: AgentID? = nil) {
        self.spaceID = spaceID; self.featureDirectory = featureDirectory; self.consentFingerprint = consentFingerprint
        self.approvedArtifacts = approvedArtifacts; self.plannerAgentID = plannerAgentID
    }

    public func validate() throws {
        guard featureDirectory.map(SpecKit.isSafeRelativePath) ?? true,
              consentFingerprint.map({ $0.utf8.count <= 128 }) ?? true,
              [approvedArtifacts, observedArtifacts].allSatisfy({ $0.map { $0.count <= 512 && $0.allSatisfy { SpecKit.isSafeRelativePath($0.key) && $0.value.utf8.count <= 128 } } ?? true }) else {
            throw MissionError("invalid_mission_run", "Invalid Spec Kit lane record.")
        }
    }
}

public struct MissionSpecKitConvergence: Codable, Hashable, Sendable {
    public var attemptID: UUID
    public var outcome: SpecKitConvergeOutcome
    public var accepted: Bool
    public init(attemptID: UUID, outcome: SpecKitConvergeOutcome, accepted: Bool = false) {
        self.attemptID = attemptID; self.outcome = outcome; self.accepted = accepted
    }
}

public struct MissionSpecKitRun: Codable, Hashable, Sendable {
    public var lanes: [MissionSpecKitLane]
    public init(lanes: [MissionSpecKitLane] = []) { self.lanes = lanes }

    public subscript(space: SpaceID) -> MissionSpecKitLane? { lanes.first { $0.spaceID == space } }

    public func validate() throws {
        guard lanes.count <= 32, Set(lanes.map(\.spaceID)).count == lanes.count else {
            throw MissionError("invalid_mission_run", "Invalid Spec Kit lanes.")
        }
        try lanes.forEach { try $0.validate() }
    }
}

/// What a Spec Kit mission's own agent launches with: the consented stock prompt folder and the
/// feature it continues. Nothing else is configurable through this path.
public struct MissionSpecKitLaunch: Hashable, Sendable {
    public var promptDirectory: String
    public var featureDirectory: String?
}

public extension ShepherdState {
    /// Only for an agent reserved by a running Spec Kit attempt, in its lane's own worktree, after the
    /// owner consented to that lane's stock files. Everything else launches exactly as before.
    func specKitLaunch(for agent: AgentID, cwd: String) -> MissionSpecKitLaunch? {
        for mission in missions {
            guard let run = mission.run, let specKit = run.specKit,
                  run.attempts.contains(where: { $0.agentID == agent && $0.status == .running && $0.command != nil }),
                  let checkout = run.checkouts.first(where: { $0.path == cwd }),
                  let lane = specKit[checkout.spaceID], lane.consentFingerprint != nil else { continue }
            return MissionSpecKitLaunch(promptDirectory: (cwd as NSString).appendingPathComponent(".pi/prompts"),
                                        featureDirectory: lane.featureDirectory)
        }
        return nil
    }
}

public struct SpecKitHook: Codable, Hashable, Sendable {
    public var event: String
    public var extensionID: String?
    public var command: String
    public var optional: Bool
    public var enabled: Bool
    public var condition: String?
}

/// What a repository's own files say, read without running anything.
public struct SpecKitPreflight: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// Required stock prompts present and no ownership conflict. Still needs owner consent.
        case ready
        /// No `.specify/` project. Initializing is the owner's explicit, separate step.
        case notInitialized
        /// A Spec Kit project without the `pi` integration's prompts.
        case piIntegrationMissing
        /// No longer produced (feature-branch hooks are adopted); kept so older records decode.
        case blocked
    }
    public var status: Status
    /// Version recorded in project metadata. Metadata alone verifies nothing.
    public var recordedVersion: String?
    /// The release Shepherd's acceptance tests ran against.
    public var testedVersion: String
    /// True only when metadata names the tested release and every pi prompt file still matches its install manifest.
    public var matchesTestedRelease: Bool
    public var scriptType: String?
    public var integrations: [String]
    public var defaultIntegration: String?
    public var missingCommands: [SpecKitCommand]
    /// Managed files whose bytes differ from the manifest: user customizations, used as-is.
    public var customizedFiles: [String]
    public var hooks: [SpecKitHook]
    public var ownershipConflicts: [String]
    public var warnings: [String]
    /// What owner consent binds to: stock prompts, scripts, templates, presets, extensions and hooks.
    public var consentFingerprint: String
}

public struct SpecKitTask: Codable, Hashable, Sendable {
    public var id: String
    public var done: Bool
    public var parallel: Bool
    public var story: String?
    public var text: String
}

public struct SpecKitPhase: Codable, Hashable, Sendable {
    public var title: String
    public var tasks: [SpecKitTask]
    public var completed: Int { tasks.filter(\.done).count }
}

/// One task for its own implement agent, with the tasks.md phase it belongs to (as `projection` numbers phases).
public struct SpecKitTaskSlot: Hashable, Sendable {
    public var phase: Int
    public var task: SpecKitTask
    public init(phase: Int, task: SpecKitTask) { self.phase = phase; self.task = task }
}

public struct SpecKitSpecSummary: Codable, Hashable, Sendable {
    public var title: String?
    public var requirements: [String]
    public var successCriteria: [String]
    public var userStories: [String]
    public var clarificationsNeeded: Int
}

public enum SpecKitConvergeOutcome: String, Codable, Sendable {
    /// tasks.md byte-identical. Ambiguous: converged, refused, failed or asked. The owner decides from the report.
    case unchanged
    /// Upstream's `tasks_appended`: the original bytes are a prefix of the new file.
    case tasksAppended
    /// Existing tasks were edited or removed, outside converge's append-only contract.
    case rewritten
    case missing
}

public enum SpecKit {
    public static let testedVersion = "1.2.3"

    public static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 1_024 && !path.hasPrefix("/") && !path.contains("\0") && !path.contains("\\")
            && !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0 == "." || $0.isEmpty }
    }

    public static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Paths the host must snapshot for preflight and consent (prefixes, relative to the repository).
    public static let snapshotPrefixes = [".specify/", ".pi/prompts/", ".shepherd/prompts/"]

    /// Machine-local or artifact content that changes during ordinary use and is not instruction code.
    static func isConsentInput(_ path: String) -> Bool {
        (path.hasPrefix(".specify/") || path.hasPrefix(".pi/prompts/") || path.hasPrefix(".shepherd/prompts/"))
            && path != ".specify/feature.json" && !path.hasPrefix(".specify/memory/")
            && !path.hasPrefix(".specify/workflows/runs/")
    }

    public static func consentFingerprint(_ files: [String: Data]) -> String {
        let lines = files.filter { isConsentInput($0.key) }.sorted { $0.key < $1.key }.map { "\($0.key)\t\(sha256($0.value))" }
        return sha256(Data(lines.joined(separator: "\n").utf8))
    }

    /// `files`: relative path → bytes for everything under `snapshotPrefixes`.
    public static func preflight(_ files: [String: Data]) -> SpecKitPreflight {
        func json(_ path: String) -> [String: Any]? { files[path].flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
        let options = json(".specify/init-options.json"), state = json(".specify/integration.json")
        var warnings: [String] = []
        let installed = (state?["installed_integrations"] as? [String]) ?? [state?["integration"] as? String, options?["integration"] as? String].compactMap { $0 }
        let defaultIntegration = (state?["default_integration"] as? String) ?? (state?["integration"] as? String)
        let missing = SpecKitCommand.allCases.filter { files[$0.promptPath] == nil }
        var customized: [String] = []
        var piManifestMatches = files[".specify/integrations/pi.manifest.json"] != nil
        for name in ["pi", "speckit"] {
            guard let manifest = (json(".specify/integrations/\(name).manifest.json")?["files"]) as? [String: String] else { continue }
            for (path, hash) in manifest.sorted(by: { $0.key < $1.key }) where isSafeRelativePath(path) {
                guard let data = files[path] else { continue }
                if sha256(data) != hash {
                    customized.append(path)
                    if name == "pi" { piManifestMatches = false }
                }
            }
        }
        let hooks = parseHooks(files[".specify/extensions.yml"].map { String(decoding: $0, as: UTF8.self) } ?? "", warnings: &warnings)
        // The git extension's mandatory `speckit.git.feature` hook is supported: the mission adopts the feature
        // branch it creates in the worktree (`MissionController.adoptFeatureBranch`), as stock tooling would use it.
        for command in SpecKitCommand.allCases where files[".shepherd/prompts/speckit.\(command.rawValue).md"] != nil {
            warnings.append(".shepherd/prompts/speckit.\(command.rawValue).md is a Shepherd-only override that stock tooling never reads.")
        }
        let script = options?["script"] as? String
        if let script, script != "sh" { warnings.append("Scripts are \(script); Shepherd's acceptance tests cover sh only.") }
        let version = options?["speckit_version"] as? String
        if version != testedVersion { warnings.append("Project records Spec Kit \(version ?? "unknown"); Shepherd was tested with \(testedVersion).") }
        let status: SpecKitPreflight.Status
        if files.keys.contains(where: { $0.hasPrefix(".specify/") }) == false { status = .notInitialized }
        else if !installed.contains("pi") || SpecKitCommand.required.contains(where: missing.contains) { status = .piIntegrationMissing }
        else { status = .ready }
        return SpecKitPreflight(status: status, recordedVersion: version, testedVersion: testedVersion,
                                matchesTestedRelease: version == testedVersion && piManifestMatches,
                                scriptType: script, integrations: installed, defaultIntegration: defaultIntegration,
                                missingCommands: missing, customizedFiles: customized, hooks: hooks,
                                ownershipConflicts: [], warnings: warnings, consentFingerprint: consentFingerprint(files))
    }

    /// `.specify/extensions.yml` as upstream's `yaml.dump(default_flow_style=False)` writes it:
    /// `hooks:` → `  event:` → `  - key: value` items.
    // ponytail: block-style YAML subset only; anything else is reported for manual review, never guessed.
    static func parseHooks(_ text: String, warnings: inout [String]) -> [SpecKitHook] {
        var hooks: [SpecKitHook] = [], inHooks = false, event: String?, item: [String: String]?
        func flush() {
            guard let fields = item, let event else { return }
            if let command = fields["command"], !command.isEmpty {
                let condition = fields["condition"].flatMap { ["", "null", "~", "''", "\"\""].contains($0) ? nil : $0 }
                hooks.append(SpecKitHook(event: event, extensionID: fields["extension"], command: command,
                                         optional: fields["optional"].map { $0 != "false" } ?? true,
                                         enabled: fields["enabled"] != "false", condition: condition))
            }
            item = nil
        }
        func pair(_ line: Substring) -> (String, String)? {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "'" || first == "\"" { value = String(value.dropFirst().dropLast()) }
            return (line[..<colon].trimmingCharacters(in: .whitespaces), value)
        }
        var unrecognized = false, dashIndent = -1
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix { $0 == " " }.count
            if indent == 0 {
                flush(); event = nil; inHooks = trimmed == "hooks:"
                if trimmed.hasPrefix("hooks:") && !inHooks && trimmed != "hooks: {}" { unrecognized = true }
                continue
            }
            guard inHooks else { continue }
            if trimmed.hasPrefix("- "), event != nil {
                flush(); item = [:]; dashIndent = indent
                if let (key, value) = pair(trimmed.dropFirst(2)) { item?[key] = value } else { unrecognized = true }
            } else if item != nil, indent > dashIndent, let (key, value) = pair(Substring(trimmed)) {
                item?[key] = value
            } else if trimmed.hasSuffix(":") || trimmed.hasSuffix(": []") {
                flush(); event = String(trimmed.prefix { $0 != ":" })
            } else { unrecognized = true }
        }
        flush()
        if unrecognized { warnings.append(".specify/extensions.yml has hook entries Shepherd could not read; review them before consenting.") }
        return hooks
    }

    public static func parseTasks(_ text: String) -> [SpecKitPhase] {
        var phases: [SpecKitPhase] = []
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                phases.append(SpecKitPhase(title: String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces), tasks: []))
                continue
            }
            guard line.hasPrefix("- ["), line.count > 6 else { continue }
            let mark = line[line.index(line.startIndex, offsetBy: 3)]
            guard [" ", "x", "X"].contains(mark), line[line.index(line.startIndex, offsetBy: 4)] == "]" else { continue }
            var words = line.dropFirst(6).split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let id = words.first, id.hasPrefix("T"), id.count > 1, id.dropFirst().allSatisfy(\.isNumber) else { continue }
            words.removeFirst()
            var parallel = false, story: String?
            while let word = words.first, word.hasPrefix("["), word.hasSuffix("]") {
                let tag = String(word.dropFirst().dropLast())
                if tag == "P" { parallel = true } else if tag.hasPrefix("US") { story = tag } else { break }
                words.removeFirst()
            }
            if phases.isEmpty { phases.append(SpecKitPhase(title: "Tasks", tasks: [])) }
            phases[phases.count - 1].tasks.append(SpecKitTask(id: id, done: mark != " ", parallel: parallel, story: story, text: words.joined(separator: " ")))
        }
        return phases.filter { !$0.tasks.isEmpty }
    }

    /// The constitution is still upstream's unfilled template (or missing): `/speckit.constitution` has never run here.
    public static func constitutionNeedsWriting(_ text: String?) -> Bool {
        guard let text else { return true }
        return text.contains("[PROJECT_NAME]") || text.contains("[PRINCIPLE_1_NAME]")
    }

    /// Stock `/speckit.analyze` puts findings in a `| ID | Category | Severity | … |` table; CRITICAL means
    /// upstream recommends resolving them before `/speckit.implement`.
    public static func analysisFoundCritical(_ report: String) -> Bool {
        report.split(whereSeparator: \.isNewline).contains { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("|")
                && line.split(separator: "|").contains { $0.trimmingCharacters(in: .whitespaces) == "CRITICAL" }
        }
    }

    public static func parseSpec(_ text: String) -> SpecKitSpecSummary {
        var summary = SpecKitSpecSummary(title: nil, requirements: [], successCriteria: [], userStories: [], clarificationsNeeded: 0)
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            summary.clarificationsNeeded += line.components(separatedBy: "[NEEDS CLARIFICATION").count - 1
            if summary.title == nil, line.hasPrefix("# ") { summary.title = String(line.dropFirst(2)) }
            if line.hasPrefix("### User Story") { summary.userStories.append(String(line.dropFirst(4))) }
            let item = line.hasPrefix("- ") ? line.dropFirst(2).replacingOccurrences(of: "**", with: "") : ""
            if item.hasPrefix("FR-") { summary.requirements.append(item) }
            if item.hasPrefix("SC-") { summary.successCriteria.append(item) }
        }
        return summary
    }

    /// Approval binds to the feature's artifacts and the constitution, by content.
    public static func artifactFingerprints(_ files: [String: Data], featureDirectory: String) -> [String: String] {
        let prefix = featureDirectory.hasSuffix("/") ? featureDirectory : featureDirectory + "/"
        return files.filter { $0.key.hasPrefix(prefix) || $0.key == ".specify/memory/constitution.md" }.reduce(into: [:]) { result, file in
            result[file.key] = sha256(file.key == prefix + "tasks.md" ? uncheckedTasks(file.value) : file.value)
        }
    }

    public static func convergeOutcome(before: Data?, after: Data?) -> SpecKitConvergeOutcome {
        guard let before, let after else { return .missing }
        if before == after { return .unchanged }
        return after.count > before.count && after.prefix(before.count) == before ? .tasksAppended : .rewritten
    }

    /// tasks.md with every checkbox cleared: approval binds to the tasks, not to implement's progress marks.
    public static func uncheckedTasks(_ data: Data) -> Data {
        Data(String(decoding: data, as: UTF8.self).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { line -> String in
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            guard trimmed.hasPrefix("- [x]") || trimmed.hasPrefix("- [X]") else { return String(line) }
            return String(line[..<trimmed.startIndex]) + "- [ ]" + trimmed.dropFirst(5)
        }.joined(separator: "\n").utf8)
    }

    // MARK: One agent per task

    /// Unchecked tasks as batches for one implement agent each, in tasks.md order: a phase finishes before the next starts,
    /// a run of [P] tasks goes at once, any other task alone. The round's first task always goes alone, because it alone
    /// runs stock implement's project setup checks (ignore files), which the others skip.
    public static func implementBatches(_ phases: [SpecKitPhase]) -> [[SpecKitTaskSlot]] {
        var batches: [[SpecKitTaskSlot]] = []
        for (index, phase) in phases.enumerated() {
            var parallel: [SpecKitTaskSlot] = []
            for task in phase.tasks where !task.done {
                if task.parallel && !batches.isEmpty { parallel.append(.init(phase: index, task: task)); continue }
                if !parallel.isEmpty { batches.append(parallel); parallel = [] }
                batches.append([.init(phase: index, task: task)])
            }
            if !parallel.isEmpty { batches.append(parallel) }
        }
        return batches
    }

    /// What stock /speckit.implement is given as the user's input for one task. One line: the template reads it as $ARGUMENTS.
    public static func taskScope(_ task: SpecKitTask, first: Bool) -> String {
        let others = first ? "Other agents implement the remaining tasks after you, in this same worktree, some at the same time."
            : "Other agents are implementing other tasks in this same worktree right now. Skip the project setup checks; the round's first task ran them."
        return "Implement only task \(task.id) from tasks.md: \(task.text) \(others) Change only the files \(task.id) needs. Don't edit tasks.md or the checklists, "
            + "don't run extension hooks and don't commit: Shepherd marks \(task.id) done from your reply. When \(task.id) is complete, end your reply with "
            + "the line `Done: \(task.id)`. If you can't complete it, end with `Blocked: \(task.id)` and the reason."
    }

    /// The agent's own closing line for its task (`Done: T005`, emphasis ignored). Anything else, or a `Blocked:` line, is not done.
    public static func taskReported(_ reply: String, task: String) -> Bool {
        let lines = reply.split(whereSeparator: \.isNewline).map { $0.filter { !"*`".contains($0) }.trimmingCharacters(in: .whitespaces) }
        return lines.contains("Done: \(task)") && !lines.contains { $0.hasPrefix("Blocked: \(task)") }
    }

    /// tasks.md with one task's checkbox checked and every other byte as it was (line endings included); nil when the task
    /// has no unchecked line. Agents running side by side never write tasks.md, so their marks can't overwrite each other.
    public static func markingDone(_ text: String, task: String) -> String? {
        guard task.count > 1, task.hasPrefix("T"), task.dropFirst().allSatisfy(\.isASCII), task.dropFirst().allSatisfy(\.isNumber),
              let range = text.range(of: "(?m)^[ \\t]*- \\[ \\] " + task + "(?=[ \\t\\r\\n]|$)", options: .regularExpression) else { return nil }
        return text.replacingCharacters(in: range, with: text[range].replacingOccurrences(of: "- [ ]", with: "- [X]"))
    }

    /// A mandatory implement hook stock runs around the whole implementation (`EXECUTE_COMMAND`): per-task agents skip hooks,
    /// so such a repository implements in one stock turn. Optional and conditional hooks are only ever printed.
    public static func hasMandatoryImplementHooks(_ hooks: [SpecKitHook]) -> Bool {
        hooks.contains { ["before_implement", "after_implement"].contains($0.event) && $0.enabled && !$0.optional && $0.condition == nil }
    }

    /// Whether a tasks.md edit only checked boxes off, as stock implement does.
    public static func onlyChecksTasks(before: String, after: String) -> Bool {
        let old = before.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline), new = after.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard old.count == new.count else { return false }
        return zip(old, new).allSatisfy { a, b in
            a == b || (a.replacingOccurrences(of: "- [ ]", with: "- [X]") == b.replacingOccurrences(of: "- [x]", with: "- [X]"))
        }
    }

    /// Stock outputs per command, from the v1.2.3 templates. Anything else is evidence to review
    /// (hooks, presets and extensions legitimately write more), never a rejection.
    public static func advisories(command: SpecKitCommand, featureDirectory: String?, changedPaths: [String],
                                  tasksBefore: String? = nil, tasksAfter: String? = nil) -> [String] {
        let feature = featureDirectory.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        func inFeature(_ path: String, _ sub: String = "") -> Bool { feature.map { path.hasPrefix($0 + sub) } ?? false }
        let stock: (String) -> Bool
        switch command {
        case .specify: stock = { inFeature($0) || ($0.hasPrefix("specs/") && feature == nil) }
        case .clarify: stock = { path in feature.map { path == $0 + "spec.md" } ?? false }
        case .plan: stock = { inFeature($0) }
        case .tasks: stock = { path in feature.map { path == $0 + "tasks.md" } ?? false }
        case .checklist: stock = { inFeature($0, "checklists/") }
        case .analyze: stock = { _ in false }
        case .constitution: stock = { $0 == ".specify/memory/constitution.md" }
        case .implement: stock = { _ in true }
        case .converge: stock = { path in feature.map { path == $0 + "tasks.md" } ?? false }
        }
        var notes = changedPaths.filter { !stock($0) }.sorted().prefix(20).map {
            "/speckit.\(command.rawValue) changed \($0), outside its stock outputs (an extension hook, preset or the model). Review it."
        }
        if let before = tasksBefore, let after = tasksAfter {
            if command == .implement, !onlyChecksTasks(before: before, after: after) {
                notes.append("/speckit.implement edited tasks.md beyond checking tasks off. Review it.")
            }
            if command == .converge, convergeOutcome(before: Data(before.utf8), after: Data(after.utf8)) == .rewritten {
                notes.append("/speckit.converge rewrote existing tasks instead of appending. Review it.")
            }
        }
        return notes
    }

    /// A deterministic station identity, so a projection redraws without churning IDs.
    public static func stationID(_ mission: MissionID, _ lane: SpaceID, _ key: String) -> MissionStationID {
        var bytes = Array(SHA256.hash(data: Data("\(mission.rawValue)/\(lane.rawValue)/\(key)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return MissionStationID(rawValue: uuid.uuidString.lowercased())
    }

    /// Every repository's projection within a map's 128 stations. Execution and publication read the owner's checks,
    /// Converge and phase-0 (implement's receipt), so only later phase stations, which only display tasks.md, are trimmed.
    public static func fitted(stations: [MissionStation], dependencies: [MissionDependency], mission: MissionID,
                              lanes: [SpaceID], limit: Int = 128) throws -> (stations: [MissionStation], dependencies: [MissionDependency]) {
        let phaseZero = Set(lanes.map { stationID(mission, $0, "phase-0") })
        let fixed = Set(stations.filter { $0.kind != .worker || phaseZero.contains($0.id) }.map(\.id))
        guard fixed.count <= limit else {
            throw MissionError("mission_limit", "These repositories need \(fixed.count) checks and Spec Kit stations; a map holds \(limit). Use fewer repositories or checks.")
        }
        let ids = fixed.union(stations.filter { !fixed.contains($0.id) }.prefix(limit - fixed.count).map(\.id))
        return (stations.filter { ids.contains($0.id) }, dependencies.filter { ids.contains($0.source) && ids.contains($0.target) })
    }

    /// The existing map types as a display of one repository's stock artifacts: planning stages,
    /// one station per tasks.md phase, then converge. Owner-entered check stations are kept as-is.
    /// Execution never schedules from this graph.
    public static func projection(mission: MissionID, lane: SpaceID, artifacts: [SpecKitCommand: Bool],
                                  spec: SpecKitSpecSummary?, phases: [SpecKitPhase], keeping checks: [MissionStation] = []) -> (stations: [MissionStation], dependencies: [MissionDependency]) {
        func clip(_ text: String, _ bytes: Int = 4_000) -> String {
            var data = Data(text.utf8.prefix(bytes))
            while !data.isEmpty && String(data: data, encoding: .utf8) == nil { data.removeLast() }
            return String(decoding: data, as: UTF8.self)
        }
        var stations: [MissionStation] = [], wires: [MissionDependency] = []
        var previous: MissionStationID?
        for (command, title, goal) in [(SpecKitCommand.specify, "Specify", "spec.md"), (.plan, "Plan", "plan.md and design artifacts"), (.tasks, "Tasks", "tasks.md")] {
            let id = stationID(mission, lane, command.rawValue)
            var done: [String] = artifacts[command] == true ? ["\(goal) exists"] : []
            if command == .specify, let spec { done += (spec.requirements + spec.successCriteria).prefix(30).map { clip($0) } }
            stations.append(MissionStation(id: id, kind: .research, laneID: lane, title: title, goal: "/speckit.\(command.rawValue) writes \(goal)", doneWhen: done))
            if let previous { wires.append(MissionDependency(source: previous, target: id)) }
            previous = id
        }
        let converge = stationID(mission, lane, SpecKitCommand.converge.rawValue)
        let workers = phases.prefix(100).enumerated().map { index, phase in
            // Checkbox progress stays out of the map: tasks.md owns it, and a checked task must not
            // read as a changed map (which would supersede receipts and clear approval).
            MissionStation(id: stationID(mission, lane, "phase-\(index)"), kind: .worker, laneID: lane, title: clip(phase.title, 800),
                           goal: "/speckit.implement works through this phase of tasks.md",
                           doneWhen: phase.tasks.prefix(32).map { clip("\($0.id) \($0.text)") })
        }
        for worker in workers {
            if let previous { wires.append(MissionDependency(source: previous, target: worker.id)) }
            previous = worker.id
            wires.append(MissionDependency(source: worker.id, target: converge, kind: .data, artifact: "tasks.md progress"))
        }
        stations += workers
        for check in checks.filter({ $0.kind == .check && $0.laneID == lane }) {
            stations.append(check)
            if let last = workers.last { wires.append(MissionDependency(source: last.id, target: check.id, kind: .data, artifact: "implementation")) }
        }
        stations.append(MissionStation(id: converge, kind: .validator, laneID: lane, title: "Converge",
                                       goal: "/speckit.converge assesses the code against spec, plan and tasks. An assessment, not test evidence."))
        if workers.isEmpty, let previous { wires.append(MissionDependency(source: previous, target: converge)) }
        return (stations, wires)
    }
}
