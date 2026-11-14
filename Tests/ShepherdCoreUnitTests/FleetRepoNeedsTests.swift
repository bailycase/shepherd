import Foundation
import Testing
import ShepherdCore

/// What a checkout asks for (Fleet ▸ Check): each marker file's parser, the rows made of several repositories, and the version comparison.
@Suite("Fleet repo needs")
struct FleetRepoNeedsTests {
    /// The needs of a checkout holding these files.
    static func needs(_ files: [String: String], repo: String = "acme-web") -> [FleetRepoNeed] {
        FleetRepoNeeds.needs(names: Set(files.keys), text: { files[$0] }, repo: repo)
    }

    static func need(_ tool: FleetRepoNeed.Tool, in files: [String: String]) -> FleetRepoNeed? {
        needs(files).first { $0.tool == tool }
    }

    // MARK: Node

    @Test func nvmrcAndNodeVersionGiveTheMajor() {
        #expect(FleetRepoNeeds.nodeVersion(inVersionFile: "v22.11.0\n") == "22")
        #expect(FleetRepoNeeds.nodeVersion(inVersionFile: "22") == "22")
        #expect(FleetRepoNeeds.nodeVersion(inVersionFile: "20.x") == "20")
        #expect(FleetRepoNeeds.nodeVersion(inVersionFile: "lts/*") == nil)
        #expect(FleetRepoNeeds.nodeVersion(inVersionFile: "node") == nil)
        let need = Self.need(.node, in: [".nvmrc": "v22.11.0\n"])
        #expect(need?.version == "22" && need?.match == .exact && need?.source == ".nvmrc" && need?.title == "node 22")
        #expect(Self.need(.node, in: [".node-version": "20.18.1"])?.source == ".node-version")
    }

    @Test func enginesNodeIsAMinimumOnlyWhenItSaysSo() {
        #expect(FleetRepoNeeds.nodeEngine(inPackageJSON: #"{"engines":{"node":">=20"}}"#)?.match == .atLeast)
        #expect(FleetRepoNeeds.nodeEngine(inPackageJSON: #"{"engines":{"node":">=20"}}"#)?.version == "20")
        #expect(FleetRepoNeeds.nodeEngine(inPackageJSON: #"{"engines":{"node":"^22.0.0"}}"#)?.match == .exact)
        #expect(FleetRepoNeeds.nodeEngine(inPackageJSON: #"{"engines":{"node":"22.x"}}"#)?.version == "22")
        #expect(FleetRepoNeeds.nodeEngine(inPackageJSON: #"{"name":"web"}"#) == nil)
        #expect(FleetRepoNeeds.nodeEngine(inPackageJSON: "not json") == nil)
        // The version file wins over engines.
        let need = Self.need(.node, in: [".nvmrc": "22", "package.json": #"{"engines":{"node":">=18"}}"#])
        #expect(need?.version == "22" && need?.source == ".nvmrc")
    }

    // MARK: Package managers

    @Test func pnpmComesFromPackageManagerThenTheLockfile() {
        #expect(FleetRepoNeeds.packageManager(inPackageJSON: #"{"packageManager":"pnpm@9.15.0+sha512.abc"}"#)?.name == "pnpm")
        #expect(FleetRepoNeeds.packageManager(inPackageJSON: #"{"packageManager":"pnpm@9.15.0+sha512.abc"}"#)?.version == "9")
        #expect(FleetRepoNeeds.packageManager(inPackageJSON: #"{"packageManager":"yarn"}"#)?.version == nil)
        let pinned = Self.need(.pnpm, in: ["package.json": #"{"packageManager":"pnpm@9.15.0"}"#, "pnpm-lock.yaml": "lockfileVersion: '6.0'\n"])
        #expect(pinned?.version == "9" && pinned?.source == "package.json")
        let locked = Self.need(.pnpm, in: ["pnpm-lock.yaml": "lockfileVersion: '9.0'\n\nimporters:\n"])
        #expect(locked?.version == "9" && locked?.match == .atLeast && locked?.source == "pnpm-lock.yaml")
    }

    @Test func aPnpmLockfileVersionNamesThePnpmThatWroteIt() {
        #expect(FleetRepoNeeds.pnpmVersion(inLockfile: "lockfileVersion: '9.0'")?.version == "9")
        #expect(FleetRepoNeeds.pnpmVersion(inLockfile: "lockfileVersion: '6.0'")?.version == "8")
        #expect(FleetRepoNeeds.pnpmVersion(inLockfile: "lockfileVersion: 5.4")?.version == "7")
        #expect(FleetRepoNeeds.pnpmVersion(inLockfile: "lockfileVersion: 5.3")?.version == "6")
        #expect(FleetRepoNeeds.pnpmVersion(inLockfile: "importers:") == nil)
    }

    @Test func npmAndYarnComeFromTheirLockfiles() {
        #expect(Self.need(.npm, in: ["package-lock.json": "{}"])?.version == nil)
        #expect(Self.need(.yarn, in: ["yarn.lock": "# yarn lockfile v1"])?.source == "yarn.lock")
        #expect(Self.need(.yarn, in: ["package.json": #"{"packageManager":"yarn@4.5.0"}"#])?.version == "4")
    }

    // MARK: Xcode

    @Test func aSwiftPackageAsksForTheXcodeItsToolsVersionCameWith() {
        #expect(FleetRepoNeeds.swiftToolsVersion(inPackageSwift: "// swift-tools-version: 6.2\nimport PackageDescription") == "6.2")
        #expect(FleetRepoNeeds.swiftToolsVersion(inPackageSwift: "// swift-tools-version:5.9") == "5.9")
        #expect(FleetRepoNeeds.swiftToolsVersion(inPackageSwift: "import PackageDescription") == nil)
        #expect(FleetRepoNeeds.xcodeMajor(forSwiftTools: "6.2") == "26")
        #expect(FleetRepoNeeds.xcodeMajor(forSwiftTools: "6.1") == "16")
        #expect(FleetRepoNeeds.xcodeMajor(forSwiftTools: "6.0") == "16")
        #expect(FleetRepoNeeds.xcodeMajor(forSwiftTools: "5.10") == "15")
        #expect(FleetRepoNeeds.xcodeMajor(forSwiftTools: "5.9") == "15")
        let package = Self.need(.xcode, in: ["Package.swift": "// swift-tools-version: 6.2\n"])
        #expect(package?.version == "26" && package?.match == .atLeast && package?.title == "Xcode 26")
    }

    @Test func anXcodeProjectOrWorkspaceAsksForXcodeWithNoVersion() {
        #expect(Self.need(.xcode, in: ["Acme.xcodeproj": ""])?.version == nil)
        #expect(Self.need(.xcode, in: ["Acme.xcworkspace": ""])?.source == "Acme.xcworkspace")
        #expect(Self.need(.xcode, in: [".xcode-version": "26.0\n", "Acme.xcodeproj": ""])?.version == "26")
        #expect(Self.need(.xcode, in: ["README.md": ""]) == nil)
    }

    // MARK: The rest

    @Test func nixCargoGoAndPythonComeFromTheirFiles() {
        #expect(Self.need(.nix, in: ["flake.nix": "{}"])?.source == "flake.nix")
        #expect(Self.need(.cargo, in: ["Cargo.toml": "[package]\nrust-version = \"1.75\"\n"])?.version == "1.75")
        #expect(Self.need(.cargo, in: ["Cargo.toml": "[package]\nname = \"x\"\n"])?.version == nil)
        #expect(FleetRepoNeeds.goVersion(inGoMod: "module acme.dev/x\n\ngo 1.22.1\n") == "1.22")
        #expect(Self.need(.go, in: ["go.mod": "module acme.dev/x\n\ngo 1.22.1\n"])?.match == .atLeast)
        #expect(Self.need(.python, in: [".python-version": "3.12.4\n"])?.version == "3.12")
        #expect(Self.need(.python, in: [".python-version": "pypy\n"])?.version == nil)
    }

    @Test func aCheckoutWithNoMarkerAsksForNothing() {
        #expect(Self.needs(["README.md": "# hi", "src": ""]).isEmpty)
    }

    @Test func oneToolIsOneNeedPerCheckoutFromTheFirstMarkerThatNamesIt() {
        let found = Self.needs([".nvmrc": "22", ".node-version": "20", "pnpm-lock.yaml": "lockfileVersion: '9.0'", "flake.nix": ""])
        #expect(found.map(\.tool) == [.node, .pnpm, .nix])
        #expect(found.first?.source == ".nvmrc")
    }

    @Test func theReaderLooksAtTheTopLevelOfAFolderAndSkipsHugeFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("needs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "v22.11.0\n".write(to: folder.appendingPathComponent(".nvmrc"), atomically: true, encoding: .utf8)
        try String(repeating: "x", count: FleetRepoNeeds.maxFile + 1).write(to: folder.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "{}".write(to: folder.appendingPathComponent("sub/flake.nix"), atomically: true, encoding: .utf8)
        let found = FleetRepoNeeds.read(folder: folder.path, repo: "acme-web")
        // go.mod is named but too big to read: the tool is asked for, with no version. A flake in a subfolder isn't at the top.
        #expect(found.map(\.tool) == [.node, .go])
        #expect(found.first?.version == "22" && found.last?.version == nil)
        #expect(FleetRepoNeeds.read(folder: folder.appendingPathComponent("missing").path, repo: "x").isEmpty)
    }

    // MARK: Rows

    @Test func repositoriesThatAskForTheSameThingShareARow() {
        let web = Self.needs([".nvmrc": "22"], repo: "web")
        let payments = Self.needs([".nvmrc": "v22.1", "flake.nix": ""], repo: "payments-api")
        let other = Self.needs([".nvmrc": "20"], repo: "legacy")
        let rows = FleetRepoNeeds.rows(web + payments + other)
        #expect(rows.map(\.need.rowID) == ["need:node:20", "need:node:22", "need:nix:"])
        let shared = rows.first { $0.need.rowID == "need:node:22" }
        #expect(shared?.repos == ["payments-api", "web"] && shared?.sources == [".nvmrc"])
    }

    @Test func aMinimumAndAPinAreDifferentRows() {
        let pinned = Self.needs([".nvmrc": "22"], repo: "web")
        let minimum = Self.needs(["package.json": #"{"engines":{"node":">=22"}}"#], repo: "api")
        #expect(FleetRepoNeeds.rows(pinned + minimum).map(\.need.rowID) == ["need:node:22", "need:node:22+"])
    }

    // MARK: Versions

    @Test func aVersionIsReadOutOfAProgramsWords() {
        #expect(FleetVersion.first(in: "v20.18.1") == [20, 18, 1])
        #expect(FleetVersion.first(in: "go version go1.23.3 darwin/arm64") == [1, 23, 3])
        #expect(FleetVersion.first(in: "Xcode 26.2") == [26, 2])
        #expect(FleetVersion.first(in: "nix (Nix) 2.31.2") == [2, 31, 2])
        #expect(FleetVersion.first(in: "Python 3.12.4") == [3, 12, 4])
        #expect(FleetVersion.first(in: "22") == [22])
        #expect(FleetVersion.first(in: "no number here") == nil)
    }

    @Test func anExactNeedMatchesAsManyPartsAsItGives() {
        #expect(FleetVersion.satisfies(have: "22.11.0", need: "22", match: .exact))
        #expect(!FleetVersion.satisfies(have: "20.18.1", need: "22", match: .exact))
        #expect(!FleetVersion.satisfies(have: "24.1.0", need: "22", match: .exact))
        #expect(FleetVersion.satisfies(have: "3.12.4", need: "3.12", match: .exact))
        #expect(!FleetVersion.satisfies(have: "3.13.0", need: "3.12", match: .exact))
    }

    @Test func aMinimumIsMetByTheSameOrANewerVersion() {
        #expect(FleetVersion.satisfies(have: "22.0", need: "22", match: .atLeast))
        #expect(FleetVersion.satisfies(have: "24.1", need: "22", match: .atLeast))
        #expect(!FleetVersion.satisfies(have: "20.18", need: "22", match: .atLeast))
        #expect(FleetVersion.satisfies(have: "1.23.3", need: "1.22", match: .atLeast))
        #expect(!FleetVersion.satisfies(have: "1.21.9", need: "1.22", match: .atLeast))
        #expect(!FleetVersion.satisfies(have: "none", need: "22", match: .atLeast))
    }
}
