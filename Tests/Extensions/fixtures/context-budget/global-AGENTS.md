# Global instructions

A stand-in for Settings ▸ Instructions' AGENTS.md: about what a user writes once and wants in every
thread (roughly 1,500 tokens). The context budget measures its size; its words mean nothing.

## Environment
- macOS with nix-darwin for package management; prefer pnpm over npm; Node comes from nix.
- Use the repository's own task runner (a Taskfile or package scripts) rather than inventing commands.

## Code style
- Go: standard gofmt, short variable names in small scopes, explicit error handling, no `ioutil`.
- TypeScript: strict mode, avoid `any`, prefer `unknown` with type guards.
- Keep functions small and name things for what they do; avoid abbreviations outside small scopes.
- Prefer the standard library where reasonable. Be conservative with dependencies: vet maintenance
  status and security before adding one, and never add a dependency for trivial functionality.
- Don't create interfaces before you need them: concrete types first.
- Don't wrap errors without adding context.

## Testing
- Follow the testing conventions already established in the codebase: match what neighbouring code
  does rather than applying a default.
- A project's own documented standard (AGENTS.md, CLAUDE.md, contributing docs) wins over anything here.
- For greenfield code with no precedent, ask what level of coverage is wanted.

## Debugging
- When something fails, check the logs first, then reproduce minimally.
- For network issues, check with curl before blaming the code.
- Use the debugger for the language at hand rather than print statements.

## Comments
- Use comments sparingly, only for complex logic or non-obvious decisions.
- Keep them concise and clear, without redundancy or verbosity.

## Git
- Conventional commits (feat:, fix:, chore:, docs:, test:), one logical change each.
- Don't amend commits or force push unless asked. Don't stage unrelated files.
- Branch off the integration branch for features (`feat/...`) and fixes (`fix/...`) and open PRs back to it.
- Never add attribution lines to commits or pull request bodies.

## Response style
- Plan ahead and outline the approach before starting, and say the plan plainly.
- Use clear, concise language. Avoid repetition and verbosity.
- Explain the choices made. Ask for feedback or clarification when it is needed.

## Scope discipline
- Do exactly what is asked, no more and no less. Don't anticipate next steps and build them unprompted.
- If something else seems needed, ask first rather than building it.
- One task at a time: finish what was requested before suggesting additions.
- When the obvious next steps are clear, complete the task first, then list them briefly, one line each,
  and wait for the user to pick.

## Planning
- For a feature or a larger problem, break it into smaller tasks and order them by importance and
  feasibility. Write the plan to the notes folder, in a file of its own with a title and a date.

## What to avoid
- Don't suggest systemd commands on macOS.
- Don't create virtual environments for Python unless asked: prefer nix.
- Don't commit .env files.
- Don't suggest `go get` to add dependencies: run `go mod tidy` after adding imports.
