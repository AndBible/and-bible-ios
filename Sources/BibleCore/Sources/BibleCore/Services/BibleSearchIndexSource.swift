// BibleSearchIndexSource.swift -- backend-neutral streaming Bible search input

import Foundation
import CryptoKit
import SwordKit

/**
 One canonical verse emitted by an installed Bible backend for transactional Search indexing.

 The value separates canonical analyzer text, visible preview text, and lexical source markup.
 Android searches canonical JSword text but presents a fresh annotation-free OSIS projection, so
 merging those concerns lets rendered filters leak annotations into both behavior domains. Canonical
 coordinates remain mandatory because grouping and scope cannot depend on localized key text.
 */
public struct BibleSearchIndexEntry: Sendable, Equatable {
    /// Backend-local display key retained for result diagnostics and compatibility UI.
    public let displayKey: String

    /// JSword-compatible canonical body supplied to the module-language analyzer.
    public let indexText: String

    /// Android MultiSearch-compatible verse text stored for user-visible result previews.
    public let previewText: String

    /// Exact or format-converted lexical markup inspected for Strong's lemmas.
    public let sourceMarkup: String

    /// Rendered/tagged source text inspected for legacy inline Strong's markers.
    public let taggedText: String

    /// Canonical source ordinal used as a stable final tie-breaker.
    public let entryOrder: Int

    /// Zero-based traversal position used only for bounded progress reporting.
    public let sourcePosition: Int

    /// Canonical JSword OSIS book identifier.
    public let osisBookId: String

    /// Source-compatible user-visible book name.
    public let displayBook: String

    /// Strategy used to derive a locale-sensitive book name when presenting this row.
    public let bookNamePresentation: SearchBookNamePresentation

    /// One-based canonical chapter number.
    public let chapter: Int

    /// One-based canonical verse number.
    public let verse: Int

    /**
     Creates one immutable, backend-neutral Search row from a source cursor position.

     - Parameters:
       - displayKey: Backend display key retained for diagnostics and lexical-row joins.
       - indexText: Canonical verse body supplied to the module analyzer.
       - previewText: Annotation-free verse text persisted for Search presentation.
       - sourceMarkup: Exact lexical markup inspected for Strong's attributes.
       - taggedText: Rendered/tagged fallback inspected for legacy Strong's markers.
       - entryOrder: Stable source ordinal used as the final query-order tie breaker.
       - sourcePosition: Traversal position used only for bounded progress publication.
       - osisBookId: Locale-independent canonical JSword book identifier.
       - displayBook: Source name or canonical fallback persisted with the generated row.
       - chapter: One-based canonical chapter.
       - verse: One-based canonical verse.
       - bookNamePresentation: Strategy for deriving the user-visible book name at query time.
     - Side effects: None.
     - Failure modes: Input is retained verbatim; the index service rejects invalid/empty generations
       and source adapters omit invalid verse coordinates before initialization.
     */
    public init(
        displayKey: String,
        indexText: String,
        previewText: String,
        sourceMarkup: String,
        taggedText: String,
        entryOrder: Int,
        sourcePosition: Int,
        osisBookId: String,
        displayBook: String,
        chapter: Int,
        verse: Int,
        bookNamePresentation: SearchBookNamePresentation = .source
    ) {
        self.displayKey = displayKey
        self.indexText = indexText
        self.previewText = previewText
        self.sourceMarkup = sourceMarkup
        self.taggedText = taggedText
        self.entryOrder = entryOrder
        self.sourcePosition = sourcePosition
        self.osisBookId = osisBookId
        self.displayBook = displayBook
        self.bookNamePresentation = bookNamePresentation
        self.chapter = chapter
        self.verse = verse
    }
}

/**
 Streams canonical Bible verses into `SearchIndexService` without exposing backend implementation.

 Implementations must emit only real positive verse coordinates, preserve deterministic source order,
 and stop immediately when the consumer returns `false`. The service owns transactionality,
 cancellation, analyzer selection, Strong's extraction, and completion metadata.
 */
public protocol BibleSearchIndexSource: AnyObject {
    /// Installed-book metadata whose initials own every generated Search row.
    var searchIndexModuleInfo: ModuleInfo { get }

    /// Backend storage revision added to the durable metadata fingerprint.
    var searchIndexStorageRevision: String { get }

    /// Exact installed source generation that a completed index must match before use.
    var searchIndexSourceIdentity: SearchIndexSourceIdentity { get }

    /// Conservative traversal denominator used for pre-commit progress reporting.
    var searchIndexProgressTotal: Int { get }

    /// Whether a real verse with neither analyzable text nor Strong's tokens still receives an identity row.
    var searchIndexIncludesEmptyIndexText: Bool { get }

    /**
     Streams real canonical verses in deterministic source order.

     - Parameter consume: Synchronous consumer; return `false` to stop without reading another row.
     - Side effects: Reads the source backend and may temporarily move a SWORD cursor. Implementations
       restore mutable source state before returning.
     - Throws: Backend read/projection failures and errors thrown by `consume`.
     - Important: Implementations must not retain the consumer or materialize the complete Bible.
     */
    func forEachSearchIndexEntry(
        _ consume: (BibleSearchIndexEntry) throws -> Bool
    ) throws
}

/** Supplies the SWORD-compatible empty-entry policy to sources that do not override it. */
public extension BibleSearchIndexSource {
    /// By default, an otherwise empty row is omitted; independently extracted Strong's tokens retain it.
    var searchIndexIncludesEmptyIndexText: Bool { false }

    /// Metadata-only revision used by native SWORD sources; module-store notifications cover replacement.
    var searchIndexStorageRevision: String { "" }

    /**
     Derives a durable readiness identity from installed metadata and backend storage revision.

     - Returns: SHA-256 identity that changes when version, language, driver, versification, repository,
       history, or backend storage generation changes.
     - Side effects: None beyond reading immutable source metadata and the storage revision property.
     - Failure modes: None; empty optional metadata remains an explicit length-prefixed component.
     */
    var searchIndexSourceIdentity: SearchIndexSourceIdentity {
        let info = searchIndexModuleInfo
        let about = info.aboutMetadata
        let components = [
            info.name,
            info.version,
            info.language,
            info.moduleDriver,
            about.versification,
            about.swordVersionDate,
            about.repository,
            about.history.joined(separator: "\u{1f}"),
            searchIndexStorageRevision,
        ]
        let canonical = components.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        let fingerprint = SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return SearchIndexSourceIdentity(
            moduleName: info.name,
            version: info.version,
            fingerprint: fingerprint
        )
    }
}

/**
 Resolves installed Search sources with Android `Books.getBook` lookup precedence.

 Callers provide genuine SWORD sources first and Android-compatible SQLite sources second. A
 case-insensitive initials collision is removed from the secondary set so a real SWORD book owns the
 identity. Lookup then applies exact initials, exact full name with last-owner semantics, and finally
 insertion-order Java UTF-16 case-insensitive initials/full-name matching.
 */
public struct BibleSearchIndexSourceRegistry {
    /// Registered sources after SWORD-first collision filtering.
    private let sources: [any BibleSearchIndexSource]

    /**
     Creates one immutable Search source snapshot.

     - Parameters:
       - primarySources: Genuine SWORD Bible sources in Android registration order.
       - additionalSources: SQLite Bible sources in their library registration order.
     - Side effects: None; sources are retained without opening content connections.
     - Failure modes: Non-Bible sources are ignored. Java-equal secondary initials owned by a primary
       source are ignored so an adapter cannot shadow readable SWORD content.
     */
    public init(
        primarySources: [any BibleSearchIndexSource],
        additionalSources: [any BibleSearchIndexSource]
    ) {
        let primaryBibles = primarySources.filter {
            $0.searchIndexModuleInfo.category == .bible
        }
        let primaryIdentities = Set(primaryBibles.map {
            SQLiteDocumentIdentity($0.searchIndexModuleInfo.name)
        })
        let additionalBibles = additionalSources.filter {
            $0.searchIndexModuleInfo.category == .bible
                && !primaryIdentities.contains(
                    SQLiteDocumentIdentity($0.searchIndexModuleInfo.name)
                )
        }
        sources = primaryBibles + additionalBibles
    }

    /**
     Resolves one selected module without substituting an active or unrelated Bible.

     - Parameter name: Initials or full book name supplied by Search state or a bridge result.
     - Returns: The exact JSword-precedence source, or nil when the snapshot has no match.
     - Side effects: None.
     - Failure modes: Empty and unmatched names return nil.
     */
    public func source(named name: String) -> (any BibleSearchIndexSource)? {
        if let exactInitials = sources.first(where: {
            Self.javaStringEquals($0.searchIndexModuleInfo.name, name)
        }) {
            return exactInitials
        }
        if let exactFullName = sources.last(where: {
            Self.javaStringEquals($0.searchIndexModuleInfo.description, name)
        }) {
            return exactFullName
        }
        let identity = SQLiteDocumentIdentity(name)
        return sources.first {
            SQLiteDocumentIdentity($0.searchIndexModuleInfo.name) == identity
                || SQLiteDocumentIdentity($0.searchIndexModuleInfo.description) == identity
        }
    }

    /** Compares Java `String.equals` values by exact UTF-16 code units without normalization. */
    private static func javaStringEquals(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.elementsEqual(rhs.utf16)
    }
}

/** Adapts native SWORD verse cursors to the backend-neutral Search source contract. */
extension SwordModule: BibleSearchIndexSource {
    /// Exact installed SWORD metadata.
    public var searchIndexModuleInfo: ModuleInfo { info }

    /// Existing SWORD progress denominator retained for compatibility with current Search UI.
    public var searchIndexProgressTotal: Int { 31_102 }

    /**
     Streams structured Search text and exact lexical markup from one serialized SWORD cursor.

     - Parameter consume: Consumer called for every real positive verse; `false` stops iteration.
     - Side effects: Traverses the module under `SwordRuntime` and restores its original cursor.
     - Throws: Re-throws the first consumer failure after restoring the cursor.
     - Note: Malformed structured entries pass through the shared pinned-JSword repair ladder. An
       irreparable entry becomes empty instead of selecting rendered/stripped text or aborting the
       remaining Bible.
     */
    public func forEachSearchIndexEntry(
        _ consume: (BibleSearchIndexEntry) throws -> Bool
    ) throws {
        var iterationFailure: Error?
        let moduleInitials = info.name
        iterateAllSearchIndexEntries { key, text, rawEntry, osisFragment, sourceIndex in
            guard iterationFailure == nil else { return false }
            guard let verseKey = self.currentVerseKeyChildren(),
                  verseKey.chapter > 0,
                  verseKey.verse > 0,
                  !verseKey.osisBookName.isEmpty else {
                return true
            }

            let projectedText = SwordBibleSearchTextProjection.project(
                sourceXML: osisFragment,
                moduleInitials: moduleInitials
            )
            do {
                return try consume(BibleSearchIndexEntry(
                    displayKey: key,
                    indexText: projectedText.indexText,
                    previewText: projectedText.previewText,
                    sourceMarkup: rawEntry,
                    taggedText: text,
                    entryOrder: verseKey.index,
                    sourcePosition: sourceIndex,
                    osisBookId: verseKey.osisBookName,
                    displayBook: verseKey.bookName,
                    chapter: verseKey.chapter,
                    verse: verseKey.verse
                ))
            } catch {
                iterationFailure = error
                return false
            }
        }
        if let iterationFailure { throw iterationFailure }
    }
}

/** Adapts Android-compatible MyBible, MySword, and e-Sword Bibles to Search indexing. */
extension SQLiteDocumentModule: BibleSearchIndexSource {
    /// Canonical installed metadata, including repository-owned package initials when present.
    public var searchIndexModuleInfo: ModuleInfo { info }

    /// KJVA's addressable span pairs with emitted canonical ordinals for monotonic progress.
    public var searchIndexProgressTotal: Int { JSwordKJVAVersification.addressableOrdinalCount }

    /**
     Identifies the exact SQLite file generation without retaining an open database connection.

     Atomic replacements change the filesystem number or modification metadata even when module
     initials and declared version remain unchanged. The central module-store generation remains the
     authoritative invalidation boundary; this revision additionally prevents stale readiness when a
     source snapshot is compared directly.

     - Returns: Stable path, size, modification-bit-pattern, and filesystem-number components.
     - Side effects: Reads filesystem attributes without opening the SQLite database.
     - Failure modes: Missing attributes use explicit zero components; lifecycle generation
       invalidation remains fail-closed when the filesystem cannot expose a distinguishing revision.
     */
    public var searchIndexStorageRevision: String {
        let url = reader.metadata.sourceURL.standardizedFileURL
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let fileNumber = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        return "\(url.path)|\(size)|\(modified.bitPattern)|\(fileNumber)"
    }

    /// Every real SQLite row receives canonical metadata even when its index text is empty.
    public var searchIndexIncludesEmptyIndexText: Bool { true }

    /**
     Streams one source chapter at a time and projects every real row into KJVA Search identity.

     - Parameter consume: Consumer called once per valid present verse; `false` stops traversal.
     - Side effects: Opens operation-owned read-only SQLite connections for chapter enumeration and
       chapter content. No shared connection or whole-Bible row array is retained.
     - Throws: Reader failures and errors thrown by `consume`, including consumer-owned
       cancellation. Structured projection itself is nonthrowing and isolates irreparable rows as
       empty text through the shared JSword-compatible repair boundary.
     - Note: Coordinates outside the source format's KJVA map are omitted exactly as Android's
       KJVA-backed custom `SwordBook` omits keys it cannot construct.
     */
    public func forEachSearchIndexEntry(
        _ consume: (BibleSearchIndexEntry) throws -> Bool
    ) throws {
        guard info.category == .bible else { return }
        let moduleInitials = info.name
        // Drained per chapter: whole-Bible streaming otherwise accumulates every XML-projection
        // temporary until the indexing dispatch block finishes.
        try reader.forEachBibleChapter { sourceBook, chapter in
            try autoreleasepool {
                guard let osisBookId = osisId(forSourceBookNumber: sourceBook) else {
                    return true
                }
                for row in try reader.chapterContent(book: sourceBook, chapter: chapter) {
                    guard let ordinal = JSwordKJVAVersification.verseOrdinal(
                        osisId: osisBookId,
                        chapter: chapter,
                        verse: row.verse
                    ) else {
                        continue
                    }
                    let projectedText = SQLiteSearchTextProjection.project(
                        row.text,
                        moduleInitials: moduleInitials
                    )
                    let key = "\(osisBookId) \(chapter):\(row.verse)"
                    let shouldContinue = try consume(BibleSearchIndexEntry(
                        displayKey: key,
                        indexText: projectedText.indexText,
                        previewText: projectedText.previewText,
                        sourceMarkup: row.text,
                        taggedText: row.text,
                        entryOrder: ordinal,
                        sourcePosition: ordinal,
                        osisBookId: osisBookId,
                        displayBook: osisBookId,
                        chapter: chapter,
                        verse: row.verse,
                        bookNamePresentation: .localizedCanonical
                    ))
                    guard shouldContinue else { return false }
                }
                return true
            }
        }
    }
}

/** Projects SQLite source into separate canonical-index and visible-preview domains. */
private enum SQLiteSearchTextProjection {
    /**
     Returns Android-compatible Search text through the shared pinned-JSword repair boundary.

     - Parameters:
       - source: Exact transformed or plain source text returned by the format reader.
       - moduleInitials: Exact installed initials controlling pinned module-specific repair.
     - Returns: Canonical analyzer text and annotation-free preview text.
     - Side effects: Parses one bounded verse fragment in memory.
     - Failure modes: Irreparable source becomes an empty projection, matching JSword `OSISFilter`.
     - Note: Every format is structural-first because Android registers its Bible backends as OSIS,
       including e-Sword `.bbli`; no format falls back to rendered, stripped, or escaped literal text.
     */
    static func project(
        _ source: String,
        moduleInitials: String
    ) -> SwordBibleSearchTextProjection {
        SwordBibleSearchTextProjection.project(
            sourceXML: source,
            moduleInitials: moduleInitials
        )
    }
}
