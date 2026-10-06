# Sidebar parents with working subagents

User requirement and element checklist: [SidebarWorkingSubagents.md](../../boards/SidebarWorkingSubagents.md).

The [render matrix](matrix.png) contains working-child, finished-child, empty and long-title states. Each has light, dark and text scale 1.3 variants. `PreviewTests.sidebarWorkingSubagents` (in `NavigationPreviewTests.swift`) renders from a scratch workspace and real `ChildRun` updates. The parent remains `.done` in the workspace; the sidebar alone derives its running presentation.

Validation:

- 1,045 app unit tests passed, including live, terminal and paused child states, raw-state preservation, pinned and blocked precedence, automation presentation, local and remote completion generations.
- 1,032 remote unit tests passed alongside the app tests.
- 32 integration tests passed across `SidebarActivityFlowTests`, `RemoteHostTests`, `RemoteWorktreeTests`, `RemotePaneTests`, `SidebarListTests` and `SidebarProjectsFlowTests`. These include native Working and Done row presses, local child publication over the extension socket, remote child refresh, disconnect and reconnect. The 300-agent sidebar mounting budget passed separately.
- The existing sidebar starting-row 24pt hit-area test still reports its recorded known issue. No assertions were weakened.
- The preview test rerendered all 16 appearances after the disconnect/reconnect fix. The matrix shows a blue running row under Working while the child lives, and the same thread under Done after it settles. Long names truncate without overlapping the activity accessory.
- Seven design-rule tests and 14 documentation checks passed. The Dev scheme built with locked package versions and signing disabled for local validation.

Regression: the new remote-child disconnect/reconnect test failed against the earlier fix. Moving the phase change before teardown prevented completion on disconnect, but reconnect still fabricated a completion before its first child query. Retaining the ephemeral child snapshot across teardown fixes both edges. Five regression cases now cover live child work across disconnect and manual reconnect, children completed or removed while offline, and an agent deleted while offline. Offline rows remain in Recents, never Working or Done. Fresh settled/empty rows create exactly one real completion, repeated reconnect does not duplicate it, deleted-agent child keys are pruned, and host removal drops its records and transport.

Commands rerun after the fix:

```sh
swift test --filter 'ShepherdAppUnitTests|ShepherdRemoteUnitTests|SidebarActivityFlowTests|RemoteHostTests|RemoteWorktreeTests|RemotePaneTests|SidebarListTests|SidebarProjectsFlowTests'
SHEPHERD_PREVIEW_DIR=/tmp/shepherd-sidebar-children-previews swift test --filter 'PreviewTests/sidebarWorkingSubagents|ListPerformanceTests/openingTheSidebarOverThreeHundredAgentsBuildsOnlyTheRowsOnScreen'
swift test --filter DesignRulesTests
python3 -m unittest discover -s Tests/Release -p test_agent_docs.py
xcodebuild -project Shepherd.xcodeproj -scheme 'Shepherd (Dev)' -destination 'platform=macOS' \
  -onlyUsePackageVersionsFromResolvedFile -derivedDataPath /tmp/shepherd-sidebar-children-dev CODE_SIGNING_ALLOWED=NO build
```

Review: the implementation reuses the existing sidebar derivation and completion tracking. It adds no child polling, persisted status, protocol field or UI control. Pinned rows, the parent's own question, failure markers and offline hosts retain their existing precedence. Row geometry and components are unchanged. Every `stopChildRefresh` caller was checked: start/restart retains the snapshot until fresh queries replace it (unsupported inspection clears it), disconnect/reconnect changes phase before cancellation, and removal cancels child/reconnect tasks after removing the host from the projection. Cached rows never persist across app launches. No new background work or provider calls are introduced.

Not verified: the built Dev app was not launched or exercised interactively, to avoid touching a running app or the user's support data. Off-screen accessibility presses and scratch remote servers cover the changed behavior.

Departures: none.
