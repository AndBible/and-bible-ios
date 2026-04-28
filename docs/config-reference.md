# Config Reference

This documents the JSON emitted by `BibleReaderController.buildConfigJSON()` and consumed by the Vue.js `set_config` listener.

## Source Files

Native producer:
- `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderController.swift:5048`

Client consumer:
- `bibleview-js/src/composables/config.ts:60`
- `bibleview-js/src/composables/config.ts:299`

## Top-Level Shape

```json
{
  "config": { ... },
  "appSettings": { ... },
  "initial": false
}
```

`initial` is currently emitted as `false` by iOS.

## `config`

This block controls document rendering and layout.

### Rendering toggles

- `developmentMode`: currently `false` from iOS
- `testMode`: currently `false` from iOS
- `showAnnotations`
- `showChapterNumbers`
- `showVerseNumbers`
- `strongsMode`
- `showMorphology`
- `showRedLetters`
- `showVersePerLine`
- `showNonCanonical`
- `makeNonCanonicalItalic`
- `showSectionTitles`
- `showStrongsSeparately`
- `showFootNotes`
- `showFootNotesInline`
- `showXrefs`
- `expandXrefs`

### Typography and layout

- `fontFamily`
- `fontSize`
- `hyphenation`
- `lineSpacing`
- `justifyText`
- `marginSize.marginLeft`
- `marginSize.marginRight`
- `marginSize.maxWidth`
- `topMargin`
- `showPageNumber`

### Bookmark visibility fields

- `disableBookmarking`
- `showBookmarks`
- `showMyNotes`
- `bookmarksHideLabels`
- `bookmarksAssignLabels`

### Color payload

`config.colors` carries Android-style signed ARGB ints:
- `dayBackground`
- `dayNoise`
- `dayTextColor`
- `nightBackground`
- `nightNoise`
- `nightTextColor`

## `appSettings`

This block carries runtime/UI state rather than document content.

### Window and interaction state

- `nightMode`
- `errorBox`
- `activeWindow`
- `actionMode`
- `hasActiveIndicator`
- `activeSince`
- `limitAmbiguousModalSize`
- `windowId`
- `rightToLeft`

### Label and StudyPad state

- `favouriteLabels`
- `recentLabels`
- `studyPadCursors`
- `autoAssignLabels`
- `hideCompareDocuments`

### Modal/feature controls

- `disableBibleModalButtons`
- `disableGenericModalButtons`
- `monochromeMode`
- `disableAnimations`
- `disableClickToEdit`
- `fontSizeMultiplier`
- `enabledExperimentalFeatures`

## How The Client Uses It

Examples from the Vue.js side:

- `appSettings.disableAnimations` affects scroll animation behavior: `bibleview-js/src/composables/scroll.ts:99` and `:167`
- `appSettings.monochromeMode` affects bookmark and page styling: `bibleview-js/src/components/BibleView.vue:269` and `bibleview-js/src/composables/bookmarks.ts`
- `appSettings.activeWindow`, `hasActiveIndicator`, and `activeSince` drive active-window UX in ambiguous selection modals: `bibleview-js/src/composables/config.ts:259-267` and `bibleview-js/src/components/modals/AmbiguousSelection.vue:300-310`
- `appSettings.disableBibleModalButtons` and `disableGenericModalButtons` control modal actions: `bibleview-js/src/components/AmbiguousActionButtons.vue:102`
- `appSettings.studyPadCursors` and `autoAssignLabels` affect StudyPad document behavior: `bibleview-js/src/components/documents/StudyPadDocument.vue:273`
- `appSettings.hideCompareDocuments` filters compare fragments: `bibleview-js/src/components/documents/MultiDocument.vue:72-78`

## Important Constraints

### Unknown keys

The client logs unknown keys but does not fail hard:
- config keys: `bibleview-js/src/composables/config.ts:325`
- appSettings keys: `bibleview-js/src/composables/config.ts:336`

That means drift can be silent in production. If you add or rename a field, update both sides in the same change.

### `fontSizeMultiplier`

Native emits a normalized decimal multiplier, not a percentage integer:
- producer normalization: `Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderController.swift:5061`
- client use: `bibleview-js/src/components/BibleView.vue:290-306`

### Margin units

The client treats `marginSize` and `topMargin` as millimeters, converts them to pixels at runtime, and recalculates layout on resize:
- `bibleview-js/src/composables/config.ts:214-250`

## Change Checklist

When editing `buildConfigJSON()`:

1. update the matching TypeScript types in `bibleview-js/src/composables/config.ts`
2. update the actual `set_config` merge logic if a field needs special handling
3. verify the consuming components/composables still use the field name you emit
4. rerun simulator tests with `xcodebuild test`
