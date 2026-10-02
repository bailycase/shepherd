# Navigation sidebar checklist

Reference: [NWNavigation.png](NWNavigation.png), revision 420, with its [HTML](NWNavigation.html).
User clarification: Pinned is first and keeps every pinned thread, regardless of status.

- Keep the 44pt top bar, Search and Hide sidebar, fixed destinations, and user footer.
- Draw nonempty groups in order: Pinned, Needs you, Working, Done, Recents, Designs.
- Each group has a 9pt outline chevron, down when open and right when closed, with a 6pt gap.
- Header titles use Geist 11.5 medium; counts immediately follow in Geist Mono 10.5.
- Needs you uses attention text; the other headers use secondary text and tertiary counts.
- Header rows follow sidebar density, with a 6pt gap above. Fold state persists per Mac.
- Collapsed Working retains a blue pulsing dot while work runs, static under Reduce Motion.
- Done has a separate "Mark all seen" button, available while open or folded.
- List rows retain the real title, state dot or outline automation bolt, host tag, question reason, and context menu.
- Working has blue dots and an activity sparkline; Done has green dots and completion age.
- Recents has idle or seen threads. Designs have the outline nib and real board count, never a Recents row.
- Pinned rows never move on a status change. Their status and attention reason remain visible.
- A finished thread stays in Done while read, including after a page opens; opening another thread marks that completion seen.
- A new completion returns an unpinned thread to Done; repeated reports and unrelated snapshots do not.
- Keyboard selection reveals a folded group and scrolls to the selected row; arrow navigation follows visible rows.
- Preserve offline hosts as dimmed, tagged rows outside actionable groups.
- Cover all open, independently folded, no Done, selected Done, empty, long titles, all densities, light and dark, and text scale 1.3.
- Press each disclosure and Mark all seen through accessibility; verify row selection, read lifecycle, persistence, hit areas, and collapsed controls.

Unavailable destinations remain hidden: Missions and Archive have no implementation in Nightly.

## Verification

- 219 focused app unit tests, 128 integration tests and 7 design-rule tests pass.
- 17 sidebar and full-window preview tests pass, producing 84 PNGs in
  `/tmp/shepherd-sidebar-pr-previews`. The PR links the immutable screenshot gallery separately
  from the implementation branch, so generated renders do not enter Nightly.
- Inspected full, independently folded, all folded, folded Done, no Done, selected Done,
  after reading Done, empty and long-title renders in light and dark, including text scale 1.3
  and Compact, Standard and Comfortable densities. Pinned is rendered in every thread status.
- Pressed every disclosure, Mark all seen with Done open and folded, and thread rows through
  the real accessibility tree at all three densities. Verified minimum hit areas, selected state,
  no disclosure change from Mark all seen, and return to Done on a new completion.
- The Shepherd (Dev) Xcode build passes with pinned package resolution. The built app was not
  launched against production state; full-window previews use the scratch harness and stub pi.
- Completion tests cover repeated reports, refused sends, a completion covered by a page,
  local/remote switching, relaunch disclosure state and deletion fallback without leaving a page.
- Validation uses scratch state and preferences, in-process hosts and stub pi. No real model
  turns or production Shepherd state. The existing CI Sparkle framework link was needed for the
  test bundles in this fresh worktree.
- Project-tree accessories remain unchanged. Departures and the remote catch-up limitation are
  recorded in [sidebar.md](../sidebar.md).
