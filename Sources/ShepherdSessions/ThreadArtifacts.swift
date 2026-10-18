import Foundation
import ShepherdProtocol
import ShepherdRemote

/// The artifacts of a thread, on the host (docs/native-thread.md › Artifacts): files a successful `write` call made. A client names a path
/// only as a key. The host re-derives the written paths from pi's own saved history for this agent and session on every request, and serves
/// nothing else: not another file, not a path that merely resembles one, not a file the history says a failed write tried to make.
enum ThreadArtifacts {
    /// The paths of the successful `write` calls in pi's history `messages`, as the calls gave them.
    static func writtenPaths(in messages: [RPCMessage]) -> Set<String> {
        var calls: [String: String] = [:]
        for message in messages where message.role == "assistant" {
            for case .toolCall(let id, let name, let args) in message.content where name == "write" {
                if let path = args?["path"]?.stringValue, !path.isEmpty { calls[id] = path }
            }
        }
        var written: Set<String> = []
        for message in messages where message.role == "toolResult" && message.toolName == "write" && message.isError != true {
            if let id = message.toolCallId, let path = calls[id] { written.insert(path) }
        }
        return written
    }

    /// The path as the file system sees it (`nativeArtifactFilePath`).
    static func resolved(_ path: String, cwd: String) -> String { nativeArtifactFilePath(path, cwd: cwd) }

    /// One piece of `path` from `offset`, if `written` holds it (`NativeArtifactFile.read`). Reads the disk: never on the server queue.
    static func read(_ path: String, offset: Int, written: Set<String>, cwd: String) -> NativeArtifactFile.Read {
        guard offset >= 0, written.contains(path) else { return .outOfRange }
        return NativeArtifactFile.read(path, offset: offset, cwd: cwd)
    }
}
