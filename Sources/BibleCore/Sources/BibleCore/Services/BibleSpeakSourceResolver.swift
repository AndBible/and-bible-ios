// BibleSpeakSourceResolver.swift -- Authoritative module and versification speech routing

import Foundation
import SwordKit

/**
 Describes why a typed Bible or memorization Speak request cannot be resolved safely.

 These failures are semantic rather than recoverable transport errors. Callers must leave speech
 stopped and surface their normal Speak error path; they must not retry against the active module or
 reinterpret source ordinals in another versification.
 */
public enum BibleSpeakSourceResolutionError: Error, Equatable, LocalizedError, Sendable {
    /// The typed request was not a Bible-backed provider category.
    case unsupportedCategory(SpeakDocumentCategory)
    /// The requested installed module does not exist.
    case moduleUnavailable(String)
    /// The requested module exists but is not a Bible.
    case moduleIsNotBible(String)
    /// The source versification was omitted or is unknown to the Android-compatible mapping engine.
    case unsupportedSourceVersification(String?)
    /// One source ordinal does not identify a concrete verse in its declared versification.
    case invalidSourceOrdinal(Int, versification: String)
    /// JSword has no authoritative source-to-target mapping for an endpoint.
    case unmappableSourceOrdinal(Int, sourceVersification: String, targetVersification: String)
    /// The requested module cannot address a mapped endpoint.
    case targetModuleDoesNotAddress(String)
    /// The module exposes no addressable verse content in the requested interval.
    case noAddressableContent(String)
    /// A persisted checkpoint is internally inconsistent or no longer addressable.
    case invalidCheckpoint(String)

    /// Localized diagnostic used by reader logs and the existing Speak error surface.
    public var errorDescription: String? {
        switch self {
        case .unsupportedCategory(let category):
            return "The \(category.rawValue) speech request is not Bible-backed."
        case .moduleUnavailable(let initials):
            return "The requested Bible module '\(initials)' is not installed."
        case .moduleIsNotBible(let initials):
            return "The requested module '\(initials)' is not a Bible."
        case .unsupportedSourceVersification(let versification):
            return "The requested source versification '\(versification ?? "")' is unavailable."
        case .invalidSourceOrdinal(let ordinal, let versification):
            return "Ordinal \(ordinal) is not a verse in \(versification)."
        case .unmappableSourceOrdinal(let ordinal, let source, let target):
            return "Ordinal \(ordinal) cannot be mapped authoritatively from \(source) to \(target)."
        case .targetModuleDoesNotAddress(let osisRef):
            return "The requested Bible does not address \(osisRef)."
        case .noAddressableContent(let initials):
            return "The requested Bible '\(initials)' has no addressable content in this range."
        case .invalidCheckpoint(let reason):
            return "The persisted speech checkpoint is invalid: \(reason)."
        }
    }
}

/**
 One independently resolved semantic passage and the module that lazily supplies its text.

 The value keeps an original Daily Reading range separate from adjacent ranges while pairing it
 with exact target positions and the module-specific loader identity needed during reconstruction.
 Construction has no side effects; callers must supply an already validated, non-empty segment.
 */
public struct ResolvedBibleSpeakPassage: @unchecked Sendable {
    /// Exact installed module owning the target positions.
    public let module: SwordModule
    /// Original source-versification range supplied by the caller.
    public let sourceRange: SpeakVerseRange
    /// Android-equivalent range title spoken before content.
    public let title: String
    /// Exact target-module positions for this passage.
    public let positions: [SpeakStreamPosition]

    /**
     Creates one complete semantic passage after strict source-to-target resolution.

     - Parameters:
       - module: Installed Bible whose text supplies the resolved positions.
       - sourceRange: Original range and versification retained as the semantic boundary.
       - title: Non-empty title spoken before this passage.
       - positions: Non-empty, ordered positions produced by strict range conversion.
     - Side effects: None.
     - Failure modes: Construction does not validate fields; resolver entry points reject malformed
       or empty values before returning this type.
     */
    public init(
        module: SwordModule,
        sourceRange: SpeakVerseRange,
        title: String,
        positions: [SpeakStreamPosition]
    ) {
        self.module = module
        self.sourceRange = sourceRange
        self.title = title
        self.positions = positions
    }
}

/**
 Fully resolved Bible source used to construct an Android-equivalent provider.

 The source owns the explicitly requested installed module, target-versification positions, and the
 converted start/bounds. It also converts persisted `verseRange` settings through the same strict
 mapping boundary so playback cannot later drift back to coordinate identity. Values are immutable;
 module reads occur only in resolver entry points and later lazy provider loaders.
 */
public struct ResolvedBibleSpeakSource: @unchecked Sendable {
    /// Explicitly requested installed Bible module.
    public let module: SwordModule
    /// Concrete source category, either Bible or memorization.
    public let category: SpeakDocumentCategory
    /// Real, addressable module verses in source order.
    public let positions: [SpeakStreamPosition]
    /// Initial position after authoritative source-to-module conversion.
    public let startIndex: Int
    /// Inclusive memorization bounds; normal Bible streams remain unbounded.
    public let bounds: ClosedRange<Int>?
    /// Effective target module versification.
    public let targetVersification: String
    /// Semantic key-list passages, empty for ordinary Bible and memorization providers.
    public let passages: [ResolvedBibleSpeakPassage]

    /**
     Creates one resolved Bible-family source without losing optional passage boundaries.

     - Parameters describe the primary module, flattened positions, current bounds, target canon,
       and any semantic passage segments.
     - Side effects: None.
     - Failure modes: Construction assumes the resolver already validated every supplied field.
     */
    public init(
        module: SwordModule,
        category: SpeakDocumentCategory,
        positions: [SpeakStreamPosition],
        startIndex: Int,
        bounds: ClosedRange<Int>?,
        targetVersification: String,
        passages: [ResolvedBibleSpeakPassage] = []
    ) {
        self.module = module
        self.category = category
        self.positions = positions
        self.startIndex = startIndex
        self.bounds = bounds
        self.targetVersification = targetVersification
        self.passages = passages
    }

    /**
     Converts a persisted Android verse range into this module's concrete position indexes.

     - Parameter range: Range serialized with its owning source versification.
     - Returns: Inclusive indexes spanning addressable verses, or `nil` when either endpoint cannot
       be converted authoritatively or the module has no content inside the interval.
     - Side effects: Reads the bundled JSword mapping resources and the module's verse index.
     - Failure modes: Unknown canons, strict mapping misses, unaddressable endpoints, and reversed
       ranges fail closed without coordinate fallback.
     */
    public func positionBounds(for range: SpeakVerseRange) -> ClosedRange<Int>? {
        BibleSpeakSourceResolver.positionBounds(
            for: range,
            module: module,
            positions: positions,
            targetVersification: targetVersification
        )
    }
}

/**
 Resolves typed Bible and memorization speech requests exactly like Android's `SpeakControl` bridge.

 Android resolves `bookInitials`, constructs source verses in the supplied `v11n`, and calls
 `toV11n(requestedBook.versification)` before starting `BibleSpeakTextProvider`. This resolver is the
 shared iOS authority for that sequence and never substitutes the reader's active Bible.
 */
public enum BibleSpeakSourceResolver {
    /**
     Resolves one typed Bible or memorization selection against installed SWORD modules.

     - Parameters:
       - request: Exact source module, source versification, and intro-inclusive source ordinals.
       - manager: Installed module registry used to resolve `bookInitials`.
     - Returns: Requested module, real module positions, converted start, and optional memorization
       bounds.
     - Side effects: Enumerates module keys and performs serialized SWORD inspections; lazily reads
       JSword's pinned versification mappings.
     - Throws: `BibleSpeakSourceResolutionError` for every unsupported, absent, unmappable, or empty
       source. No failure falls back to the active module or raw ordinal identity.
     */
    public static func resolve(
        request: SpeakSelectionRequest,
        manager: SwordManager
    ) throws -> ResolvedBibleSpeakSource {
        guard request.category == .bible || request.category == .memorization else {
            throw BibleSpeakSourceResolutionError.unsupportedCategory(request.category)
        }
        guard let module = manager.readableModule(named: request.bookInitials) else {
            throw BibleSpeakSourceResolutionError.moduleUnavailable(request.bookInitials)
        }
        guard module.info.category == .bible else {
            throw BibleSpeakSourceResolutionError.moduleIsNotBible(request.bookInitials)
        }
        guard let sourceVersification = request.versification?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ),
        !sourceVersification.isEmpty,
        VersificationMapper.supports(sourceVersification) else {
            throw BibleSpeakSourceResolutionError.unsupportedSourceVersification(request.versification)
        }

        let targetVersification = VersificationMapper.versificationName(for: module)
        let positions = biblePositions(
            module: module,
            category: request.category,
            targetVersification: targetVersification
        )
        guard !positions.isEmpty else {
            throw BibleSpeakSourceResolutionError.noAddressableContent(module.info.name)
        }

        let convertedStart = try convertedOrdinal(
            request.startOrdinal,
            sourceVersification: sourceVersification,
            targetVersification: targetVersification,
            module: module
        )
        guard let startIndex = exactPositionIndex(
            forOrdinal: convertedStart,
            positions: positions
        ) else {
            throw BibleSpeakSourceResolutionError.noAddressableContent(module.info.name)
        }

        let bounds: ClosedRange<Int>?
        if request.category == .memorization {
            guard request.endOrdinal >= request.startOrdinal else {
                throw BibleSpeakSourceResolutionError.invalidSourceOrdinal(
                    request.endOrdinal,
                    versification: sourceVersification
                )
            }
            let convertedEnd = try convertedOrdinal(
                request.endOrdinal,
                sourceVersification: sourceVersification,
                targetVersification: targetVersification,
                module: module
            )
            guard convertedEnd >= convertedStart,
                  let endIndex = exactPositionIndex(
                      forOrdinal: convertedEnd,
                      positions: positions
                  ),
                  startIndex <= endIndex else {
                throw BibleSpeakSourceResolutionError.noAddressableContent(module.info.name)
            }
            bounds = startIndex...endIndex
        } else {
            bounds = nil
        }

        return ResolvedBibleSpeakSource(
            module: module,
            category: request.category,
            positions: positions,
            startIndex: startIndex,
            bounds: bounds,
            targetVersification: targetVersification
        )
    }

    /**
     Reconstructs one persisted Bible or memorization checkpoint through the authoritative resolver.

     - Parameters:
       - checkpoint: Exact target-module current cursor and original provider bounds.
       - manager: Installed module registry used to resolve the persisted initials.
     - Returns: Requested module positions with the exact persisted current index and memorization
       bounds. Normal Bible bounds remain settings-owned so verse-range repetition is reapplied by
       `BibleSpeakTextProvider.prepare`.
     - Side effects: Enumerates the persisted module and reads pinned versification mappings.
     - Throws: `BibleSpeakSourceResolutionError` when checkpoint schema, category, module,
       versification, exact cursor identity, or bounds are invalid. No active-module fallback occurs.
     */
    public static func resolve(
        checkpoint: SpeakProviderCheckpoint,
        manager: SwordManager
    ) throws -> ResolvedBibleSpeakSource {
        if checkpoint.version == 0 {
            return try resolveAndroidLegacyCheckpoint(checkpoint, manager: manager)
        }
        if checkpoint.version == 2 {
            return try resolveOrderedPassageCheckpoint(checkpoint, manager: manager)
        }
        let current = checkpoint.current
        let lower = checkpoint.lowerBound
        let upper = checkpoint.upperBound
        guard checkpoint.version == 1 else {
            throw BibleSpeakSourceResolutionError.invalidCheckpoint("unsupported version")
        }
        guard current.category == .bible || current.category == .memorization,
              lower.category == current.category,
              upper.category == current.category,
              checkpoint.isMemorizationLoop == (current.category == .memorization),
              !current.bookInitials.isEmpty,
              lower.bookInitials == current.bookInitials,
              upper.bookInitials == current.bookInitials,
              let versification = current.versification,
              !versification.isEmpty,
              lower.versification == versification,
              upper.versification == versification,
              let currentOrdinal = exactOrdinal(from: current),
              let lowerOrdinal = exactOrdinal(from: lower),
              let upperOrdinal = exactOrdinal(from: upper),
              lowerOrdinal <= currentOrdinal,
              currentOrdinal <= upperOrdinal,
              current.category != .memorization || checkpoint.isBounded,
              checkpoint.orderedPositions == nil,
              checkpoint.orderedPositionIndex == nil,
              checkpoint.orderedPassages == nil,
              checkpoint.currentPassageIndex == nil,
              checkpoint.currentPositionIndexInPassage == nil,
              checkpoint.playbackCursor == nil else {
            throw BibleSpeakSourceResolutionError.invalidCheckpoint("inconsistent source identity or bounds")
        }

        let request = SpeakSelectionRequest(
            category: current.category,
            bookInitials: current.bookInitials,
            key: current.key,
            startOrdinal: current.category == .memorization ? lowerOrdinal : currentOrdinal,
            endOrdinal: current.category == .memorization ? upperOrdinal : currentOrdinal,
            versification: versification
        )
        let resolved = try resolve(request: request, manager: manager)
        guard let currentIndex = resolved.positions.firstIndex(where: current.matches),
              let lowerIndex = resolved.positions.firstIndex(where: lower.matches),
              let upperIndex = resolved.positions.firstIndex(where: upper.matches),
              lowerIndex <= currentIndex,
              currentIndex <= upperIndex else {
            throw BibleSpeakSourceResolutionError.invalidCheckpoint("cursor no longer addresses the requested module")
        }
        if current.category == .memorization {
            guard resolved.bounds == lowerIndex...upperIndex else {
                throw BibleSpeakSourceResolutionError.invalidCheckpoint("memorization bounds changed during mapping")
            }
        }
        return ResolvedBibleSpeakSource(
            module: resolved.module,
            category: resolved.category,
            positions: resolved.positions,
            startIndex: currentIndex,
            bounds: current.category == .memorization ? lowerIndex...upperIndex : nil,
            targetVersification: resolved.targetVersification
        )
    }

    /**
     Resolves an ordered list of Bible passage ranges against one installed module.

     Android reading-plan speech supplies a `List<Key>` whose members remain discontiguous and may
     repeat. This resolver converts every range independently, concatenates only addressable target
     positions in caller order, and bounds playback to that exact queue.

     - Parameters:
       - bookInitials: Installed Bible module that will provide speech text.
       - ranges: Ordered source-versification ranges to convert independently.
       - manager: Installed module registry.
     - Returns: A bounded Bible source whose `positions` are the complete exact playback queue.
     - Side effects: Enumerates target-module verse keys and reads pinned JSword mappings.
     - Throws: `BibleSpeakSourceResolutionError` when the module, any mapping, or any exact range is
       unavailable. No first-to-last widening or partial queue is returned.
     */
    public static func resolvePassageList(
        bookInitials: String,
        ranges: [SpeakVerseRange],
        manager: SwordManager
    ) throws -> ResolvedBibleSpeakSource {
        guard let module = manager.readableModule(named: bookInitials) else {
            throw BibleSpeakSourceResolutionError.moduleUnavailable(bookInitials)
        }
        guard module.info.category == .bible else {
            throw BibleSpeakSourceResolutionError.moduleIsNotBible(bookInitials)
        }
        guard !ranges.isEmpty else {
            throw BibleSpeakSourceResolutionError.noAddressableContent(bookInitials)
        }

        let targetVersification = VersificationMapper.versificationName(for: module)
        let availablePositions = biblePositions(
            module: module,
            category: .bible,
            targetVersification: targetVersification
        )
        guard !availablePositions.isEmpty else {
            throw BibleSpeakSourceResolutionError.noAddressableContent(bookInitials)
        }

        var orderedPositions: [SpeakStreamPosition] = []
        var resolvedPassages: [ResolvedBibleSpeakPassage] = []
        for range in ranges {
            guard let bounds = positionBounds(
                      for: range,
                      module: module,
                      positions: availablePositions,
                      targetVersification: targetVersification
                  ) else {
                throw BibleSpeakSourceResolutionError.noAddressableContent(bookInitials)
            }
            let positions = Array(availablePositions[bounds])
            guard let title = passageTitle(for: positions) else {
                throw BibleSpeakSourceResolutionError.noAddressableContent(bookInitials)
            }
            orderedPositions.append(contentsOf: positions)
            resolvedPassages.append(
                ResolvedBibleSpeakPassage(
                    module: module,
                    sourceRange: range,
                    title: title,
                    positions: positions
                )
            )
        }
        guard !orderedPositions.isEmpty else {
            throw BibleSpeakSourceResolutionError.noAddressableContent(bookInitials)
        }

        return ResolvedBibleSpeakSource(
            module: module,
            category: .bible,
            positions: orderedPositions,
            startIndex: 0,
            bounds: orderedPositions.startIndex...(orderedPositions.endIndex - 1),
            targetVersification: targetVersification,
            passages: resolvedPassages
        )
    }

    /**
     Reconstructs a version-2 semantic passage queue without inferring omitted boundaries.

     - Parameters:
       - checkpoint: Persisted ordered ranges, exact expanded cursors, occurrence indexes, and
         utterance progress.
       - manager: Installed-module registry used to re-resolve each semantic range independently.
     - Returns: A bounded source whose flattened positions and current index exactly match the
       persisted semantic queue.
     - Side effects: Enumerates installed Bible keys and reads strict versification mappings.
     - Throws: `BibleSpeakSourceResolutionError.invalidCheckpoint` for missing, inconsistent, or
       changed metadata; unavailable or non-Bible modules retain their existing typed failures.
     - Note: Validation is deterministic and atomic. No passage is clamped, inferred, or returned
       when any queue member fails.
     */
    private static func resolveOrderedPassageCheckpoint(
        _ checkpoint: SpeakProviderCheckpoint,
        manager: SwordManager
    ) throws -> ResolvedBibleSpeakSource {
        guard checkpoint.version == 2,
              checkpoint.isBounded,
              !checkpoint.isMemorizationLoop,
              checkpoint.orderedPositions == nil,
              checkpoint.orderedPositionIndex == nil,
              let passageCheckpoints = checkpoint.orderedPassages,
              !passageCheckpoints.isEmpty,
              let currentPassageIndex = checkpoint.currentPassageIndex,
              passageCheckpoints.indices.contains(currentPassageIndex),
              let currentPositionIndex = checkpoint.currentPositionIndexInPassage,
              passageCheckpoints[currentPassageIndex].positions.indices.contains(currentPositionIndex),
              checkpoint.current == passageCheckpoints[currentPassageIndex].positions[currentPositionIndex],
              let playbackCursor = checkpoint.playbackCursor,
              playbackCursor.commandIndex >= 0,
              playbackCursor.characterOffset >= 0,
              playbackCursor.commandTextLength > 0,
              playbackCursor.characterOffset < playbackCursor.commandTextLength,
              playbackCursor.characterFraction.isFinite,
              (0.0...1.0).contains(playbackCursor.characterFraction),
              abs(
                  playbackCursor.characterFraction
                      - Double(playbackCursor.characterOffset) / Double(playbackCursor.commandTextLength)
              ) < 0.000_001 else {
            throw BibleSpeakSourceResolutionError.invalidCheckpoint(
                "semantic passage queue or playback cursor is incomplete"
            )
        }

        let persistedModuleInitials = passageCheckpoints[0].bookInitials
        guard !persistedModuleInitials.isEmpty,
              passageCheckpoints.allSatisfy({ $0.bookInitials == persistedModuleInitials }),
              let module = manager.readableModule(named: persistedModuleInitials) else {
            throw BibleSpeakSourceResolutionError.invalidCheckpoint(
                "semantic passages do not identify one readable installed module"
            )
        }

        var resolvedPassages: [ResolvedBibleSpeakPassage] = []
        var flattenedPositions: [SpeakStreamPosition] = []
        var currentFlatIndex: Int?
        for (passageIndex, persistedPassage) in passageCheckpoints.enumerated() {
            guard !persistedPassage.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !persistedPassage.positions.isEmpty else {
                throw BibleSpeakSourceResolutionError.invalidCheckpoint(
                    "a semantic passage does not identify an installed module"
                )
            }
            guard module.info.category == .bible else {
                throw BibleSpeakSourceResolutionError.moduleIsNotBible(persistedPassage.bookInitials)
            }
            let targetVersification = VersificationMapper.versificationName(for: module)
            guard persistedPassage.positions.allSatisfy({ cursor in
                cursor.category == .bible
                    && cursor.bookInitials == persistedPassage.bookInitials
                    && cursor.versification == targetVersification
                    && cursor.ordinalStart != nil
                    && cursor.ordinalStart == cursor.ordinalEnd
            }) else {
                throw BibleSpeakSourceResolutionError.invalidCheckpoint(
                    "a semantic passage contains inconsistent target cursors"
                )
            }
            let availablePositions = biblePositions(
                module: module,
                category: .bible,
                targetVersification: targetVersification
            )
            guard let bounds = positionBounds(
                      for: persistedPassage.sourceRange,
                      module: module,
                      positions: availablePositions,
                      targetVersification: targetVersification
                  ) else {
                throw BibleSpeakSourceResolutionError.invalidCheckpoint(
                    "a semantic passage source range is no longer addressable"
                )
            }
            let resolvedPositions = Array(availablePositions[bounds])
            let resolvedCursors = resolvedPositions.map(SpeakStreamCursor.init(position:))
            guard resolvedCursors == persistedPassage.positions else {
                throw BibleSpeakSourceResolutionError.invalidCheckpoint(
                    "a semantic passage no longer expands to its persisted target positions"
                )
            }
            if passageIndex == currentPassageIndex {
                currentFlatIndex = flattenedPositions.count + currentPositionIndex
            }
            flattenedPositions.append(contentsOf: resolvedPositions)
            resolvedPassages.append(
                ResolvedBibleSpeakPassage(
                    module: module,
                    sourceRange: persistedPassage.sourceRange,
                    title: persistedPassage.title,
                    positions: resolvedPositions
                )
            )
        }
        guard let module = resolvedPassages.first?.module,
              let firstPosition = flattenedPositions.first,
              let lastPosition = flattenedPositions.last,
              let currentFlatIndex,
              flattenedPositions.indices.contains(currentFlatIndex),
              checkpoint.lowerBound.matches(firstPosition),
              checkpoint.upperBound.matches(lastPosition),
              checkpoint.current.matches(flattenedPositions[currentFlatIndex]) else {
            throw BibleSpeakSourceResolutionError.invalidCheckpoint(
                "semantic passage bounds do not match the flattened queue"
            )
        }
        return ResolvedBibleSpeakSource(
            module: module,
            category: .bible,
            positions: flattenedPositions,
            startIndex: currentFlatIndex,
            bounds: flattenedPositions.startIndex...(flattenedPositions.endIndex - 1),
            targetVersification: VersificationMapper.versificationName(for: module),
            passages: resolvedPassages
        )
    }

    /** Resolves Android's persisted module/OSIS pause state through the module's own canon. */
    private static func resolveAndroidLegacyCheckpoint(
        _ checkpoint: SpeakProviderCheckpoint,
        manager: SwordManager
    ) throws -> ResolvedBibleSpeakSource {
        let cursor = checkpoint.current
        guard cursor.category == .bible,
              !checkpoint.isMemorizationLoop,
              !cursor.bookInitials.isEmpty,
              let module = manager.readableModule(named: cursor.bookInitials) else {
            throw BibleSpeakSourceResolutionError.invalidCheckpoint(
                "Android Bible state does not identify an installed module"
            )
        }
        guard module.info.category == .bible else {
            throw BibleSpeakSourceResolutionError.moduleIsNotBible(cursor.bookInitials)
        }
        let targetVersification = VersificationMapper.versificationName(for: module)
        guard let range = SpeakVerseRange(
                  versification: targetVersification,
                  osisRef: cursor.key
              ),
              let references = range.validatedReferences(),
              references.start == references.end,
              let ordinal = module.verseOrdinal(
                  osisBookId: references.start.osisBookId,
                  chapter: references.start.chapter,
                  verse: references.start.verse
              ) else {
            throw BibleSpeakSourceResolutionError.invalidCheckpoint(
                "Android Bible state contains an invalid OSIS verse"
            )
        }
        return try resolve(
            request: SpeakSelectionRequest(
                category: .bible,
                bookInitials: cursor.bookInitials,
                key: cursor.key,
                startOrdinal: ordinal,
                endOrdinal: ordinal,
                versification: targetVersification
            ),
            manager: manager
        )
    }

    /**
     Converts one persisted verse range into addressable target-module indexes.

     - Parameters describe the source range and already-enumerated target module.
     - Returns: Inclusive target positions, or `nil` if strict endpoint conversion or addressability
       fails.
     - Side effects: Reads JSword mapping resources and SWORD's target verse index.
     - Failure modes: Returns `nil` atomically; no endpoint is clamped across books or relabeled.
     */
    public static func positionBounds(
        for range: SpeakVerseRange,
        module: SwordModule,
        positions: [SpeakStreamPosition],
        targetVersification: String? = nil
    ) -> ClosedRange<Int>? {
        guard let endpoints = range.validatedReferences() else { return nil }
        let target = targetVersification ?? VersificationMapper.versificationName(for: module)
        guard let convertedStart = VersificationMapper.convertStrictly(
                  osisBookId: endpoints.start.osisBookId,
                  chapter: endpoints.start.chapter,
                  verse: endpoints.start.verse,
                  from: range.versification,
                  to: target
              )?.reference,
              let convertedEnd = VersificationMapper.convertStrictly(
                  osisBookId: endpoints.end.osisBookId,
                  chapter: endpoints.end.chapter,
                  verse: endpoints.end.verse,
                  from: range.versification,
                  to: target
              )?.reference,
              let startOrdinal = module.verseOrdinal(
                  osisBookId: convertedStart.osisBookId,
                  chapter: convertedStart.chapter,
                  verse: convertedStart.verse
              ),
              let endOrdinal = module.verseOrdinal(
                  osisBookId: convertedEnd.osisBookId,
                  chapter: convertedEnd.chapter,
                  verse: convertedEnd.verse
              ),
              startOrdinal <= endOrdinal,
              let lower = exactPositionIndex(forOrdinal: startOrdinal, positions: positions),
              let upper = exactPositionIndex(forOrdinal: endOrdinal, positions: positions),
              lower <= upper else {
            return nil
        }
        return lower...upper
    }

    /** Finds one exact single-verse provider position without snapping across missing content. */
    static func exactPositionIndex(
        forOrdinal ordinal: Int,
        positions: [SpeakStreamPosition]
    ) -> Int? {
        positions.firstIndex {
            $0.ordinalStart == ordinal && $0.ordinalEnd == ordinal
        }
    }

    /**
     Formats one target-module range title using the same short verse names supplied to speech.

     - Parameter positions: Non-empty ordered positions belonging to one original passage range.
     - Returns: A single-verse name, compact same-chapter range, or first-to-last display name;
       returns `nil` for an empty range.
     - Side effects: None.
     - Failure modes: Missing chapter/verse metadata falls back to exact endpoint names rather than
       dropping or merging the passage boundary.
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

    /** Enumerates real verses while preserving exact target-module cursor and bookmark provenance. */
    private static func biblePositions(
        module: SwordModule,
        category: SpeakDocumentCategory,
        targetVersification: String
    ) -> [SpeakStreamPosition] {
        var positionsByOrdinal: [Int: SpeakStreamPosition] = [:]
        for key in module.allKeys() {
            let inspection = module.inspectVerseKeyAndRawEntryRestoringPrevious(key)
            guard let verseKey = inspection.verseKey,
                  verseKey.verse > 0,
                  inspection.actualKey == key || inspection.actualKey == verseKey.osisRef else {
                continue
            }
            let osisRef = verseKey.osisRef.isEmpty
                ? "\(verseKey.osisBookName).\(verseKey.chapter).\(verseKey.verse)"
                : verseKey.osisRef
            let displayBook = verseKey.bookName.isEmpty ? verseKey.osisBookName : verseKey.bookName
            let keyName = verseKey.shortText.isEmpty
                ? "\(displayBook) \(verseKey.chapter):\(verseKey.verse)"
                : verseKey.shortText
            let verifiedRange = VerifiedKJVAOrdinalRange(
                resolvingSourceBookInitials: module.info.name,
                sourceVersification: targetVersification,
                sourceOrdinalStart: verseKey.index,
                sourceOrdinalEnd: verseKey.index
            )
            positionsByOrdinal[verseKey.index] = SpeakStreamPosition(
                id: "\(module.info.name):\(targetVersification):\(verseKey.index)",
                category: category,
                bookInitials: module.info.name,
                key: inspection.actualKey,
                osisRef: osisRef,
                keyName: keyName,
                bookName: displayBook,
                ordinalStart: verseKey.index,
                ordinalEnd: verseKey.index,
                chapter: verseKey.chapter,
                verse: verseKey.verse,
                groupIdentifier: "\(verseKey.osisBookName).\(verseKey.chapter)",
                language: module.info.language,
                versification: targetVersification,
                verifiedBibleRange: verifiedRange
            )
        }
        return positionsByOrdinal.keys.sorted().compactMap { positionsByOrdinal[$0] }
    }

    /** Strictly converts one source ordinal into the explicitly requested target module's domain. */
    private static func convertedOrdinal(
        _ sourceOrdinal: Int,
        sourceVersification: String,
        targetVersification: String,
        module: SwordModule
    ) throws -> Int {
        guard let sourceReference = SwordVersification.reference(
                  forIndex: sourceOrdinal,
                  versification: sourceVersification
              ),
              sourceReference.verse > 0 else {
            throw BibleSpeakSourceResolutionError.invalidSourceOrdinal(
                sourceOrdinal,
                versification: sourceVersification
            )
        }
        guard let targetReference = VersificationMapper.convertStrictly(
            osisBookId: sourceReference.osisBookId,
            chapter: sourceReference.chapter,
            verse: sourceReference.verse,
            from: sourceVersification,
            to: targetVersification
        )?.reference else {
            throw BibleSpeakSourceResolutionError.unmappableSourceOrdinal(
                sourceOrdinal,
                sourceVersification: sourceVersification,
                targetVersification: targetVersification
            )
        }
        let osisRef = "\(targetReference.osisBookId).\(targetReference.chapter).\(targetReference.verse)"
        guard let targetOrdinal = module.verseOrdinal(
            osisBookId: targetReference.osisBookId,
            chapter: targetReference.chapter,
            verse: targetReference.verse
        ) else {
            throw BibleSpeakSourceResolutionError.targetModuleDoesNotAddress(osisRef)
        }
        return targetOrdinal
    }

    /** Returns one cursor's exact single-verse ordinal without accepting widened ranges. */
    private static func exactOrdinal(from cursor: SpeakStreamCursor) -> Int? {
        guard let start = cursor.ordinalStart,
              cursor.ordinalEnd == start else {
            return nil
        }
        return start
    }
}
