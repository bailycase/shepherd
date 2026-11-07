import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// A remote thread's Files tree: lazy folders, the filter over expanded ones, and one file read in place.
@Suite("Thread files model")
@MainActor
struct ThreadFilesModelTests {
    nonisolated static let tree: [String: ThreadFileListing] = [
        "": ThreadFileListing(entries: [ThreadFileEntry(name: "Widgets", kind: .directory), ThreadFileEntry(name: "render.py", kind: .file, size: 40)]),
        "Widgets": ThreadFileListing(entries: [ThreadFileEntry(name: "NeedsYouWidget.swift", kind: .file, size: 900),
                                               ThreadFileEntry(name: "Count.swift", kind: .file, size: 10)], truncated: true),
    ]

    static func model(read: @escaping ThreadFilesModel.Read = { _ in Data("let x = 1\n".utf8) }) -> ThreadFilesModel {
        ThreadFilesModel(list: { path, _ in
            guard let listing = tree[path] else { throw RemoteHostClientError.rejected(code: "not_found", message: "No such file or folder") }
            return listing
        }, read: read)
    }

    @Test func foldersLoadWhenOpenedAndTheFilterKeepsFolders() async {
        let model = Self.model()
        await model.loadIfNeeded()
        #expect(model.phase == .loaded)
        #expect(model.rows.map(\.id) == ["Widgets", "render.py"])

        await model.toggle("Widgets")
        #expect(model.rows.map(\.id) == ["Widgets", "Widgets/NeedsYouWidget.swift", "Widgets/Count.swift", "Widgets/…", "render.py"])
        #expect(model.rows[1].depth == 1 && model.rows[3].kind == .note)
        #expect(model.rows[0].kind == .folder(expanded: true, loading: false))

        model.filter = "needs"
        #expect(model.rows.map(\.id) == ["Widgets", "Widgets/NeedsYouWidget.swift", "Widgets/…"])
        model.filter = ""
        await model.toggle("Widgets")
        #expect(model.rows.map(\.id) == ["Widgets", "render.py"])
    }

    @Test func aFileOpensInPlaceAndAFailureSaysWhy() async {
        let model = Self.model(read: { path in
            if path == "blob" { throw RemoteHostClientError.rejected(code: "binary", message: "Binary file (not UTF-8 text)") }
            return Data("let x = 1\n".utf8)
        })
        await model.open("render.py")
        #expect(model.openPath == "render.py" && model.content == .text("let x = 1\n"))
        await model.open("blob")
        #expect(model.content == .failed("Binary file (not UTF-8 text)"))
        model.close()
        #expect(model.openPath == nil)
    }

    @Test func collapsedListingsStayBoundedAndKeepCurrentContent() async {
        let root = ThreadFileListing(entries: (0..<20).map { ThreadFileEntry(name: "dir\($0)", kind: .directory) })
        let files = ThreadFileListing(entries: (0..<200).map { ThreadFileEntry(name: "file\($0)", kind: .file) })
        let text = String(repeating: "x", count: 256 << 10)
        let model = ThreadFilesModel(list: { path, _ in path.isEmpty ? root : files }, read: { _ in Data(text.utf8) })
        await model.loadIfNeeded()
        await model.open("selected")
        for index in 0..<20 {
            await model.toggle("dir\(index)")
            #expect(model.retainedEntryCount == 220)
            await model.toggle("dir\(index)")
            #expect(model.retainedEntryCount == 20)
            #expect(model.rows.count == 20 && model.content == .text(text))
        }
    }

    @Test func coldReentryRestoresNestedExpansionFilterSelectionAndOpenFile() async {
        let tree: [String: ThreadFileListing] = [
            "": .init(entries: [.init(name: "dir", kind: .directory)]),
            "dir": .init(entries: [.init(name: "nested", kind: .directory)]),
            "dir/nested": .init(entries: [.init(name: "keep", kind: .file), .init(name: "other", kind: .file)])
        ]
        let model = ThreadFilesModel(list: { path, _ in tree[path]! }, read: { _ in Data("content".utf8) })
        await model.loadIfNeeded()
        await model.toggle("dir")
        await model.toggle("dir/nested")
        model.filter = "keep"
        await model.open("dir/nested/keep")
        let rows = model.rows
        await model.toggle("dir")
        #expect(model.retainedEntryCount == 1)
        await model.toggle("dir")
        #expect(model.rows == rows)
        model.releasePayload()
        #expect(model.retainedCost == 0 && model.rows.isEmpty)
        #expect(model.openPath == "dir/nested/keep" && model.selectedPath == model.openPath)
        await model.loadIfNeeded()
        #expect(model.rows == rows && model.filter == "keep" && model.content == .text("content"))
        model.close()
        #expect(model.selectedPath == "dir/nested/keep")
    }

    @Test func evictionFencesAnOldRootWithoutClobberingItsReplacement() async {
        let fresh = ThreadFileListing(entries: [.init(name: "fresh", kind: .file)])
        let gate = FilesFirstReply<ThreadFileListing>()
        let model = ThreadFilesModel(list: { _, _ in await gate.request(fresh) }, read: { _ in Data() })
        let old = Task { await model.loadIfNeeded() }
        await gate.waitUntilHeld()
        model.releasePayload()
        await model.loadIfNeeded()
        #expect(model.rows.map(\.id) == ["fresh"])
        await gate.finish(.init(entries: [.init(name: "stale", kind: .file)]))
        await old.value
        #expect(model.rows.map(\.id) == ["fresh"] && !model.hasPendingRequests)
    }

    @Test(arguments: [false, true])
    func overlappingDirectoryReadersJoinDespiteFirstReaderCancellation(root: Bool) async {
        let gate = FilesFirstReply<ThreadFileListing>()
        let listing = Self.tree[root ? "" : "Widgets"]!
        let model = ThreadFilesModel(list: { path, _ in
            if !root && path.isEmpty { return Self.tree[""]! }
            return await gate.request(listing)
        }, read: { _ in Data() })
        if !root { await model.loadIfNeeded() }
        let first = Task {
            if root { await model.loadIfNeeded() } else { await model.toggle("Widgets") }
        }
        await gate.waitUntilHeld()
        first.cancel()
        var released = false
        // Queued on this actor: it cannot release until the replacement actually suspends.
        // A premature return from loadIfNeeded fails below without sleeps or scheduling polls.
        let release = Task { @MainActor in
            released = true
            await gate.finish(listing)
        }
        await model.loadIfNeeded()
        #expect(released && model.phase == .loaded)
        #expect(model.rows.count == (root ? 2 : 5))
        await first.value
        await release.value
        #expect(await gate.calls == 1)
        #expect(!model.hasPendingRequests)
    }

    @Test func reexpandingAHeldDirectoryPublishesItsLoadingRowBeforeJoining() async {
        let gate = FilesFirstReply<ThreadFileListing>()
        let model = ThreadFilesModel(list: { path, _ in
            if path.isEmpty { return Self.tree[""]! }
            return await gate.request(Self.tree["Widgets"]!)
        }, read: { _ in Data() })
        await model.loadIfNeeded()
        let first = Task { await model.toggle("Widgets") }
        await gate.waitUntilHeld()
        await model.toggle("Widgets")
        #expect(model.rows[0].kind == .folder(expanded: false, loading: true))
        let release = Task { @MainActor in
            #expect(model.rows[0].kind == .folder(expanded: true, loading: true))
            await gate.finish(Self.tree["Widgets"]!)
        }
        await model.toggle("Widgets")
        #expect(model.rows[0].kind == .folder(expanded: true, loading: false))
        await first.value
        await release.value
        #expect(await gate.calls == 1)
    }

    @Test(arguments: [false, true])
    func joinedReadersCannotRestoreAnEvictedOrForgottenEpoch(forget: Bool) async {
        let gate = FilesFirstReply<ThreadFileListing>()
        let model = ThreadFilesModel(list: { _, _ in await gate.request(Self.tree[""]!) }, read: { _ in Data() })
        let first = Task { await model.loadIfNeeded() }
        await gate.waitUntilHeld()
        let release = Task { @MainActor in
            if forget { model.forget() } else { model.releasePayload() }
            #expect(model.hasPendingRequests) // Invalidating an epoch does not free its reservation.
            await gate.finish(Self.tree[""]!)
        }
        await model.loadIfNeeded()
        await first.value
        await release.value
        #expect(model.rows.isEmpty && model.retainedCost == 0 && !model.hasPendingRequests)
        #expect(await gate.calls == 1) // No old waiter restarted restoration in the new epoch.
        if forget {
            #expect(model.phase == .failed("This thread or host is no longer available."))
            await model.loadIfNeeded()
            #expect(await gate.calls == 1)
        } else {
            await model.loadIfNeeded()
            #expect(model.rows.count == 2)
            #expect(await gate.calls == 2)
        }
    }

    @Test func collapsedDirectoryDiscardsItsLateReplyAndReopensSafely() async {
        let gate = FilesFirstReply<ThreadFileListing>()
        let files = Self.tree["Widgets"]!
        let model = ThreadFilesModel(list: { path, _ in
            if path.isEmpty { return Self.tree[""]! }
            return await gate.request(files)
        }, read: { _ in Data() })
        await model.loadIfNeeded()
        let expanding = Task { await model.toggle("Widgets") }
        await gate.waitUntilHeld()
        await model.toggle("Widgets")
        await gate.finish(files)
        await expanding.value
        #expect(model.retainedEntryCount == 2 && model.rows.count == 2)
        await model.toggle("Widgets")
        #expect(model.retainedEntryCount == 4 && model.rows.count == 5)
    }

    @Test(arguments: [false, true])
    func forgetRejectsLateRootAndDirectoryFailures(root: Bool) async {
        let gate = FilesFirstReply<Int>()
        let model = ThreadFilesModel(list: { path, _ in
            if !root && path.isEmpty { return Self.tree[""]! }
            _ = await gate.request(0)
            throw RemoteHostClientError.rejected(code: "late", message: "Stale failure")
        }, read: { _ in Data() })
        if !root { await model.loadIfNeeded() }
        let request = Task {
            if root { await model.loadIfNeeded() } else { await model.toggle("Widgets") }
        }
        await gate.waitUntilHeld()
        model.forget()
        await gate.finish(0)
        await request.value
        #expect(model.rows.isEmpty && model.retainedCost == 0)
        #expect(model.phase == .failed("This thread or host is no longer available."))
    }

    @Test func cancelledFileReaderDoesNotCancelAJoinedRead() async {
        let gate = FilesFirstReply<Data>()
        let model = Self.model(read: { _ in await gate.request(Data("fresh".utf8)) })
        let first = Task { await model.open("render.py") }
        await gate.waitUntilHeld()
        first.cancel()
        let release = Task { @MainActor in await gate.finish(Data("shared".utf8)) }
        await model.open("render.py")
        #expect(model.content == .text("shared"))
        await first.value
        await release.value
        #expect(await gate.calls == 1)
        #expect(!model.hasPendingRequests)
    }

    @Test func forgottenOpenFileIsUnavailableAndRejectsItsLateReply() async {
        let gate = FilesFirstReply<Data>()
        let model = Self.model(read: { _ in await gate.request(Data("fresh".utf8)) })
        let reading = Task { await model.open("render.py") }
        await gate.waitUntilHeld()
        model.forget()
        #expect(model.hasPendingRequests)
        #expect(model.content == .failed("This thread or host is no longer available."))
        await gate.finish(Data("stale".utf8))
        await reading.value
        await model.loadIfNeeded()
        await model.open("render.py")
        #expect(model.content == .failed("This thread or host is no longer available."))
        #expect(model.retainedCost == 0 && !model.hasPendingRequests)
        #expect(await gate.calls == 1)
    }

    @Test func aFailedRootLoadsAgain() async {
        let model = ThreadFilesModel(list: { _, _ in throw RemoteHostClientError.rejected(code: "update_required", message: "Files needs a newer Shepherd on the host.") },
                                     read: { _ in Data() })
        await model.loadIfNeeded()
        #expect(model.phase == .failed("Files needs a newer Shepherd on the host."))
    }
}

/// Deterministic suspension without a process, polling or sleeps; only the first reply is held.
private actor FilesFirstReply<Value: Sendable> {
    private(set) var calls = 0
    private var reply: CheckedContinuation<Value, Never>?
    private var arrived: CheckedContinuation<Void, Never>?

    func request(_ next: Value) async -> Value {
        calls += 1
        guard calls == 1 else { return next }
        return await withCheckedContinuation { continuation in
            reply = continuation
            arrived?.resume()
            arrived = nil
        }
    }

    func waitUntilHeld() async {
        if reply != nil { return }
        await withCheckedContinuation { arrived = $0 }
    }

    func finish(_ value: Value) {
        reply?.resume(returning: value)
        reply = nil
    }
}

/// A remote thread's Files editor: tabs, saves over the text edited from, conflicts and the agent's changes.
@Suite("Thread files editing")
@MainActor
struct ThreadFilesEditingTests {
    /// A host's file as the edit tests see it: what it holds, and every save asked of it.
    final class Disk: @unchecked Sendable {
        var text = "a\nb\n"
        var saves: [(text: String, expected: String)] = []
    }

    static func editing(_ disk: Disk) -> ThreadFilesModel {
        ThreadFilesModel(list: { _, _ in ThreadFileListing(entries: []) }, read: { _ in Data(disk.text.utf8) }, write: { _, text, expected in
            disk.saves.append((text, expected))
            guard disk.text == expected else { return .changed(disk.text) }
            disk.text = text
            return .saved
        })
    }

    @Test func aSaveWritesOverTheTextItWasEditedFromAndTabsKeepTheirEdits() async {
        let disk = Disk()
        let model = Self.editing(disk)
        await model.open("src/App.tsx")
        model.setText("mine\nb\n", for: "src/App.tsx")
        await model.open("README.md")
        #expect(model.openTabs == ["src/App.tsx", "README.md"])
        await model.open("src/App.tsx")
        #expect(model.edits["src/App.tsx"]?.isDirty == true, "switching tabs keeps unsaved edits")

        await model.save()
        #expect(disk.text == "mine\nb\n" && disk.saves.last?.expected == "a\nb\n")
        #expect(model.edits["src/App.tsx"]?.isDirty == false && model.saveError == nil)

        await model.closeTab("src/App.tsx")
        #expect(model.openTabs == ["README.md"] && model.openPath == "README.md" && model.edits["src/App.tsx"] == nil)
    }

    @Test func aFileThatChangedUnderUnsavedEditsIsAConflictUntilOverwriteOrRevert() async {
        let disk = Disk()
        let model = Self.editing(disk)
        await model.open("a.txt")
        model.setText("mine\nb\n", for: "a.txt")
        disk.text = "a\ntheirs\n"

        await model.save()
        #expect(disk.text == "a\ntheirs\n", "nothing is written over the newer version")
        #expect(model.edits["a.txt"]?.conflict == "a\ntheirs\n" && model.edits["a.txt"]?.text == "mine\nb\n")
        await model.save()
        #expect(disk.saves.count == 1, "a plain Save waits for the person's choice")

        await model.save(overwrite: true)
        #expect(disk.text == "mine\nb\n" && disk.saves.last?.expected == "a\ntheirs\n")
        #expect(model.edits["a.txt"]?.conflict == nil && model.edits["a.txt"]?.isDirty == false)

        model.setText("again\n", for: "a.txt")
        disk.text = "agent\n"
        await model.checkDisk()
        #expect(model.edits["a.txt"]?.conflict == "agent\n")
        model.revert()
        #expect(model.edits["a.txt"]?.text == "agent\n" && model.edits["a.txt"]?.conflict == nil)
    }

    @Test func aCleanEditorTakesTheAgentsChangeAndMarksWhatWasBefore() async {
        let disk = Disk()
        let model = Self.editing(disk)
        await model.open("a.txt")
        let revision = model.textRevision
        disk.text = "a\nagent\n"
        await model.checkDisk()
        #expect(model.edits["a.txt"]?.text == "a\nagent\n" && model.edits["a.txt"]?.before == "a\nb\n")
        #expect(model.textRevision != revision && model.content == .text("a\nagent\n"))
    }

    @Test func unsavedEditsOutliveAPayloadRelease() async {
        let disk = Disk()
        let model = Self.editing(disk)
        await model.open("a.txt")
        await model.open("b.txt")
        model.setText("mine\n", for: "b.txt")
        model.releasePayload()
        #expect(model.edits.keys.sorted() == ["b.txt"])
        model.forget()
        #expect(model.edits.isEmpty)
    }
}
