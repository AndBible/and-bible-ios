# CLAUDE.md - BibleUI

## Module Purpose
SwiftUI feature screens for the entire app UI. Contains all user-facing views
organized by feature area. Uses BibleView for Bible text rendering and
BibleCore for data/services.

## Architecture
```
BibleUI
  ├── Bible/          # Main reading screen with BibleWebView
  ├── Navigation/     # Book/Chapter/Verse grid choosers
  ├── Bookmarks/      # Bookmark list, labels, StudyPad
  ├── Search/         # Full-text search UI
  ├── Downloads/      # Module browser, repository manager
  ├── ReadingPlans/   # Reading plan list, daily reading
  ├── Settings/       # App settings, text display, colors
  ├── Speak/          # TTS playback controls
  ├── Discrete/       # Calculator disguise mode
  ├── Workspace/      # Workspace selector/manager
  └── Shared/         # Reusable components (History, Progress)
```

## Key Patterns

### Navigation
Use NavigationStack with typed navigation paths:
```swift
NavigationStack(path: $navigationPath) {
    BibleReaderView()
        .navigationDestination(for: Route.self) { route in ... }
}
```

### State Management
- `@Environment(\.modelContext)` for SwiftData access
- `@Observable` service classes injected via `.environment()`
- Avoid `@StateObject` — prefer `@State` with `@Observable`

### Platform Adaptation
Use `#if os(iOS)` / `#if os(macOS)` sparingly. Prefer:
- `.navigationSplitViewStyle()` for iPad/Mac sidebar
- `ViewThatFits` for adaptive layouts
- `.toolbarRole(.editor)` for platform-appropriate toolbars

### Discrete Mode
Calculator disguise implemented as alternate root view. Gesture-activated
transition to Bible content. Must look/function as a real calculator.

## Testing
```bash
swift test --filter BibleUITests
```

## Reference (Android equivalents)
- Bible: `MainBibleActivity.kt`
- Navigation: `GridChoosePassageBook/Chapter/Verse`
- Bookmarks: `BookmarkControl.kt`, bookmark Activity classes
- Search: `SearchControl.kt`, search Activity classes
- Settings: Various settings activity/fragment classes
