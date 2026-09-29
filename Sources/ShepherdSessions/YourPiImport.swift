import Foundation
import ShepherdProtocol
import ShepherdRemote

/// What Shepherd brought over from the user's own pi: saved in Shepherd's pi home
/// (`.shepherd-imports.json`). Once it says `copied` (or can't be read), the first copy never
/// runs again on its own; Settings ▸ Pi ▸ From your pi copies again on request.
public struct YourPiImportState: Codable, Equatable, Sendable {
    /// 2: instructions, skills, prompts, themes and extensions are copied into the home. A state
    /// of version 1 (they were read in place) gets them copied once at the next launch.
    public static let currentVersion = 2

    public var version = YourPiImportState.currentVersion
    /// The first copy ran. False only when a change in Settings ▸ Pi was saved before it did (a
    /// first launch whose copy overran its deadline): the next launch still copies.
    public var copied = true
    /// When the first copy ran (or the state was first saved).
    public var copiedAt: Date
    /// The folder it read, or nil when the user had no pi.
    public var from: String?
    /// Everything copied into the home as files, each by where its copy lives.
    public var copies: [YourPiCopy] = []
    /// The extensions switched on (by their copy's `destination`): loaded by their absolute path
    /// through the home's settings.json `extensions`.
    public var extensionsOn: [String] = []
    /// Switched-on extensions that failed to load, by `destination`: left out of every launch
    /// until their files change or the user tries again.
    public var extensionFailures: [String: YourPiExtensionFailure] = [:]
    /// The entries Shepherd put in its settings.json's `extensions`, so a change replaces exactly
    /// those.
    public var extensionEntries: [String] = []
    /// Version 1's settings.json `skills` and `prompts` entries, which pointed at the user's pi;
    /// removed from Shepherd's settings when their files are copied.
    public var legacySkills: [String] = []
    public var legacyPrompts: [String] = []
    /// A digest of what each item was when Shepherd last copied it ("login:<provider>",
    /// "customProviders", "defaultModel", "trust"), never the value: Settings compares both
    /// sides against it (`PiFreshness`).
    public var digests: [String: String] = [:]

    public init(copiedAt: Date, from: String?, copied: Bool = true) {
        self.copiedAt = copiedAt
        self.from = from
        self.copied = copied
    }

    private enum CodingKeys: String, CodingKey {
        case version, copied, copiedAt, from, copies, extensionsOn, extensionFailures, extensionEntries, digests
        // Version 1's.
        case skills, prompts
    }

    // New fields decode with defaults, so an older file keeps loading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        copied = try c.decodeIfPresent(Bool.self, forKey: .copied) ?? true
        copiedAt = try c.decodeIfPresent(Date.self, forKey: .copiedAt) ?? Date(timeIntervalSince1970: 0)
        from = try c.decodeIfPresent(String.self, forKey: .from)
        copies = (try? c.decodeIfPresent([YourPiCopy].self, forKey: .copies)) ?? []
        extensionsOn = (try? c.decodeIfPresent([String].self, forKey: .extensionsOn)) ?? []
        extensionFailures = (try? c.decodeIfPresent([String: YourPiExtensionFailure].self, forKey: .extensionFailures)) ?? [:]
        extensionEntries = (try? c.decodeIfPresent([String].self, forKey: .extensionEntries)) ?? []
        legacySkills = (try? c.decodeIfPresent([String].self, forKey: .skills)) ?? []
        legacyPrompts = (try? c.decodeIfPresent([String].self, forKey: .prompts)) ?? []
        digests = (try? c.decodeIfPresent([String: String].self, forKey: .digests)) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(copied, forKey: .copied)
        try c.encode(copiedAt, forKey: .copiedAt)
        try c.encodeIfPresent(from, forKey: .from)
        try c.encode(copies, forKey: .copies)
        try c.encode(extensionsOn, forKey: .extensionsOn)
        try c.encode(extensionFailures, forKey: .extensionFailures)
        try c.encode(extensionEntries, forKey: .extensionEntries)
        if !digests.isEmpty { try c.encode(digests, forKey: .digests) }
        if !legacySkills.isEmpty { try c.encode(legacySkills, forKey: .skills) }
        if !legacyPrompts.isEmpty { try c.encode(legacyPrompts, forKey: .prompts) }
    }

    /// What was copied of `kind`, in the order it was found.
    public func copies(_ kind: YourPiResourceKind) -> [YourPiCopy] {
        copies.filter { $0.kind == kind }
    }
}

/// Why a switched-on extension of the user's is left out of every launch.
public struct YourPiExtensionFailure: Codable, Equatable, Sendable {
    /// pi's words (or Shepherd's, for files gone missing), without the extension's path.
    public var reason: String
    /// When its files last changed then: a later change tries it again.
    public var modified: Double
    /// pi's last lines as it failed (Show log); none in a state saved before they were kept.
    public var lines: [String]

    public init(reason: String, modified: Double, lines: [String] = []) {
        self.reason = reason
        self.modified = modified
        self.lines = lines
    }

    private enum CodingKeys: String, CodingKey { case reason, modified, lines }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reason = try c.decode(String.self, forKey: .reason)
        modified = try c.decodeIfPresent(Double.self, forKey: .modified) ?? 0
        lines = (try? c.decodeIfPresent([String].self, forKey: .lines)) ?? []
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
    /// What each copied item was, as digests (`YourPiImportState.digests`).
    public var digests: [String: String] = [:]
    /// Their auth.json couldn't be read or isn't JSON: its path and the parser's reason (never its
    /// contents). The rest still came over.
    public var signInsUnreadable: (path: String, reason: String)? {
        get { unreadable.map { ($0.path, $0.reason) } }
        set { unreadable = newValue.map { Unreadable(path: $0.path, reason: $0.reason) } }
    }
    private var unreadable: Unreadable?
    private struct Unreadable: Equatable, Sendable { var path: String; var reason: String }
    /// Instructions, skills, prompts, themes and extensions copied into the home as files.
    public var copied: [YourPiCopy] = []
    /// What was passed over on purpose (a second skill of one name, a package their pi never
    /// installed), one sentence each: the log's, not a problem.
    public var skipped: [String] = []
    /// What couldn't be read or written, one sentence each; the rest still copied.
    public var problems: [String] = []

    public init() {}

    /// What was copied of `kind`.
    public func copied(_ kind: YourPiResourceKind) -> [YourPiCopy] {
        copied.filter { $0.kind == kind }
    }

    /// Anything was brought over.
    public var broughtOver: Bool {
        !logins.isEmpty || !customProviders.isEmpty || defaultModel != nil || trustedFolders > 0 || !copied.isEmpty
    }

    /// One line for the log: counts and provider names only.
    public var summary: String {
        var parts = ["logins \(logins.map(\.provider).joined(separator: ", ").ifEmpty("none"))"]
        if !keptLogins.isEmpty { parts.append("kept Shepherd's \(keptLogins.joined(separator: ", "))") }
        parts.append("custom providers \(customProviders.count)")
        if let defaultModel { parts.append("default model \(defaultModel)") }
        parts.append("trusted folders \(trustedFolders)")
        if !droppedTrust.isEmpty { parts.append("\(droppedTrust.count) trust decision(s) for the home folder left out") }
        let instructions = copied(.instructions).map(\.name)
        if !instructions.isEmpty { parts.append("instructions \(instructions.joined(separator: ", "))") }
        parts.append(YourPiResourceKind.allCases.filter { $0 != .instructions }.map { "\($0.rawValue) \(copied($0).count)" }
            .joined(separator: ", "))
        return parts.joined(separator: "; ")
    }
}

/// One line of the first launch's sheet (`PiImportStepRow(item, step)`), in the order the copy
/// takes them.
public enum YourPiImportStep: String, CaseIterable, Sendable {
    case logins, apiKeys, customProviders, defaultModel, trustedFolders, files, extensions
}

/// How the first copy is going, as it goes: where it copies from, then each step as it starts and
/// ends, with the report so far (names and counts, never a value).
public enum YourPiImportProgress: Equatable, Sendable {
    case started(from: String)
    case running(YourPiImportStep)
    /// A step ended; `report` is everything copied so far.
    case finished(YourPiImportStep, report: YourPiImportReport)
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
    /// What was copied into Shepherd's home as files, in the order it was found.
    public var copies: [YourPiCopy] = []
    /// The copied instructions file's line count, when it has one.
    public var instructionLines: Int?
    /// Their extensions, as copied: each off until switched on.
    public var extensions: [YourPiExtensionRow] = []
    /// Their files that couldn't be read.
    public var problems: [String] = []
    /// The first copy has happened.
    public var copied = false
    /// When it did.
    public var copiedAt: Date?
    /// Shepherd's keys, and theirs, as Settings shows them (a mask, a variable, a command), by
    /// provider.
    public var keys: [String: PiKeyDisplay] = [:]
    public var yourKeys: [String: PiKeyDisplay] = [:]
    /// Providers whose credential in Shepherd's pi is still the one copied from theirs.
    public var copiedLogins: Set<String> = []
    /// Shepherd's custom providers, with their keys and addresses.
    public var customProviderDetails: [PiCustomProvider] = []
    /// How each copied item stands against theirs: "login:<provider>", "customProviders",
    /// "defaultModel", "trust".
    public var freshness: [String: PiFreshness] = [:]
    /// When their auth.json last changed.
    public var yourSignInsChanged: Date?
    /// Their trusted folders, for "4 folders · ~/code/shepherd and 3 more".
    public var trustedFolderPaths: [String] = []

    public init(folder: String? = nil) {
        self.folder = folder
    }

    /// What was copied of `kind`.
    public func copies(_ kind: YourPiResourceKind) -> [YourPiCopy] {
        copies.filter { $0.kind == kind }
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
            guard PiProviders.names[provider] != nil || provider == CLIProxyAPIStore.provider, !PiProviders.ambient.contains(provider),
                  !shepherdCustomProviders.contains(provider), !missing.contains(provider) else { continue }
            let login = logins.first { $0.provider == provider }
            if login?.shepherd == nil, login?.environment.isEmpty ?? true { missing.append(provider) }
        }
        return missing
    }
}

/// One of the user's extensions in Settings ▸ Pi ▸ From your pi: its copy, whether it is switched
/// on, and why it didn't load.
public struct YourPiExtensionRow: Equatable, Sendable, Identifiable {
    public var copy: YourPiCopy
    public var on: Bool
    /// Switched on, but left out of launches: pi's reason.
    public var failure: String?
    /// Its package.json's description, when it has one.
    public var summary: String?
    /// pi's last lines as it failed (Show log).
    public var failureLines: [String] = []

    public init(copy: YourPiCopy, on: Bool = false, failure: String? = nil, summary: String? = nil) {
        self.copy = copy
        self.on = on
        self.failure = failure
        self.summary = summary
    }

    public var id: String { copy.destination }
}

/// Copies the user's pi into Shepherd's pi home: logins, custom providers, the default model and
/// trust, then instructions, skills, prompts, themes and extensions as files, all as plain files: their
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
    /// Where Settings ▸ Skills keeps the skills that are switched off (`SkillsStore`): a copied
    /// skill found there is copied again there, and the first copy never adds a second of its name.
    public let offSkills: URL

    public init(home: PiHome, yourPi: YourPi?, userHome: String = NSHomeDirectory(), offSkills: URL? = nil,
                log: @escaping @Sendable (String) -> Void = { ShepherdLog.info($0) }) {
        self.home = home
        self.yourPi = yourPi
        self.userHome = userHome
        self.offSkills = offSkills ?? YourPiImport.offSkillsDirectory(home: home)
        self.log = log
    }

    /// `<support directory>/skills/off`, beside the home, where `SkillsStore` moves a skill that is off.
    public static func offSkillsDirectory(home: PiHome) -> URL {
        home.directory.deletingLastPathComponent().appendingPathComponent("skills/off", isDirectory: true)
    }

    /// Changes to the state file wait for one another.
    private static let stateLock = NSLock()
    /// So do copies of files into the home.
    private static let filesLock = NSLock()

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

    /// Loads the state (a fresh one when there's none), applies `change` and saves it, with no
    /// other change in between.
    @discardableResult
    func updateState<T>(_ change: (inout YourPiImportState) throws -> T) throws -> T {
        try Self.stateLock.withLock {
            var state = self.state() ?? YourPiImportState(copiedAt: Date(), from: nil, copied: false)
            let before = state
            let value = try change(&state)
            if state != before { try save(state) }
            return value
        }
    }

    // MARK: The first copy

    /// Copies everything once: nothing when it already ran. Shepherd's own logins, custom
    /// providers, default model and files win over theirs (a sign-in made in Shepherd's pi before
    /// this build is kept). The home must be ready (`PiSetup.prepare` passed). A state file that
    /// is there but can't be read counts as a copy that ran: a damaged file never copies again.
    /// A state from before files were copied (version 1) gets its files copied once, quietly.
    public func copyOnce(now: Date = Date(), progress: (@Sendable (YourPiImportProgress) -> Void)? = nil) -> YourPiImportReport {
        var info = stat()
        let exists = lstat(stateURL.path, &info) == 0
        let saved = exists ? state() : nil
        let filesOnly = saved?.copied == true && (saved?.version ?? YourPiImportState.currentVersion) < YourPiImportState.currentVersion
        if exists, saved?.copied != false, !filesOnly { return YourPiImportReport() }
        var report = YourPiImportReport()
        report.first = !filesOnly
        if let yourPi {
            report.from = yourPi.agentDirectory.path
            if !filesOnly { progress?(.started(from: yourPi.agentDirectory.path)) }
            func step(_ step: YourPiImportStep, _ body: (inout YourPiImportReport) -> Void) {
                progress?(.running(step))
                body(&report)
                progress?(.finished(step, report: report))
            }
            if !filesOnly {
                step(.logins) { copyLogins(from: yourPi, overwriting: nil, into: &$0) }
                // Logins and keys come from one file, together.
                progress?(.finished(.apiKeys, report: report))
                step(.customProviders) { copyModels(from: yourPi, overwrite: false, into: &$0) }
                step(.defaultModel) { copyDefaultModel(from: yourPi, overwrite: false, into: &$0) }
                step(.trustedFolders) { copyTrust(from: yourPi, into: &$0) }
            }
            step(.files) { copyFiles(of: [.instructions, .skills, .prompts, .themes], from: yourPi, replacing: false, into: &$0) }
            step(.extensions) { copyFiles(of: [.extensions], from: yourPi, replacing: false, into: &$0) }
        }
        do {
            try updateState { state in
                state.version = YourPiImportState.currentVersion
                if !filesOnly {
                    state.copied = true
                    state.copiedAt = now
                    state.from = yourPi?.agentDirectory.path
                }
                record(report.copied, in: &state)
                state.digests.merge(report.digests) { $1 }
                try dropLegacyEntries(&state)
            }
        } catch {
            report.problems.append("Shepherd couldn't record the copy from your pi: \(error)")
        }
        log("copied from your pi (\(report.from ?? "none")): \(report.summary)"
            + (report.skipped.isEmpty ? "" : "; passed over: \(report.skipped.joined(separator: " "))")
            + (report.problems.isEmpty ? "" : "; problems: \(report.problems.joined(separator: " "))"))
        return report
    }

    // MARK: Copying again

    /// What Settings ▸ Pi ▸ From your pi copies again, each overwriting Shepherd's copy.
    public enum Item: Equatable, Hashable, Sendable {
        /// One provider's login.
        case login(String)
        /// Every login their pi has, overwriting Shepherd's (Sign-in's Re-import from your pi, and
        /// the first launch's Retry).
        case logins
        case customProviders
        case defaultModel
        case trust
        /// Every file of a kind: their instructions, skills, prompts, themes or extensions.
        case files(YourPiResourceKind)
    }

    /// Copies `item` again, overwriting Shepherd's copy. Throws with the reason when their pi
    /// lacks it or its file is unreadable (Shepherd's copy is then left as it was). Files copied
    /// again replace the copies made before, and those Shepherd's own (a skill installed in
    /// Settings ▸ Skills of the same name) stay; nothing is removed that their pi no longer has,
    /// except an instructions file pi would now pick over theirs.
    @discardableResult
    public func reimport(_ item: Item) throws -> YourPiImportReport {
        guard let yourPi else { throw YourPiFileError("Shepherd found no pi of yours to copy from.") }
        var report = YourPiImportReport()
        report.from = yourPi.agentDirectory.path
        switch item {
        case .login(let provider): copyLogins(from: yourPi, overwriting: provider, into: &report)
        case .logins: copyLogins(from: yourPi, overwriting: nil, replacing: true, into: &report)
        case .customProviders: copyModels(from: yourPi, overwrite: true, into: &report)
        case .defaultModel: copyDefaultModel(from: yourPi, overwrite: true, into: &report)
        case .trust: copyTrust(from: yourPi, into: &report)
        case .files(let kind):
            copyFiles(of: [kind], from: yourPi, replacing: true, into: &report)
            if report.copied.isEmpty, report.problems.isEmpty {
                report.problems.append("Your pi has no \(Self.noun(kind)) to copy.")
            }
            try updateState { state in
                // Only a clean copy retires the old files: one of theirs that couldn't be read
                // (or none at all) leaves Shepherd's copy as it was.
                if kind == .instructions, report.problems.isEmpty {
                    try retireInstructions(keeping: Set(report.copied.map(\.destination)), in: &state)
                }
                record(report.copied, in: &state)
                if kind == .extensions { try applyExtensions(&state) }
            }
        }
        if !report.digests.isEmpty {
            try updateState { $0.digests.merge(report.digests) { $1 } }
        }
        if let problem = report.problems.first { throw YourPiFileError(problem, detail: report.signInsUnreadable?.reason) }
        log("copied again from your pi: \(report.summary)")
        return report
    }

    static func noun(_ kind: YourPiResourceKind) -> String {
        switch kind {
        case .instructions: "instructions"
        case .skills: "skills"
        case .prompts: "prompts"
        case .themes: "themes"
        case .extensions: "extensions"
        }
    }

    // MARK: Files

    /// Copies every file of `kinds` found in their pi into the home. The first copy leaves one
    /// already there (a skill installed in Shepherd, an instructions file) as it is; `replacing`
    /// replaces the copies Shepherd made before, never files of Shepherd's own.
    private func copyFiles(of kinds: [YourPiResourceKind], from yourPi: YourPi, replacing: Bool, into report: inout YourPiImportReport) {
        // One copy at a time: two replacing one folder at once would trip over each other's rename.
        Self.filesLock.lock()
        defer { Self.filesLock.unlock() }
        let settings: [String: Any]?
        do {
            settings = try YourPiFiles.read(yourPi.agentDirectory.appendingPathComponent("settings.json"))
                .map { try YourPiFiles.object($0, file: "settings.json") }
        } catch {
            report.problems.append("Your pi's settings couldn't be read, so only its own folders were copied: \(error).")
            settings = nil
        }
        let earlier = Set((state()?.copies ?? []).map(\.destination))
        // Each copy has its own staging folder, so none clears another's (from an earlier
        // process that stopped mid-copy, say) as it ends.
        let stagingRoot = home.directory.appendingPathComponent(".shepherd-staging", isDirectory: true)
        let staging = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: staging)
            rmdir(stagingRoot.path)
        }
        for kind in kinds {
            let listing = YourPiResources.find(kind, agentDirectory: yourPi.agentDirectory, settings: settings, userHome: userHome)
            report.skipped += listing.skipped
            for found in listing.found {
                var destination = home.directory.appendingPathComponent(found.copy.destination)
                if kind == .skills {
                    let off = offSkills.appendingPathComponent(found.copy.name, isDirectory: true)
                    if exists(off) { destination = off }
                }
                if exists(destination), !(replacing && earlier.contains(found.copy.destination)) {
                    if !earlier.contains(found.copy.destination) {
                        report.skipped.append("Shepherd kept its own \(found.copy.destination) over your pi's.")
                    }
                    continue
                }
                do {
                    let result = try YourPiTree.copy(found.source, to: destination, staging: staging, limits: found.limits,
                                                     fileName: found.singleFileSkill ? "SKILL.md" : nil)
                    for companion in found.companions {
                        try YourPiTree.copy(companion.source, to: home.directory.appendingPathComponent(companion.destination),
                                            staging: staging, limits: found.limits)
                    }
                    if !result.leftOut.isEmpty {
                        report.skipped.append("Left out of \(found.copy.destination), as links that lead nowhere or back up their folder, "
                            + "or not files: \(result.leftOut.prefix(5).joined(separator: ", ")).")
                    }
                    report.copied.append(found.copy)
                } catch {
                    report.problems.append("Your \(Self.noun(kind)) \(found.copy.name) (\(found.copy.source)) wasn't copied: \(error).")
                }
            }
        }
    }

    /// Adds `copies` to the state, each replacing one of its destination.
    private func record(_ copies: [YourPiCopy], in state: inout YourPiImportState) {
        for copy in copies {
            if let index = state.copies.firstIndex(where: { $0.destination == copy.destination }) {
                state.copies[index] = copy
            } else {
                state.copies.append(copy)
            }
        }
    }

    /// Removes the instructions files an earlier copy made that their pi no longer has, so pi
    /// picks the one they use now (an old `AGENTS.md` would win over a new `CLAUDE.md`).
    private func retireInstructions(keeping current: Set<String>, in state: inout YourPiImportState) throws {
        for copy in state.copies(.instructions) where !current.contains(copy.destination) {
            let url = home.directory.appendingPathComponent(copy.destination)
            if exists(url) { try FileManager.default.removeItem(at: url) }
            state.copies.removeAll { $0.destination == copy.destination }
        }
    }

    /// Takes version 1's settings entries, which read the user's pi in place, out of Shepherd's
    /// settings.json.
    private func dropLegacyEntries(_ state: inout YourPiImportState) throws {
        guard !state.legacySkills.isEmpty || !state.legacyPrompts.isEmpty else { return }
        let legacy = (skills: state.legacySkills, prompts: state.legacyPrompts)
        let notes = try PiSettingsFile(url: home.settings).update { settings in
            for (key, old) in [("skills", legacy.skills), ("prompts", legacy.prompts)] {
                let kept = (settings[key] as? [Any] ?? []).filter { entry in (entry as? String).map { !old.contains($0) } ?? true }
                if kept.isEmpty { settings.removeValue(forKey: key) } else { settings[key] = kept }
            }
            return []
        }
        guard notes.isEmpty else { throw YourPiFileError(notes.joined(separator: " ")) }
        state.legacySkills = []
        state.legacyPrompts = []
    }

    private func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// The skills copied from the user's pi, by folder name, with where each came from (for
    /// Settings ▸ Skills' Source). Reads the state only.
    public func copiedSkills() -> [String: String] {
        Dictionary((state()?.copies(.skills) ?? []).map { ($0.name, $0.source) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Extensions

    /// Switches one of the user's extensions (by its copy's `destination`) on or off. On clears a
    /// failure, so it is tried again at the next launch.
    public func setExtension(_ destination: String, on: Bool) throws {
        try updateState { state in
            guard state.copies.contains(where: { $0.kind == .extensions && $0.destination == destination }) else {
                throw YourPiFileError("Shepherd has no copy of that extension.")
            }
            state.extensionsOn.removeAll { $0 == destination }
            if on { state.extensionsOn.append(destination) }
            state.extensionFailures[destination] = nil
            try applyExtensions(&state)
        }
    }

    /// An opted-in extension failed to load at `path` (pi's words: `Failed to load extension
    /// "<path>": <reason>`): it is left out of launches, with `reason`, until its files change or
    /// the user tries again. Returns its name, or nil when `path` isn't one of the user's
    /// switched-on extensions (Shepherd's own, a project's): nothing changes then.
    @discardableResult
    public func extensionFailed(path: String, reason: String, lines: [String] = []) throws -> String? {
        let canonical = PiHome.canonical(path)
        return try updateState { state -> String? in
            guard let copy = state.copies(.extensions).first(where: { copy in
                state.extensionsOn.contains(copy.destination) && state.extensionFailures[copy.destination] == nil
                    && PiHome.isInside(canonical, PiHome.canonical(home.directory.appendingPathComponent(copy.destination).path))
            }) else { return nil }
            state.extensionFailures[copy.destination] = YourPiExtensionFailure(reason: Self.shortened(reason), modified: modified(copy),
                                                                               lines: Array(lines.suffix(NativeStartProblem.maxLines)))
            try applyExtensions(&state)
            return copy.name
        }
    }

    /// The failures pi reports for extensions on its stderr: each path and reason.
    public static func extensionFailures(in lines: [String]) -> [(path: String, reason: String)] {
        lines.compactMap { line in
            guard let start = line.range(of: "Failed to load extension \""),
                  let end = line[start.upperBound...].range(of: "\": ") else { return nil }
            var reason = String(line[end.upperBound...])
            if reason.hasPrefix("Failed to load extension: ") { reason.removeFirst("Failed to load extension: ".count) }
            return (String(line[start.upperBound..<end.lowerBound]), reason)
        }
    }

    /// Writes the switched-on extensions' files into Shepherd's settings.json `extensions`: each
    /// that is there and hasn't failed (or whose files changed since it did). Blocking, briefly:
    /// run before every launch (`PiSetup.prepare`).
    public func applyExtensions() throws {
        try updateState { state in try applyExtensions(&state) }
    }

    private func applyExtensions(_ state: inout YourPiImportState) throws {
        var entries: [String] = []
        for destination in state.extensionsOn {
            guard let copy = state.copies(.extensions).first(where: { $0.destination == destination }) else { continue }
            let paths = (copy.entries ?? [""]).map { entry in
                (entry.isEmpty ? home.directory.appendingPathComponent(copy.destination)
                    : home.directory.appendingPathComponent(copy.destination).appendingPathComponent(entry)).standardizedFileURL.path
            }
            let now = modified(copy)
            if let failure = state.extensionFailures[destination] {
                // Its files changed since: try it again.
                guard now != failure.modified else { continue }
                state.extensionFailures[destination] = nil
            }
            guard paths.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) else {
                state.extensionFailures[destination] = YourPiExtensionFailure(
                    reason: "Its files are missing from Shepherd's pi. Re-import your extensions to copy them again.", modified: now)
                continue
            }
            entries += paths
        }
        let previous = state.extensionEntries
        let notes = try PiSettingsFile(url: home.settings).update { settings in
            let others = (settings["extensions"] as? [Any] ?? []).filter { entry in
                guard let text = entry as? String else { return true }
                return !previous.contains(text) && !entries.contains(text)
            }
            let merged = others + entries.map { $0 as Any }
            if merged.isEmpty { settings.removeValue(forKey: "extensions") } else { settings["extensions"] = merged }
            return []
        }
        guard notes.isEmpty else { throw YourPiFileError(notes.joined(separator: " ")) }
        state.extensionEntries = entries
    }

    /// When an extension's copy last changed: the newest of its entry files.
    private func modified(_ copy: YourPiCopy) -> Double {
        let root = home.directory.appendingPathComponent(copy.destination)
        return (copy.entries ?? [""]).map { entry -> Double in
            var info = stat()
            let path = entry.isEmpty ? root.path : root.appendingPathComponent(entry).path
            guard stat(path, &info) == 0 else { return -1 }
            return Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        }.max() ?? -1
    }

    /// pi's reason, on one line and short enough for a row.
    /// Why a file of theirs couldn't be read, in the parser's words where it gave some ("Unexpected
    /// character '}' around line 31, column 5."), never the file's contents.
    static func parserReason(_ error: Error) -> String {
        (error as? YourPiFileError).map { $0.detail ?? $0.description } ?? String(describing: error)
    }

    static func shortened(_ reason: String) -> String {
        let line = reason.split(whereSeparator: \.isNewline).first.map(String.init) ?? reason
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 300 ? String(trimmed.prefix(299)) + "…" : trimmed
    }

    // MARK: The pieces

    private func copyLogins(from yourPi: YourPi, overwriting provider: String?, replacing: Bool = false,
                            into report: inout YourPiImportReport) {
        let theirs: [String: [String: Any]]
        do {
            guard let data = try YourPiFiles.read(yourPi.agentDirectory.appendingPathComponent("auth.json")) else {
                if provider != nil { report.problems.append("Your pi has no sign-ins to copy.") }
                return
            }
            theirs = try YourPiFiles.credentials(data)
        } catch {
            report.problems.append("Your pi's sign-ins couldn't be read: \(error).")
            report.signInsUnreadable = (yourPi.agentDirectory.appendingPathComponent("auth.json").path, Self.parserReason(error))
            return
        }
        if let provider, theirs[provider] == nil {
            report.problems.append("Your pi has no sign-in for \(PiProviders.name(provider)).")
            return
        }
        var copied: [PiLogin] = []
        var kept: [String] = []
        var digests: [String: String] = [:]
        do {
            let notes = try PiSettingsFile(url: auth, mode: 0o600).update { ours in
                for (name, credential) in theirs.sorted(by: { $0.key < $1.key }) {
                    if let provider, name != provider { continue }
                    if provider == nil, !replacing, ours[name] != nil { kept.append(name); continue }
                    ours[name] = credential
                    copied.append(YourPiFiles.login(provider: name, credential: credential))
                    if let digest = PiDigest.of(credential) { digests["login:\(name)"] = digest }
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
        report.digests.merge(digests) { $1 }
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
            report.digests["customProviders"] = Self.modelsDigest(data)
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
        if let kept { report.keptDefaultModel = kept } else {
            report.defaultModel = theirs
            report.digests["defaultModel"] = PiDigest.of(theirs)
        }
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
            report.digests["trust"] = PiDigest.of(decisions)
        } catch {
            report.problems.append("Your pi's trusted folders weren't copied: \(error).")
        }
    }

    /// models.json as pi reads it (comments and a BOM aside), so a copy written back byte for byte
    /// or not compares the same.
    static func modelsDigest(_ data: Data) -> String? {
        (try? YourPiFiles.object(data, file: "models.json")).flatMap { PiDigest.of($0) }
    }

    // MARK: Reading both sides

    /// Shepherd's pi and theirs, side by side, for Settings ▸ Pi and the welcome step. Plain reads.
    /// `environmentKeys` are the provider variables their login shell sets (names only).
    public func survey(environmentKeys: Set<String> = []) -> YourPiSurvey {
        var survey = YourPiSurvey(folder: yourPi?.agentDirectory.path)
        let state = self.state()
        survey.copied = state?.copied == true
        survey.copies = state?.copies ?? []
        if let context = survey.copies(.instructions).first(where: { YourPiFiles.contextFileNames.contains($0.name) }),
           let data = try? YourPiFiles.read(home.directory.appendingPathComponent(context.destination)) {
            let text = String(decoding: data, as: UTF8.self)
            survey.instructionLines = text.split(separator: "\n", omittingEmptySubsequences: false).count - (text.hasSuffix("\n") ? 1 : 0)
        }
        survey.extensions = survey.copies(.extensions).map { copy in
            let root = home.directory.appendingPathComponent(copy.destination)
            let summary = (try? YourPiFiles.read(root.appendingPathComponent("package.json")))
                .flatMap { $0 }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["description"] as? String
            var row = YourPiExtensionRow(copy: copy, on: state?.extensionsOn.contains(copy.destination) == true,
                                         failure: state?.extensionFailures[copy.destination]?.reason, summary: summary)
            row.failureLines = state?.extensionFailures[copy.destination]?.lines ?? []
            return row
        }

        survey.copiedAt = state?.copied == true ? state?.copiedAt : nil
        let digests = state?.digests ?? [:]
        let mineCredentials = (try? YourPiFiles.read(auth)).flatMap { $0 }.flatMap { try? YourPiFiles.credentials($0) } ?? [:]
        let mine = mineCredentials.map { YourPiFiles.login(provider: $0.key, credential: $0.value) }.sorted { $0.provider < $1.provider }
        for (provider, credential) in mineCredentials {
            if let key = credential["key"] as? String, credential["type"] as? String == "api_key" { survey.keys[provider] = .of(key) }
            if let copied = digests["login:\(provider)"], PiDigest.of(credential) == copied { survey.copiedLogins.insert(provider) }
        }
        var theirs: [PiLogin] = []
        var theirSettings: [String: Any]?
        if let yourPi {
            let folder = yourPi.agentDirectory
            do {
                let credentials = try YourPiFiles.read(folder.appendingPathComponent("auth.json")).map(YourPiFiles.credentials) ?? [:]
                theirs = credentials.map { YourPiFiles.login(provider: $0.key, credential: $0.value) }.sorted { $0.provider < $1.provider }
                for (provider, credential) in credentials {
                    if let key = credential["key"] as? String, credential["type"] as? String == "api_key" { survey.yourKeys[provider] = .of(key) }
                    let ours = mineCredentials[provider]
                    let expiry = { (c: [String: Any]?) in (c?["expires"] as? NSNumber)?.doubleValue ?? 0 }
                    survey.freshness["login:\(provider)"] = PiFreshness.compare(
                        ours: ours.flatMap { PiDigest.of($0) }, theirs: PiDigest.of(credential), copied: digests["login:\(provider)"],
                        theirsNewer: expiry(credential) > expiry(ours))
                }
                var info = stat()
                if stat(folder.appendingPathComponent("auth.json").path, &info) == 0 {
                    survey.yourSignInsChanged = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
                }
            } catch {
                survey.problems.append("Your pi's sign-ins couldn't be read: \(error).")
            }
            do {
                let data = try YourPiFiles.read(folder.appendingPathComponent("models.json"))
                survey.customProviders = try data.map(YourPiFiles.customProviders) ?? []
                survey.freshness["customProviders"] = PiFreshness.compare(
                    ours: (try? YourPiFiles.read(models)).flatMap { $0 }.flatMap(Self.modelsDigest), theirs: data.flatMap(Self.modelsDigest),
                    copied: digests["customProviders"])
            } catch {
                survey.problems.append("Your pi's custom providers couldn't be read: \(error).")
            }
            do { theirSettings = try YourPiFiles.read(folder.appendingPathComponent("settings.json")).map { try YourPiFiles.object($0, file: "settings.json") } } catch {
                survey.problems.append("Your pi's settings couldn't be read: \(error).")
            }
            survey.defaultModel = YourPiFiles.defaultModel(theirSettings)
            do {
                let decisions = try YourPiFiles.read(folder.appendingPathComponent("trust.json")).map { try YourPiFiles.trust($0, home: userHome).decisions } ?? [:]
                survey.trustedFolders = decisions.count
                survey.trustedFolderPaths = decisions.filter(\.value).keys.sorted()
                let ours = (try? YourPiFiles.read(trust)).flatMap { $0 }.flatMap { try? YourPiFiles.trust($0, home: userHome).decisions }
                survey.freshness["trust"] = decisions.isEmpty ? nil
                    : PiFreshness.compare(ours: ours.flatMap { PiDigest.of($0) }, theirs: PiDigest.of(decisions), copied: digests["trust"])
            } catch {
                survey.problems.append("Your pi's trusted folders couldn't be read: \(error).")
            }
        }
        survey.shepherdCustomProviders = (try? YourPiFiles.read(models)).flatMap { $0 }.flatMap { try? YourPiFiles.customProviders($0) } ?? []
        survey.customProviderDetails = (try? YourPiFiles.read(models)).flatMap { $0 }.flatMap { try? PiCustomProvider.parse($0) } ?? []
        if CLIProxyAPIStore.configured(in: home), !survey.shepherdCustomProviders.contains(CLIProxyAPIStore.provider) {
            survey.shepherdCustomProviders.append(CLIProxyAPIStore.provider)
        }
        let ownSettings = (try? YourPiFiles.read(home.settings)).flatMap { $0 }.flatMap { try? YourPiFiles.object($0, file: "settings.json") }
        survey.shepherdDefaultModel = YourPiFiles.defaultModel(ownSettings)
        if let theirs = survey.defaultModel {
            survey.freshness["defaultModel"] = PiFreshness.compare(ours: survey.shepherdDefaultModel.flatMap(PiDigest.of),
                                                                   theirs: PiDigest.of(theirs), copied: digests["defaultModel"])
        }
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
