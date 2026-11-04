import Foundation
import Testing
import ShepherdTestSupport
import ShepherdProtocol
@testable import ShepherdSessions

/// Settings' Test button: one command handler run against a sample event.
@Suite("Hook tester", .integrationTimeLimit)
struct HookTesterTests {
    @Test func exitZeroGoesAheadWithTheSampleEnvironmentAndContext() throws {
        let root = try makeScratchDirectory("hook"); defer { try? FileManager.default.removeItem(at: root) }
        let result = HookTester.run(command: #"cat >/dev/null; printf '%s %s %s' "$SHEPHERD_HOOK_EVENT" "$CLAUDE_PROJECT_DIR" "$(pwd -P)""#,
                                    event: .sessionStart, root: root.path)
        let real = PiHome.canonical(root.path)
        #expect(result.exit == 0)
        #expect(result.stdout == "SessionStart \(root.path) \(real)")
        #expect(result.outcome == .context("SessionStart \(root.path) \(real)"))
    }

    @Test func exitTwoWouldBlockWithStderrAsTheReason() throws {
        let root = try makeScratchDirectory("hook"); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(".env")
        try "SECRET=1\n".write(to: file, atomically: true, encoding: .utf8)
        // The sample's file is a temporary copy, so the hook can't touch the real one.
        let result = HookTester.run(command: #"input=$(cat); case "$input" in *'"tool_name":"Edit"'*) ;; *) exit 1 ;; esac; path=$(printf '%s' "$input" | /usr/bin/sed -E 's/.*"file_path":"([^"]*)".*/\1/'); [ "$path" != "$0" ] && rm "$path"; echo "no .env edits" >&2; exit 2"#,
                                    event: .preToolUse, matcher: "Edit|Write", root: root.path, file: file)
        #expect(result.exit == 2)
        #expect(result.outcome == .blocked(reason: "no .env edits"))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aHookThatRunsTooLongTimesOut() throws {
        let root = try makeScratchDirectory("hook"); defer { try? FileManager.default.removeItem(at: root) }
        let result = HookTester.run(command: "sleep 30", event: .stop, timeout: 0.3, root: root.path)
        #expect(result.outcome == .timedOut && result.exit == nil)
        #expect(result.milliseconds < 10_000)
    }
}
