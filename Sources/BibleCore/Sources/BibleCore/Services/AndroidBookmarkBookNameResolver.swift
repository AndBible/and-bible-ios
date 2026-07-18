// AndroidBookmarkBookNameResolver.swift - Android bookmark book-column normalization

import Foundation
import SwordKit

/**
 Resolves iOS display book names for Android-origin Bible bookmark rows.

 Android's `BibleBookmark.book` column stores SWORD module initials (or NULL) because Android
 renders bookmark references from `v11n` plus ordinals and only uses the column to pick a
 translation for verse text. iOS repurposed the same field as the user-facing Bible book name
 that drives list display, chapter-highlight queries, and navigation. Restore flows use this
 boundary to translate Android's module-initials semantics into iOS display-name semantics.

 Side effects:
 - implementations may query installed SWORD modules

 Failure modes:
 - implementations return `nil` when no installed module can resolve the requested ordinal
 */
public protocol AndroidBookmarkBookNameResolving {
    /**
     Reports whether a raw Android `book` value matches an installed SWORD Bible's initials.

     - Parameter rawValue: Raw string from the Android `book` column.
     - Returns: `true` when the value equals an installed Bible module's initials.
     - Side effects: may lazily enumerate installed modules.
     - Failure modes: returns `false` when module enumeration is unavailable.
     */
    func isInstalledBibleInitials(_ rawValue: String) -> Bool

    /**
     Derives the display book name for a bookmark ordinal in its own versification.

     - Parameters:
       - v11nName: Versification name stored with the Android bookmark row; empty means KJV.
       - ordinal: Intro-inclusive whole-Bible ordinal in `v11nName`.
       - kjvOrdinal: Intro-inclusive whole-Bible ordinal in KJVA used as a fallback key.
     - Returns: The SWORD book name (e.g. `Genesis`), or `nil` when no installed module matches
       the bookmark's versification and no KJVA-versified module can use the fallback ordinal.
     - Side effects: may lazily create SWORD manager state and cache module book lists.
     - Failure modes: returns `nil` for intro ordinals and unresolvable versifications.
     */
    func displayBookName(v11nName: String, ordinal: Int, kjvOrdinal: Int) -> String?
}

/**
 SWORD-backed resolver that derives display book names from installed Bible modules.

 The resolver prefers an installed Bible whose versification matches the bookmark's own `v11n`
 so ordinals resolve in the versification they were recorded in, exactly like Android's
 JSword reverse mapping. When no matching module exists it falls back to a KJVA-versified
 module using the bookmark's KJVA ordinal, which is versification-correct by construction.

 Side effects:
 - lazily creates a `SwordManager` on first resolution and caches per-module book lists

 Failure modes:
 - resolution returns `nil` when no installed module matches and no KJVA module exists
 */
public final class AndroidBookmarkSwordBookNameResolver: AndroidBookmarkBookNameResolving {
    private let managerProvider: () -> SwordManager?
    private var cachedManager: SwordManager??
    private var cachedBibleInitials: Set<String>?
    private var bookNamesByModule: [String: [String: String]] = [:]

    /**
     Creates a resolver backed by lazily created SWORD manager state.

     - Parameter managerProvider: Factory for the SWORD manager; defaults to the shared module
       root used by the app. The factory runs at most once, on first resolution.
     - Side effects: none until the first resolution call.
     - Failure modes: a `nil` manager disables resolution and initials matching.
     */
    public init(managerProvider: @escaping () -> SwordManager? = { SwordManager() }) {
        self.managerProvider = managerProvider
    }

    /**
     Reports whether a raw Android `book` value matches an installed SWORD Bible's initials.

     - Parameter rawValue: Raw string from the Android `book` column.
     - Returns: `true` when the value equals an installed Bible module's initials.
     - Side effects: lazily enumerates installed Bible modules once.
     - Failure modes: returns `false` when the SWORD manager cannot be created.
     */
    public func isInstalledBibleInitials(_ rawValue: String) -> Bool {
        installedBibleInitials().contains(rawValue)
    }

    /**
     Derives the display book name for a bookmark ordinal in its own versification.

     - Parameters:
       - v11nName: Versification name stored with the Android bookmark row; empty means KJV.
       - ordinal: Intro-inclusive whole-Bible ordinal in `v11nName`.
       - kjvOrdinal: Intro-inclusive whole-Bible ordinal in KJVA used as a fallback key.
     - Returns: The SWORD book name for the resolved verse, or `nil` when unresolvable.
     - Side effects: lazily creates the SWORD manager and caches module book-name maps.
     - Failure modes: returns `nil` for intro ordinals, empty book lists, and versifications
       with no installed module.
     */
    public func displayBookName(v11nName: String, ordinal: Int, kjvOrdinal: Int) -> String? {
        guard let manager = manager() else { return nil }

        if let moduleName = moduleName(matchingV11n: v11nName, manager: manager),
           let name = bookName(moduleName: moduleName, ordinal: ordinal, manager: manager) {
            return name
        }

        guard normalizedV11n(v11nName) != "KJVA",
              let kjvaModuleName = moduleName(matchingV11n: "KJVA", manager: manager) else {
            return nil
        }
        return bookName(moduleName: kjvaModuleName, ordinal: kjvOrdinal, manager: manager)
    }

    private func manager() -> SwordManager? {
        if let cachedManager {
            return cachedManager
        }
        let created = managerProvider()
        cachedManager = created
        return created
    }

    private func installedBibleInitials() -> Set<String> {
        if let cachedBibleInitials {
            return cachedBibleInitials
        }
        var initials = Set<String>()
        if let manager = manager() {
            for info in manager.installedModules(category: ModuleCategory.bible) {
                initials.insert(info.name)
            }
        }
        cachedBibleInitials = initials
        return initials
    }

    /// Android and SWORD both treat a missing versification name as the KJV default.
    private func normalizedV11n(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "KJV" : trimmed.uppercased()
    }

    private func moduleName(matchingV11n v11nName: String, manager: SwordManager) -> String? {
        let wanted = normalizedV11n(v11nName)
        for info in manager.installedModules(category: ModuleCategory.bible)
        where normalizedV11n(info.aboutMetadata.versification) == wanted {
            return info.name
        }
        return nil
    }

    private func bookName(moduleName: String, ordinal: Int, manager: SwordManager) -> String? {
        guard let module = manager.module(named: moduleName),
              let reference = module.verseReference(ordinal: ordinal) else {
            return nil
        }

        if let cached = bookNamesByModule[moduleName] {
            return cached[reference.osisBookId]
        }

        let names = Dictionary(
            module.getBookList().map { ($0.osisId, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        bookNamesByModule[moduleName] = names
        return names[reference.osisBookId]
    }
}
