// JSwordCanon.swift - Android's exact versification dimensions

import Foundation
import SwordKit

/**
 Provides reference validation and canon ordering from the pinned JSword revision used by Android.

 JSword mapping resources are defined against JSword's own book lists and chapter dimensions. SWORD
 has similarly named systems, but a few edge dimensions differ; indexing JSword rules through those
 tables can move an out-of-range endpoint into the following chapter. The bundled fixture is
 generated from `Versifications` at the revision recorded in the file and is therefore the sole
 ordering authority for `JSwordVersificationMapping`.

 Systems are expanded lazily because constructing every intro-inclusive reference for every canon
 at startup would be unnecessary. A malformed or revision-mismatched fixture fails closed.
 */
enum JSwordCanon {
    /// JSword revision from which both canon dimensions and mapping resources were copied.
    static let pinnedRevision = JSwordVersificationRegistry.pinnedRevision

    private struct Fixture: Decodable {
        let jswordRevision: String
        let systems: [String: SystemFixture]
    }

    private struct SystemFixture: Decodable {
        let books: [BookFixture]
    }

    private struct BookFixture: Decodable {
        let osis: String
        /// Last verse by chapter index, including chapter zero.
        let chapters: [Int]
    }

    private struct Coordinate: Hashable {
        let osisBookId: String
        let chapter: Int
        let verse: Int

        init(_ reference: SwordVersification.Reference) {
            osisBookId = reference.osisBookId
            chapter = reference.chapter
            verse = reference.verse
        }

        var reference: SwordVersification.Reference {
            .init(osisBookId: osisBookId, chapter: chapter, verse: verse)
        }
    }

    private struct System {
        let references: [Coordinate]
        let indexes: [Coordinate: Int]

        init(fixture: SystemFixture) {
            var references: [Coordinate] = []
            for book in fixture.books {
                for (chapter, lastVerse) in book.chapters.enumerated() where lastVerse >= 0 {
                    for verse in 0...lastVerse {
                        references.append(
                            Coordinate(
                                .init(osisBookId: book.osis, chapter: chapter, verse: verse)
                            )
                        )
                    }
                }
            }
            self.references = references
            self.indexes = Dictionary(
                uniqueKeysWithValues: references.enumerated().map { ($0.element, $0.offset) }
            )
        }
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var systems: [String: System] = [:]

        func system(named name: String, fixture: Fixture) -> System? {
            lock.lock()
            defer { lock.unlock() }
            if let system = systems[name] {
                return system
            }
            guard let systemFixture = fixture.systems[name] else { return nil }
            let system = System(fixture: systemFixture)
            systems[name] = system
            return system
        }
    }

    private static let cache = Cache()

    private static let fixture: Fixture? = {
        guard let data = JSwordVersificationRegistry.canonFixtureData(),
           let decoded = try? JSONDecoder().decode(Fixture.self, from: data),
           decoded.jswordRevision == pinnedRevision else {
            return nil
        }
        return decoded
    }()

    /// All OSIS identifiers representable by JSword's `BibleBook` enum at the pinned revision.
    private static let knownOSISBookIDs: Set<String> = Set(
        fixture?.systems.values.flatMap { system in
            system.books.map(\.osis)
        } ?? []
    )

    /**
     Normalizes a JSword versification name and confirms that its canon fixture exists.

     - Parameter rawValue: Module or payload versification name; empty means Android's KJV default.
     - Returns: Canonical fixture key, or `nil` for an unsupported system or invalid fixture.
     - Side effects: Decodes the bundled fixture on first access.
     - Failure modes: Missing, malformed, or revision-mismatched fixture data returns `nil`.
     */
    static func normalizedName(_ rawValue: String) -> String? {
        guard let candidate = JSwordVersificationRegistry.normalizedName(rawValue),
              fixture?.systems[candidate] != nil else { return nil }
        return candidate
    }

    /**
     Returns the intro-inclusive JSword canon index for one coordinate.

     - Parameters:
       - reference: Coordinate in the named JSword system.
       - versification: JSword system name; empty means KJV.
     - Returns: Zero-based internal index, or `nil` when the system or coordinate is invalid.
     - Side effects: Lazily expands and caches the requested canon.
     - Failure modes: Invalid fixture data and unsupported references return `nil`.
     */
    static func referenceIndex(
        for reference: SwordVersification.Reference,
        versification: String
    ) -> Int? {
        guard let fixture,
              let name = normalizedName(versification),
              let system = cache.system(named: name, fixture: fixture) else {
            return nil
        }
        return system.indexes[Coordinate(reference)]
    }

    /**
     Reports whether JSword can directly construct a `Verse` for the supplied coordinate.

     JSword's public `Verse` initializer accepts any nonnegative chapter and verse for a known
     `BibleBook`, even when that coordinate is absent from the source canon. Its ordinal becomes
     zero or noncanonical, strict conversion fails, and `VersificationConverter.convert` returns
     the original coordinate in the target versification as a non-authoritative fallback.

     - Parameters:
       - reference: Raw coordinate supplied to Android's public conversion boundary.
       - versification: JSword system name; empty means KJV.
     - Returns: `true` for a known JSword system and globally known OSIS book identifier when the
       chapter and verse are nonnegative; otherwise `false`.
     - Side effects: Lazily reads the bundled canon fixture.
     - Failure modes: Unknown systems or books and negative coordinates return `false`.
     */
    static func canConstructReference(
        _ reference: SwordVersification.Reference,
        versification: String
    ) -> Bool {
        guard reference.chapter >= 0,
              reference.verse >= 0,
              normalizedName(versification) != nil else {
            return false
        }
        return knownOSISBookIDs.contains(reference.osisBookId)
    }

    /**
     Returns JSword's ordinal index for a mapping-resource coordinate without verse-bound checks.

     JSword's mapping parser constructs `Verse` values directly. Its `getOrdinal` implementation
     validates the book and chapter array access but adds the supplied verse number without checking
     that it is within the chapter. A few checked-in Android resources rely on this behavior: for
     example, KJVA `Hos.1.14` aliases the canonical ordinal reached three positions beyond Hosea
     1:11. This API is intentionally parser-only; user and persistence inputs must use the strict
     `referenceIndex` boundary above.

     - Parameters:
       - reference: Raw coordinate read from a pinned JSword mapping resource.
       - versification: JSword system name; empty means KJV.
     - Returns: Zero-based JSword ordinal index, or `nil` when the book/chapter is invalid or the
       computed ordinal falls outside the canon.
     - Side effects: Lazily expands and caches the requested canon.
     - Failure modes: Negative verses, unknown systems, invalid chapters, and out-of-canon results
       return `nil`.
     */
    static func mappingReferenceIndex(
        for reference: SwordVersification.Reference,
        versification: String
    ) -> Int? {
        guard reference.verse >= 0,
              let fixture,
              let name = normalizedName(versification),
              let system = cache.system(named: name, fixture: fixture),
              let chapterIntroductionIndex = system.indexes[
                  Coordinate(
                      .init(
                          osisBookId: reference.osisBookId,
                          chapter: reference.chapter,
                          verse: 0
                      )
                  )
              ] else {
            return nil
        }
        let (index, overflow) = chapterIntroductionIndex.addingReportingOverflow(reference.verse)
        guard !overflow, system.references.indices.contains(index) else { return nil }
        return index
    }

    /**
     Returns the coordinate at one intro-inclusive JSword canon index.

     - Parameters:
       - index: Zero-based internal index returned by `referenceIndex`.
       - versification: JSword system name; empty means KJV.
     - Returns: Exact coordinate, or `nil` when the system or index is invalid.
     - Side effects: Lazily expands and caches the requested canon.
     - Failure modes: Invalid fixture data, unknown systems, and out-of-range indexes return `nil`.
     */
    static func reference(
        forIndex index: Int,
        versification: String
    ) -> SwordVersification.Reference? {
        guard index >= 0,
              let fixture,
              let name = normalizedName(versification),
              let system = cache.system(named: name, fixture: fixture),
              system.references.indices.contains(index) else {
            return nil
        }
        return system.references[index].reference
    }
}
