# Remove agent approvals

User requirements in this conversation:

- "remove all the approval modals"
- "remove that section from the settings"

## Checklist

- Remove cross-thread approval sheets and agent-deletion confirmation sheets.
- Remove the Agent-to-agent messages row and its search entries. On current nightly, this row is in Settings > Extensions.
- Retain the existing Terminals and agent tools, Diff review tool, MCP servers, Browser tools and Design references switches, with their existing glyphs, spacing, sizes, radii, colors and behavior.
- No new glyph, size, color token, string or control is required.
- Ignore legacy permission preferences, including `never`. The removed setting must not leave an invisible restriction.
- Calls still validate process identity, sender and target, directory and request contents.
- Delete an agent through Delete Agent, preserving worktrees, branches and local files. Claim the live request before deleting; cancellation before claim prevents deletion.
- Leave tool questions in the question dock. Leave user-invoked destructive confirmations unchanged.

## States and validation

Render the real Extensions page with Design tool enabled, in light and dark appearances and at text scales 1.0 and 1.3. There is no permission control in any state. Test the accessibility tree for its absence and the neighboring switches' presence.

Test cross-thread delivery and deletion with a legacy `never` preference. Test cancellation before the deletion claim and identity validation. No approval buttons remain to press.

Departures: none.
