# Subagents settings

> Read when: changing named subagent files, their Settings list, or discovery.

The user supplied `SubagentsSettings.dc.html@598`. Its unchanged 2x image is
[SubagentsSettings.png](boards/SubagentsSettings.png). The later full-width Settings requirement
still applies: 232pt navigation and 40pt side gutters, with no fixed 720pt page cap.

## Implementation checklist

- Settings navigation uses the existing supplied `NWGlyph.Settings.subagents` artwork, the outline `arrow.turn.down.right` equivalent. The existing Back, search, Pi subpages and footer remain.
- At 44pt from the top, show `Subagents`, Geist 22pt/600, then the board's explanation in Geist 13.5pt/400 with 1.5 line height: `A subagent is a Markdown file: a name, a description, and the instructions it runs with. An agent starts one by name and gets the result back. Shepherd ships a few to start with. Edit them, delete them, or add your own. They are read from one folder, and nowhere else.`
- Separate header, toolbar and list section by 22pt. Toolbar gap 10pt. Filter is 302pt including the board's 280pt content width, 20pt padding and 2pt border. Use the supplied 13pt search artwork, `Filter subagents`, 32pt height, raised fill, strong 1pt border, 8pt radius.
- Trailing `Restore defaults` is secondary, and `New subagent` is lantern primary, both 32pt high, 14pt horizontal padding, 8pt radius, 13pt type. New has the board's 12pt outline plus artwork, not a substitute SF Symbol.
- Section heading has 4pt horizontal inset: `SUBAGENTS`, 11pt/600, tracking 0.06em; actual file count in 11pt mono. Trailing folder label is `Shepherd/pi/agents`, the actual absolute path on hover, and `Show in Finder`, 11.5pt, strong border, 6pt radius. Its pointer target is at least 24pt even though the board draws 22pt.
- List has 1pt subtle border, 10pt radius, 4pt inset. Each file is one native Button with 60pt minimum slot, a 56pt minimum content area, 14pt horizontal padding, 12pt gaps and 8pt radius. Hover/focus uses bubble fill and strong border.
- File glyph is the supplied 14pt outline bent branch path in a 28pt bubble tile with 7pt radius. Chevron is the supplied 12pt outline right arrow. Both are static vector resources in `NWGlyph.Settings`.
- Name is actual parsed name, 13pt/500 mono. Filename identifies invalid or unreadable files. Description is actual runtime-parser output, 12.5pt and 1.4 line height, one line with full text on hover/accessibility. `default` is an outlined 10.5pt mono badge for shipped filenames. Capability text is derived from allowed tools: `read-only` or `can edit`, with ` · fork` for a fork profile.
- Invalid definitions remain openable, with `can’t load`, failed glyph/text and actual diagnostic. Unknown fields fail closed, such as `Unsupported agent fields: runner. The profile did not load.` Never substitute sample names, count or diagnostics from the board.
- Empty folder shows `No subagents` and offers the existing New and Restore controls. A filter with no match says `No matching subagents`. Initial read says `Loading subagents…`. Read/save/delete/restore failure keeps the draft and shows the actual bounded error.
- Row opens the file in the form below. New opens an unsaved starter draft in the same form, with the filename typed in the path chip. Save validates through the runtime parser, conflict-checks the original bytes and atomically writes only inside the owned directory. Open in editor uses the native editor; Back refuses dirty dismissal without explicit Discard.
- Delete requires confirmation and the file snapshot shown. Restore requires confirmation, restores only shipped definitions, preserves custom files and refuses stale snapshots. Cancel writes nothing. New Save refuses filename/path collisions.
- Under the list, the page carries the Native subagents and Native subagent defaults groups (`NativeSubagentSettings`, standard Settings groups 28pt below the list), moved from Pi on 2026-10-07 by the user's decision; no board draws them. There is no discovery selector that contradicts single-folder ownership. Existing runs retain their loaded configuration; future launches read the updated files. No model call, background watcher, remote synchronization or automatic restart is added.

## Edit form (SubagentEdit)

The user supplied `SubagentEdit.dc.html@1105`, saved unchanged as
[SubagentEdit.png](boards/SubagentEdit.png). A row opens it, and New opens it empty. The page is a
wide one: 40pt sides, 44pt top, no 720pt cap.

- Header: `Subagents` (Back, 13) `/` the name (15/600) and the `pi/agents/<file>.md` chip (mono 11, radius 5). Delete (failed), Revert and Save (lantern, 600) are 30pt high at radius 7. Delete shows only for a saved file. Revert and Save wait for an edit.
- Left column 400pt, 16pt apart: Name (mono), Description (58pt, wraps), Tools chips (read grep find ls bash edit write, 26pt, on = raised with a strong line), Model and Thinking popups side by side, Starts with, Instructions are, then three switches (AGENTS.md, skills, Disabled) each with its note.
- Right column: Instructions with `Markdown` and `used / 65,536`, a plain mono 12.5 editor at 1.65 lines with no line numbers, and the board's note.
- Every control reads and rewrites one frontmatter key of the draft (`SubagentProfileText`). Keys the form does not draw, comments and block lists stay as written. Clearing Name, Description, Model or Thinking removes the key. Save still validates through the runtime parser, so an unsupported field refuses the save and the form says which one, with Open in editor to repair it.
- Starts with is `defaultContext` (fresh, fork), and an older `context:` key is dropped when it changes. Instructions are is `systemPromptMode` (replace, append). The switches are `inheritProjectContext`, `inheritSkills`, `disabled`. Tools omitted from the file show pi's four defaults on.
- Below 700pt the columns stack and the instructions take 360pt.

## Ownership

Only `<Shepherd support>/pi/agents` supplies named definitions. Do not read user `.agents`, project
`.agents` or `.shepherd/agents`, package agent directories, extra-directory environment variables, or
third-party subagent settings overrides. Seed the existing scout, reviewer, planner and worker once without
overwriting existing files. Persist completion of seeding so deletes survive relaunch. Restoring
defaults is an explicit action. Existing custom files already in the owned folder stay in place.

## Validation

Pending implementation: shared parser/discovery regressions, safe file lifecycle/conflicts,
accessibility presses, lazy-list budget, light/dark and 1.3-scale preview matrix, bundled Dev
captures, shipping build, release guards and independent design/code review.

Discovery and validation have fixed limits of 512 files, 512 folders, 16 nesting levels and
128 KiB per file. The local parser process has a ten-second deadline. Metadata and file text
stay on this Mac; opening Settings never starts a model or a helper.
