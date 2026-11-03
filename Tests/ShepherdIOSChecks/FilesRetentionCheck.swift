import Foundation
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote

/// The shipped registry and model, without SwiftUI, disk, networking or timing-based waits.
@main
struct FilesRetentionCheck {
    @MainActor
    static func main() async {
        await visitingAndMultiwindow()
        await byteBudget()
        await pendingAndForget()
        print("FILES RETENTION CHECK COMPLETE")
    }

    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
    }

    static func ref(_ index: Int, host: UUID) -> AgentRef {
        AgentRef(host: host, agent: AgentID(rawValue: "files-\(index)"))
    }

    @MainActor
    static func make(nameLength: Int = 0) -> ThreadFilesModel {
        let root = ThreadFileListing(entries: (0..<20).map { .init(name: "dir\($0)", kind: .directory) })
        let files = ThreadFileListing(entries: (0..<200).map {
            .init(name: String(repeating: "n", count: nameLength) + "file\($0)", kind: .file)
        })
        return ThreadFilesModel(list: { path, _ in path.isEmpty ? root : files },
                                read: { _ in Data(repeating: 120, count: 256 << 10) })
    }

    @MainActor
    static func visitingAndMultiwindow() async {
        let stores = ThreadFilesStores(), host = UUID()
        let pinnedRef = ref(-1, host: host)
        let pinned = stores.model(for: pinnedRef) { make() }
        stores.appeared(pinnedRef, model: pinned)
        stores.appeared(pinnedRef, model: pinned)
        await pinned.loadIfNeeded()
        await pinned.toggle("dir0")
        pinned.filter = "file1"
        await pinned.open("dir0/file1")
        let pinnedRows = pinned.rows
        stores.disappeared(pinnedRef, model: pinned) // A second window still reads this same instance.
        check(stores.model(for: pinnedRef) { fatalError("duplicate model") } === pinned, "windows share a model")

        for index in 0..<50 {
            let key = ref(index, host: host)
            let model = stores.model(for: key) { make() }
            stores.appeared(key, model: model)
            await model.loadIfNeeded()
            for directory in 0..<20 {
                await model.toggle("dir\(directory)")
                await model.toggle("dir\(directory)")
            }
            await model.open("selected")
            stores.disappeared(key, model: model)
            let inactive = stores.models.filter { $0.key != pinnedRef }.map(\.value)
            check(inactive.filter { $0.retainedCost > 0 }.count <= 8, "eight inactive payloads at most")
            check(inactive.reduce(0) { $0 + $1.retainedCost } <= 8 << 20, "inactive accounted byte bound")
            check(model.retainedEntryCount == 20, "collapsed entries do not accumulate")
            check(pinned.rows == pinnedRows && pinned.content == .text(String(repeating: "x", count: 256 << 10)),
                  "second window keeps expanded rows, filter and current content")
        }
        check(stores.models.count == 51, "live threads keep thin metadata")
        stores.disappeared(pinnedRef, model: pinned)
        check(pinned.retainedCost == 0, "last reader leaving allows old payload eviction")
        stores.appeared(pinnedRef, model: pinned)
        await pinned.loadIfNeeded()
        check(pinned.rows == pinnedRows && pinned.filter == "file1" && pinned.selectedPath == "dir0/file1",
              "cold reentry restores expansion, filter and selection")
        check(pinned.openPath == "dir0/file1" && pinned.content != .loading, "cold open file reloads")
        stores.prune(host: host, live: [pinnedRef.agent])
        check(stores.models.count == 1, "deleted refs lose metadata too")
        let removed = stores.model(for: ref(0, host: host)) { make() }
        await removed.loadIfNeeded()
        check(removed.retainedCost == 0 && stores.models.count == 1, "a stale deleted screen cannot recreate payload")
        print("PASS: Files 50-thread visits plateau; two-window readers, cold reentry and deleted-ref pruning")
    }

    @MainActor
    static func byteBudget() async {
        let stores = ThreadFilesStores(), host = UUID()
        for index in 0..<4 {
            let key = ref(index, host: host)
            let model = stores.model(for: key) { make(nameLength: 160) }
            stores.appeared(key, model: model)
            await model.loadIfNeeded()
            for directory in 0..<20 { await model.toggle("dir\(directory)") }
            stores.disappeared(key, model: model)
        }
        check(stores.models.values.reduce(0) { $0 + $1.retainedCost } <= 8 << 20, "bytes bound, independently of count")
        check(stores.models.values.filter { $0.retainedCost > 0 }.count < 4, "byte pressure evicts before eight models")
        let key = ref(9, host: host)
        let huge = stores.model(for: key) { make(nameLength: 1_024) }
        stores.appeared(key, model: huge)
        await huge.loadIfNeeded()
        for directory in 0..<20 { await huge.toggle("dir\(directory)") }
        check(huge.retainedCost > 8 << 20 && huge.rows.count == 4_020, "visible expanded trees are exempt")
        stores.disappeared(key, model: huge)
        check(huge.retainedCost == 0, "one oversized inactive payload is not retained")
        print("PASS: Files inactive accounted bytes bounded at 8 MiB; active trees exempt")
    }

    @MainActor
    static func pendingAndForget() async {
        let stores = ThreadFilesStores(), host = UUID(), otherHost = UUID()
        let key = ref(0, host: host), other = ref(0, host: otherHost)
        let gate = FilesHeldReply<Data>()
        let model = stores.model(for: key) {
            ThreadFilesModel(list: { _, _ in .init(entries: [.init(name: "read", kind: .file)]) },
                             read: { _ in await gate.request() })
        }
        stores.appeared(key, model: model)
        await model.loadIfNeeded()
        let read = Task { await model.open("read") }
        await gate.waitUntilHeld()
        read.cancel() // The model-owned read still protects its payload until actual completion.
        stores.disappeared(key, model: model)
        for index in 1...10 {
            let next = ref(index, host: host)
            let value = stores.model(for: next) { make() }
            stores.appeared(next, model: value)
            await value.loadIfNeeded()
            stores.disappeared(next, model: value)
        }
        check(model.hasPendingRequests && !model.rows.isEmpty, "pending offscreen requests are protected")
        await gate.finish(Data("late".utf8))
        await read.value
        check(!model.hasPendingRequests && model.retainedCost == 0, "completion trims payload that landed offscreen")

        let otherModel = stores.model(for: other) { make() }
        await otherModel.loadIfNeeded()
        let rootGate = FilesHeldReply<ThreadFileListing>()
        let forgottenRef = ref(99, host: host)
        let forgotten = stores.model(for: forgottenRef) {
            ThreadFilesModel(list: { _, _ in await rootGate.request() }, read: { _ in Data() })
        }
        stores.appeared(forgottenRef, model: forgotten)
        let root = Task { await forgotten.loadIfNeeded() }
        await rootGate.waitUntilHeld()
        stores.forget(host: host)
        await rootGate.finish(.init(entries: [.init(name: "stale", kind: .file)]))
        await root.value
        check(forgotten.rows.isEmpty && forgotten.retainedCost == 0, "forgotten late root does not repopulate")
        check(forgotten.phase == .failed("This thread or host is no longer available."), "lingering deleted tree is terminal, not loading")
        await forgotten.loadIfNeeded()
        await forgotten.open("stale")
        check(forgotten.retainedCost == 0, "lingering model cannot reload a forgotten host")
        stores.disappeared(forgottenRef, model: forgotten)
        let staleView = stores.model(for: forgottenRef) { make() }
        await staleView.loadIfNeeded()
        check(staleView.retainedCost == 0 && stores.models.count == 1 && stores.models[other] === otherModel,
              "forget removes only its host and blocks stale view recreation")
        print("PASS: Files in-flight protection, completion trimming and forgotten-host late-reply fencing")
    }
}

private actor FilesHeldReply<Value: Sendable> {
    private var reply: CheckedContinuation<Value, Never>?
    private var arrived: CheckedContinuation<Void, Never>?

    func request() async -> Value {
        await withCheckedContinuation { continuation in
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
