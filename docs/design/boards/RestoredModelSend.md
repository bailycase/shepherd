# Restored model send failure

The user's requested behavior is the reference for this change: recover the exact saved provider
and model once; otherwise retain the message and show an inline error with a model-picker action.
The earlier screenshot demonstrates the bug, not a new layout to copy.

## Checklist

- Above the composer, reuse `NWBanner(.failed)` with its existing failed-state glyph, color,
  caption fonts, padding, radius and layout. No new dimensions or colors.
- Title: "Message wasn't sent."
- Message comes from the host's validated blocked-input event: "Couldn't restore this
  conversation's model: CLIProxyAPI / <model ID>. Your message wasn't sent. Try again or choose
  a model."
- "Choose model" uses the existing small secondary button and opens the composer's existing
  model picker. The already-selected model can be explicitly selected again after this error.
- Send remains the retry action. Draft text, images, files, references and page elements stay
  until the host actually accepts them. A queued send that fails returns to the paused queue.
- No automatic prompt replay or provider/model substitution. A successful model selection or
  another action clears the notice using the existing notice lifecycle.
- Verify the error with empty and long drafts, long model IDs, both appearances and text scale
  1.3. Verify the normal composer still has no banner. Press Send and Choose model through the
  native control path; verify a rejected send keeps its attachments.
- Departures: none planned. Report any unverified platform or state in the PR.
