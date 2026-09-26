import Foundation
import WebKit

/// The scripts a board runs with, from this module's resources.
enum DesignRuntime {
    /// React 18.3.1's production UMD builds (MIT; `Resources/react/LICENSE`), pinned and checked
    /// by `DesignRuntimeTests`.
    static let reactFiles = ["react.production.min.js", "react-dom.production.min.js"]

    /// What a board's `./support.js` gets: React, ReactDOM, then Shepherd's runtime. Nil only if
    /// the module's resources are missing.
    static let supportScript: Data? = {
        var parts: [Data] = []
        for name in reactFiles {
            guard let data = resource("react/" + name) else { return nil }
            parts.append(data)
        }
        guard let runtime = resource("shepherd-dc-runtime.js") else { return nil }
        parts.append(runtime)
        return parts.reduce(into: Data()) { script, part in
            script.append(part)
            script.append(contentsOf: Array(";\n".utf8))
        }
    }()

    /// The bridge, injected into Shepherd's content world beside each board.
    static let bridgeScript: String = resource("shepherd-dc-bridge.js").map { String(decoding: $0, as: UTF8.self) } ?? ""

    static func resource(_ path: String) -> Data? {
        guard let url = Bundle.module.resourceURL?.appendingPathComponent(path) else { return nil }
        return try? Data(contentsOf: url)
    }
}

/// The compiled `DesignSandbox.contentRules`, one per network setting for the whole process.
@MainActor
enum DesignContentRules {
    private static var compiled: [DesignSandbox.Network: Task<WKContentRuleList, any Error>] = [:]

    static func list(network: DesignSandbox.Network) async throws -> WKContentRuleList {
        if let task = compiled[network] { return try await task.value }
        let task = Task { @MainActor in
            let source = DesignSandbox.contentRules(network: network)
            // Compiled lists persist in a store of their own under the temporary folder, never
            // WebKit's default store in the user's Library.
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShepherdDesignRules", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard let store = WKContentRuleListStore(url: folder) else { throw DesignBoardError.rulesUnavailable }
            // Compiled afresh once per process, over the last copy.
            let identifier = "shepherd-design-" + (network == .googleFonts ? "fonts" : "offline")
            guard let list = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: source) else {
                throw DesignBoardError.rulesUnavailable
            }
            return list
        }
        compiled[network] = task
        do {
            return try await task.value
        } catch {
            compiled[network] = nil
            throw error
        }
    }
}
