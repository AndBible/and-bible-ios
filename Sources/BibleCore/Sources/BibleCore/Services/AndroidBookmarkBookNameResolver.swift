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
     Reports whether a raw Android `book` value matches an installed passage module's initials.

     - Parameter rawValue: Raw string from the Android `book` column.
     - Returns: `true` when the value equals an installed Bible or commentary module's initials.
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
     - Returns: The SWORD book name (e.g. `Genesis`), or `nil` when no installed module can
       resolve the ordinal in a versification-sound way.
     - Side effects: may lazily create SWORD manager state and cache module book lists.
     - Failure modes: returns `nil` for intro ordinals and unresolvable versifications.
     */
    func displayBookName(v11nName: String, ordinal: Int, kjvOrdinal: Int) -> String?
}

/**
 SWORD-backed resolver that derives display book names from installed Bible modules.

 The resolver tries every installed Bible whose versification matches the bookmark's own `v11n`
 so ordinals resolve in the versification they were recorded in, exactly like Android's JSword
 reverse mapping. Candidates that libsword cannot open (Android custom-driver or MyBible package
 projections) or that lack the resolved book's content are skipped rather than aborting
 derivation. When no matching module resolves, two versification-sound fallbacks use the
 bookmark's KJVA ordinal: a KJVA-versified module when installed, then any KJV-versified module
 restricted to Old Testament results, because KJV and KJVA ordinals are identical up to Malachi
 and diverge only after the apocrypha insertion point.

 Side effects:
 - lazily creates a `SwordManager` on first resolution; caches the module inventory, per-module
   book lists, and per-versification module choices for the resolver's lifetime

 Failure modes:
 - resolution returns `nil` when no installed module can resolve the ordinal soundly
 - the caches never observe module installs performed after the first resolution, so restore
   flows should use a fresh resolver instance per operation (the default service wiring does)
 */
public final class AndroidBookmarkSwordBookNameResolver: AndroidBookmarkBookNameResolving {
    private let managerProvider: () -> SwordManager?
    private var cachedManager: SwordManager??
    private var cachedBibleModuleInfos: [ModuleInfo]?
    private var cachedPassageInitials: Set<String>?
    private var moduleNamesByV11n: [String: [String]] = [:]
    private var bookListsByModule: [String: [BookInfo]] = [:]

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
     Reports whether a raw Android `book` value matches an installed passage module's initials.

     Android's `book` column holds an `AbstractPassageBook`, which covers commentaries as well as
     Bibles, so both categories participate in initials classification.

     - Parameter rawValue: Raw string from the Android `book` column.
     - Returns: `true` when the value equals an installed Bible or commentary module's initials.
     - Side effects: lazily enumerates installed modules once.
     - Failure modes: returns `false` when the SWORD manager cannot be created.
     */
    public func isInstalledBibleInitials(_ rawValue: String) -> Bool {
        installedPassageInitials().contains(rawValue)
    }

    /**
     Derives the display book name for a bookmark ordinal in its own versification.

     - Parameters:
       - v11nName: Versification name stored with the Android bookmark row; empty means KJV.
       - ordinal: Intro-inclusive whole-Bible ordinal in `v11nName`.
       - kjvOrdinal: Intro-inclusive whole-Bible ordinal in KJVA used as a fallback key.
     - Returns: The SWORD book name for the resolved verse, or `nil` when unresolvable.
     - Side effects: lazily creates the SWORD manager and populates the resolver caches.
     - Failure modes: returns `nil` for intro ordinals, unloadable candidate modules, and
       versifications with no sound resolution path.
     */
    public func displayBookName(v11nName: String, ordinal: Int, kjvOrdinal: Int) -> String? {
        guard let manager = manager() else { return nil }

        let wanted = normalizedV11n(v11nName)
        for moduleName in moduleNames(matchingV11n: wanted) {
            if let book = resolvedBook(moduleName: moduleName, ordinal: ordinal, manager: manager) {
                return book.name
            }
        }

        if wanted != "KJVA" {
            for moduleName in moduleNames(matchingV11n: "KJVA") {
                if let book = resolvedBook(moduleName: moduleName, ordinal: kjvOrdinal, manager: manager) {
                    return book.name
                }
            }
        }

        guard wanted != "KJV" else { return nil }
        for moduleName in moduleNames(matchingV11n: "KJV") {
            if let book = resolvedBook(moduleName: moduleName, ordinal: kjvOrdinal, manager: manager),
               book.testament == 1 {
                return book.name
            }
        }
        return nil
    }

    private func manager() -> SwordManager? {
        if let cachedManager {
            return cachedManager
        }
        let created = managerProvider()
        cachedManager = created
        return created
    }

    private func bibleModuleInfos() -> [ModuleInfo] {
        if let cachedBibleModuleInfos {
            return cachedBibleModuleInfos
        }
        let infos = manager()?.installedModules(category: ModuleCategory.bible) ?? []
        cachedBibleModuleInfos = infos
        return infos
    }

    private func installedPassageInitials() -> Set<String> {
        if let cachedPassageInitials {
            return cachedPassageInitials
        }
        var initials = Set<String>()
        if let manager = manager() {
            for info in manager.installedModules(category: ModuleCategory.bible) {
                initials.insert(info.name)
            }
            for info in manager.installedModules(category: ModuleCategory.commentary) {
                initials.insert(info.name)
            }
        }
        cachedPassageInitials = initials
        return initials
    }

    /// Android and SWORD both treat a missing versification name as the KJV default.
    private func normalizedV11n(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "KJV" : trimmed.uppercased()
    }

    private func moduleNames(matchingV11n normalizedName: String) -> [String] {
        if let cached = moduleNamesByV11n[normalizedName] {
            return cached
        }
        var names: [String] = []
        for info in bibleModuleInfos()
        where normalizedV11n(info.aboutMetadata.versification) == normalizedName {
            names.append(info.name)
        }
        moduleNamesByV11n[normalizedName] = names
        return names
    }

    private func resolvedBook(moduleName: String, ordinal: Int, manager: SwordManager) -> BookInfo? {
        guard let module = manager.module(named: moduleName),
              let reference = module.verseReference(ordinal: ordinal) else {
            return nil
        }

        let books: [BookInfo]
        if let cached = bookListsByModule[moduleName] {
            books = cached
        } else {
            books = module.getBookList()
            bookListsByModule[moduleName] = books
        }
        return books.first(where: { $0.osisId == reference.osisBookId })
    }
}
