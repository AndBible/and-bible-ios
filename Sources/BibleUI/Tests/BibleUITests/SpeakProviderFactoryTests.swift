import BibleCore
import Foundation
import SwordKit
import XCTest
@testable import BibleUI

/** Contract tests for strict reader speech-provider construction and checkpoint reconstruction. */
final class SpeakProviderFactoryTests: BibleUISwordFixtureTestCase {
    /**
     Verifies Android reading-plan key lists remain ordered, discontiguous, bounded, and repeat-safe.

     The fixture queues Genesis, Matthew, and Genesis again while a stale global verse-repeat range
     points elsewhere. The exact queue and duplicate must survive preparation, and exhaustion must
     stop instead of wrapping or widening to every verse between Genesis and Matthew.
     */
    func testBiblePassageListPreservesExactOrderedRangesAndStopsAtExhaustion() throws {
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let build = try BibleReaderSpeechProviderFactory.biblePassageList(
            bookInitials: "KJV",
            ranges: [
                try XCTUnwrap(SpeakVerseRange(versification: "KJV", osisRef: "Gen.1.1-Gen.1.2")),
                try XCTUnwrap(SpeakVerseRange(versification: "KJV", osisRef: "Matt.1.1")),
                try XCTUnwrap(SpeakVerseRange(versification: "KJV", osisRef: "Gen.1.1")),
            ],
            manager: manager,
            displaySettings: TextDisplaySettings(),
            advancedSettings: AdvancedSpeakSettings()
        )
        var settings = SpeakSettings()
        settings.playbackSettings.verseRange = try XCTUnwrap(
            SpeakVerseRange(versification: "KJV", osisRef: "Rev.22.21")
        )

        XCTAssertTrue(build.provider.prepare(settings: settings))
        XCTAssertEqual(
            build.provider.availablePositions.compactMap(\.osisRef),
            ["Gen.1.1", "Gen.1.2", "Matt.1.1", "Gen.1.1"]
        )
        XCTAssertEqual(build.provider.currentPosition?.osisRef, "Gen.1.1")
        XCTAssertTrue(build.provider.advance(settings: settings))
        XCTAssertTrue(build.provider.advance(settings: settings))
        XCTAssertTrue(build.provider.advance(settings: settings))
        XCTAssertEqual(build.provider.currentPosition?.osisRef, "Gen.1.1")
        XCTAssertFalse(build.provider.advance(settings: settings))
    }

    /**
     Verifies pause reconstruction retains the complete passage queue and duplicate occurrence.

     A cursor alone cannot distinguish the first Genesis occurrence from the repeated final one.
     The version-2 checkpoint therefore carries semantic passage boundaries, exact expanded cursors,
     occurrence indexes, and command progress; reconstruction must preserve all of them.
     */
    func testBiblePassageListCheckpointRestoresExactQueueOccurrence() throws {
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let ranges = [
            try XCTUnwrap(SpeakVerseRange(versification: "KJV", osisRef: "Gen.1.1")),
            try XCTUnwrap(SpeakVerseRange(versification: "KJV", osisRef: "Matt.1.1")),
            try XCTUnwrap(SpeakVerseRange(versification: "KJV", osisRef: "Gen.1.1")),
        ]
        let original = try BibleReaderSpeechProviderFactory.biblePassageList(
            bookInitials: "KJV",
            ranges: ranges,
            manager: manager,
            displaySettings: TextDisplaySettings(),
            advancedSettings: AdvancedSpeakSettings()
        ).provider
        let settings = SpeakSettings()
        XCTAssertTrue(original.prepare(settings: settings))
        XCTAssertTrue(original.advance(settings: settings))
        XCTAssertTrue(original.advance(settings: settings))
        let baseCheckpoint = try XCTUnwrap(original.checkpoint())
        let currentTitle = try XCTUnwrap(original.currentPosition?.keyName)
        let punctuatedTitle = ".!?".contains(currentTitle.last ?? " ")
            ? currentTitle
            : currentTitle + "."
        let playbackCursor = SpeakPlaybackCursor(
            commandIndex: 0,
            characterOffset: 0,
            commandTextLength: punctuatedTitle.utf16.count,
            characterFraction: 0
        )
        let checkpoint = baseCheckpoint.withPlaybackCursor(playbackCursor)

        XCTAssertEqual(checkpoint.version, 2)
        XCTAssertNil(checkpoint.orderedPositionIndex)
        XCTAssertNil(checkpoint.orderedPositions)
        XCTAssertEqual(checkpoint.currentPassageIndex, 2)
        XCTAssertEqual(checkpoint.currentPositionIndexInPassage, 0)
        XCTAssertEqual(
            checkpoint.orderedPassages?.map { $0.positions.map(\.key) },
            original.availablePositions.map { [$0.key] }
        )
        XCTAssertEqual(checkpoint.orderedPassages?.map(\.sourceRange), ranges)
        XCTAssertEqual(checkpoint.playbackCursor, playbackCursor)

        let restored = try BibleReaderSpeechProviderFactory.bible(
            checkpoint: checkpoint,
            manager: manager,
            displaySettings: TextDisplaySettings(),
            advancedSettings: AdvancedSpeakSettings()
        ).provider

        XCTAssertTrue(restored.prepare(settings: settings))
        XCTAssertEqual(restored.availablePositions.map(\.osisRef), ["Gen.1.1", "Matt.1.1", "Gen.1.1"])
        XCTAssertEqual(restored.currentPosition?.osisRef, "Gen.1.1")
        XCTAssertEqual(restored.resumePlaybackCursor, playbackCursor)
        XCTAssertEqual(restored.checkpoint()?.orderedPassages, checkpoint.orderedPassages)
        XCTAssertFalse(restored.advance(settings: settings))
    }

    /**
     Verifies malformed version-2 progress fails closed before a provider can be reconstructed.

     The fixture changes only the character fraction while retaining valid passages and cursors. A
     successful reconstruction would permit resume at an untrusted position and violate the semantic
     checkpoint contract.
     */
    func testBiblePassageListRejectsMalformedVersionTwoPlaybackCursor() throws {
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let range = try XCTUnwrap(SpeakVerseRange(versification: "KJV", osisRef: "Gen.1.1"))
        let provider = try BibleReaderSpeechProviderFactory.biblePassageList(
            bookInitials: "KJV",
            ranges: [range],
            manager: manager,
            displaySettings: TextDisplaySettings(),
            advancedSettings: AdvancedSpeakSettings()
        ).provider
        let base = try XCTUnwrap(provider.checkpoint())
        let malformed = base.withPlaybackCursor(
            SpeakPlaybackCursor(
                commandIndex: 0,
                characterOffset: 2,
                commandTextLength: 10,
                characterFraction: 0.9
            )
        )

        XCTAssertThrowsError(
            try BibleReaderSpeechProviderFactory.bible(
                checkpoint: malformed,
                manager: manager,
                displaySettings: TextDisplaySettings(),
                advancedSettings: AdvancedSpeakSettings()
            )
        ) { error in
            guard case BibleSpeakSourceResolutionError.invalidCheckpoint = error else {
                return XCTFail("Expected invalid semantic checkpoint, got \(error)")
            }
        }
    }

    /**
     Verifies malformed version-2 semantic queue metadata fails closed before reconstruction.

     - Side effects: Resolves one fixture passage, then attempts reconstruction with an out-of-range
       current passage occurrence while every source cursor remains otherwise valid.
     - Failure modes: The assertion fails if reconstruction clamps, infers, or partially accepts the
       invalid queue occurrence.
     */
    func testBiblePassageListRejectsMalformedVersionTwoQueueMetadata() throws {
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let range = try XCTUnwrap(SpeakVerseRange(versification: "KJV", osisRef: "Gen.1.1"))
        let provider = try BibleReaderSpeechProviderFactory.biblePassageList(
            bookInitials: "KJV",
            ranges: [range],
            manager: manager,
            displaySettings: TextDisplaySettings(),
            advancedSettings: AdvancedSpeakSettings()
        ).provider
        let base = try XCTUnwrap(provider.checkpoint())
        let title = try XCTUnwrap(base.orderedPassages?.first?.title)
        let punctuatedTitle = ".!?".contains(title.last ?? " ") ? title : title + "."
        let malformed = SpeakProviderCheckpoint(
            version: 2,
            current: base.current,
            lowerBound: base.lowerBound,
            upperBound: base.upperBound,
            isBounded: true,
            isMemorizationLoop: false,
            orderedPassages: base.orderedPassages,
            currentPassageIndex: 1,
            currentPositionIndexInPassage: 0,
            playbackCursor: SpeakPlaybackCursor(
                commandIndex: 0,
                characterOffset: 0,
                commandTextLength: punctuatedTitle.utf16.count,
                characterFraction: 0
            )
        )

        XCTAssertThrowsError(
            try BibleReaderSpeechProviderFactory.bible(
                checkpoint: malformed,
                manager: manager,
                displaySettings: TextDisplaySettings(),
                advancedSettings: AdvancedSpeakSettings()
            )
        ) { error in
            guard case BibleSpeakSourceResolutionError.invalidCheckpoint = error else {
                return XCTFail("Expected invalid semantic queue metadata, got \(error)")
            }
        }
    }

    /** Verifies each original key range emits its own title and explicit separator pause commands. */
    func testBiblePassageListEmitsTitleAndSeparatorCommandsAtOriginalBoundaries() throws {
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let provider = try BibleReaderSpeechProviderFactory.biblePassageList(
            bookInitials: "KJV",
            ranges: [
                try XCTUnwrap(SpeakVerseRange(versification: "KJV", osisRef: "Gen.1.1-Gen.1.2")),
                try XCTUnwrap(SpeakVerseRange(versification: "KJV", osisRef: "Matt.1.1")),
            ],
            manager: manager,
            displaySettings: TextDisplaySettings(),
            advancedSettings: AdvancedSpeakSettings()
        ).provider
        let settings = SpeakSettings()

        let firstCommands = try XCTUnwrap(provider.currentUnit(settings: settings)).commands
        guard case .announcement(let firstTitle) = firstCommands.first else {
            return XCTFail("Expected the original range title before passage content")
        }
        XCTAssertTrue(firstTitle.contains("1:1-2"))
        XCTAssertTrue(provider.advance(settings: settings))
        XCTAssertTrue(provider.advance(settings: settings))
        let secondCommands = try XCTUnwrap(provider.currentUnit(settings: settings)).commands
        XCTAssertTrue(secondCommands.contains(.pause(milliseconds: 500)))
        guard case .announcement(let secondTitle) = secondCommands.first else {
            return XCTFail("Expected the next original range title before its content")
        }
        XCTAssertTrue(secondTitle.contains("1:1") && secondTitle.hasSuffix("."))
    }

    /** Verifies factory wiring supplies real Bible bounds and the module-backed range resolver. */
    func testBibleFactoryAppliesVerseRangeThroughRequestedModuleResolver() throws {
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let startOrdinal = try XCTUnwrap(
            module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1)
        )
        let request = SpeakSelectionRequest(
            category: .bible,
            bookInitials: "KJV",
            key: "Gen.1.1",
            startOrdinal: startOrdinal,
            endOrdinal: startOrdinal,
            versification: "KJV"
        )
        let build = try BibleReaderSpeechProviderFactory.bible(
            request: request,
            manager: manager,
            displaySettings: TextDisplaySettings(),
            advancedSettings: AdvancedSpeakSettings()
        )
        var settings = SpeakSettings()
        settings.playbackSettings.verseRange = try XCTUnwrap(
            SpeakVerseRange(versification: "KJV", osisRef: "Gen.1.2-Gen.1.3")
        )

        XCTAssertTrue(build.provider.prepare(settings: settings))
        XCTAssertEqual(build.provider.currentPosition?.osisRef, "Gen.1.2")
        XCTAssertTrue(build.provider.advance(settings: settings))
        XCTAssertEqual(build.provider.currentPosition?.osisRef, "Gen.1.3")
        XCTAssertTrue(build.provider.advance(settings: settings))
        XCTAssertEqual(build.provider.currentPosition?.osisRef, "Gen.1.2")
    }

    /** Verifies the real loader consumes verse zero without duplicating its embedded verse-one title. */
    func testBibleFactoryUsesChapterIntroductionWithoutDuplicatingEmbeddedHeading() throws {
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let startOrdinal = try XCTUnwrap(
            module.verseOrdinal(osisBookId: "Ps", chapter: 3, verse: 1)
        )
        let build = try BibleReaderSpeechProviderFactory.bible(
            request: SpeakSelectionRequest(
                category: .bible,
                bookInitials: "KJV",
                key: "Ps.3.1",
                startOrdinal: startOrdinal,
                endOrdinal: startOrdinal,
                versification: "KJV"
            ),
            manager: manager,
            displaySettings: TextDisplaySettings(),
            advancedSettings: AdvancedSpeakSettings()
        )

        let settings = SpeakSettings()
        let advancedSettings = AdvancedSpeakSettings()
        let position = try XCTUnwrap(build.provider.currentPosition)
        let commands = try XCTUnwrap(
            build.provider.currentUnit(settings: settings)
        ).commands
        let introduction = module.inspectVerseKeyAndRawEntryRestoringPrevious("=Ps.3.0")
        let introductionCommands = SpeakCommandBuilder.commands(
            rawOSIS: introduction.rawEntry,
            fallbackPlainText: "",
            language: position.language,
            playbackSettings: settings.playbackSettings,
            advancedSettings: advancedSettings
        )

        XCTAssertTrue(introductionCommands.contains { command in
            if case .heading = command { return true }
            return false
        })
        XCTAssertFalse(introductionCommands.isEmpty)
        XCTAssertEqual(commands.compactMap(\.spokenText).filter { $0 == "PSALM 3." }.count, 1)
    }

    /** Verifies verse-zero commands prepend only when verse one does not already embed them. */
    func testBibleCommandMergePrependsMissingAndDeduplicatesEmbeddedIntroduction() {
        let introduction: [SpeakCommand] = [
            .pause(milliseconds: 150),
            .heading("Section"),
            .pause(milliseconds: 500),
        ]
        let plainVerse: [SpeakCommand] = [.verseNumber(1), .text("Verse")]
        let embeddedVerse: [SpeakCommand] = [
            .verseNumber(1),
            .pause(milliseconds: 150),
            .heading("Section"),
            .pause(milliseconds: 500),
            .text("Verse"),
        ]

        XCTAssertEqual(
            BibleReaderSpeechProviderFactory.mergedBibleCommands(
                chapterIntroduction: introduction,
                verse: plainVerse
            ),
            introduction + plainVerse
        )
        XCTAssertEqual(
            BibleReaderSpeechProviderFactory.mergedBibleCommands(
                chapterIntroduction: introduction,
                verse: embeddedVerse
            ),
            embeddedVerse
        )
    }

    /** Verifies Android's module/OSIS pause state resolves through the installed module canon. */
    func testBibleFactoryReconstructsAndroidLegacyPauseStateAuthoritatively() throws {
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let cursor = SpeakStreamCursor(
            category: .bible,
            bookInitials: "KJV",
            key: "Gen.1.2",
            ordinalStart: nil,
            ordinalEnd: nil,
            versification: nil
        )
        let checkpoint = SpeakProviderCheckpoint(
            version: 0,
            current: cursor,
            lowerBound: cursor,
            upperBound: cursor,
            isBounded: false,
            isMemorizationLoop: false
        )

        let build = try BibleReaderSpeechProviderFactory.bible(
            checkpoint: checkpoint,
            manager: manager,
            displaySettings: TextDisplaySettings(),
            advancedSettings: AdvancedSpeakSettings()
        )

        XCTAssertEqual(build.module?.info.name, "KJV")
        XCTAssertEqual(build.provider.currentPosition?.bookInitials, "KJV")
        XCTAssertEqual(build.provider.currentPosition?.osisRef, "Gen.1.2")
        XCTAssertEqual(build.provider.currentPosition?.versification, "KJV")
    }

    /** Verifies page factory reconstruction retains cross-key local-ordinal bounds. */
    func testPageFactoryReconstructsExactCurrentCursorAndOriginalBounds() throws {
        let pages = [
            BibleReaderSpeechPage(
                key: "one.xhtml",
                title: "One",
                plainText: "",
                rawMarkup: #"<html><body><bva ordinal="1">One</bva><bva ordinal="2">Two</bva></body></html>"#,
                ordinalRange: 1...2,
                language: "en"
            ),
            BibleReaderSpeechPage(
                key: "two.xhtml",
                title: "Two",
                plainText: "",
                rawMarkup: #"<html><body><bva ordinal="10">Ten</bva><bva ordinal="11">Eleven</bva></body></html>"#,
                ordinalRange: 10...11,
                language: "en"
            ),
        ]
        let original = try XCTUnwrap(
            BibleReaderSpeechProviderFactory.pages(
                category: .generalBook,
                bookInitials: "EPUB",
                bookName: "Test EPUB",
                pages: pages,
                currentKey: "one.xhtml",
                startOrdinal: 2,
                endKey: "two.xhtml",
                endOrdinal: 11
            )?.provider
        )
        XCTAssertTrue(original.advance(settings: SpeakSettings()))
        XCTAssertEqual(original.currentPosition?.ordinalStart, 10)
        let checkpoint = try XCTUnwrap(original.checkpoint())

        let reconstructed = try XCTUnwrap(
            BibleReaderSpeechProviderFactory.pages(
                category: .generalBook,
                bookInitials: "EPUB",
                bookName: "Test EPUB",
                pages: pages,
                checkpoint: checkpoint
            )?.provider
        )
        XCTAssertEqual(reconstructed.checkpoint(), checkpoint)
        XCTAssertTrue(reconstructed.rewind(.oneUnit))
        XCTAssertEqual(reconstructed.currentPosition?.key, "one.xhtml")
        XCTAssertEqual(reconstructed.currentPosition?.ordinalStart, 2)
        XCTAssertTrue(reconstructed.forward(.smart))
        XCTAssertEqual(reconstructed.currentPosition?.ordinalStart, 11)
        XCTAssertFalse(reconstructed.advance(settings: SpeakSettings()))
    }

    /** Verifies Android's generic persisted cursor is reclassified by its typed page source. */
    func testPageFactoryReconstructsAndroidLegacyGenericCursor() throws {
        let pages = [
            BibleReaderSpeechPage(
                key: "entry.xhtml",
                title: "Entry",
                plainText: "",
                rawMarkup: #"<html><body><bva ordinal="4">Four</bva><bva ordinal="5">Five</bva></body></html>"#,
                ordinalRange: 4...5,
                language: "en"
            ),
        ]
        let cursor = SpeakStreamCursor(
            category: .generalBook,
            bookInitials: "DOC",
            key: "entry.xhtml",
            ordinalStart: 5,
            ordinalEnd: 5,
            versification: nil
        )
        let checkpoint = SpeakProviderCheckpoint(
            version: 0,
            current: cursor,
            lowerBound: cursor,
            upperBound: cursor,
            isBounded: false,
            isMemorizationLoop: false
        )

        let provider = try XCTUnwrap(
            BibleReaderSpeechProviderFactory.pages(
                category: .myDocument,
                bookInitials: "DOC",
                bookName: "Document",
                pages: pages,
                checkpoint: checkpoint
            )?.provider
        )

        XCTAssertEqual(provider.category, .myDocument)
        XCTAssertEqual(provider.currentPosition?.key, "entry.xhtml")
        XCTAssertEqual(provider.currentPosition?.ordinalStart, 5)
        XCTAssertFalse(try XCTUnwrap(provider.checkpoint()).isBounded)
    }

    /**
     Verifies speech checkpoint identities preserve Java-distinct Unicode spellings.

     - Setup: Creates canonically equivalent composed/decomposed module initials with identical
       generic page keys and ordinals.
     - Expected result: A cursor matches and reconstructs only the exact UTF-16 spelling; the
       canonically equivalent spelling fails closed before page-source construction.
     - Failure meaning: Swift canonical equality can resume a checkpoint against a different
       Android document owner and read speech content under the stale identity.
     - Side effects: None; the test uses immutable in-memory page fixtures.
     */
    func testSpeechCheckpointRejectsCanonicallyEquivalentJavaDistinctInitials() throws {
        let composed = "Caf\u{00E9}Speech"
        let decomposed = "Cafe\u{0301}Speech"
        let page = BibleReaderSpeechPage(
            key: "entry.xhtml",
            title: "Entry",
            plainText: "",
            rawMarkup: #"<html><body><bva ordinal="4">Four</bva></body></html>"#,
            ordinalRange: 4...4,
            language: "en"
        )
        let composedCursor = SpeakStreamCursor(
            category: .myDocument,
            bookInitials: composed,
            key: page.key,
            ordinalStart: 4,
            ordinalEnd: 4,
            versification: nil
        )
        let decomposedCursor = SpeakStreamCursor(
            category: .myDocument,
            bookInitials: decomposed,
            key: page.key,
            ordinalStart: 4,
            ordinalEnd: 4,
            versification: nil
        )
        let decomposedPosition = SpeakStreamPosition(
            id: "\(decomposed):\(page.key):4",
            category: .myDocument,
            bookInitials: decomposed,
            key: page.key,
            osisRef: nil,
            keyName: page.title,
            bookName: "Document",
            ordinalStart: 4,
            ordinalEnd: 4,
            chapter: nil,
            verse: nil,
            groupIdentifier: page.key,
            language: page.language,
            versification: nil
        )
        XCTAssertFalse(composedCursor.matches(decomposedPosition))
        XCTAssertTrue(decomposedCursor.matches(decomposedPosition))

        let staleCheckpoint = SpeakProviderCheckpoint(
            version: 0,
            current: decomposedCursor,
            lowerBound: decomposedCursor,
            upperBound: decomposedCursor,
            isBounded: false,
            isMemorizationLoop: false
        )
        XCTAssertNil(BibleReaderSpeechProviderFactory.pages(
            category: .myDocument,
            bookInitials: composed,
            bookName: "Document",
            pages: [page],
            checkpoint: staleCheckpoint
        ))

        let exactCheckpoint = SpeakProviderCheckpoint(
            version: 0,
            current: composedCursor,
            lowerBound: composedCursor,
            upperBound: composedCursor,
            isBounded: false,
            isMemorizationLoop: false
        )
        XCTAssertNotNil(BibleReaderSpeechProviderFactory.pages(
            category: .myDocument,
            bookInitials: composed,
            bookName: "Document",
            pages: [page],
            checkpoint: exactCheckpoint
        ))
    }
}
