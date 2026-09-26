import Foundation
import ShepherdProtocol
import ShepherdRemote

/// Settings ▸ Skills on this host (docs/skills.md): the agent skills every pi session here can
/// use. A skill is a folder with a SKILL.md in `directory` (~/.agents/skills, which pi reads at
/// startup). Beside it, in `stateDirectory` (the support directory's `skills/`), Shepherd keeps
/// the skills that are off (`off/`, out of pi's sight), the ones just removed (`removed/`, for
/// Undo, kept a day), a partial clone of each repository skills came from (`repos/`), and
/// `skills.json`: where each installed skill came from, the update a check found, and Update
/// automatically.
///
/// A folder someone copied into `directory` by hand is a Local skill: it has no source and never
/// updates. Everything else about a skill (its description, how it's used) is read from its
/// SKILL.md, so a hand edit shows at once.
///
/// Every method blocks (git fetches from the network), so the server calls it on its own queue
/// and the Mac's Settings page off the main thread. A lock makes each change whole; fetching and
/// exporting run under a second lock, outside the first, so the page can read while an install
/// fetches.
public final class SkillsStore: @unchecked Sendable {
    public enum StoreError: Error, Equatable, CustomStringConvertible {
        case noSuchSkill(String)
        case alreadyThere(String)
        case notARepository(String)
        case noSkills(String)
        case noSuchPath(String)
        case invalidFiles(String)
        case git(String)
        case writeFailed(String)

        /// The code a remote client gets with the message.
        public var code: String {
            switch self {
            case .noSuchSkill: "no_such_skill"
            case .alreadyThere: "conflict"
            case .notARepository: "not_a_repository"
            case .noSkills: "no_skills"
            case .noSuchPath: "no_such_path"
            case .invalidFiles: "invalid"
            case .git: "git_failed"
            case .writeFailed: "write_failed"
            }
        }

        public var description: String {
            switch self {
            case .noSuchSkill(let name): "There's no skill named \(name) here."
            case .alreadyThere(let name): "A skill named \(name) is already there."
            case .notARepository(let input): "“\(input)” isn't a repository. Use owner/repo, or a git URL."
            case .noSkills(let repo): "\(repo) has no skills: no folder in it holds a SKILL.md."
            case .noSuchPath(let path): "The repository has no skill at \(path.isEmpty ? "its top" : path)."
            case .invalidFiles(let reason): reason
            case .git(let message): message
            case .writeFailed(let reason): "Couldn't change the skills: \(reason)"
            }
        }
    }

    /// How long a removed skill waits for Undo.
    public static let keepsRemoved: TimeInterval = 24 * 3600
    /// How often a host looks for newer commits of its skills.
    public static let checkInterval: TimeInterval = 24 * 3600
    /// A repository's SKILL.md as Add from repo previews it, at most (less when it has many).
    static let previewBytes = 16 * 1024
    /// What every preview in one answer may add up to, under the 1 MiB frame cap.
    static let previewBudget = 600 * 1024

    /// What reads the skills this host's pi loads from outside `directory` (`PiSkillsLoader`).
    public typealias PiSkillsReader = @Sendable (_ installedDirectory: URL) -> PiSkills

    public let directory: URL
    public let stateDirectory: URL
    private let now: () -> Date
    private let lock = NSLock()
    private let gitLock = NSLock()
    private let piLock = NSLock()
    private var reader: PiSkillsReader?

    public init(directory: URL, stateDirectory: URL, now: @escaping () -> Date = Date.init, piSkills: PiSkillsReader? = nil) {
        self.directory = directory
        self.stateDirectory = stateDirectory
        self.now = now
        reader = piSkills
    }

    /// Reads the skills pi loads from elsewhere into every answer (`SkillsSnapshot.pi`); nil
    /// leaves them out.
    public var piSkills: PiSkillsReader? {
        get { piLock.withLock { reader } }
        set { piLock.withLock { reader = newValue } }
    }

    // MARK: Requests

    /// A remote client's request (`RemoteRequest.skills`), or the Mac's own page's. Every answer
    /// with the host's skills carries pi's own beside them, read outside the store's lock.
    public func perform(_ request: RemoteSkillsRequest) throws -> RemoteSkillsResult {
        switch request {
        case .fetch: .skills(withPi(snapshot()))
        case .lookUp(let repo): .repo(try lookUp(repo))
        case .install(let repo, let paths, let commit, let invocation):
            .skills(withPi(try install(repo: repo, paths: paths, commit: commit, invocation: invocation)))
        case .installFiles(let name, let files, let invocation):
            .skills(withPi(try installFiles(name: name, files: files, invocation: invocation)))
        case .setOn(let name, let on): .skills(withPi(try setOn(name, on: on)))
        case .setInvocation(let name, let invocation): .skills(withPi(try setInvocation(name, invocation)))
        case .remove(let name): .skills(withPi(try remove(name)))
        case .restore(let name): .skills(withPi(try restore(name)))
        case .checkUpdates: .skills(withPi(try checkUpdates()))
        case .configure(let autoUpdate): .skills(withPi(try configure(autoUpdate: autoUpdate)))
        }
    }

    /// `snapshot` with the skills pi loads from elsewhere, when a reader is set.
    public func withPi(_ snapshot: SkillsSnapshot) -> SkillsSnapshot {
        guard let reader = piSkills else { return snapshot }
        var snapshot = snapshot
        snapshot.pi = reader(directory)
        return snapshot
    }

    /// The skills as they are now, by name.
    public func snapshot() -> SkillsSnapshot {
        lock.withLock { unlockedSnapshot() }
    }

    // MARK: Changes

    /// Moves a skill out of the folder pi reads (off) or back into it (on).
    @discardableResult
    public func setOn(_ name: String, on: Bool) throws -> SkillsSnapshot {
        try lock.withLock {
            try Self.check(name)
            let from = (on ? offDirectory : directory).appendingPathComponent(name, isDirectory: true)
            let to = (on ? directory : offDirectory).appendingPathComponent(name, isDirectory: true)
            if isSkill(to), !isSkill(from) { return unlockedSnapshot() }
            guard isSkill(from) else { throw StoreError.noSuchSkill(name) }
            guard !exists(to) else { throw StoreError.alreadyThere(name) }
            try writing {
                try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: from, to: to)
            }
            return unlockedSnapshot()
        }
    }

    /// Rewrites the skill's SKILL.md for how it's used (`disable-model-invocation`).
    @discardableResult
    public func setInvocation(_ name: String, _ invocation: SkillInvocation) throws -> SkillsSnapshot {
        try lock.withLock {
            try Self.check(name)
            guard let folder = locate(name)?.folder else { throw StoreError.noSuchSkill(name) }
            try writing { try Self.apply(invocation, to: folder) }
            return unlockedSnapshot()
        }
    }

    /// Takes a skill off the host, on or off; `restore` puts it back for a day.
    @discardableResult
    public func remove(_ name: String) throws -> SkillsSnapshot {
        try lock.withLock {
            try Self.check(name)
            guard let found = locate(name) else { throw StoreError.noSuchSkill(name) }
            var records = loadRecords()
            let date = now().timeIntervalSince1970
            let kept = removedDirectory.appendingPathComponent(name, isDirectory: true)
            try writing {
                try FileManager.default.createDirectory(at: removedDirectory, withIntermediateDirectories: true)
                if exists(kept) { try FileManager.default.removeItem(at: kept) }
                try FileManager.default.moveItem(at: found.folder, to: kept)
                records.removed[name] = Removed(wasOn: found.isOn, record: records.skills[name], removedAt: date)
                records.skills[name] = nil
                prune(&records, at: date)
                try save(records)
            }
            return unlockedSnapshot()
        }
    }

    /// Puts back a skill `remove` took, where it was (on or off).
    @discardableResult
    public func restore(_ name: String) throws -> SkillsSnapshot {
        try lock.withLock {
            try Self.check(name)
            var records = loadRecords()
            let kept = removedDirectory.appendingPathComponent(name, isDirectory: true)
            guard let removed = records.removed[name], exists(kept) else { throw StoreError.noSuchSkill(name) }
            guard locate(name) == nil else { throw StoreError.alreadyThere(name) }
            let destination = (removed.wasOn ? directory : offDirectory).appendingPathComponent(name, isDirectory: true)
            try writing {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: kept, to: destination)
                records.skills[name] = removed.record
                records.removed[name] = nil
                try save(records)
            }
            return unlockedSnapshot()
        }
    }

    /// Update automatically: a check that finds a newer commit installs it.
    @discardableResult
    public func configure(autoUpdate: Bool) throws -> SkillsSnapshot {
        try lock.withLock {
            var records = loadRecords()
            if records.autoUpdate != autoUpdate {
                records.autoUpdate = autoUpdate
                try writing { try save(records) }
            }
            return unlockedSnapshot()
        }
    }

    // MARK: Installing

    /// The skills in a repository, at its default branch's newest commit (Add from repo).
    public func lookUp(_ repo: String) throws -> RepoSkills {
        guard let reference = SkillsText.reference(repo) else { throw StoreError.notARepository(repo) }
        return try gitLock.withLock {
            let git = repository(for: reference)
            let (branch, commit) = try fetching(reference) { try git.refresh() }
            let entries = try reading { try git.tree(commit) }
            let folders = Self.skillFolders(in: entries)
            guard !folders.isEmpty else { throw StoreError.noSkills(reference.repo) }
            let texts = try reading { try git.contents(folders.map { $0.skillFile.object }) }
            let budget = min(Self.previewBytes, Self.previewBudget / folders.count)
            var skills: [RepoSkill] = []
            for (folder, data) in zip(folders, texts) {
                let text = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                let frontmatter = SkillsText.frontmatter(text)
                skills.append(RepoSkill(
                    path: folder.path, name: SkillsText.folderName(for: frontmatter, path: folder.path, repo: reference.repo),
                    summary: frontmatter.description ?? "", instructions: Self.prefix(text, bytes: budget),
                    files: Self.entries(folder.files, under: folder.path)))
            }
            skills.sort { $0.name < $1.name }
            return RepoSkills(repo: reference.repo, branch: branch, commit: commit, skills: skills)
        }
    }

    /// Installs the skills at `paths` in a repository, at `commit` (nil: the newest on its default
    /// branch). One already here by the same name is replaced where it is, on or off, keeping how
    /// it's used unless `invocation` says otherwise; a new one is on and automatic unless it says.
    @discardableResult
    public func install(repo: String, paths: [String], commit: String?, invocation: SkillInvocation?) throws -> SkillsSnapshot {
        guard let reference = SkillsText.reference(repo) else { throw StoreError.notARepository(repo) }
        let staging = stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let staged: [Staged] = try gitLock.withLock {
            let git = repository(for: reference)
            let resolved: String
            if let commit {
                if FileManager.default.fileExists(atPath: git.directory.appendingPathComponent(".git").path) {
                    resolved = try fetching(reference) { try git.commit(commit) }
                } else {
                    _ = try fetching(reference) { try git.refresh() }
                    resolved = try fetching(reference) { try git.commit(commit) }
                }
            } else {
                resolved = try fetching(reference) { try git.refresh() }.commit
            }
            let entries = try reading { try git.tree(resolved) }
            let folders = Self.skillFolders(in: entries)
            var result: [Staged] = []
            for path in Set(paths).sorted() {
                guard let folder = folders.first(where: { $0.path == path }) else { throw StoreError.noSuchPath(path) }
                let contents = try reading { try git.contents(folder.files.map(\.object)) }
                let skillIndex = folder.files.firstIndex { $0.path == folder.skillFile.path }
                let skillData = skillIndex.flatMap { contents[$0] }
                let skillText = skillData.map { String(decoding: $0, as: UTF8.self) } ?? ""
                let name = SkillsText.folderName(for: SkillsText.frontmatter(skillText), path: path, repo: reference.repo)
                guard !result.contains(where: { $0.name == name }) else { continue }
                let target = staging.appendingPathComponent(name, isDirectory: true)
                try writing {
                    for (entry, data) in zip(folder.files, contents) {
                        guard let data else { throw StoreError.git("Couldn't read \(entry.path) from \(reference.repo).") }
                        let relative = path.isEmpty ? entry.path : String(entry.path.dropFirst(path.count + 1))
                        try Self.write(data, to: target.appendingPathComponent(relative), executable: entry.isExecutable)
                    }
                }
                let change = try reading { try git.lastChange(of: path, at: resolved) }
                result.append(Staged(name: name, folder: target,
                                     source: SkillSource(repo: reference.repo, path: path, commit: change.commit,
                                                         committedAt: change.date)))
            }
            return result
        }
        return try lock.withLock {
            var records = loadRecords()
            let date = now().timeIntervalSince1970
            try writing {
                for skill in staged {
                    let existing = locate(skill.name)
                    let current = existing.map { SkillsText.invocation(Self.skillText(in: $0.folder)) }
                    try Self.apply(invocation ?? current ?? SkillsText.invocation(Self.skillText(in: skill.folder)), to: skill.folder)
                    let destination = existing?.folder ?? directory.appendingPathComponent(skill.name, isDirectory: true)
                    try swap(skill.folder, into: destination)
                    records.skills[skill.name] = Record(source: skill.source, installedAt: date)
                    records.removed[skill.name] = nil
                }
                try save(records)
            }
            return unlockedSnapshot()
        }
    }

    /// Installs a skill from its files: a folder copied from another Mac. It is Local here.
    @discardableResult
    public func installFiles(name: String, files: [SkillFile], invocation: SkillInvocation) throws -> SkillsSnapshot {
        try Self.check(name)
        guard files.contains(where: { $0.path == "SKILL.md" }) else {
            throw StoreError.invalidFiles("A skill needs a SKILL.md at the top of its folder.")
        }
        guard files.reduce(0, { $0 + $1.contents.count }) <= SkillFile.maxTotalBytes else {
            throw StoreError.invalidFiles("\(name) is too big to copy to another host. Put it in a git repository instead.")
        }
        let staging = stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let target = staging.appendingPathComponent(name, isDirectory: true)
        try writing {
            for file in files {
                guard Self.isSafe(file.path) else { throw StoreError.invalidFiles("\(file.path) isn't a path inside the skill.") }
                try Self.write(file.contents, to: target.appendingPathComponent(file.path), executable: file.executable)
            }
            try Self.apply(invocation, to: target)
        }
        return try lock.withLock {
            var records = loadRecords()
            try writing {
                let destination = locate(name)?.folder ?? directory.appendingPathComponent(name, isDirectory: true)
                try swap(target, into: destination)
                records.skills[name] = nil
                records.removed[name] = nil
                try save(records)
            }
            return unlockedSnapshot()
        }
    }

    // MARK: Updates

    /// Looks for a newer commit of every installed skill's folder in its repository, and with
    /// Update automatically on installs what it finds. A repository that can't be reached keeps
    /// what the last check found.
    @discardableResult
    public func checkUpdates() throws -> SkillsSnapshot {
        let records = lock.withLock { loadRecords() }
        var found: [String: SkillUpdate?] = [:]
        let byRepo = Dictionary(grouping: records.skills, by: { $0.value.source.repo })
        gitLock.withLock {
            for (repo, skills) in byRepo.sorted(by: { $0.key < $1.key }) {
                guard let reference = SkillsText.reference(repo) else { continue }
                let git = repository(for: reference)
                guard let tip = try? git.refresh(), let entries = try? git.tree(tip.commit) else { continue }
                let folders = Self.skillFolders(in: entries)
                for (name, record) in skills {
                    let source = record.source
                    // A skill its repository no longer has has nothing to update to.
                    guard let folder = folders.first(where: { $0.path == source.path }),
                          let newest = try? git.lastChange(of: source.path, at: tip.commit),
                          newest.commit != source.commit else {
                        found.updateValue(nil, forKey: name)
                        continue
                    }
                    let diffed = try? git.changedFiles(under: source.path, from: source.commit, to: newest.commit)
                    let changed = diffed ?? folder.files.count
                    let update: SkillUpdate? = changed == 0
                        ? nil : SkillUpdate(commit: newest.commit, committedAt: newest.date, filesChanged: changed)
                    found.updateValue(update, forKey: name)
                }
            }
        }
        let (snapshot, autoUpdate) = try lock.withLock {
            var records = loadRecords()
            for (name, update) in found where records.skills[name] != nil {
                records.skills[name]?.update = update
            }
            records.checkedAt = now().timeIntervalSince1970
            try writing { try save(records) }
            return (unlockedSnapshot(), records.autoUpdate)
        }
        guard autoUpdate else { return snapshot }
        var updated = snapshot
        for skill in snapshot.skills {
            guard let source = skill.source, let update = skill.update else { continue }
            if let installed = try? install(repo: source.repo, paths: [source.path], commit: update.commit, invocation: nil) {
                updated = installed
            }
        }
        return updated
    }

    /// Checks for updates when the last check is a day old, or there was none.
    @discardableResult
    public func checkUpdatesIfDue() -> SkillsSnapshot? {
        let checkedAt = lock.withLock { loadRecords().checkedAt }
        if let checkedAt, now().timeIntervalSince1970 - checkedAt < Self.checkInterval { return nil }
        return (try? checkUpdates()).map(withPi)
    }

    // MARK: Records

    private struct Record: Codable {
        var source: SkillSource
        var installedAt: Double
        var update: SkillUpdate?
    }

    private struct Removed: Codable {
        var wasOn: Bool
        var record: Record?
        var removedAt: Double
    }

    private struct Records: Codable {
        var version = 1
        var autoUpdate = false
        var checkedAt: Double?
        var skills: [String: Record] = [:]
        var removed: [String: Removed] = [:]

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
            autoUpdate = try c.decodeIfPresent(Bool.self, forKey: .autoUpdate) ?? false
            checkedAt = try c.decodeIfPresent(Double.self, forKey: .checkedAt)
            skills = try c.decodeIfPresent([String: Record].self, forKey: .skills) ?? [:]
            removed = try c.decodeIfPresent([String: Removed].self, forKey: .removed) ?? [:]
        }
    }

    private struct Staged {
        var name: String
        var folder: URL
        var source: SkillSource
    }

    private var offDirectory: URL { stateDirectory.appendingPathComponent("off", isDirectory: true) }
    private var removedDirectory: URL { stateDirectory.appendingPathComponent("removed", isDirectory: true) }
    private var reposDirectory: URL { stateDirectory.appendingPathComponent("repos", isDirectory: true) }
    private var stagingDirectory: URL { stateDirectory.appendingPathComponent("staging", isDirectory: true) }
    private var recordsURL: URL { stateDirectory.appendingPathComponent("skills.json") }

    private func loadRecords() -> Records {
        guard let data = try? Data(contentsOf: recordsURL), let records = try? JSONDecoder().decode(Records.self, from: data) else {
            return Records()
        }
        return records
    }

    private func save(_ records: Records) throws {
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(records).write(to: recordsURL, options: .atomic)
    }

    /// Forgets removed skills older than a day, and their folders.
    private func prune(_ records: inout Records, at date: Double) {
        for (name, removed) in records.removed where date - removed.removedAt > Self.keepsRemoved {
            records.removed[name] = nil
            try? FileManager.default.removeItem(at: removedDirectory.appendingPathComponent(name, isDirectory: true))
        }
    }

    // MARK: Reading the folders

    private func unlockedSnapshot() -> SkillsSnapshot {
        let records = loadRecords()
        var skills: [String: InstalledSkill] = [:]
        for (base, isOn) in [(offDirectory, false), (directory, true)] {
            for name in skillNames(in: base) {
                let folder = base.appendingPathComponent(name, isDirectory: true)
                let frontmatter = SkillsText.frontmatter(Self.skillText(in: folder))
                let record = records.skills[name]
                let modified = (try? folder.appendingPathComponent("SKILL.md").resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate?.timeIntervalSince1970 ?? 0
                // On wins over a stray copy of the same name that is off.
                skills[name] = InstalledSkill(
                    name: name, summary: frontmatter.description ?? "", isOn: isOn, invocation: frontmatter.invocation,
                    source: record?.source, updatedAt: record.map { max($0.installedAt, modified) } ?? modified,
                    files: Self.entries(of: folder), update: record?.update)
            }
        }
        return SkillsSnapshot(directory: (directory.path as NSString).abbreviatingWithTildeInPath,
                              skills: skills.values.sorted { $0.name < $1.name }, checkedAt: records.checkedAt,
                              autoUpdate: records.autoUpdate)
    }

    /// The folders in `base` that hold a SKILL.md, skipping hidden ones as pi does.
    private func skillNames(in base: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        return names.filter { name in
            !name.hasPrefix(".") && name != "node_modules" && isSkill(base.appendingPathComponent(name, isDirectory: true))
        }
    }

    private func locate(_ name: String) -> (folder: URL, isOn: Bool)? {
        let on = directory.appendingPathComponent(name, isDirectory: true)
        if isSkill(on) { return (on, true) }
        let off = offDirectory.appendingPathComponent(name, isDirectory: true)
        return isSkill(off) ? (off, false) : nil
    }

    private func isSkill(_ folder: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent("SKILL.md").path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    private func exists(_ url: URL) -> Bool {
        (try? url.checkResourceIsReachable()) == true
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// Puts `staged` where `destination` is, replacing what's there only once the new folder is
    /// in place.
    private func swap(_ staged: URL, into destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard exists(destination) else {
            try fileManager.moveItem(at: staged, to: destination)
            return
        }
        let old = stagingDirectory.appendingPathComponent("replaced-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try fileManager.moveItem(at: destination, to: old)
        do {
            try fileManager.moveItem(at: staged, to: destination)
        } catch {
            try? fileManager.moveItem(at: old, to: destination)
            throw error
        }
        try? fileManager.removeItem(at: old)
    }

    private func repository(for reference: SkillRepoReference) -> SkillsGit {
        SkillsGit(directory: reposDirectory.appendingPathComponent(Self.cacheName(reference), isDirectory: true),
                  cloneURL: reference.cloneURL)
    }

    /// A fetch that fails names the repository and git's reason.
    private func fetching<T>(_ reference: SkillRepoReference, _ work: () throws -> T) throws -> T {
        do {
            return try work()
        } catch let failure as SkillsGit.Failure {
            throw StoreError.git("Couldn't fetch \(reference.repo): \(failure.message)")
        }
    }

    private func reading<T>(_ work: () throws -> T) throws -> T {
        do {
            return try work()
        } catch let failure as SkillsGit.Failure {
            throw StoreError.git(failure.message)
        }
    }

    private func writing(_ work: () throws -> Void) throws {
        do {
            try work()
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: Helpers

    /// A skill's folder in a repository: its path ("" when the repository is the skill), its
    /// SKILL.md, and every file under it.
    struct RepoFolder {
        var path: String
        var skillFile: SkillsGit.Entry
        var files: [SkillsGit.Entry]
    }

    /// Every folder in the tree that holds a SKILL.md, outside `node_modules`.
    static func skillFolders(in entries: [SkillsGit.Entry]) -> [RepoFolder] {
        let files = entries.filter { $0.isFile && !$0.path.split(separator: "/").contains("node_modules") }
        return files.compactMap { entry -> RepoFolder? in
            guard entry.path == "SKILL.md" || entry.path.hasSuffix("/SKILL.md") else { return nil }
            let path = entry.path == "SKILL.md" ? "" : String(entry.path.dropLast("/SKILL.md".count))
            let prefix = path.isEmpty ? "" : path + "/"
            return RepoFolder(path: path, skillFile: entry, files: files.filter { $0.path.hasPrefix(prefix) })
        }
    }

    /// A folder's top level as the page's chips show it: SKILL.md first, the other files by name,
    /// then the folders with how many files each holds.
    static func entries(of folder: URL) -> [SkillFileEntry] {
        let fileManager = FileManager.default
        let names = ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }
        var entries: [SkillFileEntry] = []
        for name in names {
            let url = folder.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                entries.append(SkillFileEntry(name: name))
                continue
            }
            var count = 0
            if let walk = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                for case let item as URL in walk where (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                    count += 1
                }
            }
            entries.append(SkillFileEntry(name: name, isDirectory: true, fileCount: count))
        }
        return sorted(entries)
    }

    /// The same for a folder in a repository.
    static func entries(_ files: [SkillsGit.Entry], under path: String) -> [SkillFileEntry] {
        var top: [String: SkillFileEntry] = [:]
        for file in files {
            let relative = path.isEmpty ? file.path : String(file.path.dropFirst(path.count + 1))
            let parts = relative.split(separator: "/", maxSplits: 1).map(String.init)
            guard let first = parts.first, !first.hasPrefix(".") else { continue }
            if parts.count == 1 {
                top[first] = SkillFileEntry(name: first)
            } else {
                top[first, default: SkillFileEntry(name: first, isDirectory: true, fileCount: 0)].fileCount += 1
            }
        }
        return sorted(Array(top.values))
    }

    private static func sorted(_ entries: [SkillFileEntry]) -> [SkillFileEntry] {
        entries.sorted { a, b in
            if (a.name == "SKILL.md") != (b.name == "SKILL.md") { return a.name == "SKILL.md" }
            if a.isDirectory != b.isDirectory { return !a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    static func skillText(in folder: URL) -> String {
        (try? String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8)) ?? ""
    }

    /// Sets how a skill is used in its SKILL.md, writing only when that changes it.
    private static func apply(_ invocation: SkillInvocation, to folder: URL) throws {
        let url = folder.appendingPathComponent("SKILL.md")
        let text = skillText(in: folder)
        let rewritten = SkillsText.setting(invocation, in: text)
        guard rewritten != text else { return }
        try Data(rewritten.utf8).write(to: url, options: .atomic)
    }

    private static func write(_ data: Data, to url: URL, executable: Bool) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
    }

    /// A name that stays one folder inside the skills directory.
    private static func check(_ name: String) throws {
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains("\0"), name.count <= 255 else {
            throw StoreError.invalidFiles("“\(name)” isn't a skill's name.")
        }
    }

    /// A relative path that stays inside its folder.
    private static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    /// The text cut to at most `bytes`, at a line's end.
    private static func prefix(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var result = ""
        var count = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let size = line.utf8.count + 1
            guard count + size <= bytes else { break }
            result += String(line) + "\n"
            count += size
        }
        return result
    }

    /// A readable, stable folder name for a repository's cache ("github.com-anthropics-skills").
    static func cacheName(_ reference: SkillRepoReference) -> String {
        let base = reference.gitHub.map { "github.com-" + $0 } ?? reference.cloneURL
        let readable = String(base.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "-" }.prefix(80))
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in reference.cloneURL.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "\(readable)-\(String(hash, radix: 16).prefix(8))"
    }
}
