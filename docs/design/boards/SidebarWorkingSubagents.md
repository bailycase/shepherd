# Sidebar working subagents

## User requirement

A thread with working subagents stays in Working instead of appearing Done, even after its parent's turn ends.

## Checklist before implementation

- Reuse the existing sidebar order and controls: Done, Pinned, Needs you, Working, Recents, Designs. No new strings, icons, sizes, spacing or color tokens.
- Derive the parent's sidebar presentation from its real published `ChildRun` rows, locally and on connected hosts. Nonterminal, unpaused children keep an idle or done parent working. Terminal and paused children do not. Unknown nonterminal states follow `ChildRun.isTerminal`.
- Use `AgentState.working` and the existing `NWSidebarRow` tokens for the blue working dot. Automation runs retain their existing `bolt` glyph. Accessibility uses the existing "running" status word. Never change the actual stored `Agent.status`.
- Keep a parent's own question in Needs you, pinned threads in Pinned, unavailable local threads in their existing state, and offline hosts in Recents. A child's question never puts its parent in Needs you.
- Project-tree rows and their running rollups use the same presentation. Remote rows retain their host tags.
- Do not record a completion while children work. Finishing the last child produces a new completion generation, so an earlier seen parent turn does not hide it in Recents.
- Retain remote child snapshots only in memory across disconnect/reconnect, with offline rows in Recents, never Working or Done. Reconnect refreshes completed/empty rows and prunes deleted agents; only real settlement produces a completion. Host removal cancels refresh and reconnect work.
- Render real view-model output with working children, finished children, empty and long names, light and dark, and text scale 1.3. Preserve existing density and Reduce Motion behavior.
- Press the running parent's row through accessibility to open its thread. Existing disclosure and Mark all seen controls retain their actions and hit areas.

## Validation

See the [render matrix and validation record](../evidence/sidebar-working-subagents/README.md). The parent stays `.done` in the real data source while its derived sidebar row says running. Both local extension publication and connected-host child refresh drive Working and completion transitions.

## Departures

None.
