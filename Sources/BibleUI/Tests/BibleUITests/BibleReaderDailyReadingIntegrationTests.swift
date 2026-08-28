import AVFoundation
import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import BibleView
@testable import SwordKit

/**
 Production reader integration tests for Android Daily Reading actions.

 Tests use an isolated KJV fixture, an in-memory bridge, and a recording speech engine. They perform
 no network or shared persistence work and inherit deterministic fixture cleanup. The suite runs on
 the main actor because production Daily Reading speech and reader navigation share UI-owned state.
 */
@MainActor
final class BibleReaderDailyReadingIntegrationTests: BibleUISwordFixtureTestCase {
    /**
     Verifies the controller commits one Read navigation with the complete mapped highlight range.

     - Side effects: Loads an isolated Bible chapter and records bridge emissions.
     - Failure modes: Fails if production wiring drops the range, bypasses the active module, or
       emits a single-verse setup target.
     */
    @MainActor
    func testReadNavigatesActiveBibleWithCompleteMappedRange() async throws {
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.bridgeDidSetClientReady(bridge)
        let baseline = scripts().count
        let request = makeRequest(
            kind: .read,
            readingNumbers: [1],
            passages: [passage("Gen", chapter: 1, startVerse: 1, endVerse: 3)]
        )

        try await controller.performDailyReadingAction(request)

        let emissions = Array(scripts().dropFirst(baseline))
        let setup = try XCTUnwrap(
            bridgeEmissionPayload(from: emissions, event: "setup_content") as? [String: Any]
        )
        let expectedStart = try XCTUnwrap(
            module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1)
        )
        let expectedEnd = try XCTUnwrap(
            module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 3)
        )
        XCTAssertEqual(controller.currentBook, "Genesis")
        XCTAssertEqual(controller.currentChapter, 1)
        XCTAssertEqual(controller.currentVerse, 1)
        XCTAssertEqual(setup["ordinalStart"] as? Int, expectedStart)
        XCTAssertEqual(setup["ordinalEnd"] as? Int, expectedEnd)
        XCTAssertEqual(setup["highlight"] as? Bool, true)
    }

    /**
     Verifies the controller submits Speak All as separate ordered bounded passages.

     - Side effects: Builds a provider from isolated SWORD data and synchronously records the first
       accepted utterance without platform audio.
     - Failure modes: Fails if production wiring flattens discontiguous ranges, changes their order,
       replaces duplicates, or reports success before synthesis accepts an utterance.
     */
    @MainActor
    func testSpeakAllStartsOrderedBoundedPassageList() async throws {
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let synthesizer = DailyReadingSpeechSynthesizer()
        let service = SpeakService(synthesizer: synthesizer)
        let controller = BibleReaderController(bridge: BibleBridge(), swordManagerOverride: manager)
        controller.speakService = service
        let request = makeRequest(
            kind: .speak,
            readingNumbers: [1, 2, 3],
            passages: [
                passage("Gen", chapter: 1, startVerse: 1, endVerse: 2),
                passage("Matt", chapter: 1, startVerse: 1, endVerse: 1),
                passage("Gen", chapter: 1, startVerse: 2, endVerse: 2),
            ]
        )

        try await controller.performDailyReadingAction(request)

        XCTAssertEqual(synthesizer.acceptedUtterances.count, 1)
        XCTAssertEqual(
            service.availableBiblePositions.map(\.osisRef),
            ["Gen.1.1", "Gen.1.2", "Matt.1.1", "Gen.1.2"]
        )
    }

    /**
     Verifies Android Books parity for Daily Reading across every supported SQLite Bible family.

     - Setup: Installs checked-in MyBible, MySword, and e-Sword Bibles without same-name SWORD
       modules, selects each as the active document, and injects a synchronous speech engine.
     - Expected result: Read navigates with exact intro-inclusive KJVA bounds, while Speak preserves
       ordered duplicate ranges and exposes positions owned by the selected SQLite initials.
     - Failure meaning: Daily Reading still requires `SwordModule`, falls back to active SWORD text,
       uses local SQLite row numbers, or flattens Android's ordered passage list.
     - Side effects: Copies fixtures beneath the inherited temporary module root, records bridge
       emissions, and starts fake speech without platform audio; fixture teardown removes all files.
     */
    @MainActor
    func testSQLiteBibleFamiliesPerformDailyReadingReadAndSpeakWithoutSwordFallback() async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try installSQLiteBibleFixtures(in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let expectedStart = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 1, verse: 1)
        )
        let expectedEnd = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 1, verse: 2)
        )
        let moduleNames = ["MyBible-bible", "MySword-sample_bbl", "ESword-sample"]

        for moduleName in moduleNames {
            XCTAssertNil(manager.module(named: moduleName))
            let (bridge, scripts) = makeRecordingBridge()
            let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
            controller.bridgeDidSetClientReady(bridge)
            controller.switchBibleDocument(to: moduleName)
            XCTAssertEqual(controller.activeModuleName, moduleName)

            let readBaseline = scripts().count
            try await controller.performDailyReadingAction(
                makeRequest(
                    kind: .read,
                    readingNumbers: [1],
                    passages: [passage("Gen", chapter: 1, startVerse: 1, endVerse: 2)]
                )
            )
            let readEmissions = Array(scripts().dropFirst(readBaseline))
            let setup = try XCTUnwrap(
                bridgeEmissionPayload(from: readEmissions, event: "setup_content") as? [String: Any]
            )
            XCTAssertEqual(controller.currentBook, "Genesis")
            XCTAssertEqual(controller.currentChapter, 1)
            XCTAssertEqual(controller.currentVerse, 1)
            XCTAssertEqual(setup["ordinalStart"] as? Int, expectedStart)
            XCTAssertEqual(setup["ordinalEnd"] as? Int, expectedEnd)
            XCTAssertEqual(setup["highlight"] as? Bool, true)

            let synthesizer = DailyReadingSpeechSynthesizer()
            let service = SpeakService(synthesizer: synthesizer)
            controller.speakService = service
            try await controller.performDailyReadingAction(
                makeRequest(
                    kind: .speak,
                    readingNumbers: [1, 2],
                    passages: [
                        passage("Gen", chapter: 1, startVerse: 1, endVerse: 2),
                        passage("Gen", chapter: 1, startVerse: 1, endVerse: 1),
                    ]
                )
            )

            XCTAssertEqual(synthesizer.acceptedUtterances.count, 1)
            XCTAssertEqual(
                service.availableBiblePositions.map(\.osisRef),
                ["Gen.1.1", "Gen.1.2", "Gen.1.1"]
            )
            XCTAssertEqual(
                service.availableBiblePositions.map(\.bookInitials),
                [moduleName, moduleName, moduleName]
            )
            XCTAssertEqual(
                service.availableBiblePositions.map(\.ordinalStart),
                [expectedStart, expectedEnd, expectedStart]
            )
        }
    }

    /**
     Verifies missing active Bible wiring fails before navigation or speech.

     - Side effects: None beyond constructing an in-memory reader.
     - Failure modes: Fails if Daily Reading borrows placeholder coordinates or reports completion
       without an installed active Bible.
     */
    @MainActor
    func testMissingActiveBibleFailsBeforeAnyAction() async {
        let controller = BibleReaderController(bridge: BibleBridge(), initializesSword: false)
        let request = makeRequest(
            kind: .read,
            readingNumbers: [1],
            passages: [passage("Gen", chapter: 1, startVerse: 1, endVerse: 1)]
        )

        do {
            try await controller.performDailyReadingAction(request)
            XCTFail("Expected active-Bible failure")
        } catch {
            XCTAssertEqual(
                error as? BibleReaderDailyReadingActionFailure,
                .activeBibleUnavailable
            )
        }
    }

    /** Creates one exact plan-canon passage with canonical OSIS endpoints. */
    private func passage(
        _ osisBookId: String,
        chapter: Int,
        startVerse: Int,
        endVerse: Int
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
            sourceVersification: "KJV",
            sourceExpression: start == end ? startOSIS : "\(startOSIS)-\(endOSIS)",
            start: start,
            end: end,
            osisReference: start == end ? startOSIS : "\(startOSIS)-\(endOSIS)"
        )
    }

    /** Creates one typed Daily Reading request with paired reading numbers and passages. */
    private func makeRequest(
        kind: DailyReadingActionKind,
        readingNumbers: [Int],
        passages: [ReadingPlanPassageTarget]
    ) -> DailyReadingActionRequest {
        DailyReadingActionRequest(
            planID: UUID(uuidString: "d2000000-0000-0000-0000-000000000001")!,
            planCode: "reader-daily-reading",
            dayNumber: 1,
            kind: kind,
            readingNumbers: readingNumbers,
            passages: passages
        )
    }

    /**
     Installs one real Bible fixture for each Android-compatible SQLite family.

     - Parameter modulePath: Temporary installed-module root owned by the current test.
     - Side effects: Creates family directories and copies three immutable fixture databases.
     - Throws: Repository-location, directory-creation, or file-copy failures.
     */
    private func installSQLiteBibleFixtures(in modulePath: String) throws {
        try copySQLiteFixture(
            "mybible-bible.SQLite3",
            to: "mybible/bible.SQLite3",
            in: modulePath
        )
        try copySQLiteFixture(
            "sample.bbl.mybible",
            to: "mysword/sample.bbl.mybible",
            in: modulePath
        )
        try copySQLiteFixture(
            "sample.bblx",
            to: "esword/sample.bblx",
            in: modulePath
        )
    }

    /**
     Copies one checked-in SQLite document fixture into an Android family directory.

     - Parameters:
       - fixtureName: Exact fixture filename beneath BibleCore's SQLite fixture directory.
       - relativePath: Android-family destination relative to the temporary module root.
       - modulePath: Temporary installed-module root.
     - Side effects: Creates the destination parent and copies one fixture.
     - Throws: Source-location, directory-creation, and copy failures.
     */
    private func copySQLiteFixture(
        _ fixtureName: String,
        to relativePath: String,
        in modulePath: String
    ) throws {
        let repositoryRoot = try BibleUITestSourceLocator.repositoryRoot(
            containing: "Sources/BibleCore/Tests/Fixtures/SQLiteDocumentReaders"
        )
        let source = repositoryRoot
            .appendingPathComponent("Sources/BibleCore/Tests/Fixtures/SQLiteDocumentReaders")
            .appendingPathComponent(fixtureName)
        let destination = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: source, to: destination)
    }
}

/** Deterministic speech-engine double that records synchronous utterance acceptance. */
private final class DailyReadingSpeechSynthesizer: SpeechSynthesizing {
    /// Delegate retained weakly to mirror AVSpeechSynthesizer ownership.
    weak var delegate: AVSpeechSynthesizerDelegate?
    /// Utterances accepted synchronously by the fake engine.
    private(set) var acceptedUtterances: [AVSpeechUtterance] = []

    /** Records one accepted utterance before returning to SpeakService. */
    func speak(_ utterance: AVSpeechUtterance) {
        acceptedUtterances.append(utterance)
    }

    /** Reports successful immediate stopping. */
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool { true }

    /** Reports successful pausing. */
    func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool { true }

    /** Reports successful continuation. */
    func continueSpeaking() -> Bool { true }
}
