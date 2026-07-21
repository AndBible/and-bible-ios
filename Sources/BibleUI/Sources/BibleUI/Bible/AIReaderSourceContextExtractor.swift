// AIReaderSourceContextExtractor.swift -- Immutable Android-parity reader source capture

import BibleCore
import Foundation
import SwordKit

/**
 Numeric source endpoints proven small enough for synchronous reader extraction.

 Construction is confined to `AIReaderSourceRange`; callers pass raw bridge endpoints so an
 excessive value such as `Int.max` is rejected before a `ClosedRange` is formed or iterated.
 */
struct AIReaderSourceBounds: Equatable, Sendable {
  /// Inclusive first source ordinal.
  let start: Int

  /// Inclusive last source ordinal.
  let end: Int

  /// Inclusive ordinal count, computed only after overflow-safe validation.
  let count: Int

  /// Inclusive range for immutable context values after backend addressability is proven.
  var closedRange: ClosedRange<Int> { start...end }
}

/** Shared bounded-work validation for native AI source requests. */
enum AIReaderSourceRange {
  /// Maximum inclusive source-ordinal span read synchronously for one AI action.
  static let maximumVerseCount = 500

  /**
   Validates raw Bible bridge endpoints without constructing or iterating a range.

   - Parameters:
     - start: Inclusive source-versification start ordinal.
     - end: Inclusive source-versification end ordinal.
   - Returns: Bounded endpoints, or `nil` for zero, reverse, overflow-prone, or excessive spans.
   - Side effects: None.
   - Failure modes: Invalid numeric endpoints fail closed before backend work begins.
   */
  static func bibleBounds(start: Int, end: Int) -> AIReaderSourceBounds? {
    bounded(start: start, end: end, minimum: 1)
  }

  /**
   Validates generic local-anchor endpoints without changing their zero-based domain.

   - Parameters:
     - start: Inclusive local `BVA` start ordinal.
     - end: Inclusive local `BVA` end ordinal.
   - Returns: Bounded endpoints, or `nil` for negative, reverse, or excessive spans.
   - Side effects: None.
   - Failure modes: Invalid numeric endpoints fail closed before range construction.
   */
  static func genericBounds(start: Int, end: Int) -> AIReaderSourceBounds? {
    bounded(start: start, end: end, minimum: 0)
  }

  /** Performs overflow-safe inclusive-count validation for one ordinal domain. */
  private static func bounded(
    start: Int,
    end: Int,
    minimum: Int
  ) -> AIReaderSourceBounds? {
    guard start >= minimum, end >= start, end < Int.max else { return nil }
    let distance = end - start
    guard distance < maximumVerseCount else { return nil }
    return AIReaderSourceBounds(start: start, end: end, count: distance + 1)
  }
}

/**
 Captured reader source supplied to Android-compatible AI actions.

 Source identity, source-versification passage identity, optional KJVA cache identity, canonical
 text, and structured content remain separate. A failed canonical projection never discards valid
 OSIS, and malformed OSIS never relabels or discards a valid source/canonical projection.
 */
struct AIReaderSourceContext: Equatable, Sendable {
  /// Exact installed document initials that produced this capture.
  let sourceDocumentInitials: String

  /// Exact current page key in the source document's key domain.
  let sourceBookKey: String

  /// Source-versification OSIS passage used for Bible prompt/reference lookup.
  let sourceOSISRange: String?

  /// Canonical structured source; independently optional when source conversion or parsing fails.
  let selectedContent: String?

  /// Canonical Bible text, or Android's exact empty string for generic documents.
  let selectedText: String?

  /// Inclusive source-versification Bible range, or `nil` for generic documents.
  let sourceOrdinalRange: ClosedRange<Int>?
}

/** Exact source request accepted by both SWORD and SQLite Bible backends. */
enum AIReaderBibleSourceRequest: Equatable, Sendable {
  /// Whole current chapter with its independent pane page key.
  case page(sourceBookKey: String, osisBookId: String, chapter: Int)

  /// Exact bridge/bookmark source range; page key is optional outside a pane.
  case selection(sourceBookKey: String?, startOrdinal: Int, endOrdinal: Int)
}

/**
 Reads immutable AI context from the same SWORD, SQLite, My Documents, and EPUB sources as the pane.

 SWORD Bible extraction uses source-format conversion under one cursor-restoring lease. SQLite
 selections reuse one chapter query per touched chapter. My Documents and EPUB reads verify the
 exact page generation again before publishing a result.
 */
enum AIReaderSourceContextExtractor {
  /** One exact Bible verse copied from an immutable source capture. */
  private struct BibleVerseContent {
    let osisBookId: String
    let chapter: Int
    let verse: Int
    let ordinal: Int
    let xml: String?

    var osisRef: String { "\(osisBookId).\(chapter).\(verse)" }
  }

  /** Hashable chapter identity used to reuse one SQLite query across a selected range. */
  private struct SQLiteChapterIdentity: Hashable {
    let osisBookId: String
    let chapter: Int
  }

  /** Immutable My Documents page generation checked before and after markup processing. */
  private struct MyDocumentPageGeneration: Equatable {
    let id: UUID
    let pageKey: String
    let contentTypeRawValue: String
    let content: String
    let title: String
    let updatedAt: Date
  }

  /**
   Captures a SWORD Bible chapter or exact source-versification selection.

   - Parameters:
     - module: Exact Bible module instance supplied by the controller.
     - request: Raw page or selection identity; selection endpoints remain unconstructed here.
   - Returns: Source identity with independently optional canonical text and structured OSIS.
   - Side effects: Performs one bounded, serialized SWORD inspection and restores its cursor.
   - Failure modes: Wrong categories, invalid pages, excessive/non-addressable endpoints, empty
     chapters, and cursor-restoration failures return `nil`.
   */
  static func swordBible(
    module: SwordModule,
    request: AIReaderBibleSourceRequest
  ) -> AIReaderSourceContext? {
    guard module.info.category == .bible else { return nil }

    let sourceBookKey: String?
    let bounds: AIReaderSourceBounds
    switch request {
    case .page(let pageKey, let osisBookId, let chapter):
      guard !pageKey.isEmpty, !osisBookId.isEmpty, chapter > 0,
        let verseCount = module.verseCount(osisBookId: osisBookId, chapter: chapter),
        verseCount > 0,
        let firstOrdinal = module.verseOrdinal(
          osisBookId: osisBookId,
          chapter: chapter,
          verse: 1
        ),
        let lastOrdinal = module.verseOrdinal(
          osisBookId: osisBookId,
          chapter: chapter,
          verse: verseCount
        ),
        let validated = AIReaderSourceRange.bibleBounds(
          start: firstOrdinal,
          end: lastOrdinal
        )
      else {
        return nil
      }
      sourceBookKey = pageKey
      bounds = validated

    case .selection(let pageKey, let startOrdinal, let endOrdinal):
      guard let validated = AIReaderSourceRange.bibleBounds(
        start: startOrdinal,
        end: endOrdinal
      ) else {
        return nil
      }
      sourceBookKey = pageKey
      bounds = validated
    }

    guard let capture = try? module.inspectVerseSourceRangeRestoringPrevious(
      startOrdinal: bounds.start,
      endOrdinal: bounds.end,
      maximumVerseCount: AIReaderSourceRange.maximumVerseCount
    ) else {
      return nil
    }
    let verses = capture.entries.map { entry in
      BibleVerseContent(
        osisBookId: entry.reference.osisBookId,
        chapter: entry.reference.chapter,
        verse: entry.reference.verse,
        ordinal: entry.reference.ordinal,
        xml: entry.osisFragment
      )
    }
    guard !verses.isEmpty else { return nil }

    return bibleContext(
      sourceDocumentInitials: module.info.name,
      sourceBookKey: sourceBookKey ?? capture.sourceOSISRange,
      sourceOSISRange: capture.sourceOSISRange,
      verses: verses,
      sourceOrdinalRange: bounds.closedRange,
      canonicalText: capture.canonicalText
    )
  }

  /**
   Captures a KJVA-backed SQLite Bible chapter or exact source range.

   - Parameters:
     - module: Exact immutable SQLite module handle.
     - request: Raw page or selection identity.
   - Returns: Source identity with independently projected canonical text and structured OSIS.
   - Side effects: Executes at most one read-only chapter query per touched chapter.
   - Failure modes: Invalid/non-addressable endpoints, excessive spans, query errors, and absent
     endpoint rows fail closed before an ordinal range is published.
   */
  static func sqliteBible(
    module: BibleReaderSQLiteModuleHandle,
    request: AIReaderBibleSourceRequest
  ) -> AIReaderSourceContext? {
    guard module.info.category == .bible else { return nil }

    switch request {
    case .page(let sourceBookKey, let osisBookId, let chapter):
      guard !sourceBookKey.isEmpty, !osisBookId.isEmpty, chapter > 0,
        let rows = try? module.chapterContent(osisId: osisBookId, chapter: chapter)
      else {
        return nil
      }
      let textByVerse = firstSQLiteTextByVerse(rows)
      let verses = textByVerse.keys.sorted().compactMap { verse -> BibleVerseContent? in
        guard let text = textByVerse[verse],
          let coordinate = SQLiteReaderNavigationResolver.coordinate(
            osisBookId: osisBookId,
            chapter: chapter,
            verse: verse
          )
        else {
          return nil
        }
        return sqliteVerse(
          module: module,
          osisBookId: osisBookId,
          chapter: chapter,
          verse: verse,
          ordinal: coordinate.ordinal,
          text: text
        )
      }
      guard let first = verses.first, let last = verses.last,
        let bounds = AIReaderSourceRange.bibleBounds(start: first.ordinal, end: last.ordinal)
      else {
        return nil
      }
      return bibleContext(
        sourceDocumentInitials: module.info.name,
        sourceBookKey: sourceBookKey,
        sourceOSISRange: osisRange(start: first.osisRef, end: last.osisRef),
        verses: verses,
        sourceOrdinalRange: bounds.closedRange,
        canonicalText: canonicalBibleText(
          verses,
          moduleInitials: module.info.name
        )
      )

    case .selection(let pageKey, let startOrdinal, let endOrdinal):
      guard let bounds = AIReaderSourceRange.bibleBounds(
        start: startOrdinal,
        end: endOrdinal
      ), let startReference = JSwordKJVAVersification.verseReference(ordinal: bounds.start),
        let endReference = JSwordKJVAVersification.verseReference(ordinal: bounds.end)
      else {
        return nil
      }

      var references: [JSwordKJVAVerseReference] = []
      references.reserveCapacity(bounds.count)
      for offset in 0..<bounds.count {
        if let reference = JSwordKJVAVersification.verseReference(
          ordinal: bounds.start + offset
        ) {
          references.append(reference)
        }
      }

      var rowsByChapter: [SQLiteChapterIdentity: [Int: String]] = [:]
      for reference in references {
        let identity = SQLiteChapterIdentity(
          osisBookId: reference.osisId,
          chapter: reference.chapter
        )
        guard rowsByChapter[identity] == nil else { continue }
        guard let rows = try? module.chapterContent(
          osisId: reference.osisId,
          chapter: reference.chapter
        ) else {
          return nil
        }
        rowsByChapter[identity] = firstSQLiteTextByVerse(rows)
      }

      let startIdentity = SQLiteChapterIdentity(
        osisBookId: startReference.osisId,
        chapter: startReference.chapter
      )
      let endIdentity = SQLiteChapterIdentity(
        osisBookId: endReference.osisId,
        chapter: endReference.chapter
      )
      guard rowsByChapter[startIdentity]?[startReference.verse] != nil,
        rowsByChapter[endIdentity]?[endReference.verse] != nil
      else {
        return nil
      }

      let verses = references.compactMap { reference -> BibleVerseContent? in
        let identity = SQLiteChapterIdentity(
          osisBookId: reference.osisId,
          chapter: reference.chapter
        )
        guard let text = rowsByChapter[identity]?[reference.verse] else { return nil }
        return sqliteVerse(
          module: module,
          osisBookId: reference.osisId,
          chapter: reference.chapter,
          verse: reference.verse,
          ordinal: reference.ordinal,
          text: text
        )
      }
      guard !verses.isEmpty else { return nil }
      let sourceOSISRange = osisRange(
        start: startReference.osisRef,
        end: endReference.osisRef
      )
      return bibleContext(
        sourceDocumentInitials: module.info.name,
        sourceBookKey: pageKey ?? sourceOSISRange,
        sourceOSISRange: sourceOSISRange,
        verses: verses,
        sourceOrdinalRange: bounds.closedRange,
        canonicalText: canonicalBibleText(
          verses,
          moduleInitials: module.info.name
        )
      )
    }
  }

  /**
   Captures one exact generic SWORD entry without treating raw source bytes as OSIS.

   - Parameters:
     - module: Exact installed generic module.
     - key: Byte-exact current source key, including meaningful whitespace.
   - Returns: Source-filtered, generic-anchor content and Android's empty selected text.
   - Side effects: Temporarily moves and restores the module cursor in `rawOSISFragment`.
   - Failure modes: Missing/snapped keys fail closed. A proven exact key with malformed converted
     OSIS survives with `selectedContent == nil`.
   */
  static func swordDocument(module: SwordModule, key: String) -> AIReaderSourceContext? {
    do {
      let fragment = try module.rawOSISFragment(forKey: key)
      return genericContext(
        sourceDocumentInitials: fragment.source.initials,
        sourceBookKey: fragment.osisRef,
        selectedContent: fragment.xml.isEmpty ? nil : fragment.xml
      )
    } catch SwordRawOSISFragmentError.malformedOSIS(let resolvedKey, _) {
      guard resolvedKey == key else { return nil }
      return genericContext(
        sourceDocumentInitials: module.info.name,
        sourceBookKey: key,
        selectedContent: nil
      )
    } catch {
      return nil
    }
  }

  /**
   Captures one exact SQLite commentary source row.

   - Parameters describe the exact selected KJVA verse.
   - Returns: Generic anchored content when parsing succeeds; source identity and empty selected
     text remain available when structural parsing fails.
   - Side effects: Executes one operation-owned SQLite lookup.
   - Failure modes: Invalid coordinates, absent rows, and database failures return `nil`.
   */
  static func sqliteCommentary(
    module: BibleReaderSQLiteModuleHandle,
    osisBookId: String,
    bookName _: String,
    chapter: Int,
    verse: Int,
    isNewTestament _: Bool
  ) -> AIReaderSourceContext? {
    guard module.info.category == .commentary,
      let coordinate = SQLiteReaderNavigationResolver.coordinate(
        osisBookId: osisBookId,
        chapter: chapter,
        verse: verse
      ), let content = try? module.verseContent(
        osisId: osisBookId,
        chapter: chapter,
        verse: verse
      )
    else {
      return nil
    }
    return genericContext(
      sourceDocumentInitials: module.info.name,
      sourceBookKey: coordinate.osisKey,
      selectedContent: processedGenericContent(
        content.text,
        category: .commentary,
        moduleInitials: module.info.name
      )
    )
  }

  /**
   Captures one byte-exact SQLite dictionary entry.

   - Parameters:
     - module: Exact immutable SQLite dictionary handle.
     - key: Case- and whitespace-sensitive source key.
   - Returns: Generic anchored content when parsing succeeds; malformed content remains a valid
     identity with empty selected text and absent structured content.
   - Side effects: Enumerates source keys and executes one exact read-only lookup.
   - Failure modes: Missing keys and database failures return `nil` without key normalization.
   */
  static func sqliteDictionary(
    module: BibleReaderSQLiteModuleHandle,
    key: String
  ) -> AIReaderSourceContext? {
    guard module.info.category == .dictionary,
      let keys = try? module.dictionaryKeys(),
      keys.contains(key),
      let content = try? module.dictionaryContent(for: key)
    else {
      return nil
    }
    return genericContext(
      sourceDocumentInitials: module.info.name,
      sourceBookKey: key,
      selectedContent: processedGenericContent(
        content.text,
        category: .dictionary,
        moduleInitials: module.info.name
      )
    )
  }

  /**
   Captures one exact My Documents page and verifies its generation after processing.

   - Parameters:
     - store: Reader's SwiftData-backed page store.
     - bookInitials: Exact parent document initials.
     - pageKey: Exact parent-scoped key, including meaningful whitespace.
   - Returns: Anchored generic source, or valid identity with absent content for malformed markup.
   - Side effects: Performs two exact SwiftData reads and deterministic in-memory rendering.
   - Failure modes: Missing, duplicate, changed, or unreadable page generations return `nil`.
   */
  static func myDocument(
    store: MyDocumentStore,
    bookInitials: String,
    pageKey: String
  ) -> AIReaderSourceContext? {
    guard let before = try? store.exactPage(bookInitials: bookInitials, pageKey: pageKey) else {
      return nil
    }
    let generation = myDocumentGeneration(before)
    let selectedContent = MyDocumentContentType(rawValue: generation.contentTypeRawValue)
      .flatMap { contentType in
        try? SwordOSISFragmentProcessor.process(
          sourceXML: MyDocumentContentRenderer.render(
            generation.content,
            contentType: contentType
          ),
          category: .generalBook,
          moduleInitials: bookInitials
        ).xml
      }
    guard let after = try? store.exactPage(bookInitials: bookInitials, pageKey: pageKey),
      myDocumentGeneration(after) == generation
    else {
      return nil
    }
    return genericContext(
      sourceDocumentInitials: bookInitials,
      sourceBookKey: pageKey,
      selectedContent: selectedContent
    )
  }

  /**
   Captures one exact page from an immutable EPUB generation.

   - Parameters:
     - reader: Exact retained EPUB generation.
     - key: Canonical persisted key; aliases and surrounding whitespace are rejected.
   - Returns: Native XHTML plus Android's empty selected text.
   - Side effects: Reads the retained read-only EPUB index twice to prove stable identity/content.
   - Failure modes: Missing, noncanonical, changed, or unreadable pages return `nil`.
   */
  static func epub(reader: EpubReader, key: String) -> AIReaderSourceContext? {
    guard let before = try? reader.exactContent(forPersistedKey: key),
      let after = try? reader.exactContent(forPersistedKey: key),
      before == after
    else {
      return nil
    }
    return genericContext(
      sourceDocumentInitials: reader.initials,
      sourceBookKey: before.persistedKey,
      selectedContent: before.html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? nil
        : before.html
    )
  }

  /** Projects one SQLite row into source XML without performing a per-verse text projection. */
  private static func sqliteVerse(
    module: BibleReaderSQLiteModuleHandle,
    osisBookId: String,
    chapter: Int,
    verse: Int,
    ordinal: Int,
    text: String
  ) -> BibleVerseContent {
    let projected = SQLiteReaderMarkupProjection.bibleVerseXML(text, module: module)
    return BibleVerseContent(
      osisBookId: osisBookId,
      chapter: chapter,
      verse: verse,
      ordinal: ordinal,
      xml: SQLiteDocumentXMLCompatibility.validatedFragmentOrEscapedText(projected)
    )
  }

  /** Keeps the first source row for each SQLite verse, matching the chapter renderer. */
  private static func firstSQLiteTextByVerse(
    _ rows: [(verse: Int, text: String)]
  ) -> [Int: String] {
    var result: [Int: String] = [:]
    for row in rows where row.verse > 0 && result[row.verse] == nil {
      result[row.verse] = row.text
    }
    return result
  }

  /**
   Builds one Bible context while keeping canonical and structured projections independent.

   Bible uses `originalXML`, captured before the generic sentence-anchor pass, so `BVA` never enters
   canonical Bible OSIS. Source identity and ordinals survive even when either projection is absent.
   */
  private static func bibleContext(
    sourceDocumentInitials: String,
    sourceBookKey: String,
    sourceOSISRange: String,
    verses: [BibleVerseContent],
    sourceOrdinalRange: ClosedRange<Int>,
    canonicalText: String?
  ) -> AIReaderSourceContext {
    let selectedContent: String?
    if verses.allSatisfy({ $0.xml != nil }) {
      let verseXML = verses.compactMap { verse in
        verse.xml.map {
          "<verse osisID=\"\(verse.osisRef)\" verseOrdinal=\"\(verse.ordinal)\">\($0)</verse>"
        }
      }.joined()
      selectedContent = try? SwordOSISFragmentProcessor.process(
        sourceXML: "<div>\(verseXML)</div>",
        category: .bible,
        moduleInitials: sourceDocumentInitials
      ).originalXML
    } else {
      selectedContent = nil
    }
    return AIReaderSourceContext(
      sourceDocumentInitials: sourceDocumentInitials,
      sourceBookKey: sourceBookKey,
      sourceOSISRange: sourceOSISRange,
      selectedContent: selectedContent,
      selectedText: canonicalText,
      sourceOrdinalRange: sourceOrdinalRange
    )
  }

  /**
   Creates one canonical projection over the complete SQLite passage.

   - Parameters:
     - verses: Source XML rows in exact verse order.
     - moduleInitials: Exact SQLite module identity used by source-specific XML repair.
   - Returns: One globally normalized visible-text projection, or `nil` when any source row or the
     combined XML cannot be processed.
   - Side effects: Parses copied XML in memory; no backend or reader state is mutated.
   - Failure modes: Missing/malformed source XML remains independently absent from structured OSIS.
   */
  private static func canonicalBibleText(
    _ verses: [BibleVerseContent],
    moduleInitials: String
  ) -> String? {
    let sourcePieces = verses.compactMap(\.xml)
    guard !sourcePieces.isEmpty, sourcePieces.count == verses.count,
      let processed = try? SwordOSISFragmentProcessor.process(
        sourceXML: "<div>\(sourcePieces.joined(separator: " "))</div>",
        category: .bible,
        moduleInitials: moduleInitials
      )
    else {
      return nil
    }
    return processed.comparablePlainText
  }

  /** Formats a source-versification OSIS identity without consulting KJVA. */
  private static func osisRange(start: String, end: String) -> String {
    start == end ? start : "\(start)-\(end)"
  }

  /** Processes generic source markup; malformed XML remains an independently absent projection. */
  private static func processedGenericContent(
    _ source: String,
    category: ModuleCategory,
    moduleInitials: String
  ) -> String? {
    guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return try? SwordOSISFragmentProcessor.process(
      sourceXML: "<div>\(source)</div>",
      category: category,
      moduleInitials: moduleInitials
    ).xml
  }

  /** Creates a generic context with exact identity and Android's strict-cache empty selected text. */
  private static func genericContext(
    sourceDocumentInitials: String,
    sourceBookKey: String,
    selectedContent: String?
  ) -> AIReaderSourceContext {
    AIReaderSourceContext(
      sourceDocumentInitials: sourceDocumentInitials,
      sourceBookKey: sourceBookKey,
      sourceOSISRange: nil,
      selectedContent: selectedContent,
      selectedText: "",
      sourceOrdinalRange: nil
    )
  }

  /** Copies mutation-sensitive My Documents fields into an immutable generation token. */
  private static func myDocumentGeneration(
    _ page: MyDocumentPage
  ) -> MyDocumentPageGeneration {
    MyDocumentPageGeneration(
      id: page.id,
      pageKey: page.pageKey,
      contentTypeRawValue: page.contentTypeRawValue,
      content: page.pageContent?.content ?? "",
      title: page.title,
      updatedAt: page.updatedAt
    )
  }
}
