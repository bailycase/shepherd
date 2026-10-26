import Foundation

/// How a Project's own tools read in a thread's activity lines: words from the call's typed arguments and the tool's own result
/// (never from the model's prose), instead of the first 120 characters of its JSON. The raw output and arguments stay the line's
/// expanded details ("Show Call", Copy Output). A result that does not parse says only what the tool was, and a failure shows the
/// tool's own `message`.
public enum NativeProjectToolActivity {
    public static let names: Set<String> = [
        "project_read", "project_list_spaces", "project_inspect", "project_publish", "project_assign", "project_follow_up", "project_resolve",
        "project_propose_space", "project_remember", "project_answer", "project_question",
    ]

    public static func isTool(_ name: String) -> Bool { names.contains(name) }

    private static func object(_ output: String) -> [String: Any]? {
        guard output.utf8.count <= 1 << 20, let data = output.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The one subject a compact line adds after its words: a file name, a thread's title, a count. Empty when there is none.
    static func subject(_ name: String, arguments: [String: Any]?, output: String) -> String {
        let result = object(output)
        func argument(_ key: String) -> String? { (arguments?[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        switch name {
        case "project_publish":
            let artifact = (result?["artifact"] as? [String: Any])?["artifactName"] as? String
            return argument("artifactName") ?? artifact ?? ""
        case "project_inspect":
            let task = (result?["tasks"] as? [[String: Any]])?.first?["title"] as? String
            return task ?? ""
        case "project_assign", "project_follow_up":
            // The thread's title. A follow-up names its task by ID, so its title comes from the owner's result when it is there.
            let task = argument("taskID").flatMap { id in (result?["tasks"] as? [[String: Any]])?.first { $0["id"] as? String == id }?["title"] as? String }
            return argument("title") ?? task ?? ""
        case "project_question":
            // The question the worker asked, from the call's own arguments; the person's answer rides in the same line once given.
            let asked = argument("question").map { $0.split(whereSeparator: \.isNewline).first.map(String.init) ?? $0 } ?? ""
            if let answer = result?["answer"] as? String, !answer.isEmpty { return asked.isEmpty ? answer : "\(asked) · \(answer)" }
            return asked
        case "project_read":
            guard let tasks = result?["tasks"] as? [Any] else { return "" }
            return tasks.isEmpty ? "no threads yet" : nativeCount(tasks.count, "thread")
        default:
            return ""
        }
    }

    /// The model and thinking level the coordinator chose for a thread (`project_assign`, `project_follow_up`), from the call's own
    /// arguments: "sonnet-4-5 · high". Empty when it chose neither (the Project's defaults apply).
    static func choice(_ call: NativeActivityCall) -> [String] {
        guard call.name == "project_assign" || call.name == "project_follow_up", let data = call.arguments?.data(using: .utf8),
              let arguments = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        func argument(_ key: String) -> String? { (arguments[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return [argument("model").map { $0.split(separator: "/").last.map(String.init) ?? $0 }, argument("thinking")].compactMap { $0 }
    }

    /// A refusal's own message ("Only an active native-scoped Project worker may publish."), never the JSON around it.
    static func failureMessage(_ output: String) -> String? {
        guard let message = object(output)?["message"] as? String, !message.isEmpty else { return nil }
        return String(message.prefix(80))
    }

    /// `{"cancelled":true}`: a question that ended without an answer, which is neither an answer nor permission.
    private static func cancelled(_ call: NativeActivityCall) -> Bool {
        call.name == "project_question" && object(call.output)?["cancelled"] as? Bool == true
    }

    private static func published(_ call: NativeActivityCall) -> Bool? {
        guard call.name == "project_publish", let status = object(call.output)?["status"] as? String else { return nil }
        return status == "published"
    }

    static func running(_ name: String, subject: String) -> String {
        let words: String
        switch name {
        case "project_read": words = "Reading the project"
        case "project_list_spaces": words = "Listing spaces"
        case "project_inspect": words = "Inspecting a thread"
        case "project_publish": words = "Publishing"
        case "project_question": words = "Asking"
        case "project_assign": words = "Starting thread"
        case "project_follow_up": words = "Sending a follow-up to"
        case "project_resolve": words = "Resolving a thread"
        case "project_propose_space": words = "Adding a space"
        case "project_remember": words = "Saving a memory"
        default: words = "Relaying an answer"
        }
        if name == "project_question" { return subject.isEmpty ? "Waiting for your answer" : "Waiting for your answer · " + subject }
        return subject.isEmpty || name == "project_read" ? words : words + " " + subject
    }

    static func failed(_ name: String) -> String {
        switch name {
        case "project_read": "Couldn’t read the project"
        case "project_list_spaces": "Couldn’t list spaces"
        case "project_inspect": "Couldn’t inspect the thread"
        case "project_publish": "Couldn’t publish"
        case "project_question": "Couldn’t ask the question"
        case "project_assign": "Couldn’t assign the thread"
        case "project_follow_up": "Couldn’t send the follow-up"
        case "project_resolve": "Couldn’t resolve the thread"
        case "project_propose_space": "Couldn’t add the space"
        case "project_remember": "Couldn’t save the memory"
        default: "Couldn’t relay the answer"
        }
    }

    static func stopped(_ name: String) -> String { failed(name).replacingOccurrences(of: "Couldn’t", with: "Stopped:") }

    /// The finished line of consecutive calls of one tool, and its meta; nil for a call that is not a Project tool.
    static func done(_ calls: [NativeActivityCall], duration: String?) -> (String, [String])? {
        let first = calls[0]
        guard isTool(first.name) else { return nil }
        let time = [duration].compactMap { $0 }
        func one(_ words: String) -> (String, [String]) {
            (words, ([first.detail].filter { !$0.isEmpty }) + time)
        }
        func many(_ words: String) -> (String, [String]) { ("\(words) \(calls.count) times", time) }
        switch first.name {
        case "project_read": return calls.count == 1 ? one("Read the project") : many("Read the project")
        case "project_list_spaces": return calls.count == 1 ? one("Listed spaces") : many("Listed spaces")
        case "project_inspect": return calls.count == 1 ? one("Inspected a thread") : many("Inspected threads")
        case "project_publish":
            if calls.count == 1 {
                let name = first.detail
                switch published(first) {
                case true?: return ("Published" + (name.isEmpty ? "" : " " + name), time)
                case false?: return ("Staged" + (name.isEmpty ? "" : " " + name), ["waiting for the owner"] + time)
                case nil: return ("Publish" + (name.isEmpty ? "" : " " + name), time)
                }
            }
            return many("Published files")
        case "project_assign", "project_follow_up":
            let words = first.name == "project_assign" ? "Started thread" : "Sent a follow-up to"
            if calls.count == 1 { return (first.detail.isEmpty ? words : words + " " + first.detail, choice(first) + time) }
            return many(first.name == "project_assign" ? "Started threads" : "Sent follow-ups")
        case "project_resolve": return calls.count == 1 ? one("Resolved a thread") : many("Resolved threads")
        case "project_propose_space":
            let linked = calls.allSatisfy { call in
                let proposals = object(call.output)?["spaceProposals"] as? [[String: Any]] ?? []
                return !proposals.isEmpty && proposals.allSatisfy { $0["phase"] as? String == "accepted" }
            }
            return calls.count == 1 ? one(linked ? "Added a space" : "Asked to add a space") : many(linked ? "Added spaces" : "Asked to add spaces")
        case "project_question":
            if calls.count == 1 {
                if cancelled(first) { return ("Question cancelled", [first.detail].filter { !$0.isEmpty } + time) }
                return ("Asked a question", [first.detail].filter { !$0.isEmpty } + time)
            }
            return many("Asked a question")
        case "project_remember": return calls.count == 1 ? one("Saved a memory") : many("Saved memories")
        default: return calls.count == 1 ? one("Relayed an answer") : many("Relayed answers")
        }
    }
}
