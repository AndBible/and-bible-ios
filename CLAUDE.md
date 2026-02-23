# CLAUDE.md - AndBible iOS

## Project Overview
iOS port of AndBible, a powerful offline Bible study app. Universal SwiftUI app
targeting iPhone, iPad, and Mac (iOS 17+, macOS 14+). Uses libsword (C++) for
SWORD Bible module handling and a Vue.js WKWebView for Bible text rendering
(hybrid approach with progressive SwiftUI replacement).

## Project Structure

```
and-bible-ios/
├── AndBible.xcodeproj          # Main Xcode project (open this in Xcode)
├── AndBible/                   # iOS app target source files
│   ├── AndBibleApp.swift       # App entry point
│   ├── ContentView.swift       # Root view
│   ├── Info.plist             # App configuration
│   └── Assets.xcassets        # App icons, images
├── Package.swift               # Swift Package for library modules
└── Sources/                    # Swift Package modules
    ├── SwordKit/              # libsword wrapper (C bridge + Swift)
    ├── BibleCore/             # Domain models, SwiftData, services
    ├── BibleView/             # WKWebView + Vue.js bridge
    └── BibleUI/               # SwiftUI feature screens
```

## Architecture

```
Xcode Project (AndBible.xcodeproj)
  └── AndBible App Target → References local Swift Package
        ├── BibleUI: SwiftUI feature screens
        ├── BibleView: WKWebView + Vue.js bridge (WKScriptMessageHandler)
        ├── BibleCore: Domain models (SwiftData), business logic services
        └── SwordKit: libsword flat C API → Swift wrapper
```

### Module Dependencies
- **AndBible** (app target) → BibleUI, BibleView, BibleCore, SwordKit
- **BibleUI** → BibleView, BibleCore, SwordKit
- **BibleView** → BibleCore
- **BibleCore** → SwordKit
- **SwordKit** → CLibSword (C module for flatapi.h)

## Opening the Project

**In Xcode (Recommended):**
1. Open `AndBible.xcodeproj` in Xcode
2. Select a simulator (iPhone 17, iPad, etc.)
3. Press Cmd+R to build and run

**From Command Line:**
```bash
# Build for simulator
xcodebuild -scheme AndBible -destination 'platform=iOS Simulator,name=iPhone 17' build

# Build libsword XCFramework
cd libsword && ./build-ios.sh

# Build Vue.js bundle
cd bibleview-js && npm install && npm run build

# Run tests
swift test                              # SPM package tests
cd bibleview-js && npm run test:ci      # Vue.js tests
```

## Key Patterns

### Bridge Communication (Swift ↔ Vue.js)
Vue.js calls Swift via:
```javascript
window.webkit.messageHandlers.bibleView.postMessage({ method, args })
```
Swift calls Vue.js via:
```swift
webView.evaluateJavaScript("bibleView.emit('\(event)', \(jsonData))")
```

### SwiftData Models
All entities use UUID primary keys (matching Android's IdType).
Settings inheritance: Window → Workspace → App defaults.

### libsword Usage
All SWORD operations go through SwordKit's Swift wrappers around flatapi.h.
Never call flatapi C functions directly from app code.

### Supported Formats
- SWORD modules (via libsword/SwordKit)
- MySword SQLite databases (via MySwordReader)
- MyBible SQLite databases (via MyBibleReader)
- EPUB files (via EpubReader)

## Testing

Run only tests relevant to the changes made:
- Swift changes: `swift test` or `xcodebuild test`
- Vue.js/TypeScript changes: `cd bibleview-js && npm run test:ci`
- Bridge changes: test both sides

## Reference: Android Codebase
The original Android codebase is at `../and-bible/`
Key reference files for porting:
- Bridge methods: `app/bibleview-js/src/composables/android.ts`
- Data contracts: `app/bibleview-js/src/types/client-objects.ts`
- JSword facade: `app/src/main/java/net/bible/service/sword/SwordContentFacade.kt`
- DB entities: `app/src/main/java/net/bible/android/database/WorkspaceEntities.kt`
- Bookmarks: `app/src/main/java/net/bible/android/control/bookmark/BookmarkControl.kt`
- JS interface: `app/src/main/java/net/bible/android/view/activity/page/BibleJavascriptInterface.kt`

## Code Style
- Swift: Follow Apple's Swift API Design Guidelines
- Use SwiftUI for all new UI (no UIKit unless required for WKWebView)
- Use SwiftData for persistence (not Core Data)
- Use async/await for concurrency (not Combine unless needed for reactive streams)
- Use Swift Package Manager for all internal modules

## Current Status (updated 2026-02-14)

### What's Done
- Phase 1 scaffolding complete: 78 files, ~5,850 lines across all modules
- **✅ Project compiles successfully on macOS with `swift build`**
- 23 compilation fixes applied (see below)
- All SwiftData, SwiftUI, and platform compatibility issues resolved

### Compilation Fixes Already Applied
1. CLibSword uses stub C implementations (35+ functions) — no real libsword needed yet
2. BibleWebView split into #if os(iOS)/#elseif os(macOS) for platform protocols
3. SpeakService: removed @Observable (NSObject subclass incompatible)
4. SpeakControlView: passes SpeakService via init (not @Environment)
5. ContentView: UIDevice wrapped in #if os(iOS)
6. AndBibleApp: SpeakService as plain `let` (not @State)
7. BookmarkService: fixed bad cast and unused variable
8. SwordModule/InstallManager: fixed C pointer nil-coalescing (can't ?? with String vs UnsafePointer)
9. Added `import Observation` to 6 service files using @Observable
10. Fixed import ordering in SpeakControlView
11. Added `import SwiftData` to 6 BibleUI views using @Environment(\.modelContext)
12. Wrapped `.navigationBarTitleDisplayMode(.inline)` in #if os(iOS) for 3 views
13. Created Color.systemBackground extension for cross-platform UIColor/NSColor compatibility
14. Created Color.systemGray2 extension for cross-platform color compatibility

### Next Steps
1. ~~Run `swift build` on macOS to find remaining errors~~ ✅ DONE
2. ~~Fix any errors found~~ ✅ DONE
3. ~~Build Vue.js bundle and copy to BibleView Resources/~~ ✅ DONE
4. Run in iOS Simulator — verify basic app launch
5. Implement Phase 1 functionality: load SWORD module, display Genesis 1
6. Cross-compile libsword when needed (requires: brew install subversion; cd libsword && ./build-ios.sh)
   - Currently using stub implementations which are sufficient for development
