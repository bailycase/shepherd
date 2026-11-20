import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdTestKit
import Testing
@testable import ShepherdSessions

extension StateStoreTests {
    // Keep the reference golden frozen. StateRecoveryTests, YourPiImportEdgeTests and HookCatalogTests
    // exercise the new policies for these damaged inputs instead of asserting the old rewrites.
    private static let damagedRows: Set<String> = [
        "workspace-invalid-split", "workspace-dangling-tab", "workspace-unreadable-agent", "workspace-truncated",
        "pi-import-bad-element", "pi-import-damaged", "hook-settings-bad-element", "hook-settings-damaged",
    ]

    @Test func historicalFilesLoadAndRewriteAsRecorded() async throws {
        try await ValidationGolden.check("c-state.json", from: #filePath,
                                         completion: "persisted file shapes matched the golden", excluding: Self.damagedRows) { golden in
            try await Self.observeFiles(seed: golden.seed, observe: golden.observe)
        }
    }

    private static func observeFiles(seed: Any, observe: (String, [String: Any]) throws -> Void) async throws {
        let seed = try #require(seed as? [String: Any])
        let files = try #require(seed["files"] as? [[String: Any]])
        let now = Date(timeIntervalSince1970: try #require(seed["writeTime"] as? Double))
        for file in files {
            let step = try #require(file["case"] as? String)
            guard !damagedRows.contains(step) else { continue }
            let path = try #require(file["file"] as? String)
            let dir = try makeScratchDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent(path)
            let input: Data
            if let raw = file["malformed"] as? String {
                input = Data(raw.utf8)
            } else {
                input = try JSONSerialization.data(withJSONObject: try #require(file["json"]), options: [.sortedKeys])
            }
            let result = try await observeFile(at: url, path: path, root: dir, input: input, now: now, step: step)
            try observe(step, result)
        }
    }

    private static let agent = AgentID(rawValue: "00000000-0000-4000-8000-000000000001")
    private static let automation = AutomationID(rawValue: "00000000-0000-4000-8000-000000000002")
    private static let writerID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 9))

    private static func observeFile(at url: URL, path: String, root: URL, input: Data, now: Date, step: String) async throws -> [String: Any] {
        let fm = FileManager.default
        func install() throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try input.write(to: url)
        }
        func json<T: Encodable>(_ value: T) throws -> Any {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
        }
        if path != "design/thread-notes.json" { try install() }
        let loaded: Any
        var outcome: [String: Any] = [:]
        var ids: [String: String] = [:]
        switch path {
        case "state.json":
            let store = StateStore(url: url)
            let backups = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("state.json.") }
            loaded = try json(store.state)
            if step == "workspace-lenient-values" {
                // The encoder omits the standard tier, so record its decoded value separately.
                outcome["loadedServiceTier"] = store.state.agents.first?.serviceTier.rawValue
            }
            outcome["fileStillPresentAfterLoad"] = fm.fileExists(atPath: url.path)
            outcome["quarantinedCopies"] = backups.count
            if !backups.isEmpty { outcome["quarantineMatchesInput"] = try backups.allSatisfy { try Data(contentsOf: $0) == input } }
            try store.update { _ in }
        case "automation-runs.json":
            let store = AutomationRunLog(url: url)
            loaded = try json(store.runs[automation] ?? [])
            store.recordFailure(automation, trigger: nil, triggerURL: nil, message: "Sample write", now: now)
            if let id = store.runs[automation]?.last?.id { ids[id.uuidString] = "<new-run>" }
            store.flush()
        case "automation-triggers.json":
            var calendar = Calendar(identifier: .iso8601)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let store = AutomationTriggers(url: url, clock: { now }, calendar: calendar)
            let status = await store.status(of: Automation(id: automation, name: "Sample", prompt: "Check", cwd: "/tmp/acme"))
            loaded = try json(status)
            await store.setAllPaused(!status.allPaused)
            await store.setAllPaused(status.allPaused)
        case "changes/turns.json":
            let store = TurnStore(url: url)
            loaded = try json(store.all(agent))
            try store.updateAndCheckpoint(agent) { _ in }
        case "changes/bases.json":
            let store = ChangesRecents(url: url)
            let repository = "/tmp/acme"
            let bases = store.list(repository)
            loaded = bases
            store.note(bases.first ?? "main", repository: repository)
        case "thread-origins/sample.json":
            let store = ThreadOriginStore(directory: url.deletingLastPathComponent())
            let session = store.loadSession(sessionID: "sample")
            loaded = ["entries": try session.entries.map { ["id": $0.id, "record": try json($0.record)] },
                      "questions": try json(session.questions)]
            store.save(sessionID: "sample", records: session.entries, questions: session.questions)
            store.flush()
        case "instructions/history.json":
            let store = InstructionsStore(directory: url.deletingLastPathComponent())
            loaded = try json(store.snapshot().history)
            let after = try store.save(.agents, content: "Sample write\n", now: now)
            if let id = after.history.first?.id { ids[id.uuidString] = "<new-revision>" }
        case "forge-pins.json":
            let store = ForgeService(pinsURL: url, now: { now })
            loaded = try json(store.loadPins())
            store.setPinned(ForgeItemRef(kind: .issue, repo: "acme/web", number: 99), title: "", pinned: false)
        case "push-registrations.json":
            let store = PushNotifications(file: url, queue: DispatchQueue(label: "validation.push-registrations"))
            loaded = try json(store.registrations.values.sorted { $0.id < $1.id })
            try store.unregister(writerID.uuidString)
        case "design/thread-notes.json":
            let store = DesignStore(directory: root)
            let design = DesignID(rawValue: "design")
            _ = try await store.create(design, title: "Sample design", at: now)
            try install()
            let notes = try await store.threadNotes(design)
            loaded = try json(notes)
            let board = try #require(DesignPath("other.dc.html"))
            let note = DesignThreadNote(id: writerID, agentID: agent, thread: "Sample writer", board: board,
                                        revision: 1, text: "Sample write", createdAt: now.timeIntervalSince1970 * 1000)
            _ = try await store.addThreadNote(design, note)
            _ = try await store.removeThreadNote(design, noteID: writerID)
        case "hooks/settings.json":
            let store = HookSettingsStore(support: root)
            let settings = try store.read()
            loaded = try json(settings)
            try store.setReader(.claude, !settings.readers.claude)
            try store.setReader(.claude, settings.readers.claude)
        case "suggestions.json":
            let store = SuggestionsStore(url: url, instructions: InstructionsStore(directory: root))
            let snapshot = store.snapshot()
            loaded = try json(snapshot)
            try store.configure(snapshot.settings, now: now)
        case "skills/skills.json":
            let state = url.deletingLastPathComponent()
            let directory = root.appendingPathComponent("active/sample")
            let skill = directory.appendingPathComponent("SKILL.md")
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("---\nname: sample\ndescription: Sample skill\n---\n".utf8).write(to: skill)
            try fm.setAttributes([.modificationDate: now], ofItemAtPath: skill.path)
            let store = SkillsStore(directory: directory.deletingLastPathComponent(), stateDirectory: state, now: { now })
            let snapshot = store.snapshot()
            loaded = try json(snapshot)
            try store.configure(autoUpdate: !snapshot.autoUpdate)
            try store.configure(autoUpdate: snapshot.autoUpdate)
        case "pi/.shepherd-imports.json":
            let engine = PiEngine(command: [], packageDirectory: nil, version: nil, node: .executable("/usr/bin/false"))
            let home = PiHome(directory: url.deletingLastPathComponent(), engine: engine, userHome: root.path)
            let store = YourPiImport(home: home, yourPi: nil, userHome: root.path)
            let state = try #require(store.state())
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            loaded = try JSONSerialization.jsonObject(with: encoder.encode(state))
            try store.updateState { $0.copied.toggle() }
            try store.updateState { $0 = state }
        default:
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        func normalized(_ value: Any) -> Any {
            // The suggestions and push schemas encode sets as arrays in hash order. Preserve the
            // order of recents, history, and all other arrays.
            if path == "suggestions.json", var object = value as? [String: Any], var settings = object["settings"] as? [String: Any] {
                for key in ["files", "sources"] { settings[key] = (settings[key] as? [String])?.sorted() }
                object["settings"] = settings
                return object
            }
            if path == "push-registrations.json", let registrations = value as? [[String: Any]] {
                return registrations.map { registration in
                    var registration = registration
                    if var preferences = registration["preferences"] as? [String: Any] {
                        preferences["topics"] = (preferences["topics"] as? [String])?.sorted()
                        registration["preferences"] = preferences
                    }
                    return registration
                }.sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
            }
            return ValidationGolden.normalize(value, ids: ids, root: root.path)
        }
        outcome["loaded"] = normalized(loaded)
        outcome["rewritten"] = try normalized(JSONSerialization.jsonObject(with: Data(contentsOf: url)))
        return outcome
    }
}
