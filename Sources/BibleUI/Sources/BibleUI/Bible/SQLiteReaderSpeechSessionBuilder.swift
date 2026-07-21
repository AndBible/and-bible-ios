// SQLiteReaderSpeechSessionBuilder.swift -- Speech sessions for Android SQLite modules

import BibleCore
import Foundation
import SwordKit

/**
 Builds source-owned speech sessions for MyBible, MySword, and e-Sword modules.

 Every lazy content read goes through `BibleReaderSQLiteModuleHandle` on an operation-owned
 connection, so AVFoundation callbacks and reader rendering can overlap without sharing SQLite
 state. Bible positions contain only real source rows and retain exact KJVA ordinals. Dictionary
 keys remain byte-exact; commentary speaks the covering content returned for the requested verse
 without widening to another key.
 */
struct SQLiteReaderSpeechSessionBuilder {
    /// Immutable module selected by the speech request.
    let module: BibleReaderSQLiteModuleHandle

    /**
     Builds or reconstructs a SQLite Bible or memorization provider.

     - Parameters:
       - category: Bible or memorization behavior.
       - sourceVersification: Canon owning new-session ordinal inputs.
       - startOrdinal: Exact KJVA start for a new session.
       - endOrdinal: Exact KJVA end required by memorization.
       - checkpoint: Optional persisted source cursor to reconstruct.
       - service: Live speech settings and generation owner.
       - positionChanged: Main-actor visible-position callback.
       - stopped: Main-actor highlight cleanup callback.
     - Returns: Complete speech session, or `nil` when source identity or requested bounds contain
       no addressable source row.
     - Side effects: Enumerates real Bible rows through operation-owned connections. Verse text is
       loaded lazily through the same immutable handle during playback.
     - Failure modes: Non-KJVA requests, malformed checkpoints, and empty bounds fail closed without
       synthetic verses or SWORD fallback. Like Android's `skipEmptyVerses`, a missing requested
       row advances to the next real source row.
     */
    func bibleSession(
        category: SpeakDocumentCategory,
        sourceVersification: String = JSwordKJVAVersification.name,
        startOrdinal: Int?,
        endOrdinal: Int?,
        checkpoint: SpeakProviderCheckpoint? = nil,
        service: SpeakService,
        positionChanged: @escaping @MainActor (SpeakStreamPosition) -> Void,
        stopped: @escaping @MainActor () -> Void
    ) -> SpeakSessionReconstruction? {
        guard module.info.category == .bible,
              category == .bible || category == .memorization,
              let positions = try? biblePositions(category: category),
              !positions.isEmpty else {
            return nil
        }

        let selection: (start: Int, bounds: ClosedRange<Int>?)
        if let checkpoint {
            guard let restored = restoredBibleSelection(
                checkpoint: checkpoint,
                category: category,
                positions: positions
            ) else {
                return nil
            }
            selection = restored
        } else {
            guard let startOrdinal,
                  let endOrdinal = endOrdinal ?? Optional(startOrdinal),
                  let mapped = VerifiedKJVAOrdinalRange(
                      resolvingSourceBookInitials: module.info.name,
                      sourceVersification: sourceVersification,
                      sourceOrdinalStart: startOrdinal,
                      sourceOrdinalEnd: endOrdinal
                  ),
                  let start = Self.firstPositionIndex(
                      atOrAfter: mapped.kjvaOrdinalStart,
                      in: positions,
                      wrapping: category == .bible
                  ) else {
                return nil
            }
            if category == .memorization {
                guard let end = Self.lastPositionIndex(
                    atOrBefore: mapped.kjvaOrdinalEnd,
                    in: positions
                ),
                      start <= end else {
                    return nil
                }
                selection = (start, start...end)
            } else {
                selection = (start, nil)
            }
        }

        guard let loader = bibleLoader(for: positions) else { return nil }

        let provider: SpeakTextProviding
        if category == .memorization {
            guard let bounds = selection.bounds else { return nil }
            provider = MemorizationSpeakTextProvider(
                positions: positions,
                startIndex: selection.start,
                bounds: bounds,
                advancedSettings: service.advancedSettings,
                loader: loader
            )
        } else {
            provider = BibleSpeakTextProvider(
                positions: positions,
                startIndex: selection.start,
                advancedSettings: service.advancedSettings,
                verseRangeResolver: { range in
                    Self.positionBounds(for: range, positions: positions)
                },
                loader: loader
            )
        }
        return SpeakSessionReconstruction(
            provider: provider,
            callbacks: callbacks(
                service: service,
                positionChanged: positionChanged,
                stopped: stopped
            ),
            title: provider.currentPosition?.keyName,
            subtitle: BibleReaderSQLiteSourceMetadata(module: module).name
        )
    }

    /**
     Builds Android's ordered bounded key-list provider for one SQLite Bible.

     - Parameters:
       - ranges: Independently mapped target ranges in exact playback order.
       - service: Live speech settings and generation owner.
       - positionChanged: Main-actor visible-position callback.
       - stopped: Main-actor highlight cleanup callback.
     - Returns: Complete bounded passage-list session, or nil when any range contains no real
       source row or cannot map exactly into KJVA.
     - Side effects: Enumerates real SQLite verse rows once; content remains lazy and every later
       read uses the immutable module handle's operation-owned connection.
     - Failure modes: Empty, malformed, partially unmappable, and wholly sparse ranges fail the
       complete request without flattening, widening, or falling back to SWORD.
     - Note: Passage order, gaps, overlaps, and duplicates are retained as semantic segments.
     */
    func biblePassageListSession(
        ranges: [SpeakVerseRange],
        service: SpeakService,
        positionChanged: @escaping @MainActor (SpeakStreamPosition) -> Void,
        stopped: @escaping @MainActor () -> Void
    ) -> SpeakSessionReconstruction? {
        guard module.info.category == .bible,
              !ranges.isEmpty,
              let availablePositions = try? biblePositions(category: .bible),
              !availablePositions.isEmpty,
              let loader = bibleLoader(for: availablePositions) else {
            return nil
        }

        var segments: [SpeakPassageSegment] = []
        segments.reserveCapacity(ranges.count)
        for range in ranges {
            guard let bounds = Self.positionBounds(for: range, positions: availablePositions) else {
                return nil
            }
            let positions = Array(availablePositions[bounds])
            guard let title = Self.passageTitle(for: positions) else { return nil }
            segments.append(
                SpeakPassageSegment(
                    sourceRange: range,
                    title: title,
                    positions: positions
                )
            )
        }

        let provider = BiblePassageListSpeakTextProvider(
            passages: segments,
            loaders: segments.map { _ in loader },
            advancedSettings: service.advancedSettings
        )
        return SpeakSessionReconstruction(
            provider: provider,
            callbacks: callbacks(
                service: service,
                positionChanged: positionChanged,
                stopped: stopped
            ),
            title: provider.currentPosition?.keyName,
            subtitle: BibleReaderSQLiteSourceMetadata(module: module).name
        )
    }

    /**
     Builds or reconstructs an exact SQLite commentary or dictionary provider.

     - Parameters mirror Android's generic `(book, key, ordinal)` cursor.
     - Returns: A source-owned session using exact keys and source language, or `nil` when the key
       or ordinal is absent.
     - Side effects: Enumerates dictionary keys once when needed. Content remains lazy and every
       read owns its SQLite connection.
     - Failure modes: Category mismatch, case-mismatched dictionary keys, malformed commentary
       coordinates, missing content, and invalid checkpoints fail closed.
     */
    func genericSession(
        category: SpeakDocumentCategory,
        key: String?,
        startOrdinal: Int?,
        endOrdinal: Int?,
        checkpoint: SpeakProviderCheckpoint? = nil,
        service: SpeakService,
        synchronize: @escaping @MainActor (_ key: String, _ ordinal: Int) -> Void
    ) -> SpeakSessionReconstruction? {
        guard let expectedModuleCategory = Self.moduleCategory(for: category),
              module.info.category == expectedModuleCategory else {
            return nil
        }
        let requestedKey = checkpoint?.current.key ?? key
        guard let requestedKey,
              let source = genericSource(category: category, requestedKey: requestedKey) else {
            return nil
        }

        let provider: GenericOrdinalSpeakTextProvider?
        if let checkpoint {
            if checkpoint.version == 0 {
                let cursor = checkpoint.current
                guard cursor.bookInitials == module.info.name,
                      cursor.category == category,
                      let ordinal = cursor.ordinalStart,
                      cursor.ordinalEnd == ordinal else {
                    return nil
                }
                provider = GenericOrdinalSpeakTextProvider(
                    source: source,
                    startKey: cursor.key,
                    startOrdinal: ordinal
                )
            } else {
                provider = GenericOrdinalSpeakTextProvider(source: source, checkpoint: checkpoint)
            }
        } else {
            let normalizedStart = startOrdinal.flatMap { $0 >= 0 ? $0 : nil }
            let normalizedEnd = endOrdinal.flatMap { $0 >= 0 ? $0 : nil }
            provider = GenericOrdinalSpeakTextProvider(
                source: source,
                startKey: requestedKey,
                startOrdinal: normalizedStart,
                endKey: normalizedEnd == nil ? nil : requestedKey,
                endOrdinal: normalizedEnd
            )
        }
        guard let provider else { return nil }
        return SpeakSessionReconstruction(
            provider: provider,
            callbacks: genericCallbacks(service: service, synchronize: synchronize),
            title: provider.currentPosition?.keyName,
            subtitle: BibleReaderSQLiteSourceMetadata(module: module).name
        )
    }

    /** One immutable real verse coordinate retained outside provider-facing metadata. */
    private struct VerseCoordinate {
        /// Canonical KJVA OSIS book identifier used for lazy source reads.
        let osisBookId: String

        /// One-based KJVA chapter used for lazy source reads.
        let chapter: Int

        /// One-based KJVA verse used for lazy source reads.
        let verse: Int
    }

    /**
     Creates one occurrence-safe lazy loader for exact SQLite Bible positions.

     - Parameter positions: Unique real source positions in KJVA ordinal order.
     - Returns: Lazy command loader keyed by exact ordinal, or nil when any position lacks a
       complete coordinate or duplicates another ordinal.
     - Side effects: The returned closure opens an operation-owned SQLite read for each materialized
       verse and projects its source markup into speech commands.
     - Failure modes: Missing content returns no commands; no alternate module or nearby verse is
       substituted. Ordinal lookup remains valid when passage-list providers decorate position IDs.
     */
    private func bibleLoader(for positions: [SpeakStreamPosition]) -> SpeakStreamUnitLoader? {
        var coordinates: [Int: VerseCoordinate] = [:]
        coordinates.reserveCapacity(positions.count)
        for position in positions {
            guard let ordinal = position.ordinalStart,
                  position.ordinalEnd == ordinal,
                  coordinates[ordinal] == nil,
                  let osisRef = position.osisRef,
                  let chapter = position.chapter,
                  let verse = position.verse,
                  let osisBookId = osisRef.split(separator: ".").first.map(String.init) else {
                return nil
            }
            coordinates[ordinal] = VerseCoordinate(
                osisBookId: osisBookId,
                chapter: chapter,
                verse: verse
            )
        }
        return { position, settings, advanced in
            guard let ordinal = position.ordinalStart,
                  position.ordinalEnd == ordinal,
                  let coordinate = coordinates[ordinal],
                  let content = try? module.verseContent(
                      osisId: coordinate.osisBookId,
                      chapter: coordinate.chapter,
                      verse: coordinate.verse
                  ) else {
                return []
            }
            return SpeakCommandBuilder.commands(
                rawOSIS: SQLiteReaderMarkupProjection.bibleVerseXML(
                    content.text,
                    module: module
                ),
                fallbackPlainText: SQLiteReaderMarkupProjection.plainText(
                    content.text,
                    module: module
                ),
                language: position.language,
                playbackSettings: settings.playbackSettings,
                advancedSettings: advanced
            )
        }
    }

    /**
     Enumerates every real Bible row as a source-owned speech position in canonical KJVA order.

     - Parameter category: Bible or memorization category copied onto every emitted position.
     - Returns: Real, addressable positions sorted by exact intro-inclusive KJVA ordinal.
     - Side effects: Enumerates the module's key-derived books and chapter rows through
       operation-owned SQLite connections.
     - Throws: Re-throws book-list or chapter-read failures; invalid/out-of-KJVA rows are skipped.
     - Note: No missing verse is synthesized, so sparse modules remain sparse during playback.
     */
    private func biblePositions(category: SpeakDocumentCategory) throws -> [SpeakStreamPosition] {
        let source = BibleReaderSQLiteSourceMetadata(module: module)
        var positionsByOrdinal: [Int: SpeakStreamPosition] = [:]
        for book in try module.bookList() {
            for chapter in 1...book.chapterCount {
                for row in try module.chapterContent(osisId: book.osisId, chapter: chapter) {
                    guard let coordinate = SQLiteReaderNavigationResolver.coordinate(
                        osisBookId: book.osisId,
                        chapter: chapter,
                        verse: row.verse
                    ), let verified = VerifiedKJVAOrdinalRange(
                        resolvingSourceBookInitials: source.initials,
                        sourceVersification: source.versification,
                        sourceOrdinalStart: coordinate.ordinal,
                        sourceOrdinalEnd: coordinate.ordinal
                    ), positionsByOrdinal[coordinate.ordinal] == nil else {
                        continue
                    }
                    let key = coordinate.osisKey
                    positionsByOrdinal[coordinate.ordinal] = SpeakStreamPosition(
                        id: "\(source.initials):\(coordinate.ordinal)",
                        category: category,
                        bookInitials: source.initials,
                        key: key,
                        osisRef: key,
                        keyName: "\(book.name) \(chapter):\(row.verse)",
                        bookName: book.name,
                        ordinalStart: coordinate.ordinal,
                        ordinalEnd: coordinate.ordinal,
                        chapter: chapter,
                        verse: row.verse,
                        groupIdentifier: "\(book.osisId).\(chapter)",
                        language: Self.speechLanguage(source.language),
                        versification: source.versification,
                        verifiedBibleRange: verified
                    )
                }
            }
        }
        return positionsByOrdinal.values.sorted {
            ($0.ordinalStart ?? 0) < ($1.ordinalStart ?? 0)
        }
    }

    /**
     Validates one version-one Bible checkpoint against freshly enumerated source positions.

     - Parameters:
       - checkpoint: Persisted speech cursor and bounds to reconstruct.
       - category: Expected Bible or memorization category.
       - positions: Fresh real-source positions for the selected SQLite module.
     - Returns: Current index plus memorization bounds, or nil when any source field is stale.
     - Side effects: None.
     - Failure modes: Version, module, category, versification, bound, or loop mismatches fail
       closed without moving the persisted cursor to a neighboring verse.
     */
    private func restoredBibleSelection(
        checkpoint: SpeakProviderCheckpoint,
        category: SpeakDocumentCategory,
        positions: [SpeakStreamPosition]
    ) -> (start: Int, bounds: ClosedRange<Int>?)? {
        guard checkpoint.version == 1,
              checkpoint.current.category == category,
              checkpoint.lowerBound.category == category,
              checkpoint.upperBound.category == category,
              checkpoint.current.bookInitials == module.info.name,
              checkpoint.lowerBound.bookInitials == module.info.name,
              checkpoint.upperBound.bookInitials == module.info.name,
              checkpoint.current.versification == JSwordKJVAVersification.name,
              checkpoint.lowerBound.versification == JSwordKJVAVersification.name,
              checkpoint.upperBound.versification == JSwordKJVAVersification.name,
              checkpoint.isMemorizationLoop == (category == .memorization),
              let current = Self.positionIndex(for: checkpoint.current, positions: positions),
              let lower = Self.positionIndex(for: checkpoint.lowerBound, positions: positions),
              let upper = Self.positionIndex(for: checkpoint.upperBound, positions: positions),
              lower <= current,
              current <= upper else {
            return nil
        }
        if category == .memorization {
            guard checkpoint.isBounded else { return nil }
            return (current, lower...upper)
        }
        guard !checkpoint.isBounded else { return nil }
        return (current, nil)
    }

    /**
     Resolves a checkpoint cursor only when every persisted source field still matches.

     - Parameters:
       - cursor: Persisted exact source key, ordinals, and versification.
       - positions: Fresh positions from the same selected module.
     - Returns: Matching array index, or nil when the source changed.
     - Side effects: None.
     - Failure modes: Matching is exact and never normalizes keys or ordinals.
     */
    private static func positionIndex(
        for cursor: SpeakStreamCursor,
        positions: [SpeakStreamPosition]
    ) -> Int? {
        positions.firstIndex {
            $0.key == cursor.key
                && $0.ordinalStart == cursor.ordinalStart
                && $0.ordinalEnd == cursor.ordinalEnd
                && $0.versification == cursor.versification
        }
    }

    /**
     Resolves Android's first non-empty verse at or after a requested canonical ordinal.

     - Parameters:
       - ordinal: Requested KJVA ordinal.
       - positions: Sorted real SQLite source rows.
       - wrapping: Whether an exhausted unbounded Bible stream restarts at its first real row.
     - Returns: Matching real-row index, or `nil` when a bounded stream has no later row.
     - Side effects: None.
     - Failure modes: Empty position collections return `nil`; no synthetic verse is emitted.
     */
    private static func firstPositionIndex(
        atOrAfter ordinal: Int,
        in positions: [SpeakStreamPosition],
        wrapping: Bool
    ) -> Int? {
        if let index = positions.firstIndex(where: { ($0.ordinalStart ?? Int.min) >= ordinal }) {
            return index
        }
        return wrapping && !positions.isEmpty ? positions.startIndex : nil
    }

    /**
     Resolves the last real SQLite verse no later than one canonical upper bound.

     - Parameters:
       - ordinal: Inclusive requested KJVA upper bound.
       - positions: Sorted real SQLite source rows.
     - Returns: Last in-range real-row index, or `nil` when every row follows the bound.
     - Side effects: None.
     - Failure modes: Empty or wholly out-of-range position collections return `nil`.
     */
    private static func lastPositionIndex(
        atOrBefore ordinal: Int,
        in positions: [SpeakStreamPosition]
    ) -> Int? {
        positions.lastIndex(where: { ($0.ordinalStart ?? Int.max) <= ordinal })
    }

    /**
     Formats one semantic passage title without merging it with adjacent ranges.

     - Parameter positions: Non-empty real SQLite rows belonging to one requested range.
     - Returns: Single-verse, compact same-chapter, or exact endpoint title; nil for no rows.
     - Side effects: None.
     - Failure modes: Missing chapter/verse metadata uses endpoint display names rather than
       dropping the passage boundary.
     */
    private static func passageTitle(for positions: [SpeakStreamPosition]) -> String? {
        guard let first = positions.first, let last = positions.last else { return nil }
        if positions.count == 1 { return first.keyName }
        if first.bookName == last.bookName,
           first.chapter == last.chapter,
           let chapter = first.chapter,
           let firstVerse = first.verse,
           let lastVerse = last.verse {
            return "\(first.bookName) \(chapter):\(firstVerse)-\(lastVerse)"
        }
        return "\(first.keyName)-\(last.keyName)"
    }

    /**
     Converts a settings-owned verse range into exact indexes in the real SQLite verse stream.

     - Parameters:
       - range: User-configured source-versification range.
       - positions: Real KJVA-addressable SQLite positions.
     - Returns: Inclusive indexes spanning the real rows inside the converted source range, or nil
       when the range contains no source row.
     - Side effects: Reads pinned versification mapping data only.
     - Failure modes: Invalid/reversed ranges and ranges with no real rows fail without widening
       beyond the requested canonical endpoints.
     */
    private static func positionBounds(
        for range: SpeakVerseRange,
        positions: [SpeakStreamPosition]
    ) -> ClosedRange<Int>? {
        guard let endpoints = range.validatedReferences(),
              let sourceStartOrdinal = SwordVersification.referenceIndex(
                  for: endpoints.start,
                  versification: range.versification
              ), let sourceEndOrdinal = SwordVersification.referenceIndex(
                  for: endpoints.end,
                  versification: range.versification
              ), let mapped = VersificationMapper.kjvaOrdinalRange(
                  start: VerseKeyReference(
                      osisBookId: endpoints.start.osisBookId,
                      chapter: endpoints.start.chapter,
                      verse: endpoints.start.verse,
                      ordinal: sourceStartOrdinal
                  ),
                  end: VerseKeyReference(
                      osisBookId: endpoints.end.osisBookId,
                      chapter: endpoints.end.chapter,
                      verse: endpoints.end.verse,
                      ordinal: sourceEndOrdinal
                  ),
                  sourceVersification: range.versification
              ), let lower = firstPositionIndex(
                  atOrAfter: mapped.lowerBound,
                  in: positions,
                  wrapping: false
              ), let upper = lastPositionIndex(
                  atOrBefore: mapped.upperBound,
                  in: positions
              ),
              lower <= upper else {
            return nil
        }
        return lower...upper
    }

    /**
     Creates a lazy exact-key source for one SQLite auxiliary category.

     - Parameters:
       - category: Commentary or dictionary speech category.
       - requestedKey: Exact source key selected by the caller or checkpoint.
     - Returns: Lazy source preserving source-order dictionary keys or one commentary key.
     - Side effects: Enumerates dictionary keys during construction; content reads remain lazy and
       use operation-owned SQLite connections.
     - Failure modes: Category mismatch, malformed commentary coordinates, case-mismatched
       dictionary keys, missing content, and unrenderable markup return nil from construction or
       from the per-key loader without backend fallback.
     */
    private func genericSource(
        category: SpeakDocumentCategory,
        requestedKey: String
    ) -> GenericSpeakOrdinalSource? {
        guard let expectedModuleCategory = Self.moduleCategory(for: category) else { return nil }
        let source = BibleReaderSQLiteSourceMetadata(module: module)
        let keys: [String]
        switch category {
        case .dictionary:
            guard let loaded = try? module.dictionaryKeys(),
                  BibleReaderSQLiteDictionaryChooser.exactSourceKey(
                      matching: requestedKey,
                      in: loaded
                  ) != nil else {
                return nil
            }
            keys = loaded
        case .commentary:
            guard SQLiteReaderNavigationResolver.commentaryCoordinate(for: requestedKey) != nil else {
                return nil
            }
            keys = [requestedKey]
        case .bible, .memorization, .generalBook, .myDocument, .selection:
            return nil
        }
        return GenericSpeakOrdinalSource(
            category: category,
            bookInitials: source.initials,
            bookName: source.name,
            language: Self.speechLanguage(source.language),
            keys: keys,
            loadContent: { sourceKey in
                let text: String
                switch category {
                case .dictionary:
                    guard let content = try? module.dictionaryContent(for: sourceKey) else {
                        return nil
                    }
                    text = content.text
                case .commentary:
                    guard let coordinate = SQLiteReaderNavigationResolver.commentaryCoordinate(
                        for: sourceKey
                    ),
                          let content = try? module.verseContent(
                              osisId: coordinate.osisBookId,
                              chapter: coordinate.chapter,
                              verse: coordinate.verse
                          ) else {
                        return nil
                    }
                    text = content.text
                case .bible, .memorization, .generalBook, .myDocument, .selection:
                    return nil
                }
                guard let fragment = try? SwordOSISFragmentProcessor.process(
                    sourceXML: "<div>\(text)</div>",
                    category: expectedModuleCategory,
                    moduleInitials: source.initials
                ), fragment.hasRenderableContent,
                   !fragment.anchorTexts.isEmpty else {
                    return nil
                }
                let commands = fragment.anchorTexts.mapValues { anchorText -> [SpeakCommand] in
                    let normalized = SpeakCommandBuilder.normalizeText(
                        anchorText.replacingOccurrences(of: "\n", with: " ")
                    )
                    return normalized.isEmpty ? [] : [.text(normalized)]
                }
                return GenericSpeakKeyContent(
                    key: sourceKey,
                    keyName: sourceKey,
                    ordinalRange: fragment.contentOrdinalRange,
                    commandsByOrdinal: commands
                )
            }
        )
    }

    /**
     Maps speech categories to the only SQLite module categories they may access.

     - Parameter category: Provider-facing speech category.
     - Returns: Matching module category, or nil for unsupported generic/page categories.
     - Side effects: None.
     - Failure modes: Unsupported categories deliberately return nil.
     */
    private static func moduleCategory(for category: SpeakDocumentCategory) -> ModuleCategory? {
        switch category {
        case .commentary: .commentary
        case .dictionary: .dictionary
        case .bible, .memorization: .bible
        case .generalBook, .myDocument, .selection: nil
        }
    }

    /**
     Normalizes English source metadata to the preferred platform speech identifier.

     - Parameter language: Source language token from validated module metadata.
     - Returns: `en-US` for English-prefixed tokens; every other token is preserved exactly.
     - Side effects: None.
     - Failure modes: Empty or unknown tokens pass through for the platform resolver to handle.
     */
    private static func speechLanguage(_ language: String) -> String {
        language.hasPrefix("en") ? "en-US" : language
    }

    /**
     Creates generation-scoped Bible synchronization and cleanup callbacks.

     - Parameters:
       - service: Session generation owner, captured weakly.
       - positionChanged: Main-actor visible-position callback.
       - stopped: Main-actor highlight cleanup callback.
     - Returns: Provider callbacks that discard stale session events.
     - Side effects: Creates main-actor tasks for current-generation events only.
     - Failure modes: A released service or stale generation silently drops the callback.
     - Important: No SQLite read occurs in these callbacks; provider loaders own their reads.
     */
    private func callbacks(
        service: SpeakService,
        positionChanged: @escaping @MainActor (SpeakStreamPosition) -> Void,
        stopped: @escaping @MainActor () -> Void
    ) -> SpeakSessionCallbacks {
        SpeakSessionCallbacks(
            onPositionChanged: { [weak service] position, generation in
                Task { @MainActor in
                    guard service?.isCurrentSession(generation) == true else { return }
                    positionChanged(position)
                }
            },
            onStopped: { [weak service] generation in
                Task { @MainActor in
                    guard service?.mayApplyStoppedSessionCleanup(generation) == true else { return }
                    stopped()
                }
            }
        )
    }

    /**
     Creates generation-scoped exact-key synchronization callbacks for auxiliary speech.

     - Parameters:
       - service: Session generation and live synchronization-setting owner, captured weakly.
       - synchronize: Main-actor callback receiving the exact key and local content ordinal.
     - Returns: Provider callbacks that synchronize only the current enabled session.
     - Side effects: Creates a main-actor task after each addressable spoken position.
     - Failure modes: Missing ordinals, released services, stale generations, and disabled
       synchronization drop the event without mutating pane state.
     */
    private func genericCallbacks(
        service: SpeakService,
        synchronize: @escaping @MainActor (_ key: String, _ ordinal: Int) -> Void
    ) -> SpeakSessionCallbacks {
        SpeakSessionCallbacks(onPositionChanged: { [weak service] position, generation in
            guard let ordinal = position.ordinalStart else { return }
            Task { @MainActor in
                guard service?.isCurrentSession(generation) == true,
                      service?.advancedSettings.synchronize == true else {
                    return
                }
                synchronize(position.key, ordinal)
            }
        })
    }
}
