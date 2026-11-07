import Foundation

/// Agent replies that exercise the thread's rich content, shared by the preview renders and the performance budgets.
public enum MarkdownFixtures {
    /// The reply that showed its table as raw pipes (a user's report), verbatim.
    public static let toolsReply = """
    ## What Shepherd exposes

    The normal root-agent surface contains **31 model-callable tools**, depending on enabled settings.

    | Area | Tools |
    |---|---|
    | Terminals | `terminal_list`, `terminal_open`, `terminal_run`, `terminal_read`, `terminal_focus`, `terminal_close` |
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

    /// A wide table (more columns than the thread holds), a keycap, a Mermaid chart and math source.
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

    /// A long reply of `cycles` cycles, each a paragraph, a Swift fence, a 3x3 table and a three-item list.
    /// The cycles are numbered from `first`, so a reply grown by appending more of them keeps its earlier text.
    /// With `markerEvery`, a `## Marker N` heading starts every that-many-th cycle, for a reader to find their place by.
    public static func longReply(cycles: Int, from first: Int = 0, markerEvery: Int? = nil) -> String {
        (first..<first + cycles).map { n in
            let marker = markerEvery.map { n.isMultiple(of: $0) } == true ? "## Marker \(n)\n\n" : ""
            return """
            \(marker)Paragraph \(n) of the reply, long enough to wrap onto a second line or two inside the column of the thread.

            ```swift
            func step\(n)(input: Int) -> Int {
                let doubled = input * 2 // step \(n)
                return doubled + \(n)
            }
            ```

            | Step | Calls | Result |
            |---|---|---|
            | a\(n) | \(n % 7) | ok |
            | b\(n) | \(n % 5) | ok |
            | c\(n) | \(n % 3) | failed |

            - First item of cycle \(n), with a few words to read.
            - Second item of cycle \(n).
            - Third item of cycle \(n).
            """
        }.joined(separator: "\n\n")
    }

    /// A reply ending in a table of `rows` rows, three columns each.
    public static func largeTable(rows: Int) -> String {
        var lines = ["Every call this session made:", "", "| # | Tool | Result |", "|--:|---|---|"]
        for index in 0..<rows {
            lines.append("| \(index + 1) | `tool_\(index % 17)` | Finished in \(index % 9 + 1).\(index % 10)s with **\(index % 5)** warnings |")
        }
        return lines.joined(separator: "\n")
    }
}
