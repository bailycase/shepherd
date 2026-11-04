import Foundation
import ShepherdProtocol

/// Runs one command handler against a sample event, as Settings' Test and a proposal do.
public enum HookTester {
    /// Per-stream cap on what a hook's output keeps.
    public static let outputCap = 64 << 10

    /// A sample of what `event` sends on stdin, with Claude Code's field names. Tool events pick
    /// the first agent tool `matcher` matches (a file tool when `file` is given) and send `file`
    /// as its path.
    public static func sampleEvent(_ event: HookEvent, cwd: String, matcher: String = "", file: String? = nil) -> HookJSON {
        var sample = HookJSON.object(["session_id": .string("sample"), "transcript_path": .string(""), "cwd": .string(cwd),
                                      "hook_event_name": .string(event.rawValue)])
        switch event {
        case .sessionStart: sample["source"] = .string("startup")
        case .userPromptSubmit: sample["prompt"] = .string("Add a test for the date parser")
        case .preToolUse, .permissionRequest, .postToolUse:
            let preferred = file == nil ? ["bash", "edit", "write", "read", "grep", "find", "ls"] : ["edit", "write", "read", "bash", "grep", "find", "ls"]
            let tool = HookMatcher.agentTools(matching: matcher, among: preferred).first ?? (file == nil ? "bash" : "edit")
            let path = file ?? (cwd as NSString).appendingPathComponent("README.md")
            var input = HookJSON.object([HookJSON.Member]())
            switch tool {
            case "bash": input["command"] = .string("ls")
            case "edit": input = .object(["path": .string(path), "edits": .array([.object(["oldText": .string("old"), "newText": .string("new")])])])
            case "write": input = .object(["path": .string(path), "content": .string("Sample text\n")])
            case "grep": input = .object(["pattern": .string("TODO"), "path": .string(cwd)])
            case "find": input = .object(["pattern": .string("*.swift")])
            default: input["path"] = .string(path)
            }
            if let path = input["path"] { input["file_path"] = path }
            sample["tool_name"] = .string(HookMatcher.claudeName(forAgentTool: tool))
            sample["tool_input"] = input
            if event == .postToolUse {
                sample["tool_response"] = tool == "bash" ? .object(["stdout": .string("README.md\n"), "stderr": .string("")]) : .object(["success": .bool(true)])
            }
        case .preCompact, .postCompact: sample["trigger"] = .string("manual")
        case .subagentStart: sample["agent_type"] = .string("scout")
        case .subagentStop:
            sample["agent_type"] = .string("scout")
            sample["stop_hook_active"] = .bool(false)
        case .stop: sample["stop_hook_active"] = .bool(false)
        case .notification:
            sample["reason"] = .string("question")
            sample["message"] = .string("The agent needs you")
        case .sessionEnd: sample["reason"] = .string("other")
        }
        return sample
    }

    /// Runs `command` under `sh -c` in `root` with `CLAUDE_PROJECT_DIR` and `SHEPHERD_HOOK_EVENT`,
    /// the sample event (`sample`, else `sampleEvent`) on stdin, and the event's timeout unless
    /// `timeout` is given. A tool event given a real `file` gets a temporary copy of it, removed
    /// after. Blocks until the command finishes: call it off the main thread.
    public static func run(command: String, event: HookEvent, matcher: String = "", timeout: Double? = nil,
                           root: String, sample: HookJSON? = nil, file: URL? = nil) -> HookTestResult {
        var limit = timeout ?? event.defaultTimeout
        if let maximum = event.maximumTimeout { limit = min(limit, maximum) }
        limit = min(max(limit, 0.1), 600)

        var scratch: URL?
        defer { if let scratch { try? FileManager.default.removeItem(at: scratch) } }
        var copy: String?
        if let file, [.preToolUse, .postToolUse, .permissionRequest].contains(event) {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shepherd-hook-test-\(UUID().uuidString)", isDirectory: true)
            let target = folder.appendingPathComponent(file.lastPathComponent)
            if (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
               (try? FileManager.default.copyItem(at: file, to: target)) != nil {
                scratch = folder; copy = target.path
            }
        }
        let input = sample ?? sampleEvent(event, cwd: root, matcher: matcher, file: copy)

        // Never the agent's (or the app's inherited) socket, identity or secrets.
        var environment = PiHome.withoutAgentOnly(ProcessInfo.processInfo.environment)
        environment["CLAUDE_PROJECT_DIR"] = root
        environment["SHEPHERD_HOOK_EVENT"] = event.rawValue
        let start = DispatchTime.now().uptimeNanoseconds
        func elapsed() -> Int { Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000) }
        do {
            // ponytail: stdout over 4 MiB fails the run instead of being cut at 64 KiB; BoundedCommand throws past its limit.
            let result = try BoundedCommand.run(["/bin/sh", "-c", command], directory: URL(fileURLWithPath: root),
                                                environment: environment, input: Data(input.canonical.utf8),
                                                timeout: limit, outputLimit: 4 << 20)
            let stdout = String(decoding: result.output.prefix(outputCap), as: UTF8.self)
            let stderr = String(decoding: result.errors.prefix(outputCap), as: UTF8.self)
            return HookTestResult(exit: result.status, stdout: stdout, stderr: stderr, milliseconds: elapsed(),
                                  outcome: HookOutcome.interpret(event: event.rawValue, exit: result.status, stdout: stdout, stderr: stderr),
                                  stdoutCut: result.output.count > outputCap, stderrCut: result.errors.count > outputCap)
        } catch BoundedCommand.Failure.timedOut {
            return HookTestResult(exit: nil, stdout: "", stderr: "", milliseconds: elapsed(), outcome: .timedOut)
        } catch BoundedCommand.Failure.outputTooLarge {
            return HookTestResult(exit: nil, stdout: "", stderr: "", milliseconds: elapsed(), outcome: .failed("output over 4 MiB"))
        } catch {
            return HookTestResult(exit: nil, stdout: "", stderr: "", milliseconds: elapsed(), outcome: .failed("couldn't start: \(error)"))
        }
    }
}
