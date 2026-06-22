# 0005: Workspace Color Scope And Reader Chrome

Status: Accepted

Date: 2026-06-22

## Context

Android exposes workspace color through the color settings UI, but the setting
is not a normal text-display color. The durable value is
`WorkspaceSettings.workspaceColor`, with `#ff444444` as the fallback. Android's
`Colors.workspaceColor` field is marked `@Ignore` and exists only to carry the
workspace metadata value through the color settings screen.

The Android routing and commit paths are easy to misread:

- Application Settings opens global text-display settings with
  `SettingsLevel.GLOBAL` and no workspace identity:
  `and-bible/app/src/main/java/net/bible/android/view/activity/settings/SettingsActivity.kt`.
- Reader All Text Options opens workspace-scoped settings with
  `SettingsLevel.WORKSPACE` and injects the active workspace color:
  `and-bible/app/src/main/java/net/bible/android/view/activity/page/MainBibleActivity.kt`.
- Per-window options open `SettingsLevel.WINDOW`:
  `and-bible/app/src/main/java/net/bible/android/view/activity/page/screen/SplitBibleArea.kt`.
- `ColorSettingsFragment` hides `workspace_color` only when `windowId != null`,
  so a true global color route can still inflate the row.
- The durable write path in `TextDisplaySettingsActivity.commitDirtyToInMemoryState`
  writes `WorkspaceSettings.workspaceColor` only for `SettingsLevel.WORKSPACE`.
  The `SettingsLevel.GLOBAL` branch updates global text-display settings and
  does not own workspace metadata.

Android applies workspace color to reader chrome, not reader document content:

- day mode uses workspace color for the main reader toolbar/action bar surfaces
- night mode keeps toolbar chrome black and tints the home/drawer affordance
  with workspace color
- monochrome mode uses black-on-white toolbar chrome
- workspace selector rows use the workspace color as the row affordance
- Bible text, Bible page background, background noise, navigation bar, and
  speak transport remain text-display settings, not workspace color

This creates a parity trap for iOS. Copying Android's global-row visibility
literally would let true global settings mutate whichever workspace iOS treats
as active. That would turn workspace metadata into an accidental global side
effect. Hiding workspace color everywhere would also be wrong, because Android's
reader All Text Options route is workspace-scoped and does edit this color.

## Decision

iOS treats workspace color as workspace-owned reader chrome metadata.

The `workspace_color` row may be exposed only from workspace-owned text options,
including Android's main reader All Text Options route and workspace settings
routes. True global settings and window-scoped settings must not mutate
workspace color.

iOS must apply workspace color to the same behavioral surfaces Android applies
it to:

- reader toolbar/action-bar chrome in day mode
- drawer/menu affordance tint in night mode, while preserving black night toolbar
  chrome
- workspace selector row affordance

iOS must not apply workspace color to reader document text, reader document
background, background noise, or window-specific text-display colors.

When Android's global color route exposes `workspace_color`, iOS treats that as
a loose Android UI artifact rather than a durable parity contract. The durable
contract is the persistence and application model: only workspace scope owns
`WorkspaceSettings.workspaceColor`.

## Consequences

- Global Color Settings on iOS must not show an active workspace-color picker or
  reset workspace metadata.
- Workspace Text Options must continue to expose the workspace color row.
- Window Text Options must continue to hide the workspace color row.
- Reader toolbar repaint logic must observe workspace color separately from
  `TextDisplaySettings`, because workspace color is not part of the text-display
  inheritance model.
- Future refactors must not move workspace color into global settings or page
  content colors for convenience.
- If Android later formalizes a global workspace-color default, this ADR should
  be revisited with the new Android source contract.

## Related

- [Reader All Text Options Contract](../parity/reader/text-display-options-contract.md)
- [Android Settings Contract](../parity/settings/contract.md)
- [Android parity contract](../parity/android-parity-contract.md)
- AndBible iOS PR #227
- #226
