// SQLiteCommentaryBlockNavigator.swift -- Android linked-block navigation for SQLite commentary

import BibleCore
import Foundation
import SwordKit

/**
 Converts synchronized Bible coordinates at the SQLite commentary boundary.

 Android exposes MyBible and MySword commentaries as ordinary JSword passage books. Their keys live
 in KJVA even when the synchronized Bible uses another versification, so display and linked-block
 navigation must perform the same public conversion in opposite directions. This helper accepts
 only concrete KJVA verses because Android's commentary block walker treats introduction keys as
 empty separators when a custom SQLite backend cannot render them.
 */
enum SQLiteCommentaryReferenceRouter {
    /**
     Converts the active Bible coordinate to one concrete KJVA commentary verse.

     - Parameters:
       - reference: Exact coordinate owned by the active Bible versification.
       - sourceVersification: Active Bible's JSword versification name.
     - Returns: Concrete KJVA verse accepted by the SQLite commentary domain, or `nil`.
     - Side effects: Reads pinned versification resources.
     - Failure modes: Invalid source coordinates, unavailable mappings, chapter introductions, and
       coordinates outside KJVA fail closed without searching a neighboring verse.
     */
    static func kjvaReference(
        for reference: SwordVersification.Reference,
        sourceVersification: String
    ) -> JSwordKJVAVerseReference? {
        BibleReaderCommentaryVersificationRouter.resolve(
            reference: reference,
            from: sourceVersification,
            to: JSwordKJVAVersification.name
        ) { mapped in
            guard let coordinate = SQLiteReaderNavigationResolver.coordinate(
                osisBookId: mapped.osisBookId,
                chapter: mapped.chapter,
                verse: mapped.verse
            ) else {
                return nil
            }
            return JSwordKJVAVerseReference(
                osisId: coordinate.osisBookId,
                chapter: coordinate.chapter,
                verse: coordinate.verse,
                ordinal: coordinate.ordinal
            )
        }
    }

    /**
     Converts a KJVA commentary target back into the active Bible's address space.

     - Parameters:
       - reference: Concrete target returned by linked-block traversal.
       - destinationVersification: Active Bible's JSword versification name.
       - resolve: Exact active-Bible addressability check for the converted coordinate.
     - Returns: Destination-owned value supplied by `resolve`, or `nil`.
     - Side effects: Reads pinned versification resources and invokes `resolve` once.
     - Failure modes: Missing mappings and unaddressable destinations fail closed; no nearby Bible
       coordinate is substituted.
     */
    static func sourceReference<Value>(
        for reference: JSwordKJVAVerseReference,
        destinationVersification: String,
        resolve: (SwordVersification.Reference) -> Value?
    ) -> Value? {
        BibleReaderCommentaryVersificationRouter.resolve(
            reference: .init(
                osisBookId: reference.osisId,
                chapter: reference.chapter,
                verse: reference.verse
            ),
            from: JSwordKJVAVersification.name,
            to: destinationVersification,
            resolve: resolve
        )
    }
}

/** One resolved KJVA commentary block with Android-compatible range metadata. */
struct SQLiteCommentaryBlock: Equatable {
    /// First verse whose semantic commentary equals the selected entry.
    let start: JSwordKJVAVerseReference

    /// Last consecutive verse whose semantic commentary equals the selected entry.
    let end: JSwordKJVAVerseReference

    /// Plain semantic text used only for block equality.
    let comparableText: String

    /** User-visible range label using the static KJVA book names. */
    var name: String {
        let startName = Self.bookName(start.osisId)
        guard start != end else {
            return "\(startName) \(start.chapter):\(start.verse)"
        }
        if start.osisId == end.osisId, start.chapter == end.chapter {
            return "\(startName) \(start.chapter):\(start.verse)-\(end.verse)"
        }
        let endName = Self.bookName(end.osisId)
        return "\(startName) \(start.chapter):\(start.verse)-\(endName) \(end.chapter):\(end.verse)"
    }

    /** Resolves one canonical KJVA long name without consulting an active SWORD module. */
    private static func bookName(_ osisId: String) -> String {
        JSwordKJVAVersification.books.first { $0.osisId == osisId }?.longName ?? osisId
    }
}

/**
 Applies Android's linked-commentary block semantics to an immutable SQLite module handle.

 Traversal uses concrete KJVA verses, skips introduction ordinals, changes books only through the
 module's Android-compatible book inventory, and preserves Android's scripture/non-scripture scope.
 Rendering reads covering commentary content, converts valid OSIS to trimmed semantic plain text,
 and treats empty, malformed, cancelled, or transiently unreadable entries as block separators.
 */
struct SQLiteCommentaryBlockNavigator {
    /// Active validated SQLite commentary module.
    let module: BibleReaderSQLiteModuleHandle

    /**
     Resolves the equal-content block containing one KJVA verse.

     - Parameters identify one concrete KJVA verse.
     - Returns: Complete non-empty block, or nil when the selected verse has no renderable content.
     - Side effects: Performs operation-owned SQLite reads while expanding both block boundaries.
     - Failure modes: Individual query/markup failures act as empty separators and return nil when
       they affect the selected verse.
     */
    func block(
        osisId: String,
        chapter: Int,
        verse: Int
    ) -> SQLiteCommentaryBlock? {
        guard module.info.category == .commentary,
              let selected = reference(osisId: osisId, chapter: chapter, verse: verse) else {
            return nil
        }
        let block = resolver().block(containing: selected.ordinal)
        guard let content = block.content,
              let start = JSwordKJVAVersification.verseReference(ordinal: block.start),
              let end = JSwordKJVAVersification.verseReference(ordinal: block.end) else {
            return nil
        }
        return SQLiteCommentaryBlock(start: start, end: end, comparableText: content)
    }

    /**
     Resolves Android's previous or next non-empty linked commentary block.

     - Parameters:
       - osisId: Selected KJVA OSIS book id.
       - chapter: One-based selected chapter.
       - verse: One-based selected verse.
       - forward: True for next; false for previous.
     - Returns: Start verse of the adjacent non-empty block, or nil at a boundary.
     - Side effects: Performs lazy operation-owned SQLite reads through one render cache.
     - Failure modes: Invalid coordinates, wrong-category modules, and unreadable entries fail closed.
     */
    func adjacentBlockStart(
        osisId: String,
        chapter: Int,
        verse: Int,
        forward: Bool
    ) -> JSwordKJVAVerseReference? {
        guard module.info.category == .commentary,
              let selected = reference(osisId: osisId, chapter: chapter, verse: verse),
              let ordinal = resolver().adjacentBlockStart(
                  from: selected.ordinal,
                  forward: forward
              ) else {
            return nil
        }
        return JSwordKJVAVersification.verseReference(ordinal: ordinal)
    }

    /**
     Creates one resolver over Android-traversable concrete KJVA verse ordinals.

     - Returns: Resolver whose book transitions use the module's included-book inventory.
     - Side effects: Reads the immutable module book list once for this navigation action.
     - Failure modes: A book-list failure leaves the selected verse renderable but prevents
       traversal beyond it.
     */
    private func resolver() -> LinkedDocumentBlockResolver<Int> {
        let books = (try? module.bookList()) ?? []
        return LinkedDocumentBlockResolver(
            next: {
                Self.adjacentVerseOrdinal(after: $0, forward: true, books: books)
            },
            previous: {
                Self.adjacentVerseOrdinal(after: $0, forward: false, books: books)
            },
            render: { comparableText(at: $0) }
        )
    }

    /** Resolves and validates one concrete KJVA verse reference. */
    private func reference(
        osisId: String,
        chapter: Int,
        verse: Int
    ) -> JSwordKJVAVerseReference? {
        guard let ordinal = JSwordKJVAVersification.verseOrdinal(
            osisId: osisId,
            chapter: chapter,
            verse: verse
        ) else { return nil }
        return JSwordKJVAVersification.verseReference(ordinal: ordinal)
    }

    /**
     Returns Android's adjacent traversable verse for one SQLite commentary document.

     - Parameters:
       - ordinal: Current concrete KJVA verse ordinal.
       - forward: `true` for next and `false` for previous.
       - books: Included books in module order, calculated with Android's 1:1/1:2 probe rule.
     - Returns: Adjacent concrete KJVA verse, or `nil` at the current scripture-scope boundary.
     - Side effects: None.
     - Failure modes: Invalid coordinates and current books absent from the module inventory fail
       closed. Empty commentary rows remain traversal positions and are skipped by the block
       resolver, just as Android's walker does.
     */
    private static func adjacentVerseOrdinal(
        after ordinal: Int,
        forward: Bool,
        books: [BookInfo]
    ) -> Int? {
        guard let verse = JSwordKJVAVersification.verseReference(ordinal: ordinal),
              let bookIndex = books.firstIndex(where: { $0.osisId == verse.osisId }),
              let lastChapter = JSwordKJVAVersification.lastChapter(osisId: verse.osisId) else {
            return nil
        }

        if forward {
            guard let lastVerse = JSwordKJVAVersification.verseCount(
                osisId: verse.osisId,
                chapter: verse.chapter
            ) else { return nil }
            if verse.verse < lastVerse {
                return JSwordKJVAVersification.verseOrdinal(
                    osisId: verse.osisId,
                    chapter: verse.chapter,
                    verse: verse.verse + 1
                )
            }
            if verse.chapter < lastChapter {
                return JSwordKJVAVersification.verseOrdinal(
                    osisId: verse.osisId,
                    chapter: verse.chapter + 1,
                    verse: 1
                )
            }

            let isScripture = AndroidScriptureBookScope.isScripture(osisBookId: verse.osisId)
            for candidate in books.dropFirst(bookIndex + 1)
                where AndroidScriptureBookScope.isScripture(osisBookId: candidate.osisId)
                    == isScripture {
                if let candidateOrdinal = JSwordKJVAVersification.verseOrdinal(
                    osisId: candidate.osisId,
                    chapter: 1,
                    verse: 1
                ) {
                    return candidateOrdinal
                }
            }
            return nil
        }

        if verse.verse > 1 {
            return JSwordKJVAVersification.verseOrdinal(
                osisId: verse.osisId,
                chapter: verse.chapter,
                verse: verse.verse - 1
            )
        }
        if verse.chapter > 1,
           let previousChapterLastVerse = JSwordKJVAVersification.verseCount(
               osisId: verse.osisId,
               chapter: verse.chapter - 1
           ) {
            return JSwordKJVAVersification.verseOrdinal(
                osisId: verse.osisId,
                chapter: verse.chapter - 1,
                verse: previousChapterLastVerse
            )
        }

        let isScripture = AndroidScriptureBookScope.isScripture(osisBookId: verse.osisId)
        for candidate in books[..<bookIndex].reversed()
            where AndroidScriptureBookScope.isScripture(osisBookId: candidate.osisId)
                == isScripture {
            guard let candidateLastChapter = JSwordKJVAVersification.lastChapter(
                osisId: candidate.osisId
            ), let candidateLastVerse = JSwordKJVAVersification.verseCount(
                osisId: candidate.osisId,
                chapter: candidateLastChapter
            ) else {
                continue
            }
            if let candidateOrdinal = JSwordKJVAVersification.verseOrdinal(
                osisId: candidate.osisId,
                chapter: candidateLastChapter,
                verse: candidateLastVerse
            ) {
                return candidateOrdinal
            }
        }
        return nil
    }

    /** Renders one covering SQLite commentary row to Android-comparable plain text. */
    private func comparableText(at ordinal: Int) -> String? {
        guard let reference = JSwordKJVAVersification.verseReference(ordinal: ordinal),
              let content = try? module.verseContent(
                  osisId: reference.osisId,
                  chapter: reference.chapter,
                  verse: reference.verse
              ) else {
            return nil
        }
        let sourceXML = "<div>\(content.text)</div>"
        guard let fragment = try? SwordOSISFragmentProcessor.process(
            sourceXML: sourceXML,
            category: .commentary,
            moduleInitials: module.info.name
        ), let plainText = fragment.comparablePlainText?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !plainText.isEmpty else {
            return nil
        }
        return plainText
    }
}
