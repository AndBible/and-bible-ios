// BibleReaderDailyReadingActionCoordinator.swift -- Active-Bible daily-reading execution

import BibleCore
import Foundation
import SwordKit

/** Exact active-source passage produced from one reading-plan range. */
struct BibleReaderDailyReadingPassage: Equatable {
    /// First converted target-source verse.
    let start: SwordVersification.Reference
    /// Last converted target-source verse.
    let end: SwordVersification.Reference
    /// Inclusive active-source ordinal range used for navigation highlighting.
    let ordinalRange: ClosedRange<Int>
    /// Exact target-versification range supplied to bounded key-list speech.
    let speechRange: SpeakVerseRange
}

/** Fail-visible reasons the reader cannot perform a Daily Reading action. */
enum BibleReaderDailyReadingActionFailure: Error, Equatable, LocalizedError {
    /// No installed active Bible can own the action.
    case activeBibleUnavailable
    /// The request shape or one source-to-target mapping is invalid.
    case invalidPassage
    /// The target module mapped the range but speech could not start.
    case speechUnavailable

    /// Android-shared localized message presented by `DailyReadingView`.
    var errorDescription: String? {
        switch self {
        case .activeBibleUnavailable:
            return String(localized: "picker_no_bible_modules", defaultValue: "No Bible modules installed")
        case .invalidPassage:
            return String(localized: "reading_plan_import_error_format", defaultValue: "Invalid reading plan format")
        case .speechUnavailable:
            return String(localized: "tts_lang_not_available", defaultValue: "Language is not available.")
        }
    }
}

/**
 Maps and performs Android Daily Reading actions against the active installed Bible source.

 Android parses plan keys in the plan's declared versification, converts each complete key to the
 current Bible, navigates Read to the first converted verse, and sends Speak/Speak All as an ordered
 `List<Key>`. This coordinator validates every passage before invoking either side-effect closure,
 preventing partial speech queues and source-coordinate reinterpretation.
 */
@MainActor
enum BibleReaderDailyReadingActionCoordinator {
    /**
     Performs one already parsed Daily Reading request against a backend-neutral installed Bible.

     - Parameters:
       - request: Plan-canon request emitted by `DailyReadingView`.
       - source: Active SWORD or Android-compatible SQLite Bible owning output coordinates.
       - navigate: Atomic active-Bible navigation callback for one converted range.
       - speak: Bounded ordered passage-list speech callback retaining semantic boundaries.
     - Side effects: Invokes exactly one supplied callback after every passage maps successfully.
     - Throws: Cancellation, invalid request/mapping, or speech-start failure. No callback runs after
       a validation failure, and Read rejects multi-passage requests instead of choosing one.
     */
    static func perform(
        _ request: DailyReadingActionRequest,
        source: BibleReaderInstalledScriptureSource,
        navigate: (BibleReaderDailyReadingPassage) throws -> Void,
        speak: ([BibleReaderDailyReadingPassage]) throws -> Bool
    ) throws {
        try Task.checkCancellation()
        let passages = try mappedPassages(request.passages, source: source)
        guard passages.count == request.readingNumbers.count, !passages.isEmpty else {
            throw BibleReaderDailyReadingActionFailure.invalidPassage
        }
        try Task.checkCancellation()

        switch request.kind {
        case .read:
            guard passages.count == 1, let passage = passages.first else {
                throw BibleReaderDailyReadingActionFailure.invalidPassage
            }
            try navigate(passage)
        case .speak:
            guard try speak(passages) else {
                throw BibleReaderDailyReadingActionFailure.speechUnavailable
            }
        }
    }

    /**
     Preserves the established SWORD-only collaborator contract for existing callers and tests.

     - Parameters:
       - request: Plan-canon request emitted by `DailyReadingView`.
       - module: Active installed Bible that owns navigation and speech output.
       - navigate: Atomic active-Bible navigation callback for one converted range.
       - speak: Bounded ordered passage-list speech callback.
     - Side effects: Invokes exactly one supplied callback after every passage maps successfully.
     - Throws: Cancellation, invalid request/mapping, or speech-start failure. No callback runs after
       a validation failure, and Read rejects multi-passage requests instead of choosing one.
     */
    static func perform(
        _ request: DailyReadingActionRequest,
        module: SwordModule,
        navigate: (BibleReaderDailyReadingPassage) throws -> Void,
        speak: ([SpeakVerseRange]) throws -> Bool
    ) throws {
        try perform(
            request,
            source: .sword(module),
            navigate: navigate,
            speak: { passages in
                try speak(passages.map(\.speechRange))
            }
        )
    }

    /**
     Converts every source passage atomically into an installed source's versification.

     - Parameters:
       - passages: Exact plan-canon endpoints in caller order.
       - source: Active SWORD or Android-compatible SQLite target Bible.
     - Returns: Converted ranges with target ordinals and speech identities.
     - Side effects: Reads JSword mapping resources and source-owned verse indexes.
     - Throws: `activeBibleUnavailable` for a non-Bible source, or `invalidPassage` when Android's
       public conversion rejects an endpoint, the retained or mapped coordinate is not addressable,
       the ordinal range is reversed, or the target OSIS range is invalid. No partial result returns.
     */
    static func mappedPassages(
        _ passages: [ReadingPlanPassageTarget],
        source: BibleReaderInstalledScriptureSource
    ) throws -> [BibleReaderDailyReadingPassage] {
        guard source.info.category == .bible else {
            throw BibleReaderDailyReadingActionFailure.activeBibleUnavailable
        }
        let targetVersification = source.versificationName
        return try passages.map { passage in
            guard let mappedStart = VersificationMapper.convert(
                      osisBookId: passage.start.osisBookId,
                      chapter: passage.start.chapter,
                      verse: passage.start.verse,
                      from: passage.sourceVersification,
                      to: targetVersification
                  )?.reference,
                  let mappedEnd = VersificationMapper.convert(
                      osisBookId: passage.end.osisBookId,
                      chapter: passage.end.chapter,
                      verse: passage.end.verse,
                      from: passage.sourceVersification,
                      to: targetVersification
                  )?.reference,
                  let startOrdinal = source.verseOrdinal(
                      osisBookId: mappedStart.osisBookId,
                      chapter: mappedStart.chapter,
                      verse: mappedStart.verse
                  ),
                  let endOrdinal = source.verseOrdinal(
                      osisBookId: mappedEnd.osisBookId,
                      chapter: mappedEnd.chapter,
                      verse: mappedEnd.verse
                  ),
                  startOrdinal <= endOrdinal else {
                throw BibleReaderDailyReadingActionFailure.invalidPassage
            }
            let targetOSIS = mappedStart == mappedEnd
                ? osisReference(mappedStart)
                : "\(osisReference(mappedStart))-\(osisReference(mappedEnd))"
            guard let speechRange = SpeakVerseRange(
                      versification: targetVersification,
                      osisRef: targetOSIS
                  ) else {
                throw BibleReaderDailyReadingActionFailure.invalidPassage
            }
            return BibleReaderDailyReadingPassage(
                start: mappedStart,
                end: mappedEnd,
                ordinalRange: startOrdinal...endOrdinal,
                speechRange: speechRange
            )
        }
    }

    /**
     Preserves the established SWORD mapping entry point for focused coordinator callers.

     - Parameters:
       - passages: Exact plan-canon endpoints in caller order.
       - module: Active target Bible.
     - Returns: Converted ranges with target ordinals and speech identities.
     - Side effects: Reads JSword mapping resources and target-module verse indexes.
     - Throws: `invalidPassage` when Android's public conversion rejects an endpoint, the retained
       or mapped coordinate is not addressable by the active module, the ordinal range is reversed,
       or the target OSIS range is invalid. No partial result is returned.
     */
    static func mappedPassages(
        _ passages: [ReadingPlanPassageTarget],
        module: SwordModule
    ) throws -> [BibleReaderDailyReadingPassage] {
        try mappedPassages(passages, source: .sword(module))
    }

    /** Returns one canonical OSIS verse identifier for a concrete mapped reference. */
    private static func osisReference(_ reference: SwordVersification.Reference) -> String {
        "\(reference.osisBookId).\(reference.chapter).\(reference.verse)"
    }
}
