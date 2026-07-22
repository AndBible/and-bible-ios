import BibleCore
import SwordKit
import XCTest
@testable import BibleUI

/** Active-Bible mapping and side-effect ordering tests for Android Daily Reading actions. */
final class BibleReaderDailyReadingActionCoordinatorTests: BibleUISwordFixtureTestCase {
    /// Owns native SWORD managers for as long as returned module handles remain under test.
    private var retainedManagers: [SwordManager] = []

    /**
     Verifies Read converts the complete plan range before invoking one atomic Bible navigation.

     A successful callback receives target-module references and the inclusive target ordinal span;
     speech must remain untouched. Failure indicates Read can navigate source coordinates directly
     or lose the selected range before the parent reader boundary.
     */
    @MainActor
    func testReadMapsRangeAndInvokesOnlyNavigation() throws {
        let module = try makeKJVModule()
        let request = makeRequest(
            kind: .read,
            readingNumbers: [1],
            passages: [passage("Gen", 1, 1, 3)]
        )
        var navigation: BibleReaderDailyReadingPassage?
        var didSpeak = false

        try BibleReaderDailyReadingActionCoordinator.perform(
            request,
            module: module,
            navigate: { navigation = $0 },
            speak: { _ in
                didSpeak = true
                return true
            }
        )

        XCTAssertEqual(navigation?.start, .init(osisBookId: "Gen", chapter: 1, verse: 1))
        XCTAssertEqual(navigation?.end, .init(osisBookId: "Gen", chapter: 1, verse: 3))
        XCTAssertEqual(navigation?.ordinalRange.lowerBound, module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1))
        XCTAssertEqual(navigation?.ordinalRange.upperBound, module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 3))
        XCTAssertFalse(didSpeak)
    }

    /**
     Verifies Speak All retains each converted range as a separate ordered key-list member.

     Genesis, Matthew, and Revelation must reach speech as three ranges. A first-to-last
     normalization would include most of the Bible and fail this contract.
     */
    @MainActor
    func testSpeakAllPreservesDiscontiguousPassageOrder() throws {
        let module = try makeKJVModule()
        let request = makeRequest(
            kind: .speak,
            readingNumbers: [1, 2, 3],
            passages: [
                passage("Gen", 1, 1, 2),
                passage("Matt", 1, 1, 1),
                passage("Rev", 22, 20, 21),
            ]
        )
        var ranges: [SpeakVerseRange] = []

        try BibleReaderDailyReadingActionCoordinator.perform(
            request,
            module: module,
            navigate: { _ in XCTFail("Speak All must not navigate") },
            speak: {
                ranges = $0
                return true
            }
        )

        XCTAssertEqual(ranges.map(\.osisRef), [
            "Gen.1.1-Gen.1.2",
            "Matt.1.1",
            "Rev.22.20-Rev.22.21",
        ])
        XCTAssertEqual(ranges.map(\.versification), ["KJV", "KJV", "KJV"])
    }

    /**
     Verifies one unmappable endpoint aborts Speak All before any side effect occurs.

     The malformed target reference is mixed with a valid first passage to prove the coordinator
     validates the whole list atomically instead of starting a partial queue.
     */
    @MainActor
    func testInvalidPassageFailsBeforeNavigationOrSpeech() throws {
        let module = try makeKJVModule()
        let request = makeRequest(
            kind: .speak,
            readingNumbers: [1, 2],
            passages: [
                passage("Gen", 1, 1, 1),
                passage("Gen", 999, 1, 1),
            ]
        )
        var sideEffectCount = 0

        XCTAssertThrowsError(
            try BibleReaderDailyReadingActionCoordinator.perform(
                request,
                module: module,
                navigate: { _ in sideEffectCount += 1 },
                speak: { _ in
                    sideEffectCount += 1
                    return true
                }
            )
        ) { error in
            XCTAssertEqual(error as? BibleReaderDailyReadingActionFailure, .invalidPassage)
        }
        XCTAssertEqual(sideEffectCount, 0)
    }

    /**
     Verifies Daily Reading retains Android's public conversion fallback when the active Bible owns it.

     JSword can construct `Matt.1.1` in the source `MT` system even though strict conversion rejects
     the coordinate because MT has no New Testament canon entry. Android's public converter retains
     that coordinate, and the active KJV module can address it, so Read must navigate successfully.
     A failure means iOS has regressed to stricter behavior than Android.
     */
    @MainActor
    func testReadAcceptsAndroidFallbackCoordinateWhenActiveBibleAddressesIt() throws {
        let module = try makeKJVModule()
        let request = makeRequest(
            kind: .read,
            readingNumbers: [1],
            passages: [passage("Matt", 1, 1, 1, sourceVersification: "MT")]
        )
        var navigation: BibleReaderDailyReadingPassage?

        XCTAssertNil(
            VersificationMapper.convertStrictly(
                osisBookId: "Matt",
                chapter: 1,
                verse: 1,
                from: "MT",
                to: "KJV"
            )
        )
        try BibleReaderDailyReadingActionCoordinator.perform(
            request,
            module: module,
            navigate: { navigation = $0 },
            speak: { _ in
                XCTFail("Read must not start speech")
                return false
            }
        )

        XCTAssertEqual(navigation?.start, .init(osisBookId: "Matt", chapter: 1, verse: 1))
        XCTAssertEqual(navigation?.end, .init(osisBookId: "Matt", chapter: 1, verse: 1))
    }

    /**
     Verifies a provider-start failure remains throwable so Daily Reading does not mark progress.

     Mapping succeeds, but the speech closure rejects startup. The coordinator must surface the
     failure rather than treating validated ranges as completed playback.
     */
    @MainActor
    func testSpeechStartFailureThrowsAfterExactMapping() throws {
        let module = try makeKJVModule()
        let request = makeRequest(
            kind: .speak,
            readingNumbers: [1],
            passages: [passage("Gen", 1, 1, 1)]
        )

        XCTAssertThrowsError(
            try BibleReaderDailyReadingActionCoordinator.perform(
                request,
                module: module,
                navigate: { _ in XCTFail("Speak must not navigate") },
                speak: { _ in false }
            )
        ) { error in
            XCTAssertEqual(error as? BibleReaderDailyReadingActionFailure, .speechUnavailable)
        }
    }

    /** Loads the deterministic KJV fixture used as the active target Bible. */
    private func makeKJVModule() throws -> SwordModule {
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        retainedManagers.append(manager)
        return try XCTUnwrap(manager.module(named: "KJV"))
    }

    /** Creates one exact KJV plan passage for the supplied endpoints. */
    private func passage(
        _ osisBookId: String,
        _ chapter: Int,
        _ startVerse: Int,
        _ endVerse: Int,
        sourceVersification: String = "KJV"
    ) -> ReadingPlanPassageTarget {
        let start = SwordVersification.Reference(
            osisBookId: osisBookId,
            chapter: chapter,
            verse: startVerse
        )
        let end = SwordVersification.Reference(
            osisBookId: osisBookId,
            chapter: chapter,
            verse: endVerse
        )
        let startOSIS = "\(osisBookId).\(chapter).\(startVerse)"
        let endOSIS = "\(osisBookId).\(chapter).\(endVerse)"
        return ReadingPlanPassageTarget(
            sourceVersification: sourceVersification,
            sourceExpression: startVerse == endVerse ? startOSIS : "\(startOSIS)-\(endOSIS)",
            start: start,
            end: end,
            osisReference: startVerse == endVerse ? startOSIS : "\(startOSIS)-\(endOSIS)"
        )
    }

    /** Creates a typed request while retaining production pairing between numbers and passages. */
    private func makeRequest(
        kind: DailyReadingActionKind,
        readingNumbers: [Int],
        passages: [ReadingPlanPassageTarget]
    ) -> DailyReadingActionRequest {
        DailyReadingActionRequest(
            planID: UUID(uuidString: "d1000000-0000-0000-0000-000000000001")!,
            planCode: "daily-reading-action",
            dayNumber: 1,
            kind: kind,
            readingNumbers: readingNumbers,
            passages: passages
        )
    }
}
