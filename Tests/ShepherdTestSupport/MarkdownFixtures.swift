import Foundation

/// Agent replies that exercise the thread's rich content (DESIGN.md › Thread › Rich content in
/// prose), shared by the preview renders and the performance budgets.
public enum MarkdownFixtures {
    /// The reply that showed its table as raw pipes (a user's report), verbatim.
    public static let toolsReply = """
    ## What Shepherd exposes

    The normal root-agent surface contains **31 model-callable tools**, depending on enabled settings.

    | Area | Tools |
    |---|---|
    | Terminal panes | `pane_list`, `pane_open`, `pane_run`, `pane_read`, `pane_focus`, `pane_close` |
    | Peer agents | `agent_list`, `agent_send`, `agent_read`, `agent_steer`, `agent_interrupt`, `agent_wait`, `agent_delete`, `agent_spawn` |
    | Automations | `automation_create`, `automation_list`, `automation_update`, `automation_delete`, `automation_start`, `automation_stop` |
    | Notifications and review | `notify`, `review_diff` |
    | Native children | `shepherd_child_agents`, `shepherd_child_start`, `shepherd_child_message`, `shepherd_child_result`, `shepherd_child_wait`, `shepherd_child_cancel`, `shepherd_child_resume` |
    | Orchestration and records | `shepherd_workflow`, `shepherd_mission` |

    Additional extension behavior includes:

    - Child-only `shepherd_parent_message` and an overridden child `bash` implementation.
    """

    /// Task list, nested lists, strikethrough, an autolink, footnotes, a local image
    /// (`image`, relative to the agent's folder) and a remote one, and a disclosure.
    public static func structureReply(image: String) -> String {
        """
        The parser now covers what agents write. ~~Raw pipes~~ are gone,[^pipes] and bare links like https://github.com/bailycase/shepherd stay tappable.

        - [x] Parse GFM tables with alignment
        - [x] Nest lists to any depth
        - [ ] Render mermaid diagrams

        1. Parser
           - Blocks
             - Tables, task lists and footnotes
             - `<details>` and images
           - Inline runs
        2. Renderers, shared by the Mac and iPhone[^shared]

        ![Thread with a table](\(image))

        ![Build status](https://ci.example.com/shepherd/badge.png)

        <details><summary>Full parser log</summary>

        - 41 tests passed, 0 failed
        - Longest parse: 0.2 ms for a 200-row table

        </details>

        [^pipes]: A header line waits for its delimiter row while it streams, so it never shows as a paragraph.
        [^shared]: One parser in ShepherdRemote, one set of views in ShepherdUI.
        """
    }

    /// A wide table (more columns than the thread holds), a keycap, and fences Shepherd shows as
    /// source: mermaid and math.
    public static let wideReply = """
    Benchmarks across the fixtures (press <kbd>⌘</kbd><kbd>C</kbd> on a table to copy it as Markdown):

    | Fixture | Rows | Columns | Parse | Layout | First frame | Scroll step | Memory | Result | Notes |
    |:--|--:|--:|--:|--:|--:|--:|--:|:-:|:--|
    | Tools reply | 6 | 2 | 0.04 ms | 0.3 ms | 4.1 ms | 0.2 ms | 1.1 MB | ✓ | The reported reply, verbatim |
    | Wide benchmark | 12 | 10 | 0.07 ms | 0.6 ms | 5.9 ms | 0.3 ms | 1.4 MB | ✓ | Scrolls inside its card |
    | Large table | 200 | 3 | 0.9 ms | 7.8 ms | 18.2 ms | 0.4 ms | 6.2 MB | ✓ | Streams a row at a time |

    ```mermaid
    graph TD
      Reply --> Parser
      Parser --> Blocks
      Blocks --> Mac & iPhone
    ```

    $$
    \\text{cost} = \\sum_{r=1}^{rows} \\max_{c}\\ h(r, c)
    $$
    """

    /// A reply ending in a table of `rows` rows, three columns each.
    public static func largeTable(rows: Int) -> String {
        var lines = ["Every call this session made:", "", "| # | Tool | Result |", "|--:|---|---|"]
        for index in 0..<rows {
            lines.append("| \(index + 1) | `tool_\(index % 17)` | Finished in \(index % 9 + 1).\(index % 10)s with **\(index % 5)** warnings |")
        }
        return lines.joined(separator: "\n")
    }
}
