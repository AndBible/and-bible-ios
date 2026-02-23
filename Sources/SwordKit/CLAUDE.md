# CLAUDE.md - SwordKit

## Module Purpose
Swift wrapper around the libsword C++ library's flat C API (`flatapi.h`).
Provides safe, idiomatic Swift access to SWORD Bible module operations.

## Architecture
```
SwordKit (Swift)
  └── CLibSword (C module map)
        └── flatapi.h (from SWORD project)
              └── libsword.xcframework (pre-built C++ library)
```

## Key Types
- `SwordManager`: Wraps SWMgr. Manages module installation path, lists installed modules, gets modules by name, sets global options (Strong's, morphology, footnotes, etc.)
- `SwordModule`: Wraps SWModule. Sets verse key, retrieves rendered text (HTML/OSIS), raw entry, navigates (next/prev/begin/end), searches.
- `InstallManager`: Wraps InstallMgr. Lists remote sources, refreshes catalogs, downloads/installs/uninstalls modules.
- `ModuleInfo`: Value type for module metadata (name, description, language, category, features, version, cipher key status).
- `SearchResult`: Value type for search hits (module name, key, preview text).
- `SwordConfig`: Wraps SWConfig for reading/writing sword.conf.

## C Bridging Pattern
All C function calls go through the CLibSword module. Swift code should:
1. Never store raw C pointers longer than a single call scope
2. Always use `withUnsafePointer` / `String(cString:)` for string conversion
3. Handle NULL returns as Optional
4. Call cleanup functions (e.g., module search cleanup) in defer blocks

## Thread Safety
libsword is NOT thread-safe. All calls must be serialized. Use a dedicated
serial DispatchQueue or Swift actor for all SwordKit operations.

## Testing
Unit tests mock the C layer. Integration tests require actual SWORD modules.
```bash
swift test --filter SwordKitTests
```

## Reference
- SWORD flatapi: https://crosswire.org/svn/sword/trunk/bindings/flatapi.h
- Android equivalent: `SwordContentFacade.kt`, `SwordDocumentFacade.kt`
