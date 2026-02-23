# AndBible iOS - Quick Start Guide

## Opening the Project

### In Xcode (Recommended)

1. **Open the project:**
   ```bash
   open AndBible.xcodeproj
   ```
   Or: Double-click `AndBible.xcodeproj` in Finder

2. **Wait for package resolution:**
   - Xcode will automatically resolve the Swift Package dependencies
   - This may take 10-30 seconds on first open

3. **Select a simulator:**
   - Click the device selector next to the play button
   - Choose "iPhone 17" or any iOS simulator

4. **Build and Run:**
   - Press `Cmd+R` or click the Play button
   - First build takes 1-2 minutes
   - Subsequent builds are faster

## Project Structure

```
AndBible.xcodeproj  ← Open this in Xcode!
├── App code: AndBible/
│   ├── AndBibleApp.swift
│   └── ContentView.swift
└── Library modules (Swift Package):
    ├── SwordKit       - Bible library wrapper
    ├── BibleCore      - Domain models & services
    ├── BibleView      - Vue.js WebView component
    └── BibleUI        - SwiftUI screens
```

## What to Expect

### Current State (Phase 1 Scaffolding Complete)
✅ App compiles and launches
✅ Basic SwiftUI structure in place
✅ All modules scaffolded
✅ Vue.js bundle integrated
⚠️  Using stub SWORD library (mock data)
🚧 Most features are placeholder UI only

### What Works
- App launches in simulator
- Basic navigation structure
- SwiftUI views render
- Module architecture is set up

### What Doesn't Work Yet
- Loading actual Bible modules (using stubs)
- Bible text display (needs implementation)
- Bookmarks, search, settings (placeholders)
- Most UI interactions

## Next Steps (Phase 1 Implementation)

1. **Verify app launches** - Run in simulator, see the app shell
2. **Implement mock data provider** - Create sample Bible verses
3. **Connect BibleView** - Display Genesis 1 using Vue.js component
4. **Basic navigation** - Book/Chapter/Verse selection
5. **Replace stubs** - Build real libsword when needed

## Troubleshooting

### "Package resolution failed"
- Check that you're online (first time needs to download dependencies)
- Try: Product → Clean Build Folder (Cmd+Shift+K)
- Close and reopen Xcode

### "Build failed" errors
- Make sure Xcode is up to date (Xcode 15+)
- Check iOS deployment target is set to 17.0+
- See CLAUDE.md for detailed build info

### Can't select simulator
- Open Window → Devices and Simulators
- Download iOS 17+ simulator if needed
- Restart Xcode

## Resources

- **Full documentation:** See `CLAUDE.md` in project root
- **Android reference:** `../and-bible/` (original app)
- **Vue.js code:** `bibleview-js/` (shared frontend)

## Development Workflow

1. **Make Swift changes** → Edit in Xcode
2. **Make Vue.js changes** → Build in `bibleview-js/`, copy to Resources
3. **Test** → Cmd+R in Xcode
4. **Commit** → Use git as normal

Happy coding! 🎉
