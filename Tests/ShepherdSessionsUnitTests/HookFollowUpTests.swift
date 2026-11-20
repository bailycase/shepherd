import Darwin
import Foundation
import Testing
@testable import ShepherdProtocol
@testable import ShepherdSessions

/// Follow-ups to the disabled-hook fixes: an inbound Fleet op that can't be applied is retried, not recorded;
/// adding a hook back is an explicit enable; lookups share the writer's lock; and the host's server queue
/// never waits for a settings lock another process holds.
@Suite("Hook follow-ups")
struct HookFollowUpTests {
    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T
        init(_ value: T) { stored = value }
        var value: T {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    static let event = "PreToolUse"
    static let handler = HookJSON.object(["command": .string("./check.sh"), "type": .string("command"), "x-note": .string("kept")])
    static var id: String { FleetHooksSource.id(event: event, matcher: "Bash", handler: handler) }
    static var draft: HookDraft { HookDraft(event: event, matcher: "Bash", handler: HookHandler(raw: handler)) }
    static func value(on: Bool) -> Data {
        Data(HookJSON.object(["event": .string(event), "handler": handler, "matcher": .string("Bash"), "on": .bool(on)]).canonical.utf8)
    }

    /// Whether another file descriptor can't take the settings lock right now.
    static func isLocked(_ store: HookSettingsStore) -> Bool {
        let fd = open(store.url.deletingLastPathComponent().appendingPathComponent("settings.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return flock(fd, LOCK_EX | LOCK_NB) != 0
    }

    // MARK: Inbound ops while the catalog is churning

    @Test(arguments: [false, true])
    func anInboundOpIsRetriedNotRecordedWhileTheHookFilesKeepChanging(upsert: Bool) throws {
        let f = try HookCatalogTests.Fixture(); defer { f.remove() }
        let path = f.home + "/.shepherd/hooks.json"
        try f.write(path, HookCatalogTests.preToolUse)
        var catalog = f.catalog
        let reads = Box(0)
        catalog.readSettings = { store in
            reads.value += 1
            try? #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"./c\#(reads.value).sh"}]}]}}"#.write(toFile: path, atomically: true, encoding: .utf8)
            return try store.read()
        }
        let churning = catalog
        let source = FleetHooksSource(catalog: { churning })
        #expect(throws: (any Error).self) {
            try source.write(FleetHooksSource.kind + Self.id, upsert ? Self.value(on: true) : nil, origin: "B")
        }
        #expect(f.catalog.load().entries.count == 1, "an upsert didn't append a duplicate")
    }

    // MARK: Adding a hook back is an explicit enable

    /// A hook that was turned off and then deleted leaves its off record; every way of adding the same bytes again turns it on.
    @Test(arguments: ["add", "settings save", "fleet", "edit"])
    func addingADeletedDisabledHookAgainIsAnExplicitEnable(how: String) throws {
        let f = try HookCatalogTests.Fixture(); defer { f.remove() }
        let catalog = f.catalog
        let path = f.home + "/.shepherd/hooks.json"
        let writer = HookFileWriter(settings: catalog.settingsStore)
        let hash = try writer.add(Self.draft, to: path, on: false)
        try writer.delete(#require(catalog.load().entries.first))
        #expect(try catalog.settingsStore.read().off == [hash], "deleting keeps the off record")

        switch how {
        case "add": try writer.add(Self.draft, to: path)
        case "settings save": try writer.save([Self.draft], to: path, replacing: nil, kept: nil)
        case "fleet": try FleetHooksSource(catalog: { catalog }).write(FleetHooksSource.kind + Self.id, Self.value(on: true), origin: "B")
        default:
            let other = HookDraft(event: Self.event, matcher: "Bash", handler: .command("./other.sh"))
            try writer.add(other, to: path)
            try writer.update(#require(catalog.load().entries.first), to: Self.draft)
        }
        let entry = try #require(catalog.load().entries.first { $0.handler.command == "./check.sh" })
        #expect(entry.on && entry.hash == hash)
        #expect(try catalog.settingsStore.read().off.isEmpty)
    }

    @Test func editingOrDeletingADisabledHookNeverRemovesItsOffRecord() throws {
        let f = try HookCatalogTests.Fixture(); defer { f.remove() }
        let catalog = f.catalog
        let path = f.home + "/.shepherd/hooks.json"
        let writer = HookFileWriter(settings: catalog.settingsStore)
        let hash = try writer.add(Self.draft, to: path, on: false)
        let other = HookDraft(event: Self.event, matcher: "Bash", handler: .command("./other.sh"))
        let edited = try writer.update(#require(catalog.load().entries.first), to: other)
        let off = try catalog.settingsStore.read().off
        #expect(Set(off) == [hash, edited], "the edit carries the switch and keeps the old record")
        try writer.delete(#require(catalog.load().entries.first))
        #expect(Set(try catalog.settingsStore.read().off) == [hash, edited])
    }

    // MARK: One lock for the lookup and the change

    @Test func aRemoteSwitchLooksTheHookUpUnderTheSettingsLock() throws {
        let f = try HookCatalogTests.Fixture(); defer { f.remove() }
        try f.write(f.home + "/.shepherd/hooks.json", HookCatalogTests.preToolUse)
        var catalog = f.catalog
        let locked = Box<[Bool]>([])
        catalog.readSettings = { store in
            locked.value.append(Self.isLocked(store))
            return try store.read()
        }
        let hash = try #require(f.catalog.load().entries.first).hash
        _ = try catalog.perform(.setOn(hash: hash, on: false), spaceRoots: [])
        #expect(locked.value.contains(true))
        #expect(try catalog.settingsStore.read().off == [hash])
    }

    @Test(arguments: [false, true])
    func aFleetWriteLooksTheHookUpUnderTheSettingsLock(upsert: Bool) throws {
        let f = try HookCatalogTests.Fixture(); defer { f.remove() }
        try f.write(f.home + "/.shepherd/hooks.json", HookCatalogTests.preToolUse)
        var catalog = f.catalog
        let locked = Box<[Bool]>([])
        catalog.readSettings = { store in
            locked.value.append(Self.isLocked(store))
            return try store.read()
        }
        let reading = catalog
        try FleetHooksSource(catalog: { reading }).write(FleetHooksSource.kind + Self.id, upsert ? Self.value(on: false) : nil, origin: "B")
        #expect(locked.value.contains(true))
    }

    // MARK: The server queue never waits for the settings lock

    @Test(.timeLimit(.minutes(1))) func aFleetWriteGivesUpWhileAnotherProcessHoldsTheSettingsLockAndSucceedsOnceItIsFree() throws {
        let f = try HookCatalogTests.Fixture(); defer { f.remove() }
        let catalog = f.catalog
        let source = FleetHooksSource(catalog: { catalog })
        let folder = catalog.settingsStore.url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fd = open(folder.appendingPathComponent("settings.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        try #require(fd >= 0)
        try #require(flock(fd, LOCK_EX) == 0)
        var held = true
        defer { if held { close(fd) } }

        let outcome = Box<[String]>([])
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            for unit in [FleetHooksSource.kind + Self.id, FleetHooksSource.readers] {
                let value = unit == FleetHooksSource.readers ? Data(#"{"claude":false,"codex":true}"#.utf8) : Self.value(on: true)
                do { try source.write(unit, value, origin: "B"); outcome.value.append("wrote") }
                catch is HookSettingsStore.Busy { outcome.value.append("busy") }
                catch { outcome.value.append("\(error)") }
            }
            finished.signal()
        }
        let returned = finished.wait(timeout: .now() + 10) == .success
        close(fd)
        held = false
        if !returned { finished.wait() }
        #expect(returned, "the write returned while the lock was held")
        #expect(outcome.value == ["busy", "busy"])
        #expect(catalog.load().entries.isEmpty, "nothing was written")

        try source.write(FleetHooksSource.kind + Self.id, Self.value(on: true), origin: "B")
        #expect(catalog.load().entries.map(\.hash).count == 1)
    }
}
