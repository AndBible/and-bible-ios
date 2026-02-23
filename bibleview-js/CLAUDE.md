# CLAUDE.md - bibleview-js (iOS Fork)

## Purpose
Forked Vue.js frontend from Android AndBible's `app/bibleview-js/`. Renders
Bible text, bookmarks, StudyPads, and other documents in a WKWebView on iOS.

## Key Modification: Platform Bridge Abstraction

The primary change from Android is the `native-bridge.ts` abstraction layer:

```
composables/native-bridge.ts  ← NEW: Platform detection + routing
composables/android.ts         ← MODIFIED: Delegates to native-bridge.ts
```

### How It Works
```typescript
// native-bridge.ts detects platform:
const isIOS = !!window.webkit?.messageHandlers?.bibleView
const isAndroid = !!window.android

// Routes calls to correct native bridge:
export function callNative(method: string, ...args: any[]) {
    if (isIOS) {
        window.webkit.messageHandlers.bibleView.postMessage({ method, args })
    } else if (isAndroid) {
        (window.android as any)[method](...args)
    }
}

// Async calls use the same callId pattern on both platforms
export function callNativeAsync(method: string, callId: number, ...args: any[]) {
    callNative(method, callId, ...args)
    // Response comes back via: bibleView.response(callId, value)
}
```

### Rules for Modifications
1. **Never break Android compatibility** — `android.ts` must continue to work unchanged
2. **Minimize changes** — Only modify files necessary for platform abstraction
3. **Same response pattern** — Both platforms use `bibleView.response(callId, value)` for async
4. **Same event pattern** — Both platforms use `bibleView.emit(event, data)` for native→JS

## Build Commands
```bash
npm install              # Initial setup
npm run dev              # Development server
npm run test:ci          # Unit tests
npm run lint             # ESLint checking
npm run build-debug      # Debug build (output → dist/)
npm run build-production # Production build
```

## Build Output
The `dist/` directory contents are copied into `Sources/BibleView/Resources/bibleview-js/`
for embedding in the iOS app bundle.

## Reference
- Original source: `../and-bible/app/bibleview-js/`
- Android bridge: `../and-bible/app/bibleview-js/src/composables/android.ts`
- Client types: `../and-bible/app/bibleview-js/src/types/client-objects.ts`
