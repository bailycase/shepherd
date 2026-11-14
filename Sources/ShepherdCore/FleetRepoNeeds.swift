import Foundation

/// A program a repository's checkout asks for (Fleet ▸ Check): read from the files at its top level, never run.
public struct FleetRepoNeed: Hashable, Sendable {
    public enum Tool: String, Codable, CaseIterable, Sendable {
        case node, pnpm, npm, yarn, xcode, nix, cargo, go, python

        /// The program as a person says it.
        public var title: String {
            switch self {
            case .xcode: "Xcode"
            default: rawValue
            }
        }
    }

    public enum Match: String, Codable, Sendable {
        /// The repository pins this version (`.nvmrc`, `packageManager`): a different one differs.
        case exact
        /// The repository asks for this version or a newer one (`engines`, `go.mod`, the tools version).
        case atLeast
    }

    public var tool: Tool
    /// "22", "9", "1.22": as many parts as the file gives, at most two. Nil when the file names the tool and no version.
    public var version: String?
    public var match: Match
    /// The file that says so: ".nvmrc", "pnpm-lock.yaml".
    public var source: String
    /// The repository's name here (its space).
    public var repo: String

    public init(tool: Tool, version: String? = nil, match: Match = .exact, source: String, repo: String) {
        self.tool = tool
        self.version = version
        self.match = match
        self.source = source
        self.repo = repo
    }

    /// What a row of the Check grid is called: "node 22", "pnpm 9", "Xcode 26", "nix".
    public var title: String { version.map { "\(tool.title) \($0)" } ?? tool.title }

    /// The row's identity across Macs: the same tool at the same version asked the same way.
    public var rowID: String { "need:\(tool.rawValue):\(version ?? "")\(match == .atLeast ? "+" : "")" }
}

/// What a checkout asks for, from its marker files. Pure parsers over text, and one reader that looks at the folder's top level.
public enum FleetRepoNeeds {
    /// A file larger than this isn't read.
    static let maxFile = 256 * 1024

    /// The needs of the checkout at `folder`, one per tool (the first marker that names it), in a stable order.
    public static func read(folder: String, repo: String, fileManager: FileManager = .default) -> [FleetRepoNeed] {
        let root = (folder as NSString).expandingTildeInPath
        let names = (try? fileManager.contentsOfDirectory(atPath: root)) ?? []
        func text(_ name: String) -> String? {
            guard names.contains(name) else { return nil }
            let path = (root as NSString).appendingPathComponent(name)
            guard let size = (try? fileManager.attributesOfItem(atPath: path))?[.size] as? Int, size <= maxFile,
                  let data = fileManager.contents(atPath: path) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        return needs(names: Set(names), text: text, repo: repo)
    }

    /// The needs of a checkout given its top level `names` and a way to read one of them.
    public static func needs(names: Set<String>, text: (String) -> String?, repo: String) -> [FleetRepoNeed] {
        var found: [FleetRepoNeed.Tool: FleetRepoNeed] = [:]
        func add(_ tool: FleetRepoNeed.Tool, _ version: String?, _ match: FleetRepoNeed.Match = .exact, _ source: String) {
            if found[tool] == nil { found[tool] = FleetRepoNeed(tool: tool, version: version, match: match, source: source, repo: repo) }
        }
        let package = text("package.json")
        let manager = package.flatMap(packageManager(inPackageJSON:))

        for file in [".nvmrc", ".node-version"] {
            if let content = text(file) { add(.node, nodeVersion(inVersionFile: content), .exact, file) }
        }
        if let engine = package.flatMap(nodeEngine(inPackageJSON:)) { add(.node, engine.version, engine.match, "package.json") }

        if manager?.name == "pnpm" { add(.pnpm, manager?.version, .exact, "package.json") }
        if let lock = text("pnpm-lock.yaml") {
            let pinned = pnpmVersion(inLockfile: lock)
            add(.pnpm, pinned?.version, pinned?.match ?? .exact, "pnpm-lock.yaml")
        } else if names.contains("pnpm-lock.yaml") {
            add(.pnpm, nil, .exact, "pnpm-lock.yaml")
        }
        if names.contains("package-lock.json") { add(.npm, manager?.name == "npm" ? manager?.version : nil, .exact, "package-lock.json") }
        if names.contains("yarn.lock") { add(.yarn, manager?.name == "yarn" ? manager?.version : nil, .exact, "yarn.lock") }
        if manager?.name == "npm" { add(.npm, manager?.version, .exact, "package.json") }
        if manager?.name == "yarn" { add(.yarn, manager?.version, .exact, "package.json") }

        if let content = text(".xcode-version") {
            add(.xcode, version(in: content, parts: 1), .atLeast, ".xcode-version")
        }
        if let content = text("Package.swift") {
            add(.xcode, swiftToolsVersion(inPackageSwift: content).flatMap(xcodeMajor(forSwiftTools:)), .atLeast, "Package.swift")
        } else if names.contains("Package.swift") {
            add(.xcode, nil, .atLeast, "Package.swift")
        }
        if let project = names.sorted().first(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
            add(.xcode, nil, .atLeast, project)
        }

        if names.contains("flake.nix") { add(.nix, nil, .exact, "flake.nix") }
        if let content = text("Cargo.toml") {
            add(.cargo, rustVersion(inCargoToml: content), .atLeast, "Cargo.toml")
        } else if names.contains("Cargo.toml") {
            add(.cargo, nil, .exact, "Cargo.toml")
        }
        if let content = text("go.mod") {
            add(.go, goVersion(inGoMod: content), .atLeast, "go.mod")
        } else if names.contains("go.mod") {
            add(.go, nil, .exact, "go.mod")
        }
        if let content = text(".python-version") { add(.python, version(in: content, parts: 2), .exact, ".python-version") }

        return FleetRepoNeed.Tool.allCases.compactMap { found[$0] }
    }

    // MARK: Parsers

    /// ".nvmrc" or ".node-version": "v22.11.0", "22", "20.x" give the major; "lts/*" and "node" give none.
    public static func nodeVersion(inVersionFile text: String) -> String? {
        let first = text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let bare = first.hasPrefix("v") ? String(first.dropFirst()) : first
        return bare.first?.isNumber == true ? version(in: bare, parts: 1) : nil
    }

    /// `engines.node` of a package.json: ">=20" asks for 20 or newer, "22.x" and "^22" pin 22.
    public static func nodeEngine(inPackageJSON text: String) -> (version: String?, match: FleetRepoNeed.Match)? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let engines = object["engines"] as? [String: Any], let range = engines["node"] as? String else { return nil }
        let minimum = range.contains(">")
        return (version(in: range, parts: 1), minimum ? .atLeast : .exact)
    }

    /// `packageManager` of a package.json: "pnpm@9.15.0+sha512.abc" is ("pnpm", "9").
    public static func packageManager(inPackageJSON text: String) -> (name: String, version: String?)? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let field = object["packageManager"] as? String else { return nil }
        let parts = field.split(separator: "@", maxSplits: 1)
        guard let name = parts.first.map(String.init), !name.isEmpty else { return nil }
        return (name, parts.count > 1 ? version(in: String(parts[1]), parts: 1) : nil)
    }

    /// The pnpm a lockfile was written by, from its `lockfileVersion`: 9.0 is pnpm 9 or newer (10 writes it too), 6.x is 8, 5.4 is 7, 5.3 is 6.
    public static func pnpmVersion(inLockfile text: String) -> (version: String, match: FleetRepoNeed.Match)? {
        guard let line = text.split(whereSeparator: \.isNewline).prefix(10).first(where: { $0.hasPrefix("lockfileVersion") }),
              let raw = version(in: String(line), parts: 2) else { return nil }
        switch raw.split(separator: ".").first.flatMap({ Int($0) }) ?? 0 {
        case 9...: return ("9", .atLeast)
        case 6: return ("8", .exact)
        case 5: return raw == "5.3" ? ("6", .exact) : ("7", .exact)
        default: return nil
        }
    }

    /// "6.2" from `// swift-tools-version: 6.2`.
    public static func swiftToolsVersion(inPackageSwift text: String) -> String? {
        guard let range = text.prefix(512).range(of: "swift-tools-version") else { return nil }
        return version(in: String(text.prefix(512)[range.upperBound...].prefix { $0 != "\n" }), parts: 2)
    }

    /// The oldest Xcode that builds a package of this tools version: Swift 6.2 came with Xcode 26, 6.0 and 6.1 with 16, 5.9 and 5.10 with 15.
    public static func xcodeMajor(forSwiftTools tools: String) -> String? {
        let parts = tools.split(separator: ".").compactMap { Int($0) }
        guard let major = parts.first else { return nil }
        let minor = parts.count > 1 ? parts[1] : 0
        switch (major, minor) {
        case (7..., _), (6, 2...): return "26"
        case (6, _): return "16"
        case (5, 9...): return "15"
        case (5, 7...8): return "14"
        case (5, 5...6): return "13"
        default: return nil
        }
    }

    /// "1.22" from go.mod's `go 1.22.1`.
    public static func goVersion(inGoMod text: String) -> String? {
        guard let line = text.split(whereSeparator: \.isNewline).first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("go ") }) else { return nil }
        return version(in: String(line.dropFirst(2)), parts: 2)
    }

    /// "1.75" from Cargo.toml's `rust-version = "1.75"`.
    public static func rustVersion(inCargoToml text: String) -> String? {
        guard let line = text.split(whereSeparator: \.isNewline).first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("rust-version") }) else { return nil }
        return version(in: String(line), parts: 2)
    }

    /// The first dotted number in `text`, cut to `parts`: "v22.11.0" with 1 is "22". Nil when there is no number.
    public static func version(in text: String, parts: Int) -> String? {
        FleetVersion.first(in: text).map { Array($0.prefix(parts)).map(String.init).joined(separator: ".") }
    }

    // MARK: Rows

    /// A row of the Check grid before it is compared with a Mac: one tool at one version, and every repository that asks for it.
    public struct Row: Hashable, Sendable {
        public var need: FleetRepoNeed
        public var repos: [String]
        public var sources: [String]
    }

    /// The needs of every repository, one row per tool and version, repositories and files each listed once, sorted.
    public static func rows(_ needs: [FleetRepoNeed]) -> [Row] {
        var byID: [String: Row] = [:]
        for need in needs {
            var row = byID[need.rowID] ?? Row(need: need, repos: [], sources: [])
            if !row.repos.contains(need.repo) { row.repos.append(need.repo) }
            if !row.sources.contains(need.source) { row.sources.append(need.source) }
            byID[need.rowID] = row
        }
        return byID.values.map { row in
            var row = row
            row.repos.sort()
            row.sources.sort()
            return row
        }.sorted { ($0.need.tool.allIndex, $0.need.rowID) < ($1.need.tool.allIndex, $1.need.rowID) }
    }
}

private extension FleetRepoNeed.Tool {
    var allIndex: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// Dotted versions: reading one out of a program's words and comparing two.
public enum FleetVersion {
    /// The first dotted number in `text` ("go version go1.23.3" is [1, 23, 3]), else its first whole number.
    public static func first(in text: String) -> [Int]? {
        let scalars = Array(text.unicodeScalars)
        func number(from start: Int) -> (parts: [Int], end: Int)? {
            var parts: [Int] = []
            var index = start
            while index < scalars.count, ("0"..."9").contains(scalars[index]) {
                var digits = ""
                while index < scalars.count, ("0"..."9").contains(scalars[index]) { digits.unicodeScalars.append(scalars[index]); index += 1 }
                parts.append(Int(digits.prefix(9)) ?? 0)
                guard index + 1 < scalars.count, scalars[index] == ".", ("0"..."9").contains(scalars[index + 1]) else { break }
                index += 1
            }
            return parts.isEmpty ? nil : (parts, index)
        }
        var dotless: [Int]?
        var index = 0
        while index < scalars.count {
            if ("0"..."9").contains(scalars[index]), let found = number(from: index) {
                if found.parts.count > 1 { return found.parts }
                dotless = dotless ?? found.parts
                index = found.end
            } else {
                index += 1
            }
        }
        return dotless
    }

    /// Whether `have` ("20.18.1", "v20.18") meets `need` ("22", "1.22") the way the repository asks for it: an exact need matches as many leading
    /// parts as it gives, a minimum is met by the same version or a newer one.
    public static func satisfies(have: String, need: String, match: FleetRepoNeed.Match) -> Bool {
        guard let have = first(in: have), let need = first(in: need) else { return false }
        switch match {
        case .exact:
            return (0..<need.count).allSatisfy { (have.count > $0 ? have[$0] : 0) == need[$0] }
        case .atLeast:
            for index in 0..<max(have.count, need.count) {
                let left = have.count > index ? have[index] : 0, right = need.count > index ? need[index] : 0
                if left != right { return left > right }
            }
            return true
        }
    }
}
