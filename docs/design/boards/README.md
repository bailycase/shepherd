# Saved designs

> Read when you build from a design the user gave you, or review a change against one.

The design the user gives in a thread (an image, a screenshot of a board, an export) is the spec,
and the repo keeps a copy of it, so a reviewer, a later agent and the user can lay the build beside
what was asked for. Without it the only record is a chat that is gone.

- **Save it first**, as `docs/design/boards/<Name>.png`, before you write any code. `<Name>` is the
  board's name on the canvas (`ComposerSpeed`), or the component's (`GoalCard`), in the same
  PascalCase as the board index in [docs/design/README.md](../README.md). Several boards of one
  feature are `<Name>-<state>.png` or one file per board.
- **Keep it as given.** Never crop, annotate or redraw it, and never replace it with a render of
  your build. Renders go in the PR.
- **Name it** in your PR body's Design line and in the spec heading you write or update, so the spec
  and the image find each other.
- **A newer design replaces the file** in the change that builds it. Git has the old one.
- If the design only exists in words, write the words into the spec instead and say so in the PR.
- Something the image cannot settle (a glyph's fill, a size, a color) is a question, never a quiet
  choice: pick one, say which in your final message, and list it under Departures if it differs
  from what the user meant.

The PR body says what you kept that the design does not draw: every difference, each with a
reason, under **Departures** ("none" counts). The user decides whether each stays; an agent never
does ([docs/design-workflow.md](../../design-workflow.md)).
