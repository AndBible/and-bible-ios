// SQLiteReaderDocumentContentBuilder.swift -- Android SQLite auxiliary document projection

import BibleCore
import Foundation
import SwordKit

/** Stable failure reasons for SQLite commentary and dictionary document construction. */
enum SQLiteReaderDocumentContentError: Error, Equatable {
    /// The exact requested key is valid but has no renderable source content.
    case noContent

    /// The source markup cannot be represented by the native OSIS bridge contract.
    case invalidMarkup
}

/** One complete SQLite auxiliary document ready for Vue payload serialization. */
struct BibleReaderSQLiteAuxiliaryDocument {
    /// Source-aware payload request consumed by the existing document factory.
    let request: BibleReaderDocumentPayloadRequest

    /// Exact source key retained in rendered state and pane persistence.
    let key: String

    /// User-visible key label.
    let keyName: String
}

/**
 Builds Android-compatible commentary and dictionary documents from immutable SQLite handles.

 Commentary lookup uses the reader's covering-range query for the selected KJVA verse. Dictionary
 lookup is byte-exact and never snaps case or prefixes. Both paths run source markup through the
 shared structural OSIS processor so visible text, bookmark anchors, copy, and speech observe the
 same preserved content.
 */
struct SQLiteReaderDocumentContentBuilder {
    let module: BibleReaderSQLiteModuleHandle

    /**
     Builds the covering commentary content for one exact KJVA verse.

     - Parameters:
       - osisBookId: Canonical KJVA OSIS book identifier.
       - bookName: User-visible Bible book name.
       - chapter: One-based chapter.
       - verse: One-based selected verse.
       - isNewTestament: Whether the selected book belongs to the New Testament.
     - Returns: Source-aware commentary payload using the exact requested verse identity.
     - Side effects: Performs operation-owned SQLite covering-range lookups.
     - Throws: Reader failures, `.noContent` for absent/empty rows, or `.invalidMarkup` when source
       markup cannot be represented without fabrication.
     */
    func commentary(
        osisBookId: String,
        bookName: String,
        chapter: Int,
        verse: Int,
        isNewTestament: Bool
    ) throws -> BibleReaderSQLiteAuxiliaryDocument {
        guard let coordinate = SQLiteReaderNavigationResolver.coordinate(
            osisBookId: osisBookId,
            chapter: chapter,
            verse: verse
        ), let content = try module.verseContent(
            osisId: osisBookId,
            chapter: chapter,
            verse: verse
        ) else {
            throw SQLiteReaderDocumentContentError.noContent
        }
        let fragment = try processedFragment(content.text, category: .commentary)
        let commentaryBlock = SQLiteCommentaryBlockNavigator(module: module).block(
            osisId: osisBookId,
            chapter: chapter,
            verse: verse
        )
        let source = BibleReaderSQLiteSourceMetadata(module: module)
        let key = coordinate.osisKey
        let keyName = "\(bookName) \(chapter):\(verse)"
        return BibleReaderSQLiteAuxiliaryDocument(
            request: BibleReaderDocumentPayloadRequest(
                osisBookId: osisBookId,
                bookName: keyName,
                chapter: chapter,
                verseCount: 1,
                isNewTestament: isNewTestament,
                xml: fragment.xml,
                bookCategory: DocumentCategory.commentary.rawValue,
                bookInitials: source.initials,
                addChapter: false,
                documentKey: key,
                keyName: keyName,
                ordinalRangeOverride: [
                    fragment.contentOrdinalRange.lowerBound,
                    fragment.contentOrdinalRange.upperBound,
                ],
                fragmentOrdinalRange: [coordinate.ordinal, coordinate.ordinal],
                fragmentKey: "\(source.initials)--\(key)",
                fragmentOsisRef: key,
                annotateRef: fragment.annotateRef,
                commentaryRange: ReaderCommentaryRangePayload(
                    startOsisRef: commentaryBlock?.start.osisRef ?? key,
                    endOsisRef: commentaryBlock?.end.osisRef ?? key,
                    name: commentaryBlock?.name ?? keyName
                ),
                moduleName: source.name,
                moduleAbbreviation: source.abbreviation,
                versificationName: source.versification,
                language: source.language,
                direction: source.direction,
                sourceHasStrongs: source.hasStrongs
            ),
            key: key,
            keyName: keyName
        )
    }

    /**
     Builds one byte-exact dictionary entry using its source-order key ordinal.

     - Parameter key: Exact chooser key; case and leading zeroes are significant.
     - Returns: Source-aware dictionary payload whose persisted key is unchanged.
     - Side effects: Performs key enumeration and exact lookup on operation-owned connections.
     - Throws: Reader failures, `.noContent` for a missing/empty exact key, or `.invalidMarkup` for
       malformed source markup.
     */
    func dictionary(key: String) throws -> BibleReaderSQLiteAuxiliaryDocument {
        let keys = try module.dictionaryKeys()
        guard let sourceKey = BibleReaderSQLiteDictionaryChooser.exactSourceKey(
            matching: key,
            in: keys
        ), let content = try module.dictionaryContent(for: sourceKey) else {
            throw SQLiteReaderDocumentContentError.noContent
        }
        let fragment = try processedFragment(content.text, category: .dictionary)
        let source = BibleReaderSQLiteSourceMetadata(module: module)
        return BibleReaderSQLiteAuxiliaryDocument(
            request: BibleReaderDocumentPayloadRequest(
                osisBookId: "Dict",
                bookName: source.name,
                chapter: 1,
                verseCount: 1,
                isNewTestament: false,
                xml: fragment.xml,
                bookCategory: DocumentCategory.dictionary.rawValue,
                bookInitials: source.initials,
                addChapter: false,
                documentKey: sourceKey,
                keyName: sourceKey,
                ordinalRangeOverride: [
                    fragment.contentOrdinalRange.lowerBound,
                    fragment.contentOrdinalRange.upperBound,
                ],
                fragmentKey: "\(source.initials)--\(sourceKey)",
                annotateRef: fragment.annotateRef,
                fragmentFeatures: ["keyName": sourceKey],
                moduleName: source.name,
                moduleAbbreviation: source.abbreviation,
                language: source.language,
                direction: source.direction,
                sourceHasStrongs: source.hasStrongs
            ),
            key: sourceKey,
            keyName: sourceKey
        )
    }

    /**
     Parses, anchors, and validates one source fragment without replacing malformed content.

     - Parameters:
       - text: Exact SQLite source markup returned for the selected key.
       - category: Commentary or dictionary structural-processing category.
     - Returns: Renderable anchored OSIS fragment preserving source text and local ordinals.
     - Side effects: None beyond deterministic in-memory XML parsing.
     - Throws: `.noContent` for empty/nonrenderable fragments and `.invalidMarkup` when structural
       processing fails; no escaped/plain-text substitute is generated.
     */
    private func processedFragment(
        _ text: String,
        category: ModuleCategory
    ) throws -> SwordProcessedOSISFragment {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SQLiteReaderDocumentContentError.noContent }
        let sourceXML = "<div>\(trimmed)</div>"
        guard let fragment = try? SwordOSISFragmentProcessor.process(
            sourceXML: sourceXML,
            category: category,
            moduleInitials: module.info.name
        ) else {
            throw SQLiteReaderDocumentContentError.invalidMarkup
        }
        guard fragment.hasRenderableContent else {
            throw SQLiteReaderDocumentContentError.noContent
        }
        return fragment
    }
}
