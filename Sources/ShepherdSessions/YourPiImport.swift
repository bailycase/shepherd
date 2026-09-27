import Foundation
import ShepherdRemote

/// What Shepherd brought over from the user's own pi, and what it keeps reading from there: saved
/// in Shepherd's pi home (`.shepherd-imports.json`). Once it says `copied` (or can't be read), the
/// first copy never runs again on its own; Settings ▸ Pi ▸ From your pi copies again on request.
public struct YourPiImportState: Codable, Equatable, Sendable {
    public var version = 1
    /// The first copy ran. False only when a switch in Settings ▸ Pi was saved before it did (a
    /// first launch whose copy overran its deadline): the next launch still copies.
    public var copied = true
    /// When the first copy ran (or the state was first saved).
    public var copiedAt: Date
    /// The folder it read, or nil when the user had no pi.
    public var from: String?
    /// Their global instructions (`AGENTS.md`, …) join every agent's context, read live.
    public var instructions = true
    /// Whether their skills and prompts are read in place.
    public var skillsOn = true
    public var promptsOn = true
    /// The entries Shepherd put in its settings.json's `skills` and `prompts` for them, so a
    /// re-import or a switch replaces exactly those.
    public var skills: [String] = []
    public var prompts: [String] = []

    public init(copiedAt: Date, from: String?, copied: Bool = true) {
        self.copiedAt = copiedAt
        self.from = from
        self.copied = copied
    }

    // New fields decode with defaults, so an older file keeps loading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        copied = try c.decodeIfPresent(Bool.self, forKey: .copied) ?? true
        copiedAt = try c.decodeIfPresent(Date.self, forKey: .copiedAt) ?? Date(timeIntervalSince1970: 0)
        from = try c.decodeIfPresent(String.self, forKey: .from)
        instructions = try c.decodeIfPresent(Bool.self, forKey: .instructions) ?? true
        skillsOn = try c.decodeIfPresent(Bool.self, forKey: .skillsOn) ?? true
        promptsOn = try c.decodeIfPresent(Bool.self, forKey: .promptsOn) ?? true
        skills = try c.decodeIfPresent([String].self, forKey: .skills) ?? []
        prompts = try c.decodeIfPresent([String].self, forKey: .prompts) ?? []
    }
}

/// What one copy did, for the welcome step and the log. It names providers and files, never a
/// credential's value.
public struct YourPiImportReport: Equatable, Sendable {
    /// This was the first copy (the welcome step shows it).
    public var first = false
    /// The user's pi it read; nil when they have none (or it was refused).
    public var from: String?
    /// Sign-ins and keys copied into Shepherd's pi.
    public var logins: [PiLogin] = []
    /// Providers Shepherd's pi already had a login for, which the first copy left as they were.
    public var keptLogins: [String] = []
    /// Custom providers (models.json) copied.
    public var customProviders: [String] = []
    /// Shepherd's own models.json was there first and was kept.
    public var keptCustomProviders = false
    /// The default model copied.
    public var defaultModel: String?
    /// Shepherd's pi already had this default model (a first sign-in sets one), so theirs wasn't copied.
    public var keptDefaultModel: String?
    /// Folders whose trust decision was copied.
    public var trustedFolders = 0
    /// Trust decisions not copied because they would trust the home folder as a project.
    public var droppedTrust: [String] = []
    /// The instructions file agents read live, if any.
    public var instructions: String?
    /// The entries now read in place.
    public var skills: [String] = []
    public var prompts: [String] = []
    /// What couldn't be read or written, one sentence each; the rest still copied.
    public var problems: [String] = []

    public init() {}

    /// Anything was brought over or is read from their pi.
    public var broughtOver: Bool {
        !logins.isEmpty || !customProviders.isEmpty || defaultModel != nil || trustedFolders > 0 || instructions != nil
            || !skills.isEmpty || !prompts.isEmpty
    }

    /// One line for the log: counts and provider names only.
    public var summary: String {
        var parts = ["logins \(logins.map(\.provider).joined(separator: ", ").ifEmpty("none"))"]
        if !keptLogins.isEmpty { parts.append("kept Shepherd's \(keptLogins.joined(separator: ", "))") }
        parts.append("custom providers \(customProviders.count)")
        if let defaultModel { parts.append("default model \(defaultModel)") }
        parts.append("trusted folders \(trustedFolders)")
        if !droppedTrust.isEmpty { parts.append("\(droppedTrust.count) trust decision(s) for the home folder left out") }
        if let instructions { parts.append("instructions \(instructions)") }
        parts.append("skills \(skills.count), prompts \(prompts.count)")
        return parts.joined(separator: "; ")
    }
}

/// Everything Settings ▸ Pi shows about sign-ins and the user's pi, as plain values.
public struct YourPiSurvey: Equatable, Sendable {
    /// One provider's row: what Shepherd's pi has, what theirs has, and the variables for it
    /// their login shell sets.
    public struct Login: Equatable, Sendable, Identifiable {
        public var provider: String
        public var shepherd: PiLogin.Kind?
        public var yours: PiLogin.Kind?
        public var environment: [String]
        public var id: String { provider }

        public init(provider: String, shepherd: PiLogin.Kind? = nil, yours: PiLogin.Kind? = nil, environment: [String] = []) {
            self.provider = provider
            self.shepherd = shepherd
            self.yours = yours
            self.environment = environment
        }

        public var name: String { PiProviders.name(provider) }
    }

    /// Their pi's folder; nil when they have none.
    public var folder: String?
    public var logins: [Login] = []
    public var customProviders: [String] = []
    public var shepherdCustomProviders: [String] = []
    public var defaultModel: String?
    public var shepherdDefaultModel: String?
    /// Their trust decisions Shepherd would copy, and how many Shepherd's pi holds.
    public var trustedFolders = 0
    public var shepherdTrustedFolders = 0
    /// Their global instructions file, read live while `instructionsOn`.
    public var instructionsFile: String?
    public var instructionsOn = true
    public var skills: [String] = []
    public var skillsOn = true
    public var prompts: [String] = []
    public var promptsOn = true
    public var extensions: [YourPiExtension] = []
    /// Their files that couldn't be read.
    public var problems: [String] = []
    /// The first copy has happened.
    public var copied = false

    public init(folder: String? = nil) {
        self.folder = folder
    }

    /// Whether any provider can start an agent: a login in Shepherd's pi, a key in the
    /// environment, or a custom provider.
    public var canStartAgents: Bool {
        logins.contains { $0.shepherd != nil || !$0.environment.isEmpty } || !shepherdCustomProviders.isEmpty
    }

    /// The providers `models` (`provider/model` references) name that nothing in Shepherd's pi
    /// can sign in to: no login, no key in the environment, no custom provider of that name. Only
    /// providers Shepherd knows, and never one that signs in with cloud credentials pi doesn't
    /// store (`PiProviders.ambient`). In first-seen order, once each.
    public func missingSignIns(for models: [String]) -> [String] {
        var missing: [String] = []
        for model in models {
            guard let slash = model.firstIndex(of: "/"), slash != model.startIndex else { continue }
            let provider = String(model[..<slash])
            guard PiProviders.names[provider] != nil, !PiProviders.ambient.contains(provider),
                  !shepherdCustomProviders.contains(provider), !missing.contains(provider) else { continue }
            let login = logins.first { $0.provider == provider }
            if login?.shepherd == nil, login?.environment.isEmpty ?? true { missing.append(provider) }
        }
        return missing
    }
}

/// Copies the user's pi's logins, custom providers, default model and trust into Shepherd's pi
/// home, and points Shepherd's settings at their skills and prompts, all as plain files: their
/// folder is only read (no lock folders, no pi code), and every write lands in the home, by temp
/// file and rename under pi's lock. auth.json is 0600 in the 0700 home.
///
/// The first copy runs once, at the first launch of a build with Shepherd's own home, and leaves
/// `.shepherd-imports.json` behind; from then on the two pis are independent, and a copy runs
/// again only when the user asks (`reimport`), one item (or provider) at a time.
///
/// Subscription sign-ins are copied as they are (the user's decision, 2026-09-26). For providers
/// that rotate refresh tokens (Anthropic, OpenAI Codex, Kimi, Radius, and xAI when its server
/// rotates), the first refresh on one side can sign the other out, and a provider may revoke both.
public struct YourPiImport: Sendable {
    public static let stateName = ".shepherd-imports.json"

    /// Shepherd's pi home: every write goes here.
    public let home: PiHome
    /// The user's own pi, read only; nil when they have none.
    public let yourPi: YourPi?
    /// Their home folder, which is never trusted as a project.
    public let userHome: String
    /// Where notes go (counts and names only).
    public let log: @Sendable (String) -> Void

    public init(home: PiHome, yourPi: YourPi?, userHome: String = NSHomeDirectory(),
                log: @escaping @Sendable (String) -> Void = { ShepherdLog.info($0) }) {
        self.home = home
        self.yourPi = yourPi
        self.userHome = userHome
        self.log = log
    }

    public var stateURL: URL { home.directory.appendingPathComponent(Self.stateName) }
    var auth: URL { home.directory.appendingPathComponent("auth.json") }
    var models: URL { home.directory.appendingPathComponent("models.json") }
    var trust: URL { home.directory.appendingPathComponent("trust.json") }

    /// What the first copy (or a switch) left, or nil before either, or when it can't be read.
    public func state() -> YourPiImportState? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(YourPiImportState.self, from: data)
    }

    func save(_ state: YourPiImportState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try PiHome.write(try encoder.encode(state), to: stateURL, mode: 0o600)
    }

    // MARK: The first copy

    /// Copies everything once: nothing when it already ran. Shepherd's own logins, custom
    /// providers and default model win over theirs (a sign-in made in Shepherd's pi before this
    /// build is kept). The home must be ready (`PiSetup.prepare` passed). A state file that is
    /// there but can't be read counts as a copy that ran: a damaged file never copies again.
    public func copyOnce(now: Date = Date()) -> YourPiImportReport {
        var info = stat()
        let exists = lstat(stateURL.path, &info) == 0
        let saved = exists ? state() : nil
        if exists, saved?.copied != false { return YourPiImportReport() }
        var report = YourPiImportReport()
        report.first = true
        // Switches saved before the copy are kept.
        var state = saved ?? YourPiImportState(copiedAt: now, from: nil)
        state.copied = true
        state.copiedAt = now
        state.from = yourPi?.agentDirectory.path
        if let yourPi {
            report.from = yourPi.agentDirectory.path
            copyLogins(from: yourPi, overwriting: nil, into: &report)
            copyModels(from: yourPi, overwrite: false, into: &report)
            copyDefaultModel(from: yourPi, overwrite: false, into: &report)
            copyTrust(from: yourPi, into: &report)
            report.instructions = YourPiFiles.contextFile(in: yourPi.agentDirectory)?.lastPathComponent
            applyResources(from: yourPi, state: &state, into: &report)
        }
        do {
            try save(state)
        } catch {
            report.problems.append("Shepherd couldn't record the copy from your pi: \(error)")
        }
        log("copied from your pi (\(report.from ?? "none")): \(report.summary)"
            + (report.problems.isEmpty ? "" : "; problems: \(report.problems.joined(separator: " "))"))
        return report
    }

    // MARK: Copying again

    /// What Settings ▸ Pi ▸ From your pi copies again, each overwriting Shepherd's copy.
    public enum Item: Equatable, Sendable {
        /// One provider's login.
        case login(String)
        case customProviders
        case defaultModel
        case trust
    }

    /// Copies `item` again, overwriting Shepherd's copy. Throws with the reason when their pi
    /// lacks it or its file is unreadable (Shepherd's copy is then left as it was).
    @discardableResult
    public func reimport(_ item: Item) throws -> YourPiImportReport {
        guard let yourPi else { throw YourPiFileError("Shepherd found no pi of yours to copy from.") }
        var report = YourPiImportReport()
        report.from = yourPi.agentDirectory.path
        switch item {
        case .login(let provider): copyLogins(from: yourPi, overwriting: provider, into: &report)
        case .customProviders: copyModels(from: yourPi, overwrite: true, into: &report)
        case .defaultModel: copyDefaultModel(from: yourPi, overwrite: true, into: &report)
        case .trust: copyTrust(from: yourPi, into: &report)
        }
        if let problem = report.problems.first { throw YourPiFileError(problem) }
        log("copied again from your pi: \(report.summary)")
        return report
    }

    /// Turns reading their instructions live on or off.
    public func setInstructions(_ on: Bool) throws {
        var state = self.state() ?? YourPiImportState(copiedAt: Date(), from: nil, copied: false)
        state.instructions = on
        try save(state)
    }

    /// Turns reading their skills (or prompts) in place on or off, and on again reads their
    /// settings afresh.
    public func setResources(_ key: String, on: Bool) throws {
        var state = self.state() ?? YourPiImportState(copiedAt: Date(), from: nil, copied: false)
        if key == "skills" { state.skillsOn = on } else { state.promptsOn = on }
        var report = YourPiImportReport()
        applyResources(from: yourPi, state: &state, into: &report)
        if let problem = report.problems.first { throw YourPiFileError(problem) }
        try save(state)
    }

    /// The folder of their instructions for an agent's launch, while reading them is on.
    public func instructionsDirectory() -> URL? {
        guard let yourPi, state()?.instructions ?? true else { return nil }
        return yourPi.agentDirectory
    }

    // MARK: The pieces

    private func copyLogins(from yourPi: YourPi, overwriting provider: String?, into report: inout YourPiImportReport) {
        let theirs: [String: [String: Any]]
        do {
            guard let data = try YourPiFiles.read(yourPi.agentDirectory.appendingPathComponent("auth.json")) else {
                if provider != nil { report.problems.append("Your pi has no sign-ins to copy.") }
                return
            }
            theirs = try YourPiFiles.credentials(data)
        } catch {
            report.problems.append("Your pi's sign-ins couldn't be read: \(error).")
            return
        }
        if let provider, theirs[provider] == nil {
            report.problems.append("Your pi has no sign-in for \(PiProviders.name(provider)).")
            return
        }
        var copied: [PiLogin] = []
        var kept: [String] = []
        do {
            let notes = try PiSettingsFile(url: auth, mode: 0o600).update { ours in
                for (name, credential) in theirs.sorted(by: { $0.key < $1.key }) {
                    if let provider, name != provider { continue }
                    if provider == nil, ours[name] != nil { kept.append(name); continue }
                    ours[name] = credential
                    copied.append(YourPiFiles.login(provider: name, credential: credential))
                }
                return []
            }
            // Shepherd's own auth.json isn't a JSON object: it was left as it is, and nothing copied.
            report.problems += notes
        } catch {
            report.problems.append("Shepherd couldn't write its sign-ins: \(error).")
            return
        }
        report.logins += copied
        report.keptLogins += kept
    }

    private func copyModels(from yourPi: YourPi, overwrite: Bool, into report: inout YourPiImportReport) {
        do {
            guard let data = try YourPiFiles.read(yourPi.agentDirectory.appendingPathComponent("models.json")) else {
                if overwrite { report.problems.append("Your pi has no custom providers (models.json) to copy.") }
                return
            }
            let providers = try YourPiFiles.customProviders(data)
            if !overwrite, let existing = try? YourPiFiles.read(models), let mine = try? YourPiFiles.customProviders(existing), !mine.isEmpty {
                report.keptCustomProviders = true
                return
            }
            try PiSettingsFile(url: models, mode: 0o600).replace(with: data)
            report.customProviders = providers
        } catch {
            // Invalid JSON keeps Shepherd's copy as it was.
            report.problems.append("Your pi's custom providers weren't copied: \(error).")
        }
    }

    private func copyDefaultModel(from yourPi: YourPi, overwrite: Bool, into report: inout YourPiImportReport) {
        let theirs: String?
        do {
            let data = try YourPiFiles.read(yourPi.agentDirectory.appendingPathComponent("settings.json"))
            theirs = try data.map { try YourPiFiles.object($0, file: "settings.json") }.flatMap(YourPiFiles.defaultModel)
        } catch {
            report.problems.append("Your pi's settings couldn't be read: \(error).")
            return
        }
        guard let theirs, let slash = theirs.firstIndex(of: "/") else {
            if overwrite { report.problems.append("Your pi has no default model to copy.") }
            return
        }
        var kept: String?
        do {
            let notes = try PiSettingsFile(url: home.settings).update { settings in
                if !overwrite, let mine = YourPiFiles.defaultModel(settings) {
                    kept = mine
                    return []
                }
                settings["defaultProvider"] = String(theirs[..<slash])
                settings["defaultModel"] = String(theirs[theirs.index(after: slash)...])
                return []
            }
            guard notes.isEmpty else { report.problems += notes; return }
        } catch {
            report.problems.append("Shepherd couldn't write its default model: \(error).")
            return
        }
        if let kept { report.keptDefaultModel = kept } else { report.defaultModel = theirs }
    }

    private func copyTrust(from yourPi: YourPi, into report: inout YourPiImportReport) {
        do {
            guard let data = try YourPiFiles.read(yourPi.agentDirectory.appendingPathComponent("trust.json")) else { return }
            let (decisions, dropped) = try YourPiFiles.trust(data, home: userHome)
            report.droppedTrust = dropped
            guard !decisions.isEmpty else { return }
            let notes = try PiSettingsFile(url: trust, mode: 0o600).update { ours in
                for (path, trusted) in decisions { ours[path] = trusted }
                return []
            }
            guard notes.isEmpty else { report.problems += notes; return }
            report.trustedFolders = decisions.count
        } catch {
            report.problems.append("Your pi's trusted folders weren't copied: \(error).")
        }
    }

    /// Points Shepherd's settings.json `skills` and `prompts` at theirs (in place, as absolute
    /// paths), replacing only the entries Shepherd put there before; a switch that's off leaves
    /// none.
    private func applyResources(from yourPi: YourPi?, state: inout YourPiImportState, into report: inout YourPiImportReport) {
        var settings: [String: Any]?
        if let yourPi {
            do {
                settings = try YourPiFiles.read(yourPi.agentDirectory.appendingPathComponent("settings.json"))
                    .map { try YourPiFiles.object($0, file: "settings.json") }
            } catch {
                report.problems.append("Your pi's settings couldn't be read: \(error).")
            }
        }
        func entries(_ key: String, on: Bool) -> [String] {
            guard on, let yourPi else { return [] }
            return YourPiFiles.resourceEntries(key, settings: settings, agentDirectory: yourPi.agentDirectory, home: userHome)
        }
        let skills = entries("skills", on: state.skillsOn)
        let prompts = entries("prompts", on: state.promptsOn)
        let previous = (skills: state.skills, prompts: state.prompts)
        do {
            let notes = try PiSettingsFile(url: home.settings).update { ours in
                for (key, old, new) in [("skills", previous.skills, skills), ("prompts", previous.prompts, prompts)] {
                    let others = (ours[key] as? [Any] ?? []).compactMap { $0 as? String }.filter { !old.contains($0) && !new.contains($0) }
                    let merged = new + others
                    if merged.isEmpty { ours.removeValue(forKey: key) } else { ours[key] = merged }
                }
                return []
            }
            guard notes.isEmpty else { report.problems += notes; return }
            state.skills = skills
            state.prompts = prompts
            report.skills = skills
            report.prompts = prompts
        } catch {
            report.problems.append("Shepherd couldn't point its settings at your skills and prompts: \(error).")
        }
    }

    // MARK: Reading both sides

    /// Shepherd's pi and theirs, side by side, for Settings ▸ Pi and the welcome step. Plain reads.
    /// `environmentKeys` are the provider variables their login shell sets (names only).
    public func survey(environmentKeys: Set<String> = []) -> YourPiSurvey {
        var survey = YourPiSurvey(folder: yourPi?.agentDirectory.path)
        let state = self.state()
        survey.copied = state?.copied == true
        survey.instructionsOn = state?.instructions ?? true
        survey.skillsOn = state?.skillsOn ?? true
        survey.promptsOn = state?.promptsOn ?? true

        let mine = (try? YourPiFiles.read(auth)).flatMap { $0 }.flatMap { try? YourPiFiles.logins($0) } ?? []
        var theirs: [PiLogin] = []
        var theirSettings: [String: Any]?
        if let yourPi {
            let folder = yourPi.agentDirectory
            do { theirs = try YourPiFiles.read(folder.appendingPathComponent("auth.json")).map(YourPiFiles.logins) ?? [] } catch {
                survey.problems.append("Your pi's sign-ins couldn't be read: \(error).")
            }
            do { survey.customProviders = try YourPiFiles.read(folder.appendingPathComponent("models.json")).map(YourPiFiles.customProviders) ?? [] } catch {
                survey.problems.append("Your pi's custom providers couldn't be read: \(error).")
            }
            do { theirSettings = try YourPiFiles.read(folder.appendingPathComponent("settings.json")).map { try YourPiFiles.object($0, file: "settings.json") } } catch {
                survey.problems.append("Your pi's settings couldn't be read: \(error).")
            }
            survey.defaultModel = YourPiFiles.defaultModel(theirSettings)
            do { survey.trustedFolders = try YourPiFiles.read(folder.appendingPathComponent("trust.json")).map { try YourPiFiles.trust($0, home: userHome).decisions.count } ?? 0 } catch {
                survey.problems.append("Your pi's trusted folders couldn't be read: \(error).")
            }
            survey.instructionsFile = YourPiFiles.contextFile(in: folder)?.path
            survey.skills = YourPiFiles.resourceEntries("skills", settings: theirSettings, agentDirectory: folder, home: userHome)
            survey.prompts = YourPiFiles.resourceEntries("prompts", settings: theirSettings, agentDirectory: folder, home: userHome)
            survey.extensions = YourPiFiles.extensions(in: folder, settings: theirSettings, home: userHome)
        }
        survey.shepherdCustomProviders = (try? YourPiFiles.read(models)).flatMap { $0 }.flatMap { try? YourPiFiles.customProviders($0) } ?? []
        let ownSettings = (try? YourPiFiles.read(home.settings)).flatMap { $0 }.flatMap { try? YourPiFiles.object($0, file: "settings.json") }
        survey.shepherdDefaultModel = YourPiFiles.defaultModel(ownSettings)
        survey.shepherdTrustedFolders = ((try? YourPiFiles.read(trust)).flatMap { $0 }.flatMap { try? YourPiFiles.object($0, file: "trust.json") } ?? [:])
            .values.filter { ($0 as? Bool) == true }.count

        let environment = PiProviders.providers(withKeys: environmentKeys)
        let providers = Set(mine.map(\.provider)).union(theirs.map(\.provider)).union(environment.keys)
        survey.logins = providers.map { provider in
            YourPiSurvey.Login(provider: provider, shepherd: mine.first { $0.provider == provider }?.kind,
                               yours: theirs.first { $0.provider == provider }?.kind, environment: environment[provider] ?? [])
        }.sorted { ($0.name.lowercased(), $0.provider) < ($1.name.lowercased(), $1.provider) }
        return survey
    }
}

private extension String {
    func ifEmpty(_ other: String) -> String { isEmpty ? other : self }
}
