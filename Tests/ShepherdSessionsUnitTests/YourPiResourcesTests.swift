import Darwin
import Foundation
import ShepherdTestKit
import Testing
@testable import ShepherdSessions

/// What of the user's pi is copied into Shepherd's home as files, found as pi finds it, and how
/// a copy is made: whole, as plain files, with links followed and nothing of theirs linked.
@Suite("Your pi's files, copied")
struct YourPiResourcesTests {
    /// A scratch "your pi" (`agent/`) and home folder (`home/`), laid out from `files` (path:
    /// text), with `settings` as its settings.json.
    struct Layout {
        let root: URL
        var agent: URL { root.appendingPathComponent("agent", isDirectory: true) }
        var home: URL { root.appendingPathComponent("home", isDirectory: true) }

        init(_ files: [String: String], settings: String? = nil) throws {
            root = try makeScratchDirectory("res")
            for (path, text) in files { try write(text, path) }
            try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            if let settings { try write(settings, "agent/settings.json") }
        }

        func write(_ text: String, _ path: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        var settings: [String: Any]? {
            (try? Data(contentsOf: agent.appendingPathComponent("settings.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }

        func find(_ kind: YourPiResourceKind) -> YourPiResources.Listing {
            YourPiResources.find(kind, agentDirectory: agent, settings: settings, userHome: home.path)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    static func skill(_ name: String) -> String { "---\nname: \(name)\ndescription: The \(name) skill.\n---\n" }

    // MARK: What is found, per kind

    /// Each kind, found as pi finds it and in its order, with where each copy goes; what is passed
    /// over is said, one sentence each.
    @Test(arguments: [
        // Instructions: the context file pi picks, then SYSTEM.md and APPEND_SYSTEM.md.
        (YourPiResourceKind.instructions, ["agent/CLAUDE.md": "c", "agent/AGENTS.override.md": "o", "agent/APPEND_SYSTEM.md": "a"], nil as String?,
         ["AGENTS.override.md", "APPEND_SYSTEM.md"], 0),
        // Skills: folders (at any depth) and single files in pi's own folder, a settings path, a
        // package's, then ~/.agents/skills (folders only there); a second of one name is passed over,
        // and pi's filters apply.
        (.skills, ["agent/skills/pdf/SKILL.md": skill("pdf"), "agent/skills/quick.md": "q", "agent/skills/group/deep/SKILL.md": skill("deep"),
                   "agent/skills/draft-x/SKILL.md": skill("draft-x"), "agent/skills/gone/SKILL.md": skill("gone"),
                   "team/pdf/SKILL.md": skill("pdf"), "team/extra/SKILL.md": skill("extra"),
                   "agent/npm/node_modules/@acme/tools/skills/pkg/SKILL.md": skill("pkg"), "agent/npm/node_modules/@acme/tools/package.json": "{}",
                   "home/.agents/skills/agents-only/SKILL.md": skill("agents-only"), "home/.agents/skills/note.md": "not a skill here"],
         #"{"skills": ["../team", "!draft-*", "-skills/gone"], "packages": ["npm:@acme/tools@1.0.0"]}"#,
         ["skills/quick", "skills/deep", "skills/pdf", "skills/extra", "skills/pkg", "skills/agents-only"], 1),
        // Prompts: pi's own folder's top level, then a settings folder at any depth; a second prompt
        // of one name is passed over.
        (.prompts, ["agent/prompts/review.md": "r", "agent/prompts/nested/skip.md": "top level only", "more/review.md": "second",
                    "more/deep/triage.md": "t", "agent/prompts/notes.txt": "not a prompt"],
         #"{"prompts": ["../more"]}"#, ["prompts/review.md", "prompts/triage.md"], 1),
        // Themes: `.json` files.
        (.themes, ["agent/themes/harbor.json": "{}", "agent/themes/readme.md": "not a theme"], nil, ["themes/harbor.json"], 0),
        // Extensions: a file, a folder with an index, a folder without one (not an extension), a
        // settings path, and a package; one their pi never installed is passed over.
        (.extensions, ["agent/extensions/gate.ts": "g", "agent/extensions/notify/index.ts": "n", "agent/extensions/notes/readme.md": "x",
                       "tools/tool.ts": "t", "agent/npm/node_modules/web/package.json": #"{"pi": {"extensions": ["./src/main.ts"]}}"#,
                       "agent/npm/node_modules/web/src/main.ts": "w"],
         #"{"extensions": ["../tools/tool.ts"], "packages": ["npm:web", "npm:missing@2"]}"#,
         ["your-extensions/files/gate.ts", "your-extensions/files/notify", "your-extensions/paths/tool.ts",
          "your-extensions/npm/node_modules/web"], 1),
    ])
    func eachKindIsFoundAsPiFindsIt(kind: YourPiResourceKind, files: [String: String], settings: String?,
                                    destinations: [String], skipped: Int) throws {
        let layout = try Layout(files, settings: settings)
        defer { layout.remove() }
        let listing = layout.find(kind)
        #expect(listing.found.map(\.copy.destination) == destinations)
        #expect(listing.skipped.count == skipped, "\(listing.skipped)")
        #expect(listing.found.allSatisfy { $0.copy.kind == kind })
    }

    /// A link to `/` or to a folder above the one searched (a skill linked to the home folder) is
    /// never walked: finding skills never reads the disk. Real skills beside them are found, a
    /// linked one included.
    @Test func aLinkToTheRootOrAboveIsNeverSearchedForSkills() throws {
        let layout = try Layout(["home/.agents/skills/real/SKILL.md": Self.skill("real"), "agent/skills/mine/SKILL.md": Self.skill("mine")])
        defer { layout.remove() }
        let files = FileManager.default
        try files.createSymbolicLink(atPath: layout.home.path + "/.agents/skills/disk", withDestinationPath: "/")
        try files.createSymbolicLink(atPath: layout.home.path + "/.agents/skills/home", withDestinationPath: layout.home.path)
        try files.createSymbolicLink(atPath: layout.agent.path + "/skills/up", withDestinationPath: layout.root.path)
        try files.createSymbolicLink(atPath: layout.agent.path + "/skills/again", withDestinationPath: layout.agent.path + "/skills/mine")

        let listing = layout.find(.skills)

        #expect(listing.found.map(\.copy.destination) == ["skills/again", "skills/mine", "skills/real"])
    }

    /// A package whose manifest names a file outside it, however the path gets there, never
    /// loads that file: only its own entries are kept.
    @Test func anExtensionEntryLeadingOutOfItsPackageIsLeftOut() throws {
        let layout = try Layout([
            "agent/npm/node_modules/web/package.json": #"{"pi": {"extensions": ["./src/main.ts", "../other/x.ts", "src/../../other/x.ts", "src/../src/main.ts", "."]}}"#,
            "agent/npm/node_modules/web/src/main.ts": "w", "agent/npm/node_modules/other/x.ts": "outside",
        ], settings: #"{"packages": ["npm:web"]}"#)
        defer { layout.remove() }
        #expect(layout.find(.extensions).found.map { $0.copy.entries ?? [] } == [["src/main.ts"]])
    }

    /// An extension's peer dependency on pi (npm installs it beside the package) stays behind:
    /// pi hands every extension its own, and a copy would drag pi's whole tree along.
    @Test func piItselfIsNeverCopiedAsADependency() throws {
        let layout = try Layout([
            "agent/npm/node_modules/web/package.json": #"{"dependencies": {"left-pad": "1", "typebox": "1"}, "peerDependencies": {"@earendil-works/pi-coding-agent": "*"}, "pi": {"extensions": ["index.ts"]}}"#,
            "agent/npm/node_modules/web/index.ts": "w", "agent/npm/node_modules/left-pad/package.json": "{}",
            "agent/npm/node_modules/typebox/package.json": "{}",
            "agent/npm/node_modules/@earendil-works/pi-coding-agent/package.json": #"{"dependencies": {"huge": "1"}}"#,
            "agent/npm/node_modules/huge/package.json": "{}",
        ], settings: #"{"packages": ["npm:web"]}"#)
        defer { layout.remove() }
        #expect(layout.find(.extensions).found.first?.companions.map(\.destination) == ["your-extensions/npm/node_modules/left-pad"])
    }

    /// A single-file skill becomes a folder in the home, so every skill there is one Settings ▸
    /// Skills lists; an extension names the files pi loads from its copy.
    @Test func singleFileSkillsAndExtensionEntriesKeepTheirShape() throws {
        let layout = try Layout(["agent/skills/quick.md": "q", "agent/extensions/notify/index.ts": "n",
                                 "agent/npm/node_modules/web/package.json": #"{"pi": {"extensions": ["./src/main.ts", "../escape.ts"]}}"#,
                                 "agent/npm/node_modules/web/src/main.ts": "w", "agent/npm/node_modules/conv/extensions/a.ts": "a",
                                 "agent/npm/node_modules/conv/package.json": "{}"],
                                settings: #"{"packages": ["npm:web", "npm:conv"]}"#)
        defer { layout.remove() }
        #expect(layout.find(.skills).found.map(\.singleFileSkill) == [true])
        #expect(layout.find(.extensions).found.map { $0.copy.entries ?? [] } == [["index.ts"], ["src/main.ts"], ["extensions/a.ts"]])
    }

    /// A package's source as pi names it: npm's under `npm/node_modules`, git's under
    /// `git/<host>/<path>`, a token in a URL never kept.
    @Test(arguments: [
        ("git:github.com/owner/repo@v1", "github.com/owner/repo"),
        ("https://github.com/owner/repo.git", "github.com/owner/repo"),
        ("https://user:FAKE-TOKEN@github.com/owner/repo", "github.com/owner/repo"),
        ("git@github.com:owner/repo", "github.com/owner/repo"),
        ("https://example.com/x.git", nil),
        ("npm:@acme/tools", nil),
        ("./local", nil),
    ] as [(String, String?)])
    func aGitSourceNamesItsInstalledFolder(source: String, repository: String?) {
        #expect(YourPiResources.gitRepository(source) == repository)
    }

    // MARK: Copies

    /// A skill folder holding links: a link to a file or a folder is copied as their bytes, one
    /// that leads nowhere or back up its own folder is left out, and `.git` stays behind. The copy
    /// holds no link at all.
    @Test func aSkillFolderWithLinksIsCopiedAsPlainFiles() throws {
        let layout = try Layout(["agent/skills/linked/SKILL.md": Self.skill("linked"), "shared/helper.sh": "#!/bin/sh\necho hi\n",
                                 "shared/lib/util.py": "print(1)\n", "agent/skills/linked/.git/HEAD": "ref"])
        defer { layout.remove() }
        let skill = layout.agent.appendingPathComponent("skills/linked")
        chmod(layout.root.appendingPathComponent("shared/helper.sh").path, 0o755)
        let files = FileManager.default
        try files.createSymbolicLink(atPath: skill.appendingPathComponent("helper.sh").path, withDestinationPath: layout.root.path + "/shared/helper.sh")
        try files.createSymbolicLink(atPath: skill.appendingPathComponent("lib").path, withDestinationPath: layout.root.path + "/shared/lib")
        try files.createSymbolicLink(atPath: skill.appendingPathComponent("dangling").path, withDestinationPath: layout.root.path + "/nowhere")
        try files.createSymbolicLink(atPath: skill.appendingPathComponent("loop").path, withDestinationPath: ".")
        let destination = layout.root.appendingPathComponent("out/skills/linked")

        let result = try YourPiTree.copy(skill, to: destination, staging: layout.root.appendingPathComponent("out/.staging"),
                                         limits: YourPiTree.skillLimits)

        #expect(result.files == 3 && Set(result.leftOut) == ["dangling", "loop"])
        #expect(try String(contentsOf: destination.appendingPathComponent("lib/util.py"), encoding: .utf8) == "print(1)\n")
        #expect(!files.fileExists(atPath: destination.appendingPathComponent(".git").path))
        for path in try files.subpathsOfDirectory(atPath: destination.path) {
            let type = try files.attributesOfItem(atPath: destination.appendingPathComponent(path).path)[.type] as? FileAttributeType
            #expect(type != .typeSymbolicLink, "\(path) is a link")
        }
        #expect(files.isExecutableFile(atPath: destination.appendingPathComponent("helper.sh").path), "a script stays runnable")
    }

    /// A link inside a skill to `/`, or to a folder above the skill, is left out of its copy
    /// rather than copying the disk; the skill itself is copied.
    @Test func aLinkToTheRootInsideASkillIsLeftOut() throws {
        let layout = try Layout(["agent/skills/odd/SKILL.md": Self.skill("odd")])
        defer { layout.remove() }
        let skill = layout.agent.appendingPathComponent("skills/odd")
        try FileManager.default.createSymbolicLink(atPath: skill.path + "/disk", withDestinationPath: "/")
        try FileManager.default.createSymbolicLink(atPath: skill.path + "/pi", withDestinationPath: layout.agent.path)
        let result = try YourPiTree.copy(skill, to: layout.root.appendingPathComponent("out/odd"),
                                         staging: layout.root.appendingPathComponent("out/.staging"), limits: YourPiTree.skillLimits)
        #expect(Set(result.leftOut) == ["disk", "pi"] && result.files == 1)
    }

    /// A tree of empty folders is refused like one of too many files.
    @Test func tooManyFoldersAreRefusedLikeTooManyFiles() throws {
        let layout = try Layout(["agent/skills/deep/SKILL.md": Self.skill("deep")])
        defer { layout.remove() }
        let skill = layout.agent.appendingPathComponent("skills/deep")
        for name in ["a", "b", "c"] { try FileManager.default.createDirectory(at: skill.appendingPathComponent(name), withIntermediateDirectories: true) }
        #expect(throws: YourPiFileError.self) {
            try YourPiTree.copy(skill, to: layout.root.appendingPathComponent("out/deep"),
                                staging: layout.root.appendingPathComponent("out/.staging"), limits: .init(bytes: 1 << 20, files: 3))
        }
    }

    /// A skill too large to copy (a 65 MB file, sparse so the test stays quick) fails whole: no
    /// part of it lands, and what was there stays.
    @Test func aHugeSkillIsRefusedWhole() throws {
        let layout = try Layout(["agent/skills/huge/SKILL.md": Self.skill("huge"), "out/skills/huge/SKILL.md": "Shepherd's earlier copy"])
        defer { layout.remove() }
        let big = layout.agent.appendingPathComponent("skills/huge/weights.bin").path
        let fd = open(big, O_WRONLY | O_CREAT, 0o644)
        #expect(fd >= 0 && ftruncate(fd, 65 << 20) == 0)
        close(fd)
        let destination = layout.root.appendingPathComponent("out/skills/huge")

        #expect(throws: YourPiFileError.self) {
            try YourPiTree.copy(layout.agent.appendingPathComponent("skills/huge"), to: destination,
                                staging: layout.root.appendingPathComponent("out/.staging"), limits: YourPiTree.skillLimits)
        }
        #expect(try String(contentsOf: destination.appendingPathComponent("SKILL.md"), encoding: .utf8) == "Shepherd's earlier copy")
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("weights.bin").path))

        // Too many files, the same way.
        #expect(throws: YourPiFileError.self) {
            try YourPiTree.copy(layout.agent.appendingPathComponent("skills/huge"), to: destination,
                                staging: layout.root.appendingPathComponent("out/.staging"), limits: .init(bytes: 1 << 30, files: 1))
        }
    }

    /// A FIFO inside a skill is never opened (a read would block the first launch): it is left out.
    @Test func aFIFOInsideASkillIsLeftOut() throws {
        let layout = try Layout(["agent/skills/odd/SKILL.md": Self.skill("odd")])
        defer { layout.remove() }
        #expect(mkfifo(layout.agent.appendingPathComponent("skills/odd/pipe").path, 0o644) == 0)
        let result = try YourPiTree.copy(layout.agent.appendingPathComponent("skills/odd"), to: layout.root.appendingPathComponent("out/odd"),
                                         staging: layout.root.appendingPathComponent("out/.staging"), limits: YourPiTree.skillLimits)
        #expect(result.leftOut == ["pipe"] && result.files == 1)
    }

    /// An npm package loads from its copy as it did: its own `node_modules` come with it, and the
    /// dependencies npm hoisted beside it (and theirs) are copied beside it, mirroring the layout.
    @Test func aPackageWithNodeModulesBringsItsDependencies() throws {
        let layout = try Layout([
            "agent/npm/node_modules/@acme/tools/package.json": #"{"dependencies": {"left-pad": "1", "nested": "1"}, "pi": {"extensions": ["index.js"]}}"#,
            "agent/npm/node_modules/@acme/tools/index.js": "module.exports = () => {}",
            "agent/npm/node_modules/@acme/tools/node_modules/nested/package.json": "{}",
            "agent/npm/node_modules/@acme/tools/node_modules/nested/index.js": "",
            "agent/npm/node_modules/left-pad/package.json": #"{"dependencies": {"tiny": "1"}}"#,
            "agent/npm/node_modules/left-pad/index.js": "",
            "agent/npm/node_modules/tiny/package.json": "{}",
            "agent/npm/node_modules/unrelated/package.json": "{}",
        ], settings: #"{"packages": ["npm:@acme/tools@2.0.0"]}"#)
        defer { layout.remove() }
        let found = try #require(layout.find(.extensions).found.first)
        #expect(found.copy.destination == "your-extensions/npm/node_modules/@acme/tools" && found.copy.source == "npm:@acme/tools@2.0.0")
        #expect(found.companions.map(\.destination) == ["your-extensions/npm/node_modules/left-pad", "your-extensions/npm/node_modules/tiny"])

        let home = layout.root.appendingPathComponent("home-pi")
        let staging = home.appendingPathComponent(".staging")
        try YourPiTree.copy(found.source, to: home.appendingPathComponent(found.copy.destination), staging: staging, limits: found.limits)
        for companion in found.companions {
            try YourPiTree.copy(companion.source, to: home.appendingPathComponent(companion.destination), staging: staging, limits: found.limits)
        }
        let modules = home.appendingPathComponent("your-extensions/npm/node_modules")
        for path in ["@acme/tools/index.js", "@acme/tools/node_modules/nested/index.js", "left-pad/index.js", "tiny/package.json"] {
            #expect(FileManager.default.fileExists(atPath: modules.appendingPathComponent(path).path), "\(path)")
        }
        #expect(!FileManager.default.fileExists(atPath: modules.appendingPathComponent("unrelated").path))
    }

    /// Two prompts of one name: pi uses the first, so only the first is copied, and the second is
    /// named as passed over.
    @Test func aPromptWithTheSameNameTwiceIsCopiedOnce() throws {
        let layout = try Layout(["agent/prompts/review.md": "first", "team/review.md": "second"], settings: #"{"prompts": ["../team/review.md"]}"#)
        defer { layout.remove() }
        let listing = layout.find(.prompts)
        #expect(listing.found.map(\.source.path) == [layout.agent.appendingPathComponent("prompts/review.md").path])
        #expect(listing.skipped == ["The prompt review.md from \(layout.root.path)/team/review.md wasn't copied: "
            + "\(layout.agent.path)/prompts/review.md has the same name."])
    }
}
