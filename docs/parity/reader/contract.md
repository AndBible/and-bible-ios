# Reader Parity Notes (Current iOS Surface)

This file describes what "reader parity" currently means in practice on iOS.

It is not trying to be a formal spec. The point is to make it obvious which
reader behaviors are meant to feel Android-like today, even when the native
implementation is different.

Primary code references:

- top-level reader coordinator:
  `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderView.swift`
- main document controller:
  `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderController.swift`
- reader gesture/fullscreen policies:
  `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderInteractionPolicies.swift`
- web view coordinator and swipe handling:
  `Sources/BibleView/Sources/BibleView/WebViewCoordinator.swift`
- pane shell:
  `Sources/BibleUI/Sources/BibleUI/Bible/BibleWindowPane.swift`
- shared document rendering:
  `bibleview-js/src/components/documents/DocumentBroker.vue`
  and `bibleview-js/src/components/documents/MultiDocument.vue`

## Core Reader Shape

The current iOS reader keeps the same basic split Android users expect:

- a document-rendering surface in the WebView
- native coordination for windows, sheets, toolbars, and overlays
- a left navigation drawer for primary reader destinations
- a right overflow popup for reader-local toggles and configuration actions
- Android-parity settings that drive runtime reader behavior

## Reader Shell and Toolbar

At the shell level, iOS is now aiming for the same overall structure and
affordance order as Android:

- a compact toolbar with previous/next navigation bracketing the current
  reference title
- a left hamburger drawer for primary destinations such as Choose Document,
  Search, Speak, Bookmarks, StudyPads, My Notes, Reading Plan, History,
  Downloads, Backup & Restore, Device synchronization, and Application
  preferences
- a right overflow popup for reader-local actions such as Fullscreen, Night
  mode, Workspaces, Tilt to Scroll, split/pinning toggles, Label Settings,
  Section titles, Strong's numbers, Chapter & verse numbers, and All text
  options
- Android-style title/subtitle semantics in the toolbar: the current reference
  plus the active module description

The goal here is the same user-facing structure and flow, not a literal copy of
Android view classes.

## Preference-Driven Reader Behaviors

These Android-origin settings materially affect how the iOS reader behaves:

- `navigate_to_verse_pref`
- `open_links_in_special_window_pref`
- `double_tap_to_fullscreen`
- `auto_fullscreen_pref`
- `disable_two_step_bookmarking`
- `bible_view_swipe_mode`
- `toolbar_button_actions`
- `full_screen_hide_buttons_pref`
- `hide_window_buttons`
- `hide_bible_reference_overlay`
- `show_active_window_indicator`

The settings docs go into more detail, but the reader is where these values
actually become visible.

## Navigation

The reader is also trying to preserve Android-oriented navigation semantics for:

- chapter/page/none swipe modes
- active-window tracking
- current-window vs links-window navigation
- history updates and jump-back navigation
- fullscreen transitions triggered from document interaction
- Vue modal-open state blocking native reader navigation while a shared modal
  is active

## Chapter-Top and Restore Behavior

These chapter-top and restore details are easy to miss, but they are part of
the current parity expectation:

- chapter separators remain structural content rather than a toggleable visual
  option
- section titles remain preference-driven
- normal restored reading positions must not highlight the current verse as if
  it were an explicit navigation target
- explicit verse-target navigation may still highlight the requested verse/range

## Bookmarking

Reader-side bookmark actions are expected to keep these Android-oriented
behaviors:

- one-step vs two-step bookmarking
- whole-verse vs selection bookmarks
- bridge-driven label assignment entry points
- bookmark updates reflected back into the WebView document

## Display Behavior

The reader still pushes a shared config payload into the WebView surface. That
payload carries several Android-parity display options, including:

- night mode state
- monochrome mode
- animation disablement
- font-size multiplier
- bookmark modal button disablement
- active-window indicator visibility

## Strong's and Dictionary Document Routing

The Strong's / dictionary flow is part of reader parity. It is expected to
preserve the richer Android-style experience through:

- a dedicated `contentType: "strongs"` route into the embedded client instead
  of treating Strong's content as generic multi-document content
- normal document/window-pipeline ownership rather than a dedicated native
  iOS-only sheet
- per-dictionary tab selection when multiple Strong's dictionaries are installed
- morphology fragments rendered alongside definition fragments when available
- recursive Strong's navigation and `Find all occurrences` handoff from inside
  the modal

The current iOS dedicated Strong's sheet is tracked as remaining parity drift in
#8. Keeping `contentType: "strongs"` intact is necessary, but not sufficient, for
closing the routing gap. The intended endpoint is Vue/document-pipeline
presentation, not preserving the native sheet.

## Windows and Compare

The reader is also expected to preserve these multi-window and comparison
behaviors:

- focused window tracking
- special links windows
- compare requests routed through the same embedded document/window pipeline
  Android uses for the fake compare document
- synchronized window scrolling and active-window signaling

The current native iOS Compare sheet is tracked as remaining parity drift in
#123. Its existing payload coverage protects the bridge request, but should not
be read as evidence that the native sheet is the intended final parity shape.
The intended endpoint is the shared compare document flow.

## Multi-Reference and Cross-Reference Routing

Reader links that resolve to multiple references should participate in the same
embedded document pipeline Android uses for `multi://` links and the fake multi
document. The desired behavior is:

- single-reference links still navigate or open the configured links window
- multi-reference links render through the shared Vue `MultiDocument` path
- "open all" style flows stay compatible with the embedded document client

The current native iOS `CrossReferenceView` sheet is tracked as remaining parity
drift in #124. The intended endpoint is the shared Vue `MultiDocument` flow, not
preserving the native sheet.

## Vue Modal State

The embedded Vue modal stack reports whether a modal is open. The native reader
host should treat that as part of the reader contract:

- native previous/next page or chapter movement should be blocked while a Vue
  modal is open
- native horizontal-swipe and keyboard navigation should not escape an open Vue
  modal
- any available native back/escape equivalent should close Vue modals before
  normal reader back handling

The iOS bridge currently receives `reportModalState` but does not use it; #125
tracks the remaining host-gating parity work.
