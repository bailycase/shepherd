import CoreServices
import Darwin
import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestKit

/// The content index over scratch folders: what it holds, what it leaves out, what a change does to it and to the
/// manifest, and what it does when it finds it was wrong. No git and no FSEvents: events are made by hand, and a stub
/// says which files git would track.
@Suite("Fleet content index")
struct FleetContentIndexTests {
    /// A checkout in a scratch folder and an index over it. `scan` walks it; events are fed with `event`.
    final class Checkout: @unchecked Sendable {
        let root: URL
        let storage: URL
        let index: FleetContentIndex
        let added = Locked<[[FleetHash]]>([])
        let removed = Locked<[[FleetHash]]>([])
        /// Paths the stub classifier says git tracks; every `.log` is ignored and the rest untracked.
        let tracked = Locked<Set<String>>([])

        init(files: [String: String] = [:], rules: FleetExclusions = FleetExclusions(), maxFiles: Int = FleetContentIndex.maxFiles,
             clock: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 4_000_000_000) }) throws {
            let base = try makeScratchDirectory("index")
            root = base.appendingPathComponent("acme-web", isDirectory: true)
            storage = base.appendingPathComponent("index", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let tracked = tracked
            let folder = root.path
            let classifier = FleetGitClassifier { _, paths in
                var all = Set<String>()
                let walker = FileManager.default.enumerator(atPath: folder)
                while let path = walker?.nextObject() as? String {
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: folder + "/" + path, isDirectory: &isDirectory), !isDirectory.boolValue, !path.hasPrefix(".git/") { all.insert(path) }
                }
                let scope = paths.map(Set.init) ?? all
                let inGit = tracked.current
                return .init(tracked: scope.intersection(inGit), untracked: scope.filter { !inGit.contains($0) && !$0.hasSuffix(".log") })
            }
            index = FleetContentIndex(root: root.path, storage: storage, exclusions: rules, classifier: classifier, maxFiles: maxFiles, clock: clock)
            let (added, removed) = (added, removed)
            index.onDelta = { new, gone in added.withValue { $0.append(new) }; removed.withValue { $0.append(gone) } }
            for (path, content) in files { try write(path, content) }
        }

        deinit { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        func write(_ path: String, _ content: String, executable: Bool = false, modified: Date? = Date(timeIntervalSince1970: 1_700_000_000)) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
            if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        }

        func remove(_ path: String) throws { try FileManager.default.removeItem(at: root.appendingPathComponent(path)) }

        func scan(initial: Bool = true) { index.queue.sync { index.rescan(initial: initial) } }

        var entries: [String: FleetIndexEntry] { index.queue.sync { index.entries } }

        /// A batch of events for `paths`, as FSEvents would report them.
        func event(_ paths: [String], flags: Int = kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile, id: UInt64 = 1) {
            let events = paths.map { FleetFSEvents.Event(path: index.root + ($0.isEmpty ? "" : "/" + $0), flags: UInt32(flags), id: id) }
            index.queue.sync { index.ingest(events) }
        }

        /// What the manifest would hold after the deltas so far.
        var manifest: FleetManifest {
            let manifest = FleetLocalManifest(repo: "github.com/acme/web")
            for (new, gone) in zip(added.current, removed.current) { manifest.add(new); manifest.remove(gone) }
            manifest.flush()
            return manifest.manifest
        }

        func hash(_ content: String) -> FleetHash { FleetHash(of: Data(content.utf8)) }
    }

    static let tree = [
        "README.md": "# acme-web\n", "package.json": "{\"name\":\"acme-web\"}\n", "src/app.ts": "export const app = 1\n", "src/lib/util.ts": "export const util = 2\n",
        "scripts/run.sh": "#!/bin/sh\necho hi\n", "debug.log": "noise\n", ".env": "TOKEN=made-up\n",
        "node_modules/left-pad/index.js": "module.exports = 1\n", "node_modules/left-pad/package.json": "{}\n",
    ]

    // MARK: The exclusion table

    @Test func onlyPathBoundCachesStayHome() {
        func reason(_ path: String, inside: Set<String> = [], beside: Set<String> = [], _ rules: FleetExclusions = FleetExclusions()) -> FleetExclusions.Reason? {
            rules.reason(forDirectory: path, probe: .init(inside: { inside.contains($0) }, beside: { beside.contains($0) }))
        }
        #expect(reason(".build") == .swiftBuild)
        #expect(reason("Packages/Core/.build") == .swiftBuild)
        #expect(reason("DerivedData") == .derivedData)
        #expect(reason(".venv", inside: ["pyvenv.cfg"]) == .pythonVirtualenv)
        #expect(reason("tools/env", inside: ["pyvenv.cfg", "bin"]) == .pythonVirtualenv)
        #expect(reason("build", inside: ["CMakeCache.txt"]) == .cmakeBuild)
        #expect(reason("out/debug", inside: ["CMakeCache.txt"]) == .cmakeBuild)
        // `target` is a Cargo build directory only beside a Cargo.toml.
        #expect(reason("target", beside: ["Cargo.toml", "src"]) == .cargoTarget)
        #expect(reason("crates/core/target", beside: ["Cargo.toml"]) == .cargoTarget)
        #expect(reason("target", beside: ["pom.xml"]) == nil)
        #expect(reason("target") == nil)
        // A name that merely looks like a cache is not one: no marker, it travels.
        #expect(reason("venv") == nil && reason("build") == nil && reason("env") == nil)
        #expect(reason("node_modules") == nil && reason("node_modules/.bin") == nil && reason("dist") == nil && reason("Pods") == nil && reason(".next") == nil)
    }

    @Test func aSpaceAddsAndRemovesExclusions() throws {
        let rules = FleetExclusions(overrides: .init(excluded: ["packages/web/dist", "coverage", ".env.local"], included: [".build", "tools/env"]))
        func reason(_ path: String, inside: Set<String> = []) -> FleetExclusions.Reason? {
            rules.reason(forDirectory: path, probe: .init(inside: { inside.contains($0) }, beside: { _ in false }))
        }
        // A path matches itself; a bare name matches at any depth.
        #expect(reason("packages/web/dist") == .space && reason("packages/api/dist") == nil)
        #expect(reason("coverage") == .space && reason("packages/web/coverage") == .space)
        // A default rule a space switched off.
        #expect(reason(".build") == nil && reason("Sub/.build") == nil)
        #expect(reason("tools/env", inside: ["pyvenv.cfg"]) == nil && reason("other/env", inside: ["pyvenv.cfg"]) == .pythonVirtualenv)
        #expect(rules.excludes(file: ".env.local") && rules.excludes(file: "app/.env.local") && !rules.excludes(file: ".env"))
        // A change of rules changes the key an index is kept under, so it is walked again.
        #expect(rules.key != FleetExclusions().key && FleetExclusions().key == FleetExclusions(overrides: .init()).key)
        let decoded = try JSONDecoder().decode(FleetExclusions.Overrides.self, from: Data("{}".utf8))
        #expect(decoded.isEmpty)
    }

    // MARK: What the index holds

    @Test func theIndexHoldsEveryFileWithItsHashesAndGitClass() throws {
        let checkout = try Checkout(files: Self.tree)
        try FileManager.default.createDirectory(at: checkout.root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("ref".utf8).write(to: checkout.root.appendingPathComponent(".git/HEAD"))
        try FileManager.default.createSymbolicLink(atPath: checkout.root.appendingPathComponent("latest").path, withDestinationPath: "src/app.ts")
        try checkout.write("scripts/run.sh", Self.tree["scripts/run.sh"]!, executable: true)
        checkout.tracked.withValue { $0 = ["README.md", "package.json", "src/app.ts", "src/lib/util.ts", "scripts/run.sh"] }
        checkout.scan()
        let entries = checkout.entries
        // Everything but .git; node_modules and .env included.
        #expect(Set(entries.keys) == Set(Self.tree.keys).union(["latest"]))
        let readme = try #require(entries["README.md"])
        #expect(readme.hash == checkout.hash("# acme-web\n") && readme.size == 11 && readme.kind == .file && readme.state == .tracked)
        #expect(readme.gitID == FleetGitBlobID.of(Data("# acme-web\n".utf8)))
        #expect(entries["scripts/run.sh"]?.kind == .executable)
        #expect(entries[".env"]?.state == .untracked && entries["debug.log"]?.state == .ignored && entries["node_modules/left-pad/index.js"]?.state == .untracked)
        // A link is its target text, never followed.
        #expect(entries["latest"]?.kind == .symlink && entries["latest"]?.hash == checkout.hash("src/app.ts"))
        // The manifest has every content hash and every directory's.
        let manifest = checkout.manifest
        let modules = try #require(checkout.index.queue.sync { checkout.index.hash(ofDirectory: "node_modules/left-pad") })
        #expect(manifest.contains(readme.hash) && manifest.contains(modules))
        // The root's hash too: a target whose checkout is this one holds it.
        #expect(manifest.contains(checkout.index.queue.sync { checkout.index.rootHash }))
        #expect(checkout.index.queue.sync { checkout.index.state } == .ready)
    }

    @Test func pathBoundCachesAreNotIndexedAndNodeModulesIs() throws {
        let checkout = try Checkout(files: [
            "src/main.swift": "print(1)\n", "Package.swift": "// swift-tools-version: 6.0\n", "Cargo.toml": "[package]\n",
            ".build/debug/app": "binary\n", "Sub/.build/x": "x\n", "DerivedData/Build/Products/app": "binary\n",
            ".venv/pyvenv.cfg": "home = /usr/bin\n", ".venv/lib/site.py": "py\n", "env/pyvenv.cfg": "home = /usr/bin\n", "env/bin/python": "py\n",
            "cmake-out/CMakeCache.txt": "cache\n", "cmake-out/obj.o": "obj\n",
            "target/debug/app": "rust binary\n", "service/target/classes/App.class": "java class\n", "service/pom.xml": "<project/>\n",
            "node_modules/pkg/index.js": "1\n", "build/output.js": "built, no marker\n", "venv/readme.txt": "not a venv\n",
        ])
        checkout.scan()
        let held = Set(checkout.entries.keys)
        #expect(held == ["src/main.swift", "Package.swift", "Cargo.toml", "service/target/classes/App.class", "service/pom.xml", "node_modules/pkg/index.js",
                         "build/output.js", "venv/readme.txt"])
        // Cargo's `target` beside a Cargo.toml is left out; the same name beside none is a plain directory.
        #expect(!held.contains("target/debug/app") && held.contains("service/target/classes/App.class"))
    }

    @Test func aSpacesRulesChangeWhatIsIndexed() throws {
        let files = ["src/a.ts": "a\n", "dist/bundle.js": "bundle\n", ".build/x": "x\n", "secrets.local": "s\n"]
        let rules = FleetExclusions(overrides: .init(excluded: ["dist", "secrets.local"], included: [".build"]))
        let checkout = try Checkout(files: files, rules: rules)
        checkout.scan()
        #expect(Set(checkout.entries.keys) == ["src/a.ts", ".build/x"])
        // New rules, a new walk: the files that came back are in, and the hashes of those that left are out.
        checkout.index.queue.sync { checkout.index.setExclusions(FleetExclusions()) }
        #expect(Set(checkout.entries.keys) == ["src/a.ts", "dist/bundle.js", "secrets.local"] as Set)
    }

    // MARK: Changes between scans

    @Test func aRescanFindsAddedRemovedRenamedTouchedAndRechmoddedFiles() throws {
        let checkout = try Checkout(files: Self.tree)
        checkout.scan()
        let before = checkout.entries
        try checkout.write("src/new.ts", "export const fresh = 3\n")
        try checkout.remove("debug.log")
        try FileManager.default.moveItem(at: checkout.root.appendingPathComponent("README.md"), to: checkout.root.appendingPathComponent("docs-readme.md"))
        try checkout.write("package.json", "{\"name\":\"acme-web\",\"private\":true}\n")
        // Touched: the same bytes with another time. Chmod: the same bytes and time with another mode.
        try checkout.write("src/app.ts", "export const app = 1\n", modified: Date(timeIntervalSince1970: 1_700_000_500))
        chmod(checkout.root.appendingPathComponent("src/lib/util.ts").path, 0o755)
        checkout.scan(initial: false)
        let diff = FleetIndexDiff.between(before, checkout.entries)
        #expect(diff.added == ["docs-readme.md", "src/new.ts"])
        #expect(diff.removed == ["README.md", "debug.log"])
        #expect(diff.renamed.map { [$0.from, $0.to] } == [["README.md", "docs-readme.md"]])
        #expect(diff.changed == ["package.json", "src/lib/util.ts"])
        #expect(diff.touched == ["src/app.ts"])
        // The manifest followed: the new content is in, what went is out, and a touch changed nothing.
        let manifest = checkout.manifest
        #expect(manifest.contains(checkout.hash("export const fresh = 3\n")) && !manifest.contains(checkout.hash("noise\n")))
        #expect(manifest.contains(checkout.hash("export const app = 1\n")))
    }

    @Test func theManifestIsExactlyTheContentsAndTheDirectoryHashes() throws {
        let checkout = try Checkout(files: Self.tree)
        checkout.scan()
        let expected = FleetManifest((checkout.index.queue.sync { checkout.index.allHashes }).map(\.prefix))
        #expect(checkout.manifest.digest == expected.digest && checkout.manifest == expected)
        // Two files with one content are one hash, and removing one of them leaves it held.
        try checkout.write("copy-of-readme.md", "# acme-web\n")
        checkout.scan(initial: false)
        try checkout.remove("README.md")
        checkout.scan(initial: false)
        #expect(checkout.manifest.contains(checkout.hash("# acme-web\n")))
        #expect(checkout.manifest == FleetManifest((checkout.index.queue.sync { checkout.index.allHashes }).map(\.prefix)))
    }

    @Test func aFileWrittenInsideTheClocksGranularityIsReadAgainEvenIfItsSizeAndTimeMatch() throws {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        // The clock says it is a moment after the write: the time can't be trusted yet.
        let racy = try Checkout(files: ["a.txt": "aaaa\n"], clock: { stamp.addingTimeInterval(0.5) })
        racy.scan()
        try racy.write("a.txt", "bbbb\n", modified: stamp)
        racy.scan(initial: false)
        #expect(racy.entries["a.txt"]?.hash == racy.hash("bbbb\n"))
        // Long after, a matching size and time is trusted: nothing is read.
        let settled = try Checkout(files: ["a.txt": "aaaa\n"])
        settled.scan()
        try settled.write("a.txt", "bbbb\n", modified: stamp)
        settled.scan(initial: false)
        #expect(settled.entries["a.txt"]?.hash == settled.hash("aaaa\n"))
    }

    @Test func aCheckoutOverTheLimitIsNotIndexedAndSaysSo() throws {
        let checkout = try Checkout(files: ["a": "1", "b": "2", "c": "3", "d": "4"], maxFiles: 3)
        checkout.scan()
        #expect(checkout.index.queue.sync { checkout.index.state } == .tooLarge)
        #expect(checkout.entries.isEmpty && checkout.manifest.count == 0)
    }

    // MARK: Events

    @Test func anEditedFileIsReadAgainAndOnlyItsHashesMoveInTheManifest() throws {
        let checkout = try Checkout(files: Self.tree)
        checkout.scan()
        let first = checkout.added.current.count
        try checkout.write("src/app.ts", "export const app = 2\n", modified: Date(timeIntervalSince1970: 1_700_000_900))
        checkout.event(["src/app.ts"])
        let added = Set(checkout.added.current.dropFirst(first).flatMap { $0 }), removed = Set(checkout.removed.current.dropFirst(first).flatMap { $0 })
        #expect(added.contains(checkout.hash("export const app = 2\n")) && removed.contains(checkout.hash("export const app = 1\n")))
        // The file and the directories above it (src, the root): nothing else moved.
        #expect(added.count == 3 && removed.count == 3)
        #expect(checkout.entries["src/app.ts"]?.hash == checkout.hash("export const app = 2\n"))
    }

    @Test func aTouchWithNoChangeOfContentMovesNothing() throws {
        let checkout = try Checkout(files: Self.tree)
        checkout.scan()
        let deltas = checkout.added.current.count
        try checkout.write("README.md", "# acme-web\n", modified: Date(timeIntervalSince1970: 1_700_000_900))
        checkout.event(["README.md"])
        #expect(checkout.added.current.count == deltas)
        #expect(checkout.entries["README.md"]?.modified == 1_700_000_900_000_000_000)
    }

    @Test func createdRemovedAndRenamedPathsAndWholeNewDirectoriesFollowTheirEvents() throws {
        let checkout = try Checkout(files: Self.tree)
        checkout.scan()
        // A file in a directory the index knows, one in a directory it has never seen (its own event never came).
        try checkout.write("src/lib/more.ts", "more\n")
        try checkout.write("packages/api/src/index.ts", "api\n")
        try checkout.write("packages/api/package.json", "{}\n")
        checkout.event(["src/lib/more.ts", "packages/api/src/index.ts"], flags: kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
        #expect(Set(checkout.entries.keys).isSuperset(of: ["src/lib/more.ts", "packages/api/src/index.ts", "packages/api/package.json"]))
        // A directory renamed: its old path is gone, its new one is a directory event.
        try FileManager.default.moveItem(at: checkout.root.appendingPathComponent("packages"), to: checkout.root.appendingPathComponent("libs"))
        checkout.event(["packages", "libs"], flags: kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsDir)
        #expect(checkout.entries["packages/api/package.json"] == nil && checkout.entries["libs/api/package.json"] != nil)
        // A file removed.
        try checkout.remove("scripts/run.sh")
        checkout.event(["scripts/run.sh"], flags: kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsFile)
        #expect(checkout.entries["scripts/run.sh"] == nil)
        // After all that, the index is what a fresh walk finds, and so is the manifest.
        let live = checkout.entries
        let fresh = try Checkout(files: [:])
        try FileManager.default.removeItem(at: fresh.root)
        try FileManager.default.copyItem(at: checkout.root, to: fresh.root)
        fresh.scan()
        #expect(FleetIndexDiff.between(fresh.entries, live).changed.isEmpty && Set(fresh.entries.keys) == Set(live.keys))
        #expect(checkout.manifest == FleetManifest((checkout.index.queue.sync { checkout.index.allHashes }).map(\.prefix)))
    }

    @Test func eventsInsideAnExcludedDirectoryAreIgnoredAndAMarkerThatAppearsExcludesItsDirectory() throws {
        let checkout = try Checkout(files: ["src/a.ts": "a\n", ".build/debug/app": "x\n", "tools/env/bin/python": "py\n", "tools/env/lib/site.py": "py\n"])
        checkout.scan()
        // The venv has no pyvenv.cfg yet: it is indexed like any directory.
        #expect(checkout.entries["tools/env/bin/python"] != nil && checkout.entries[".build/debug/app"] == nil)
        try checkout.write(".build/debug/more", "y\n")
        checkout.event([".build/debug/more"], flags: kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
        #expect(checkout.entries[".build/debug/more"] == nil)
        // `python -m venv` writes its marker: the directory leaves the index, and its hashes leave the manifest.
        try checkout.write("tools/env/pyvenv.cfg", "home = /usr/bin\n")
        checkout.event(["tools/env/pyvenv.cfg"], flags: kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
        #expect(Set(checkout.entries.keys) == ["src/a.ts"], "\(checkout.entries.keys.sorted())")
        #expect(checkout.manifest == FleetManifest((checkout.index.queue.sync { checkout.index.allHashes }).map(\.prefix)))
        // And its removal brings it back.
        try checkout.remove("tools/env/pyvenv.cfg")
        checkout.event(["tools/env/pyvenv.cfg"], flags: kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsFile)
        #expect(checkout.entries["tools/env/bin/python"] != nil)
    }

    @Test func eventsThatSayTheyWereLostRescanTheTree() throws {
        let checkout = try Checkout(files: Self.tree)
        checkout.scan()
        let reasons = Locked<[String]>([])
        checkout.index.onDrift = { reason in reasons.withValue { $0.append(reason) } }
        try checkout.write("src/quiet.ts", "arrived without an event\n")
        checkout.event([""], flags: kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagMustScanSubDirs)
        #expect(checkout.entries["src/quiet.ts"] != nil && reasons.current.first == "events lost")
        // A must-scan flag on a directory looks at that directory deeply.
        try checkout.write("src/lib/also-quiet.ts", "this one too\n")
        checkout.event(["src"], flags: kFSEventStreamEventFlagMustScanSubDirs)
        #expect(checkout.entries["src/lib/also-quiet.ts"] != nil)
    }

    // MARK: Checking

    @Test func aSpotCheckFindsWhatTheIndexMissedAndRepairsItWithARescan() throws {
        let checkout = try Checkout(files: Self.tree)
        checkout.scan()
        #expect(!checkout.index.queue.sync { checkout.index.verify(sample: 1_000) })
        // A file changed with no event.
        try checkout.write("src/app.ts", "export const app = 99\n", modified: Date(timeIntervalSince1970: 1_700_001_000))
        #expect(checkout.index.queue.sync { checkout.index.verify(sample: 1_000) })
        #expect(checkout.entries["src/app.ts"]?.hash == checkout.hash("export const app = 99\n"))
        // A file that arrived with no event: the directory's time moved.
        try checkout.write("src/lib/arrived.ts", "arrived\n")
        #expect(checkout.index.queue.sync { checkout.index.verify(sample: 1_000) })
        #expect(checkout.entries["src/lib/arrived.ts"] != nil)
        // A file that went.
        try checkout.remove("README.md")
        #expect(checkout.index.queue.sync { checkout.index.verify(sample: 1_000) })
        #expect(checkout.entries["README.md"] == nil)
        // Clean again.
        #expect(!checkout.index.queue.sync { checkout.index.verify(sample: 1_000) })
    }
}
