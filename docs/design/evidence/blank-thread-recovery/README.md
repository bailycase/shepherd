# Blank-thread recovery

The completed-worker thread still draws its messages above the tray and composer. The fix changes
scroll recovery, not the layout, controls, or styling. Design departures: none.

`AgentsPreviewTests.threadSubagentsDone` renders these images through `NativeThreadStore` and
`ThreadView`, in light and dark at text scales 1 and 1.3:

```sh
SHEPHERD_PREVIEW_DIR=/tmp/shepherd-blank-previews swift test \
  --filter 'AgentsPreviewTests/threadSubagentsDone'
```

- [Light](thread-subagents-done-light.png)
- [Dark](thread-subagents-done-dark.png)
- [Light, text scale 1.3](thread-subagents-done-x1.3-light.png)
- [Dark, text scale 1.3](thread-subagents-done-x1.3-dark.png)

These are normal-state previews, not a capture of the reported intermittent failure. The
marker-only regression in `ThreadTailGuardTests` fails before the fix and passes afterward.
`ThreadTailFlowTests` checks the rendered transcript after a long live turn becomes a paged
history with completed workers, and after the tray disappears. The guard-disabled OS reproducer
is intermittent; guard-enabled recovery assertions remain required.
