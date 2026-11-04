import Foundation
import ShepherdProtocol

/// Settings › Hooks for a remote client (`hooks.v1`, docs/remote-protocol.md): the same reads,
/// switches, writes and test the Mac's page makes, on this host's files. A client names only the
/// catalog's own files and spaces, and a hook only as it read it.
extension HookCatalog {
    public struct RequestError: Error, Equatable, CustomStringConvertible, Sendable {
        public let code: String
        public let description: String
    }

    /// Answers `request` with the catalog afterwards (or the test's result). Reads, writes and runs
    /// a test that may take its whole time limit: call it off the server queue.
    public func perform(_ request: RemoteHooksRequest, spaceRoots: [String]) throws -> RemoteHooksResult {
        let snapshot = load(spaceRoots: spaceRoots)
        let writer = HookFileWriter(settings: settingsStore)
        func entry(_ ref: HookRef) throws -> HookEntry {
            guard let entry = snapshot.entries.first(where: { $0.slot == ref.slot && $0.hash == ref.hash }) else {
                throw RequestError(code: "hook_changed", description: "This hook changed in its file since you read it. Reload and try again.")
            }
            guard entry.editable else { throw RequestError(code: "read_only", description: "Shepherd reads \(entry.file) but doesn't write it.") }
            return entry
        }
        do {
            switch request {
            case .fetch:
                return .hooks(snapshot)
            case .setOn(let hash, let on):
                guard snapshot.entries.contains(where: { $0.hash == hash }) else {
                    throw RequestError(code: "hook_changed", description: "That hook is no longer in its file. Reload and try again.")
                }
                try settingsStore.setOn(hash, on)
            case .setReader(let format, let on):
                try settingsStore.setReader(format, on)
            case .save(let drafts, let file, let ref, let kept):
                guard snapshot.sources.contains(where: { $0.path == file && !$0.isTOML }) else {
                    throw RequestError(code: "not_a_hooks_file", description: "\(file) isn't one of this host's hooks files.")
                }
                guard !drafts.isEmpty, drafts.allSatisfy({ HookEvent(rawValue: $0.event) != nil && HookMatcher.isValid($0.matcher) }) else {
                    throw RequestError(code: "invalid_hook", description: "A hook needs a known event and a matcher Shepherd can read.")
                }
                try writer.save(drafts, to: file, replacing: try ref.map(entry), kept: kept)
            case .delete(let ref):
                try writer.delete(try entry(ref))
            case .test(let command, let event, let matcher, let timeout, let root):
                if let root, !snapshot.sources.contains(where: { $0.scope.root == root }) {
                    throw RequestError(code: "no_such_space", description: "\(root) isn't one of this host's spaces.")
                }
                return .tested(HookTester.run(command: command, event: event, matcher: matcher, timeout: timeout, root: root ?? home))
            }
        } catch let failure as HookFileWriter.Failure {
            throw RequestError(code: "hook_write_failed", description: failure.description)
        }
        return .hooks(load(spaceRoots: spaceRoots))
    }
}
