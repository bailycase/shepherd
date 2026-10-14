# Sidebar order correction

The user requested that the Automations section move above Designs. Their
screenshot showed the current section below Pinned. The attached screenshot has
no readable file path in this thread, so this note records its relevant content.

## Checklist

- Keep New thread, Designs and Automations destination buttons in their existing order.
- Move the Automations group and its run rows above the Designs group.
- Keep Projects directly below Designs and preserve every other section's order.
- Preserve labels, glyphs, spacing, colors, collapse controls and row actions.
- Empty Automations remains hidden through the existing derivation.

## Verified

The ui-ux helper changed the existing section array and its order expectation.
SidebarActivityTests and LogicalProjectSidebarTests pass, 15 tests. ControlPress
and SidebarAutomationsControlTests pass, five tests. The full App unit suite also
passes, 1161 tests. Release checks pass, 382 tests with one skip. The existing sidebar preview
matrix passed, including populated, collapsed, empty and long-content variants
in light and dark and at text scale 1.3.

Inspected the populated light and large-text dark renders. Also built and ran
Shepherd Dev from this checkout with scratch support, home, defaults and a stub
engine. Its real server supplied a design and a running automation. Accessibility
confirmed Automations precedes Designs. Pressed the Automations group to collapse
and expand it, then pressed the Automations destination and checked its page.
No posted mouse or keyboard events or provider requests.

- [Real Dev sidebar, cropped to the changed section](dev-sidebar-light.png)
- [Populated sidebar at text scale 1.3, dark](sidebar-large-text-dark.png)

Departures: none from the user's updated sidebar requirement.
