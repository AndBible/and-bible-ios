# Reader All Text Options Contract

Last audited: 2026-06-03 for #170.

This document records the Android source inventory for the reader **All Text Options**
surface and the current iOS disposition for each row. The goal is to keep iOS aligned with Android
without exposing controls that do not yet have an iOS model, bridge payload, and renderer path.

## Android Sources

- `and-bible/app/src/main/res/xml/text_display_settings.xml`: authoritative row order and categories.
- `and-bible/app/src/main/java/net/bible/android/view/activity/page/OptionsMenuItems.kt`: dynamic row titles, icons, and enablement rules.
- `and-bible/app/src/main/java/net/bible/android/view/activity/settings/TextDisplaySettings.kt`: runtime visibility and dependency handling.
- `and-bible/app/src/main/java/net/bible/android/view/activity/page/MainBibleActivity.kt`: reader overflow opens `TextDisplaySettingsActivity` with `SettingsLevel.WORKSPACE`.
- `and-bible/app/src/main/java/net/bible/android/view/activity/page/screen/SplitBibleArea.kt`: per-window popup opens text settings with `SettingsLevel.WINDOW`.
- `and-bible/app/src/main/java/net/bible/android/database/WorkspaceEntities.kt`: workspace/window text-display persistence fields.

## iOS Sources

- `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderView.swift`: reader drawer, destination routing, and window-scoped text-display persistence.
- `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderOverflowMenu.swift`: Android-style overflow menu row identifiers.
- `Sources/BibleUI/Sources/BibleUI/Settings/TextDisplaySettingsView.swift`: native SwiftUI All Text Options editor.
- `Sources/BibleUI/Sources/BibleUI/Settings/TextDisplaySettingsPresentation.swift`: Android row inventory and iOS dispositions.
- `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderController.swift`: renderer config payload emitted to Vue.
- `Sources/BibleCore/Sources/BibleCore/Models/Workspace.swift`: `TextDisplaySettings` model and inheritance chain.
- `bibleview-js/src/composables/config.ts`: shared web-client config fields consumed by the reader.

## Routing Contract

Workspace color scope and application are governed by
[ADR 0005](../../adr/0005-workspace-color-scope-and-reader-chrome.md). In
short, `workspace_color` is workspace metadata used for reader chrome. It is not
a global text-display color and must not be applied to reader document content.

Android has two relevant text-display settings routes:

- Main reader overflow `allTextOptions` opens workspace-scoped text display settings.
- Per-window popup settings open window-scoped text display settings.

iOS maps `readerOpenTextOptionsAction` to `ReaderDestination.workspaceTextOptions`, backed by
workspace-scoped `TextDisplaySettingsView`, matching Android's main reader overflow route. The
per-pane hamburger menu exposes Android's window-scoped All Text Options route through
`ReaderDestination.windowTextOptions`. Application Preferences exposes Android's
`global_text_display_settings`, and the text-options screen parent links can jump from window to
workspace/global or from workspace to global.

## Row Inventory

| Android key | Android category | iOS disposition | Notes |
| --- | --- | --- | --- |
| `open_workspace_settings` | Parent links | Implemented | Visible from window scope; opens workspace-scoped text options. |
| `open_global_settings` | Parent links | Implemented | Visible from window and workspace scopes; opens global text options. |
| `COLORS` | Font and colors | Implemented | Native color editor backed by existing config color fields. |
| `FONTSIZE` | Font and colors | Implemented | Existing `fontSize` model and renderer field. |
| `FONTFAMILY` | Font and colors | Implemented | Existing `fontFamily` model and renderer field. |
| `LINE_SPACING` | Font and colors | Implemented | Existing `lineSpacing` model and renderer field. |
| `REDLETTERS` | Font and colors | Implemented | Existing `showRedLetters` model and renderer field. |
| `MARGINSIZE` | Text layout | Implemented | Existing `marginSize` payload covers left, right, and max width. |
| `TOPMARGIN` | Text layout | Implemented | Existing `topMargin` model and renderer field. |
| `JUSTIFY` | Text layout | Implemented | Existing `justifyText` model and renderer field. |
| `HYPHENATION` | Text layout | Implemented | Existing `hyphenation` model and renderer field. |
| `VERSEPERLINE` | Text layout | Implemented | Existing `showVersePerLine` model and renderer field. |
| `STRONGS` | Strong's and morphology | Implemented | Existing `strongsMode` model and renderer field. |
| `MORPH` | Strong's and morphology | Implemented | Existing `showMorphology` model and renderer field. |
| `NON_STRONGS_WORD_ITALIC` | Strong's and morphology | Deferred | Tracked in #174; no iOS shared-client config/rendering field yet. |
| `FOOTNOTES` | Footnotes and cross references | Implemented | Existing `showFootNotes` model and renderer field. |
| `FOOTNOTES_INLINE` | Footnotes and cross references | Implemented | Disabled unless `FOOTNOTES` is enabled, matching Android dependency behavior. |
| `XREFS` | Footnotes and cross references | Implemented | Existing `showXrefs` model and renderer field. |
| `EXPAND_XREFS` | Footnotes and cross references | Implemented | Disabled unless `XREFS` is enabled, matching Android dependency behavior. |
| `VERSENUMBERS` | Verses and headings | Implemented | Existing `showVerseNumbers` model and renderer field. |
| `SECTIONTITLES` | Verses and headings | Implemented | Existing `showSectionTitles` model and renderer field. |
| `TITLE_SCROLL_BUTTON` | Verses and headings | Deferred | Tracked in #174; no iOS shared-client config/rendering field yet. |
| `PAGENUMBER` | Verses and headings | Implemented | Existing `showPageNumber` model and renderer field. |
| `INFINITE_SCROLL` | Page scrolling | Deferred | Tracked in #174; iOS scroll mode is not wired to this Android field. |
| `PAGE_SCROLL_AMOUNT` | Page scrolling | Deferred | Tracked in #174; no iOS shared-client config/rendering field yet. |
| `SCROLL_HELPER_LINES` | Page scrolling | Platform divergence | Android only shows this in e-ink mode; iOS has no e-ink mode. |
| `SCROLL_HELPER_LINE_STYLE` | Page scrolling | Platform divergence | Android only shows this in e-ink mode; iOS has no e-ink mode. |
| `PAGE_BUTTONS` | Page scrolling | Platform divergence | Android only shows this in e-ink mode; iOS has no e-ink mode. |
| `ORDINALS` | Page scrolling | Deferred | Tracked in #174; no iOS shared-client config/rendering field yet. |
| `BOOKMARKS_SHOW` | Text bookmarks | Implemented | Existing `showBookmarks` model and renderer field. |
| `MYNOTES` | Text bookmarks | Implemented | Existing `showMyNotes` model and renderer field. |
| `AI_DOC_MARKERS` | Text bookmarks | Deferred | Tracked in #174; iOS AI document markers are not implemented. |
| `BOOKMARKS_HIDELABELS` | Text bookmarks | Implemented | Existing persisted/synced field now reaches the renderer config payload. |
| `MARK_AS_READ_BUTTON` | Reading and memorization | Deferred | Tracked in #174; no iOS shared-client config/rendering field yet. |
| `MEMORIZATION_INDICATORS` | Reading and memorization | Deferred | Tracked in #174; no iOS shared-client config/rendering field yet. |
| `AUTO_TRACK_READING` | Reading and memorization | Adapted elsewhere | iOS implements this under Reading Progress Settings and emits `appSettings.autoTrackReading`. |

## Guardrails

- Add a row to `TextDisplaySettingsView` only when the iOS model, bridge payload, and renderer all
  support the behavior.
- Keep `TextDisplaySettingsPresentation.androidRows` in the same order as Android
  `text_display_settings.xml`.
- Do not add e-ink-only rows to iOS unless iOS gets an explicit e-ink feature.
- Keep the main reader overflow All Text Options entry workspace-scoped because it matches
  Android's `MainBibleActivity` route.
- Keep the pane hamburger All Text Options entry window-scoped because it matches Android's
  `SplitBibleArea` per-window popup route.
- Do not move `workspace_color` into true global settings or reader document
  colors; ADR 0005 owns that scope decision.
