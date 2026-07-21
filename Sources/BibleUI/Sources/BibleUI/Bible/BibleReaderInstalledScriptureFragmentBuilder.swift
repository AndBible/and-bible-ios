// BibleReaderInstalledScriptureFragmentBuilder.swift -- Backend-neutral Bible Multi fragments

import BibleCore
import BibleView
import Foundation
import SwordKit

/**
 Builds one Android-style Bible fragment from an exact installed SWORD or SQLite source.

 Callers supply references already owned by the selected target. The builder performs one bounded
 passage read, preserves source markup, validates canonical order, and emits source-owned identity.
 It never substitutes the active pane, a neighboring verse, or another backend.
 */
enum BibleReaderInstalledScriptureFragmentBuilder {
    /**
     Renders one target-owned passage into a Vue `OsisFragment`.

     - Parameters:
       - source: Exact installed Bible that owns every supplied reference.
       - references: Ordered concrete target references.
       - persistedOsisRef: Optional durable Android key retained instead of the normalized range.
       - requiresCompleteContent: When true, every requested reference must produce content;
         Compare passes false so an otherwise readable target may omit sparse rows.
     - Returns: Source-aware fragment, or nil when identity, ordering, content, or metadata fails.
     - Side effects: Performs one bounded source passage read and real book-list lookup. SWORD
       restores its cursor; SQLite uses operation-owned read-only connections batched by chapter.
     - Failure modes: Backend errors, noncanonical references, empty content, and encoding metadata
       failures return nil without fallback.
     */
    static func build(
        source: BibleReaderInstalledScriptureSource,
        references: [VerseKeyReference],
        persistedOsisRef: String? = nil,
        requiresCompleteContent: Bool
    ) -> OsisFragment? {
        guard let requestedFirst = references.first,
              let requestedLast = references.last,
              referencesAreCanonical(references, in: source),
              let passage = try? source.passage(
                  startOrdinal: requestedFirst.ordinal,
                  endOrdinal: requestedLast.ordinal
              ),
              !passage.verses.isEmpty else {
            return nil
        }

        if requiresCompleteContent,
           passage.verses.map(\.reference) != references {
            return nil
        }
        guard let first = passage.verses.first?.reference,
              let last = passage.verses.last?.reference else {
            return nil
        }
        let keyName: String
        let books: [BookInfo]
        do {
            guard let resolvedName = try source.displayName(start: first, end: last) else {
                return nil
            }
            keyName = resolvedName
            books = try source.bookList()
        } catch {
            return nil
        }

        let osisRef = persistedOsisRef?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? (first == last ? first.osisRef : "\(first.osisRef)-\(last.osisRef)")
        let xml = passage.verses.map { verse in
            "<verse osisID=\"\(verse.reference.osisRef)\" verseOrdinal=\"\(verse.reference.ordinal)\">\(verse.sourceXML) </verse>"
        }.joined()
        let firstBook = books.first {
            $0.osisId == first.osisBookId
        }
        return OsisFragment(
            xml: "<div>\(xml)</div>",
            key: "\(source.info.name)--\(osisRef)",
            keyName: keyName,
            v11n: source.versificationName,
            bookCategory: DocumentCategory.bible.rawValue,
            bookInitials: source.info.name,
            bookAbbreviation: source.abbreviation,
            osisRef: osisRef,
            isNewTestament: firstBook?.testament == 2,
            features: OsisFeatures(),
            hasStrongs: source.info.features.contains(.strongsNumbers),
            ordinalRange: [first.ordinal, last.ordinal],
            language: source.info.language.isEmpty ? "en" : source.info.language,
            direction: source.info.isRightToLeft ? "rtl" : "ltr"
        )
    }

    /** Validates strict ascending canonical references without tolerating an omitted real verse. */
    private static func referencesAreCanonical(
        _ references: [VerseKeyReference],
        in source: BibleReaderInstalledScriptureSource
    ) -> Bool {
        var previous: VerseKeyReference?
        for reference in references {
            guard source.verseReference(ordinal: reference.ordinal) == reference else {
                return false
            }
            if let previous,
               !source.isCanonicallyAdjacent(reference, after: previous) {
                return false
            }
            previous = reference
        }
        return true
    }
}

private extension String {
    /// Returns nil for an empty already-trimmed persistence key.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
