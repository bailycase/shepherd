import Foundation

/// The words of Shepherd's own tools that have no line of their own kind (terminals, helpers, threads, Fleet, automations, apps,
/// designs, the web, questions): "Rendered A · phone", "Opened a terminal", "Searched the web for “x”". Every tool Shepherd gives an
/// agent reads as what it did, never "Used <tool>". Shared with the iOS client, which draws the same lines.
public enum NativeToolWords {
    struct Words {
        /// While it runs, once it ran, and when it failed; `subject` is the call's detail, nil when it has none.
        var running: (String?) -> String
        var done: (String?) -> String
        var failed: (String?) -> String
        /// More than one finished call of the tool: "Rendered 3 boards".
        var merged: (Int) -> String
    }

    static func words(_ name: String) -> Words? {
        table[name]
    }

    private static func q(_ subject: String?) -> String { subject.map { " “\($0)”" } ?? "" }
    private static func s(_ subject: String?) -> String { subject.map { " \($0)" } ?? "" }
    private static func board(_ subject: String?) -> String { subject.map { " " + nativeBoardName($0) } ?? " a board" }
    private static func times(_ verb: String) -> (Int) -> String { { "\(verb) \($0) times" } }

    private static func w(_ running: @escaping (String?) -> String, _ done: @escaping (String?) -> String,
                          _ failed: @escaping (String?) -> String, _ merged: @escaping (Int) -> String) -> Words {
        Words(running: running, done: done, failed: failed, merged: merged)
    }

    private static let table: [String: Words] = [
        // Designs
        "board_render": w({ "Rendering" + board($0) }, { "Rendered" + board($0) }, { "Couldn’t render" + board($0) }, { "Rendered \($0) boards" }),
        "board_interact": w({ "Trying" + board($0) }, { "Tried" + board($0) }, { "Couldn’t try" + board($0) }, { "Tried \($0) boards" }),
        "design_export": w({ _ in "Exporting boards" }, { "Exported boards" + ($0.map { " as \($0)" } ?? "") }, { _ in "Export failed" }, times("Exported boards")),
        "design_list": w({ _ in "Listing designs" }, { _ in "Listed designs" }, { _ in "Couldn’t list designs" }, times("Listed designs")),
        "checkpoint_create": w({ "Saving checkpoint" + q($0) }, { "Saved checkpoint" + q($0) }, { "Couldn’t save checkpoint" + q($0) }, { "Saved \($0) checkpoints" }),
        "checkpoint_list": w({ _ in "Listing checkpoints" }, { _ in "Listed checkpoints" }, { _ in "Couldn’t list checkpoints" }, times("Listed checkpoints")),
        "checkpoint_restore": w({ "Restoring" + q($0) }, { "Restored checkpoint" + q($0) }, { "Couldn’t restore" + q($0) }, times("Restored checkpoints")),
        "comment_list": w({ _ in "Reading comments" }, { _ in "Read the comments" }, { _ in "Couldn’t read the comments" }, times("Read the comments")),
        "comment_reply": w({ _ in "Replying to a comment" }, { _ in "Replied to a comment" }, { _ in "Couldn’t reply" }, { "Replied to \($0) comments" }),
        "system_write": w({ "Writing the system" + s($0) }, { "Wrote the system" + s($0) }, { "Couldn’t write the system" + s($0) }, times("Wrote the system")),
        "design_show": w({ _ in "Showing a board" }, { _ in "Showed a board" }, { _ in "Couldn’t show the board" }, { "Showed \($0) boards" }),
        "design_note": w({ _ in "Leaving a note" }, { _ in "Left a note" }, { _ in "Couldn’t leave the note" }, { "Left \($0) notes" }),
        "markup_propose": w({ _ in "Proposing comments" }, { s in "Proposed" + (s.map { " \($0)" } ?? " comments") }, { _ in "Couldn’t propose comments" }, times("Proposed comments")),
        "boards_edit": w({ _ in "Editing boards" }, { _ in "Tried a batch edit" }, { _ in "Batch edit failed" }, times("Tried batch edits")),
        // Spaces
        "project_register": w({ "Adding the space" + s($0) }, { "Added the space" + s($0) }, { _ in "Couldn’t add the space" }, { "Added \($0) spaces" }),
        "project_add_child": w({ "Adding a child space" + s($0) }, { "Added a child space" + s($0) }, { _ in "Couldn’t add the child space" }, { "Added \($0) child spaces" }),
        "project_edit": w({ _ in "Editing a space" }, { _ in "Edited a space" }, { _ in "Couldn’t edit the space" }, { "Edited \($0) spaces" }),
        "project_delete": w({ _ in "Asking to remove a space" }, { _ in "Asked to remove a space" }, { _ in "Couldn’t ask to remove the space" }, { "Asked to remove \($0) spaces" }),
        "project_refresh": w({ _ in "Refreshing spaces" }, { _ in "Refreshed spaces" }, { _ in "Couldn’t refresh spaces" }, times("Refreshed spaces")),
        "project_plan": w({ _ in "Updating the plan" }, { _ in "Updated the plan" }, { _ in "Couldn’t update the plan" }, times("Updated the plan")),
        // Terminals and apps
        "terminal_open": w({ "Opening a terminal" + ($0.map { " for \($0)" } ?? "") }, { "Opened a terminal" + ($0.map { " for \($0)" } ?? "") },
                           { _ in "Couldn’t open a terminal" }, { "Opened \($0) terminals" }),
        "terminal_run": w({ "Running" + s($0) + " in a terminal" }, { "Ran" + s($0) + " in a terminal" }, { _ in "Couldn’t run in the terminal" },
                          { "Ran \($0) commands in terminals" }),
        "terminal_read": w({ _ in "Reading a terminal" }, { _ in "Read a terminal" }, { _ in "Couldn’t read the terminal" }, times("Read terminals")),
        "terminal_list": w({ _ in "Listing terminals" }, { _ in "Listed terminals" }, { _ in "Couldn’t list terminals" }, times("Listed terminals")),
        "terminal_focus": w({ _ in "Showing a terminal" }, { _ in "Showed you a terminal" }, { _ in "Couldn’t show the terminal" }, times("Showed you terminals")),
        "terminal_close": w({ _ in "Closing a terminal" }, { _ in "Closed a terminal" }, { _ in "Couldn’t close the terminal" }, { "Closed \($0) terminals" }),
        "app_list": w({ _ in "Listing apps" }, { _ in "Listed the space’s apps" }, { _ in "Couldn’t list apps" }, times("Listed apps")),
        "app_run": w({ "Starting" + ($0.map { " \($0)" } ?? " an app") }, { "Started" + ($0.map { " \($0)" } ?? " an app") },
                     { "Couldn’t start" + ($0.map { " \($0)" } ?? " the app") }, { "Started \($0) apps" }),
        "app_stop": w({ "Stopping" + ($0.map { " \($0)" } ?? " an app") }, { "Stopped" + ($0.map { " \($0)" } ?? " an app") },
                      { _ in "Couldn’t stop the app" }, { "Stopped \($0) apps" }),
        "app_logs": w({ _ in "Reading app logs" }, { s in "Read the logs" + (s.map { " of \($0)" } ?? "") }, { _ in "Couldn’t read the logs" }, times("Read app logs")),
        // Helpers and threads
        "shepherd_child_message": w({ "Messaging" + s($0) }, { "Messaged" + ($0.map { " \($0)" } ?? " a helper") }, { _ in "Couldn’t message the helper" }, { "Sent \($0) messages to helpers" }),
        "shepherd_child_result": w({ _ in "Reading a helper’s result" }, { s in "Read" + (s.map { " \($0)’s" } ?? " a helper’s") + " result" },
                                   { _ in "Couldn’t read the result" }, { "Read \($0) helper results" }),
        "shepherd_child_resume": w({ "Resuming" + s($0) }, { "Resumed" + ($0.map { " \($0)" } ?? " a helper") }, { _ in "Couldn’t resume the helper" }, { "Resumed \($0) helpers" }),
        "shepherd_child_cancel": w({ "Stopping" + s($0) }, { "Stopped" + ($0.map { " \($0)" } ?? " a helper") }, { _ in "Couldn’t stop the helper" }, { "Stopped \($0) helpers" }),
        "shepherd_child_wait": w({ _ in "Waiting for helpers" }, { _ in "Waited for helpers" }, { _ in "Waiting for helpers failed" }, times("Waited for helpers")),
        "shepherd_child_agents": w({ _ in "Listing helper profiles" }, { _ in "Listed helper profiles" }, { _ in "Couldn’t list profiles" }, times("Listed helper profiles")),
        "shepherd_workflow": w({ _ in "Running a workflow" }, { _ in "Ran a workflow" }, { _ in "Workflow failed" }, { "Ran \($0) workflows" }),
        "shepherd_parent_message": w({ _ in "Writing to the parent" }, { _ in "Wrote to the parent" }, { _ in "Couldn’t reach the parent" }, { "Wrote to the parent \($0) times" }),
        "agent_list": w({ _ in "Listing threads" }, { _ in "Listed threads" }, { _ in "Couldn’t list threads" }, times("Listed threads")),
        "agent_read": w({ _ in "Reading a thread" }, { _ in "Read a thread" }, { _ in "Couldn’t read the thread" }, { "Read \($0) threads" }),
        "agent_send": w({ _ in "Messaging a thread" }, { _ in "Messaged a thread" }, { _ in "Couldn’t message the thread" }, { "Messaged \($0) threads" }),
        "agent_steer": w({ _ in "Steering a thread" }, { _ in "Steered a thread" }, { _ in "Couldn’t steer the thread" }, { "Steered \($0) threads" }),
        "agent_spawn": w({ _ in "Starting a thread" }, { s in "Started a thread" + (s.map { " for “\($0)”" } ?? "") }, { _ in "Couldn’t start the thread" }, { "Started \($0) threads" }),
        "agent_wait": w({ _ in "Waiting for a thread" }, { _ in "Waited for a thread" }, { _ in "Waiting for the thread failed" }, times("Waited for threads")),
        "agent_interrupt": w({ _ in "Stopping a thread" }, { _ in "Stopped a thread" }, { _ in "Couldn’t stop the thread" }, { "Stopped \($0) threads" }),
        "agent_rename": w({ _ in "Renaming a thread" }, { s in "Renamed a thread" + (s.map { " to “\($0)”" } ?? "") }, { _ in "Couldn’t rename the thread" }, { "Renamed \($0) threads" }),
        "agent_move": w({ _ in "Moving a thread" }, { _ in "Moved a thread" }, { _ in "Couldn’t move the thread" }, { "Moved \($0) threads" }),
        "agent_delete": w({ _ in "Deleting a thread" }, { _ in "Deleted a thread" }, { _ in "Couldn’t delete the thread" }, { "Deleted \($0) threads" }),
        // Fleet
        "fleet_hosts": w({ _ in "Listing Macs" }, { _ in "Listed Fleet Macs" }, { _ in "Couldn’t list Macs" }, times("Listed Fleet Macs")),
        "fleet_dispatch": w({ _ in "Sending work to another Mac" }, { s in "Sent" + (s.map { " “\($0)”" } ?? " work") + " to another Mac" }, { _ in "Couldn’t send the work" },
                            { "Sent \($0) jobs to other Macs" }),
        "fleet_send": w({ _ in "Messaging another Mac" }, { _ in "Messaged another Mac" }, { _ in "Couldn’t reach the Mac" }, { "Sent \($0) messages to other Macs" }),
        "fleet_read": w({ _ in "Reading remote work" }, { _ in "Read remote work" }, { _ in "Couldn’t read the remote work" }, times("Read remote work")),
        "fleet_wait": w({ _ in "Waiting for another Mac" }, { _ in "Waited for another Mac" }, { _ in "Waiting for the Mac failed" }, times("Waited for other Macs")),
        "fleet_cancel": w({ _ in "Cancelling remote work" }, { _ in "Cancelled remote work" }, { _ in "Couldn’t cancel the remote work" }, { "Cancelled \($0) jobs" }),
        "fleet_close": w({ _ in "Closing remote work" }, { _ in "Closed remote work" }, { _ in "Couldn’t close the remote work" }, { "Closed \($0) jobs" }),
        // Automations, hooks, notices, questions
        "automation_list": w({ _ in "Listing automations" }, { _ in "Listed automations" }, { _ in "Couldn’t list automations" }, times("Listed automations")),
        "automation_create": w({ _ in "Creating an automation" }, { s in "Created" + (s.map { " “\($0)”" } ?? " an automation") }, { _ in "Couldn’t create the automation" }, { "Created \($0) automations" }),
        "automation_update": w({ _ in "Updating an automation" }, { _ in "Updated an automation" }, { _ in "Couldn’t update the automation" }, { "Updated \($0) automations" }),
        "automation_delete": w({ _ in "Deleting an automation" }, { _ in "Deleted an automation" }, { _ in "Couldn’t delete the automation" }, { "Deleted \($0) automations" }),
        "automation_start": w({ _ in "Starting an automation" }, { _ in "Started an automation" }, { _ in "Couldn’t start the automation" }, { "Started \($0) automations" }),
        "automation_stop": w({ _ in "Stopping an automation" }, { _ in "Stopped an automation" }, { _ in "Couldn’t stop the automation" }, { "Stopped \($0) automations" }),
        "hook_propose": w({ _ in "Proposing a hook" }, { _ in "Proposed a hook" }, { _ in "Couldn’t propose the hook" }, { "Proposed \($0) hooks" }),
        "notify": w({ _ in "Notifying you" }, { s in "Notified you" + (s.map { ": “\($0)”" } ?? "") }, { _ in "Couldn’t notify you" }, { "Notified you \($0) times" }),
        "ask_user": w({ _ in "Waiting for your answer" }, { _ in "Asked you" }, { _ in "Couldn’t ask you" }, { "Asked you \($0) questions" }),
        "suggest_instruction": w({ _ in "Suggesting an instruction" }, { _ in "Suggested an instruction" }, { _ in "Couldn’t suggest the instruction" }, { "Suggested \($0) instructions" }),
        "review_diff": w({ _ in "Readying a review" }, { _ in "Readied the review in Changes" }, { _ in "Couldn’t ready the review" }, times("Readied reviews")),
        "goal_finish": w({ _ in "Finishing the goal" }, { _ in "Finished the goal" }, { _ in "Couldn’t finish the goal" }, times("Finished goals")),
        "propose_title": w({ _ in "Naming the thread" }, { s in "Named the thread" + (s.map { " “\($0)”" } ?? "") }, { _ in "Couldn’t name the thread" }, times("Named the thread")),
        "compact": w({ _ in "Compacting context" }, { _ in "Compacted context" }, { _ in "Compaction failed" }, times("Compacted context")),
        "codemode": w({ _ in "Running a script" }, { _ in "Ran a script" }, { _ in "Script failed" }, { "Ran \($0) scripts" }),
        // The web
        "WebSearch": w({ "Searching the web" + ($0.map { " for “\($0)”" } ?? "") }, { "Searched the web" + ($0.map { " for “\($0)”" } ?? "") },
                       { _ in "Web search failed" }, { "Searched the web \($0) times" }),
        "web_search": w({ "Searching the web" + ($0.map { " for “\($0)”" } ?? "") }, { "Searched the web" + ($0.map { " for “\($0)”" } ?? "") },
                        { _ in "Web search failed" }, { "Searched the web \($0) times" }),
        "WebFetch": w({ "Reading" + ($0.map { " \($0)" } ?? " a page") }, { "Read" + ($0.map { " \($0)" } ?? " a page") },
                      { "Couldn’t read" + ($0.map { " \($0)" } ?? " the page") }, { "Read \($0) pages" }),
        "web_fetch": w({ "Reading" + ($0.map { " \($0)" } ?? " a page") }, { "Read" + ($0.map { " \($0)" } ?? " a page") },
                       { "Couldn’t read" + ($0.map { " \($0)" } ?? " the page") }, { "Read \($0) pages" }),
    ]

    /// The subject a tool's line names, from its arguments: a board, a terminal's command, a helper, a query, a page's host.
    static func subject(_ name: String, _ args: [String: Any]?) -> String? {
        func string(_ key: String) -> String? {
            (args?[key] as? String).flatMap { $0.split(whereSeparator: \.isNewline).first.map(String.init) }.flatMap { $0.isEmpty ? nil : String($0.prefix(80)) }
        }
        switch name {
        case "board_render", "board_interact": return string("path")
        case "design_export": return string("format")
        case "checkpoint_create", "checkpoint_restore": return string("name")
        case "system_write": return string("namespace")
        case "project_register", "project_add_child": return string("name")
        case "terminal_open": return string("command")
        case "terminal_run": return string("text")
        case "app_run", "app_stop", "app_logs": return string("name") ?? string("app") ?? string("id")
        case "shepherd_child_message", "shepherd_child_result", "shepherd_child_resume", "shepherd_child_cancel": return string("id")
        case "agent_spawn": return string("prompt").map { String($0.prefix(60)) }
        case "agent_rename": return string("title") ?? string("name")
        case "fleet_dispatch": return string("title")
        case "automation_create": return string("name") ?? string("title")
        case "notify": return string("title")
        case "propose_title": return string("title")
        case "markup_propose": return (args?["proposals"] as? [Any]).map { nativeCount($0.count, "comment") }
        case "WebSearch", "web_search": return string("query")
        case "WebFetch", "web_fetch": return string("url").flatMap { URL(string: $0)?.host }.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
        default: return nil
        }
    }

    /// A tool with no words of its own, as words: `fleet_status` reads "fleet status".
    static func spoken(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ")
    }
}
