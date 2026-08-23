// BibleReaderSpeechProviderFactory.swift -- Typed reader speech-provider construction

import BibleCore
import Foundation
import SwordKit

/** Provider plus source metadata needed by reader callbacks and reconstruction. */
struct BibleReaderSpeechProviderBuild {
    let provider: SpeakTextProviding
    let module: SwordModule?
}

/**
 Constructs reader speech providers without crossing Bible and generic source domains.

 Bible and memorization requests resolve the explicitly requested installed module and strictly map
 source ordinals into its versification. Generic sources retain exact local BVA ordinals and load
 one key lazily, matching Android's `BookAndKey` provider instead of flattening whole pages.
 */
enum BibleReaderSpeechProviderFactory {
    /**
     Builds a strict Bible or memorization provider.

     - Parameters:
       - request: Typed requested module, source versification, and source ordinals.
       - manager: Installed module registry and global markup-option owner.
       - displaySettings: Current markup settings restored after clean speech extraction.
       - advancedSettings: Current global speech behavior.
     - Returns: A category-correct provider and its requested module.
     - Side effects: Enumerates requested-module verse keys and temporarily toggles global SWORD
       markup options only while a unit is loaded.
     - Throws: Strict module, versification, mapping, or addressability errors from
       `BibleSpeakSourceResolver`; no active-module or identity fallback is used.
     */
    static func bible(
        request: SpeakSelectionRequest,
        manager: SwordManager,
        displaySettings: TextDisplaySettings,
        advancedSettings: AdvancedSpeakSettings
    ) throws -> BibleReaderSpeechProviderBuild {
        let source = try BibleSpeakSourceResolver.resolve(request: request, manager: manager)
        return try bibleBuild(
            source: source,
            manager: manager,
            displaySettings: displaySettings,
            advancedSettings: advancedSettings
        )
    }

    /** Reconstructs a strict Bible or memorization provider from an exact persisted checkpoint. */
    static func bible(
        checkpoint: SpeakProviderCheckpoint,
        manager: SwordManager,
        displaySettings: TextDisplaySettings,
        advancedSettings: AdvancedSpeakSettings
    ) throws -> BibleReaderSpeechProviderBuild {
        let source = try BibleSpeakSourceResolver.resolve(checkpoint: checkpoint, manager: manager)
        if checkpoint.version == 2 {
            return biblePassageListBuild(
                source: source,
                manager: manager,
                displaySettings: displaySettings,
                advancedSettings: advancedSettings,
                resumePlaybackCursor: checkpoint.playbackCursor
            )
        }
        return try bibleBuild(
            source: source,
            manager: manager,
            displaySettings: displaySettings,
            advancedSettings: advancedSettings
        )
    }

    /**
     Builds Android's bounded ordered `List<Key>` Bible speech provider.

     - Parameters:
       - bookInitials: Installed Bible that owns target speech text.
       - ranges: Ordered source-versification ranges; each range is converted independently.
       - manager: Installed module registry.
       - displaySettings: Markup settings restored after clean text extraction.
       - advancedSettings: Current global speech behavior.
     - Returns: Exact bounded passage-list provider and its requested module.
     - Side effects: Enumerates the target module and lazily reads its verses during playback.
     - Throws: Strict module, mapping, and addressability errors. No partial queue or first-to-last
       range is produced.
     */
    static func biblePassageList(
        bookInitials: String,
        ranges: [SpeakVerseRange],
        manager: SwordManager,
        displaySettings: TextDisplaySettings,
        advancedSettings: AdvancedSpeakSettings
    ) throws -> BibleReaderSpeechProviderBuild {
        let source = try BibleSpeakSourceResolver.resolvePassageList(
            bookInitials: bookInitials,
            ranges: ranges,
            manager: manager
        )
        return biblePassageListBuild(
            source: source,
            manager: manager,
            displaySettings: displaySettings,
            advancedSettings: advancedSettings,
            resumePlaybackCursor: nil
        )
    }

    /** Builds one resolved Bible-family source without changing its requested identity or bounds. */
    private static func bibleBuild(
        source: ResolvedBibleSpeakSource,
        manager: SwordManager,
        displaySettings: TextDisplaySettings,
        advancedSettings: AdvancedSpeakSettings
    ) throws -> BibleReaderSpeechProviderBuild {
        let loader = bibleLoader(
            module: source.module,
            manager: manager,
            displaySettings: displaySettings
        )
        let provider: SpeakTextProviding
        switch source.category {
        case .bible:
            provider = BibleSpeakTextProvider(
                positions: source.positions,
                startIndex: source.startIndex,
                bounds: source.bounds,
                advancedSettings: advancedSettings,
                verseRangeResolver: source.positionBounds(for:),
                loader: loader
            )
        case .memorization:
            guard let bounds = source.bounds else {
                throw BibleSpeakSourceResolutionError.noAddressableContent(source.module.info.name)
            }
            provider = MemorizationSpeakTextProvider(
                positions: source.positions,
                startIndex: source.startIndex,
                bounds: bounds,
                advancedSettings: advancedSettings,
                loader: loader
            )
        case .commentary, .dictionary, .generalBook, .myDocument, .selection:
            throw BibleSpeakSourceResolutionError.unsupportedCategory(source.category)
        }
        return BibleReaderSpeechProviderBuild(provider: provider, module: source.module)
    }

    /**
     Builds a queue provider from an already validated ordered passage source.

     - Parameters:
       - source: Strictly resolved passages plus the flattened current occurrence.
       - manager: Module manager whose markup settings are temporarily controlled by lazy loaders.
       - displaySettings: Reader display options restored after each text extraction.
       - advancedSettings: Speech behavior captured by the new provider.
       - resumePlaybackCursor: Exact version-2 command progress, or `nil` for a fresh request.
     - Returns: A bounded passage-list provider with one occurrence-specific loader per passage.
     - Side effects: Creates lazy module loaders; no SWORD text is read until playback materializes a
       unit.
     - Failure modes: The resolver must supply non-empty passages and a valid flattened index;
       inconsistent input creates a provider that fails preparation rather than inferring a cursor.
     */
    private static func biblePassageListBuild(
        source: ResolvedBibleSpeakSource,
        manager: SwordManager,
        displaySettings: TextDisplaySettings,
        advancedSettings: AdvancedSpeakSettings,
        resumePlaybackCursor: SpeakPlaybackCursor?
    ) -> BibleReaderSpeechProviderBuild {
        var remainingStartIndex = source.startIndex
        var startPassageIndex = 0
        var startPositionIndex = 0
        for (index, passage) in source.passages.enumerated() {
            if remainingStartIndex < passage.positions.count {
                startPassageIndex = index
                startPositionIndex = remainingStartIndex
                break
            }
            remainingStartIndex -= passage.positions.count
        }
        let segments = source.passages.map {
            SpeakPassageSegment(
                sourceRange: $0.sourceRange,
                title: $0.title,
                positions: $0.positions
            )
        }
        let loaders = source.passages.map {
            bibleLoader(
                module: $0.module,
                manager: manager,
                displaySettings: displaySettings
            )
        }
        let provider = BiblePassageListSpeakTextProvider(
            passages: segments,
            loaders: loaders,
            startPassageIndex: startPassageIndex,
            startPositionIndexInPassage: startPositionIndex,
            resumePlaybackCursor: resumePlaybackCursor,
            advancedSettings: advancedSettings
        )
        return BibleReaderSpeechProviderBuild(provider: provider, module: source.module)
    }

    /**
     Builds a lazy exact-ordinal provider for a SWORD generic module.

     - Parameters describe the concrete source and optional Android `OrdinalRange` endpoint.
     - Returns: Category-correct provider, or `nil` when category, key, or exact ordinal content is
       unavailable.
     - Side effects: Reads only the start and optional end key during construction; subsequent keys
       load lazily through `rawOSISFragment(forKey:)`, which restores the SWORD cursor.
     - Failure modes: Category mismatches, snapped keys, malformed OSIS, missing BVA anchors, and
       invalid bounds fail closed.
     */
    static func genericModule(
        context: BibleReaderGenericSpeechContext,
        requestedKey: String?,
        startOrdinal: Int?,
        endKey: String? = nil,
        endOrdinal: Int?
    ) -> BibleReaderSpeechProviderBuild? {
        guard let source = genericSource(context: context) else { return nil }
        let keys = source.keys
        guard let key = requestedKey ?? context.currentKey ?? keys.first else { return nil }
        guard let provider = GenericOrdinalSpeakTextProvider(
            source: source,
            startKey: key,
            startOrdinal: startOrdinal,
            endKey: endOrdinal == nil ? nil : (endKey ?? key),
            endOrdinal: endOrdinal
        ) else {
            return nil
        }
        return BibleReaderSpeechProviderBuild(provider: provider, module: context.module)
    }

    /** Reconstructs a SWORD generic provider from exact module, key, ordinal, and bound cursors. */
    static func genericModule(
        context: BibleReaderGenericSpeechContext,
        checkpoint: SpeakProviderCheckpoint
    ) -> BibleReaderSpeechProviderBuild? {
        if checkpoint.version == 0 {
            let cursor = checkpoint.current
            guard cursor.bookInitials == context.moduleName,
                  let ordinal = cursor.ordinalStart,
                  cursor.ordinalEnd == ordinal else {
                return nil
            }
            return genericModule(
                context: context,
                requestedKey: cursor.key,
                startOrdinal: ordinal,
                endOrdinal: nil
            )
        }
        guard let source = genericSource(context: context),
              let provider = GenericOrdinalSpeakTextProvider(
                  source: source,
                  checkpoint: checkpoint
              ) else {
            return nil
        }
        return BibleReaderSpeechProviderBuild(provider: provider, module: context.module)
    }

    /**
     Builds a lazy exact-ordinal provider for EPUB or My Documents pages.

     EPUB markup must contain one structured BVA element for every declared ordinal. A single-unit
     My Documents page uses its already structured visible-text projection. No multi-ordinal page
     silently falls back to flattened text.
     */
    static func pages(
        category: SpeakDocumentCategory,
        bookInitials: String,
        bookName: String,
        pages: [BibleReaderSpeechPage],
        currentKey: String?,
        startOrdinal: Int?,
        endKey: String? = nil,
        endOrdinal: Int?
    ) -> BibleReaderSpeechProviderBuild? {
        guard let source = pageSource(
            category: category,
            bookInitials: bookInitials,
            bookName: bookName,
            pages: pages
        ) else {
            return nil
        }
        let keys = source.keys
        guard
              let key = currentKey ?? keys.first else {
            return nil
        }
        guard let provider = GenericOrdinalSpeakTextProvider(
            source: source,
            startKey: key,
            startOrdinal: startOrdinal,
            endKey: endOrdinal == nil ? nil : (endKey ?? key),
            endOrdinal: endOrdinal
        ) else {
            return nil
        }
        return BibleReaderSpeechProviderBuild(provider: provider, module: nil)
    }

    /** Reconstructs an EPUB or My Documents provider from exact persisted page cursors. */
    static func pages(
        category: SpeakDocumentCategory,
        bookInitials: String,
        bookName: String,
        pages: [BibleReaderSpeechPage],
        checkpoint: SpeakProviderCheckpoint
    ) -> BibleReaderSpeechProviderBuild? {
        if checkpoint.version == 0 {
            let cursor = checkpoint.current
            guard cursor.bookInitials == bookInitials,
                  let ordinal = cursor.ordinalStart,
                  cursor.ordinalEnd == ordinal else {
                return nil
            }
            return Self.pages(
                category: category,
                bookInitials: bookInitials,
                bookName: bookName,
                pages: pages,
                currentKey: cursor.key,
                startOrdinal: ordinal,
                endOrdinal: nil
            )
        }
        guard let source = pageSource(
            category: category,
            bookInitials: bookInitials,
            bookName: bookName,
            pages: pages
        ),
        let provider = GenericOrdinalSpeakTextProvider(source: source, checkpoint: checkpoint) else {
            return nil
        }
        return BibleReaderSpeechProviderBuild(provider: provider, module: nil)
    }

    /** Creates the lazy Bible OSIS command loader for one explicitly requested module. */
    private static func bibleLoader(
        module: SwordModule,
        manager: SwordManager,
        displaySettings: TextDisplaySettings
    ) -> SpeakStreamUnitLoader {
        { position, settings, advanced in
            withMarkupOptionsTemporarilyDisabled(
                manager: manager,
                displaySettings: displaySettings
            ) {
                let savedKey = module.currentKey()
                defer { module.setKey(savedKey) }
                let introductionCommands = chapterIntroductionCommands(
                    for: position,
                    module: module,
                    settings: settings,
                    advancedSettings: advanced
                )
                let entry = module.setKeyAndInspect(position.key)
                let verseCommands = SpeakCommandBuilder.commands(
                    rawOSIS: entry.rawEntry,
                    fallbackPlainText: entry.strippedText,
                    language: position.language,
                    playbackSettings: settings.playbackSettings,
                    advancedSettings: advanced
                )
                return mergedBibleCommands(
                    chapterIntroduction: introductionCommands,
                    verse: verseCommands
                )
            }
        }
    }

    /** Prepends missing verse-zero content without repeating headings embedded in verse one. */
    static func mergedBibleCommands(
        chapterIntroduction: [SpeakCommand],
        verse: [SpeakCommand]
    ) -> [SpeakCommand] {
        let introductionSpeech = chapterIntroduction.compactMap(\.spokenText)
        guard !introductionSpeech.isEmpty else { return verse }
        let verseSpeech = verse.compactMap(\.spokenText)
        if verseSpeech.starts(with: introductionSpeech) {
            return verse
        }
        return chapterIntroduction + verse
    }

    /** Loads Android's chapter-introduction verse zero before a chapter's first concrete verse. */
    private static func chapterIntroductionCommands(
        for position: SpeakStreamPosition,
        module: SwordModule,
        settings: SpeakSettings,
        advancedSettings: AdvancedSpeakSettings
    ) -> [SpeakCommand] {
        guard position.verse == 1,
              let chapter = position.chapter,
              let osisBookId = position.osisRef?.split(separator: ".").first.map(String.init),
              !osisBookId.isEmpty else {
            return []
        }
        let introduction = module.inspectVerseKeyAndRawEntryRestoringPrevious(
            "=\(osisBookId).\(chapter).0"
        )
        let expectedOsisRef = "\(osisBookId).\(chapter)"
        guard let key = introduction.verseKey,
              key.osisRef == expectedOsisRef || key.osisRef == "\(expectedOsisRef).0",
              key.chapter == chapter,
              key.verse == 0,
              !introduction.rawEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        return SpeakCommandBuilder.commands(
            rawOSIS: introduction.rawEntry,
            fallbackPlainText: "",
            language: position.language,
            playbackSettings: settings.playbackSettings,
            advancedSettings: advancedSettings
        )
    }

    /** Builds the exact lazy BVA source for one category-validated SWORD generic module. */
    private static func genericSource(
        context: BibleReaderGenericSpeechContext
    ) -> GenericSpeakOrdinalSource? {
        guard category(for: context.module.info.category) == context.category else { return nil }
        return GenericSpeakOrdinalSource(
            category: context.category,
            bookInitials: context.moduleName,
            bookName: context.displayName,
            language: speechLanguage(for: context.module),
            keys: context.module.allKeys(),
            loadContent: { sourceKey in
                guard let fragment = try? context.module.rawOSISFragment(forKey: sourceKey),
                      !fragment.anchorTexts.isEmpty else {
                    return nil
                }
                let commands: [Int: [SpeakCommand]] = fragment.anchorTexts.mapValues { text in
                    let normalized = normalizeGenericText(text)
                    return normalized.isEmpty ? [] : [SpeakCommand.text(normalized)]
                }
                return GenericSpeakKeyContent(
                    key: fragment.key,
                    keyName: fragment.keyName,
                    ordinalRange: fragment.contentOrdinalRange,
                    commandsByOrdinal: commands
                )
            }
        )
    }

    /** Builds an exact lazy BVA source for EPUB or one-unit My Documents pages. */
    private static func pageSource(
        category: SpeakDocumentCategory,
        bookInitials: String,
        bookName: String,
        pages: [BibleReaderSpeechPage]
    ) -> GenericSpeakOrdinalSource? {
        guard category == .generalBook || category == .myDocument else { return nil }
        let keys = pages.map(\.key)
        guard Set(keys).count == keys.count else { return nil }
        let pagesByKey = Dictionary(uniqueKeysWithValues: pages.map { ($0.key, $0) })
        return GenericSpeakOrdinalSource(
            category: category,
            bookInitials: bookInitials,
            bookName: bookName,
            language: pages.first?.language ?? "en",
            keys: keys,
            loadContent: { sourceKey in
                guard let page = pagesByKey[sourceKey],
                      let ordinalTexts = pageOrdinalTexts(page),
                      !ordinalTexts.isEmpty else {
                    return nil
                }
                return GenericSpeakKeyContent(
                    key: page.key,
                    keyName: page.title,
                    ordinalRange: page.ordinalRange,
                    commandsByOrdinal: ordinalTexts.mapValues { [.text($0)] }
                )
            }
        )
    }

    /** Applies Android-clean SWORD markup options around one extraction operation. */
    private static func withMarkupOptionsTemporarilyDisabled<Result>(
        manager: SwordManager,
        displaySettings: TextDisplaySettings,
        _ operation: () -> Result
    ) -> Result {
        let strongsWasOn = (displaySettings.strongsMode ?? 0) > 0
        let morphWasOn = displaySettings.showMorphology ?? false
        if strongsWasOn { manager.setGlobalOption(.strongsNumbers, enabled: false) }
        if morphWasOn { manager.setGlobalOption(.morphology, enabled: false) }
        defer {
            if strongsWasOn { manager.setGlobalOption(.strongsNumbers, enabled: true) }
            if morphWasOn { manager.setGlobalOption(.morphology, enabled: true) }
        }
        return operation()
    }

    /**
     Maps one actual SWORD/JSword category into Android's speech-provider category domain.

     - Parameter moduleCategory: Installed-book category retained from JSword metadata.
     - Returns: Commentary, dictionary, or general-book speech identity; Bible/add-on/unknown books
       remain owned by their separate providers and return nil.
     - Side effects: None.
     - Failure modes: None; all pinned JSword categories have an explicit mapping.
     */
    static func category(for moduleCategory: ModuleCategory) -> SpeakDocumentCategory? {
        switch moduleCategory {
        case .commentary:
            .commentary
        case .dictionary, .glossary:
            .dictionary
        case .generalBook, .map, .dailyDevotion, .questionable, .essays, .images:
            .generalBook
        case .bible, .addon, .unknown:
            nil
        }
    }

    /** Resolves exact page ordinal text without flattening multi-ordinal EPUB content. */
    private static func pageOrdinalTexts(_ page: BibleReaderSpeechPage) -> [Int: String]? {
        if let projected = GenericSpeakOrdinalProjection.epubOrdinalTexts(
            xhtml: page.rawMarkup,
            expectedRange: page.ordinalRange
        ) {
            return projected
        }
        guard page.ordinalRange.count == 1 else { return nil }
        let text = normalizeGenericText(page.plainText)
        return text.isEmpty ? nil : [page.ordinalRange.lowerBound: text]
    }

    /** Matches Android's generic newline replacement and speech whitespace normalization. */
    private static func normalizeGenericText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /** Normalizes SWORD's short `en` code to the platform's preferred voice identifier. */
    private static func speechLanguage(for module: SwordModule) -> String {
        let language = module.info.language
        return language.hasPrefix("en") ? "en-US" : language
    }
}
