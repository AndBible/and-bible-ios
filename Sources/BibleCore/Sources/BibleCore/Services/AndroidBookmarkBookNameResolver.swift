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
 One resolved Bible book produced by a resolver gateway for an ordinal lookup.

 The selection core only needs the display name and the testament so it can gate
 cross-versification fallbacks; everything else stays inside the gateway.
 */
public struct AndroidBookmarkResolvedBook: Sendable, Equatable {
    /// Full display book name as reported by the module (e.g. `Genesis`).
    public let name: String

    /// Testament number: 1 = Old Testament, 2 = New Testament.
    public let testament: Int

    /**
     Creates one resolved book result.

     - Parameters:
       - name: Full display book name.
       - testament: Testament number, 1 for Old Testament and 2 for New Testament.
     - Side effects: none.
     - Failure modes: none.
     */
    public init(name: String, testament: Int) {
        self.name = name
        self.testament = testament
    }
}

/**
 Module access boundary used by the Android bookmark book-name selection core.

 Separating module enumeration and ordinal resolution behind this gateway keeps the fallback
 selection logic pure and unit-testable without installed SWORD modules, while the production
 gateway stays a thin SwordKit adapter.

 Side effects:
 - implementations may perform module I/O and may cache results

 Failure modes:
 - implementations return empty collections or `nil` when module state is unavailable
 */
public protocol AndroidBookmarkResolverGateway {
    /**
     Lists installed Bible modules as `(initials, versification)` pairs in inventory order.

     - Returns: Installed Bible descriptors; versification is the raw conf value (empty means KJV).
     - Side effects: may lazily enumerate installed modules once.
     - Failure modes: returns an empty array when module state is unavailable.
     */
    func bibleModules() -> [(name: String, versification: String)]

    /**
     Lists initials of installed passage modules (Bibles and commentaries).

     - Returns: Initials set used to classify Android `book` column values.
     - Side effects: may lazily enumerate installed modules once.
     - Failure modes: returns an empty set when module state is unavailable.
     */
    func passageInitials() -> Set<String>

    /**
     Resolves one intro-inclusive whole-Bible ordinal against one module.

     - Parameters:
       - moduleName: Installed module initials to resolve against.
       - ordinal: Intro-inclusive ordinal in that module's own versification.
     - Returns: The resolved book, or `nil` when the module cannot be opened, the ordinal does
       not resolve to a normal verse, or the module lacks the resolved book's content.
     - Side effects: may open the module and cache its book list.
     - Failure modes: returns `nil` rather than throwing.
     */
    func resolve(moduleName: String, ordinal: Int) -> AndroidBookmarkResolvedBook?
}

/**
 SWORD-backed resolver that derives display book names from installed Bible modules.

 The selection core tries every installed Bible whose versification matches the bookmark's own
 `v11n`, skipping candidates the gateway cannot resolve (unloadable custom-driver or MyBible
 projections, content-sparse modules). When no matching module resolves it falls back through
 three versification-sound stages driven by the bookmark's KJVA ordinal:

 1. any KJVA-versified module, because `kjvOrdinal` is defined in KJVA;
 2. any KJV-versified module restricted to Old Testament results, because KJV and KJVA
    intro-inclusive ordinals are identical from Genesis through Malachi;
 3. for ordinals at or beyond the KJVA New Testament section, any KJV-versified module after
    subtracting the fixed apocrypha ordinal span, restricted to New Testament results.

 The stage-3 constants are computed from SWORD's canonical `canon.h`/`canon_kjva.h` tables:
 both canons share Genesis..Malachi exactly; KJVA then inserts 14 apocrypha books (182 chapters,
 5,731 verses → 5,913 intro-inclusive ordinals), so the KJVA New Testament section starts at
 ordinal 30,028 versus KJV's 24,115.

 Side effects:
 - the default gateway lazily creates a `SwordManager` on first resolution and caches the module
   inventory and per-module book lists for the resolver's lifetime

 Failure modes:
 - resolution returns `nil` when no installed module can resolve the ordinal soundly
 - caches never observe module installs performed after the first resolution, so restore flows
   should use a fresh resolver instance per operation (the default service wiring does)
 */
public final class AndroidBookmarkSwordBookNameResolver: AndroidBookmarkBookNameResolving {
    /// First intro-inclusive ordinal of the KJVA New Testament section (`canon_kjva.h`).
    static let kjvaNewTestamentStartOrdinal = 30028

    /// Intro-inclusive ordinal span of the KJVA apocrypha insertion (`canon_kjva.h` minus `canon.h`).
    static let kjvaApocryphaOrdinalSpan = 5913

    private let gateway: AndroidBookmarkResolverGateway
    private var moduleNamesByV11n: [String: [String]] = [:]

    /**
     Creates a resolver backed by the production SwordKit gateway.

     - Parameter managerProvider: Factory for the SWORD manager; defaults to the shared module
       root used by the app. The factory runs at most once, on first resolution.
     - Side effects: none until the first resolution call.
     - Failure modes: a `nil` manager disables resolution and initials matching.
     */
    public convenience init(managerProvider: @escaping () -> SwordManager? = { SwordManager() }) {
        self.init(gateway: AndroidBookmarkSwordResolverGateway(managerProvider: managerProvider))
    }

    /**
     Creates a resolver over an explicit module gateway.

     - Parameter gateway: Module access boundary; tests inject deterministic fakes here.
     - Side effects: none.
     - Failure modes: none.
     */
    public init(gateway: AndroidBookmarkResolverGateway) {
        self.gateway = gateway
    }

    /**
     Reports whether a raw Android `book` value matches an installed passage module's initials.

     Android's `book` column holds an `AbstractPassageBook`, which covers commentaries as well as
     Bibles, so both categories participate in initials classification.

     - Parameter rawValue: Raw string from the Android `book` column.
     - Returns: `true` when the value equals an installed Bible or commentary module's initials.
     - Side effects: lazily enumerates installed modules once.
     - Failure modes: returns `false` when module state is unavailable.
     */
    public func isInstalledBibleInitials(_ rawValue: String) -> Bool {
        gateway.passageInitials().contains(rawValue)
    }

    /**
     Derives the display book name for a bookmark ordinal in its own versification.

     - Parameters:
       - v11nName: Versification name stored with the Android bookmark row; empty means KJV.
       - ordinal: Intro-inclusive whole-Bible ordinal in `v11nName`.
       - kjvOrdinal: Intro-inclusive whole-Bible ordinal in KJVA used by the fallback stages.
     - Returns: The SWORD book name for the resolved verse, or `nil` when unresolvable.
     - Side effects: lazily initializes the gateway's module state and the resolver caches.
     - Failure modes: returns `nil` for intro ordinals, unloadable candidate modules, and
       versifications with no sound resolution path.
     */
    public func displayBookName(v11nName: String, ordinal: Int, kjvOrdinal: Int) -> String? {
        let wanted = normalizedV11n(v11nName)
        for moduleName in moduleNames(matchingV11n: wanted) {
            if let book = gateway.resolve(moduleName: moduleName, ordinal: ordinal) {
                return book.name
            }
        }

        if wanted != "KJVA" {
            for moduleName in moduleNames(matchingV11n: "KJVA") {
                if let book = gateway.resolve(moduleName: moduleName, ordinal: kjvOrdinal) {
                    return book.name
                }
            }
        }

        if wanted != "KJV" {
            for moduleName in moduleNames(matchingV11n: "KJV") {
                if let book = gateway.resolve(moduleName: moduleName, ordinal: kjvOrdinal),
                   book.testament == 1 {
                    return book.name
                }
            }
        }

        if kjvOrdinal >= Self.kjvaNewTestamentStartOrdinal {
            let shifted = kjvOrdinal - Self.kjvaApocryphaOrdinalSpan
            for moduleName in moduleNames(matchingV11n: "KJV") {
                if let book = gateway.resolve(moduleName: moduleName, ordinal: shifted),
                   book.testament == 2 {
                    return book.name
                }
            }
        }
        return nil
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
        for module in gateway.bibleModules()
        where normalizedV11n(module.versification) == normalizedName {
            names.append(module.name)
        }
        moduleNamesByV11n[normalizedName] = names
        return names
    }
}

/**
 Production SwordKit adapter behind `AndroidBookmarkResolverGateway`.

 The adapter keeps all SwordKit access in one thin layer: it lazily creates the manager,
 enumerates the module inventory once, and caches per-module book lists so restore flows do not
 re-scan `mods.d` per bookmark.

 Side effects:
 - lazily creates a `SwordManager` and caches inventory, initials, and book lists

 Failure modes:
 - all lookups degrade to empty results when the manager cannot be created
 */
final class AndroidBookmarkSwordResolverGateway: AndroidBookmarkResolverGateway {
    private let managerProvider: () -> SwordManager?
    private var cachedManager: SwordManager??
    private var cachedBibleModules: [(name: String, versification: String)]?
    private var cachedPassageInitials: Set<String>?
    private var bookListsByModule: [String: [BookInfo]] = [:]

    /**
     Creates the SwordKit-backed gateway.

     - Parameter managerProvider: Factory for the SWORD manager, run at most once.
     - Side effects: none until first use.
     - Failure modes: a `nil` manager disables all lookups.
     */
    init(managerProvider: @escaping () -> SwordManager?) {
        self.managerProvider = managerProvider
    }

    /**
     Lists installed Bible modules as `(initials, versification)` pairs in inventory order.

     - Returns: Installed Bible descriptors from the cached inventory.
     - Side effects: lazily creates the manager and caches the inventory on first call.
     - Failure modes: returns an empty array when the manager cannot be created.
     */
    func bibleModules() -> [(name: String, versification: String)] {
        if let cachedBibleModules {
            return cachedBibleModules
        }
        var modules: [(name: String, versification: String)] = []
        if let manager = manager() {
            for info in manager.installedModules(category: ModuleCategory.bible) {
                modules.append((name: info.name, versification: info.aboutMetadata.versification))
            }
        }
        cachedBibleModules = modules
        return modules
    }

    /**
     Lists initials of installed passage modules (Bibles and commentaries).

     - Returns: Initials set from the cached inventory.
     - Side effects: lazily creates the manager and caches the set on first call.
     - Failure modes: returns an empty set when the manager cannot be created.
     */
    func passageInitials() -> Set<String> {
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

    /**
     Resolves one intro-inclusive ordinal against one installed module.

     - Parameters:
       - moduleName: Installed module initials to resolve against.
       - ordinal: Intro-inclusive ordinal in the module's own versification.
     - Returns: The resolved book with its testament, or `nil` when the module cannot be opened,
       the ordinal is not a normal verse, or the module's book list lacks the resolved book.
     - Side effects: opens the module through SwordKit and caches its book list.
     - Failure modes: returns `nil` rather than throwing.
     */
    func resolve(moduleName: String, ordinal: Int) -> AndroidBookmarkResolvedBook? {
        guard let manager = manager(),
              let module = manager.module(named: moduleName),
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
        guard let book = books.first(where: { $0.osisId == reference.osisBookId }) else {
            return nil
        }
        return AndroidBookmarkResolvedBook(name: book.name, testament: book.testament)
    }

    private func manager() -> SwordManager? {
        if let cachedManager {
            return cachedManager
        }
        let created = managerProvider()
        cachedManager = created
        return created
    }
}
