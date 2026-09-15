import AVFoundation
import Foundation
import SwiftData
import SwordKit
import XCTest
@testable import BibleCore

/**
 Contract tests for Android-equivalent speech settings, providers, commands, persistence, and
 transport behavior.

 These tests use deterministic audio, timer, and bookmark doubles. They intentionally cover the
 historical sparse JSON and SwiftData transform boundary because a nested optional decode failure
 terminates the process instead of surfacing as an ordinary test assertion.
 */
@MainActor
final class SpeakParityTests: XCTestCase {
    /** Verifies the exact historical Android payload keeps compatible fields and default values. */
    func testPlaybackSettingsDecodesHistoricalPayloadWithoutVerseRange() throws {
        let settings = try JSONDecoder().decode(
            PlaybackSettings.self,
            from: Data(#"{"bookId":"KJV","speed":140}"#.utf8)
        )

        XCTAssertEqual(settings.bookId, "KJV")
        XCTAssertEqual(settings.speed, 140)
        XCTAssertTrue(settings.speakChapterChanges)
        XCTAssertTrue(settings.speakTitles)
        XCTAssertFalse(settings.speakFootnotes)
        XCTAssertNil(settings.bookmarkWasCreated)
        XCTAssertNil(settings.verseRange)
        XCTAssertFalse(settings.isMemorizationLoop)
    }

    /**
     Verifies nullable ranges remain valid while malformed known fields default the complete object.

     Android's `PlaybackSettings.fromJson` catches serializer failures around the complete payload.
     A failure means iOS either rejects valid nullable history or preserves siblings Android drops.
     */
    func testPlaybackSettingsDefaultsNullableAndMalformedVerseRanges() throws {
        let nullable = try JSONDecoder().decode(
            PlaybackSettings.self,
            from: Data(#"{"bookId":"KJV","speed":141,"speakFootnotes":true,"verseRange":null}"#.utf8)
        )
        XCTAssertEqual(nullable.bookId, "KJV")
        XCTAssertEqual(nullable.speed, 141)
        XCTAssertTrue(nullable.speakFootnotes)
        XCTAssertNil(nullable.verseRange)

        let unaddressable = try JSONDecoder().decode(
            PlaybackSettings.self,
            from: Data(
                #"{"bookId":"NASB","speed":145,"speakTitles":false,"verseRange":"KJV::Gen.999.1"}"#.utf8
            )
        )
        XCTAssertEqual(unaddressable.bookId, "NASB")
        XCTAssertEqual(unaddressable.speed, 145)
        XCTAssertFalse(unaddressable.speakTitles)
        XCTAssertNil(unaddressable.verseRange)

        let malformedPayloads = [
            #"{"bookId":"KJV","speed":142,"speakFootnotes":true,"verseRange":"broken"}"#,
            #"{"bookId":"KJV","speed":143,"speakFootnotes":true,"verseRange":{"unexpected":1}}"#,
            #"{"bookId":"KJV","speed":144,"speakFootnotes":true,"verseRange":123}"#,
        ]

        for (index, payload) in malformedPayloads.enumerated() {
            let settings = try JSONDecoder().decode(PlaybackSettings.self, from: Data(payload.utf8))
            XCTAssertEqual(settings, PlaybackSettings(), "malformed payload index \(index)")
        }

        let mixed = PlaybackSettings.fromAndroidJSON(
            #"{"bookId":"NASB","speed":"fast","speakTitles":false,"verseRange":"KJV::"}"#
        )
        XCTAssertEqual(mixed, PlaybackSettings())
        XCTAssertEqual(PlaybackSettings.fromAndroidJSON("{") , PlaybackSettings())
    }

    /** Verifies the sparse historical payload survives the actual SwiftData transform round trip. */
    func testPlaybackSettingsHistoricalPayloadRoundTripsThroughSwiftData() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let writer = ModelContext(container)
        let bookmark = BibleBookmark(bookInitials: "KJV")
        bookmark.playbackSettings = PlaybackSettings.fromAndroidJSON(#"{"bookId":"KJV","speed":140}"#)
        writer.insert(bookmark)
        try writer.save()

        let reader = ModelContext(container)
        let restored = try XCTUnwrap(reader.fetch(FetchDescriptor<BibleBookmark>()).first?.playbackSettings)
        XCTAssertEqual(restored.bookId, "KJV")
        XCTAssertEqual(restored.speed, 140)
        XCTAssertNil(restored.verseRange)
    }

    /** Verifies synthesized Android playback JSON includes every field and explicit nullable keys. */
    func testPlaybackSettingsAndroidJSONUsesCompleteExplicitNullSchema() throws {
        let defaults = PlaybackSettings(speed: -25)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try defaults.androidJSON().utf8)) as? [String: Any]
        )

        XCTAssertEqual(Set(object.keys), [
            "speakChapterChanges", "speakTitles", "speakFootnotes", "speed", "bookId",
            "bookmarkWasCreated", "verseRange",
        ])
        XCTAssertEqual(object["speed"] as? Int, -25)
        XCTAssertTrue(object["bookId"] is NSNull)
        XCTAssertTrue(object["bookmarkWasCreated"] is NSNull)
        XCTAssertTrue(object["verseRange"] is NSNull)

        let range = try XCTUnwrap(SpeakVerseRange(versification: "KJV", osisRef: "Gen.1.1-Gen.1.3"))
        let populated = PlaybackSettings(
            speakChapterChanges: false,
            speakTitles: false,
            speakFootnotes: true,
            speed: 165,
            bookId: "KJV",
            bookmarkWasCreated: true,
            verseRange: range,
            isMemorizationLoop: true
        )
        let decoded = PlaybackSettings.fromAndroidJSON(try populated.androidJSON())
        XCTAssertEqual(decoded.verseRange, range)
        XCTAssertEqual(decoded.bookId, "KJV")
        XCTAssertEqual(decoded.speed, 165)
        XCTAssertFalse(decoded.isMemorizationLoop)
    }

    /** Verifies all Android fields round-trip and malformed known fields default the complete object. */
    func testSpeakSettingsStructuredRoundTripPreservesEveryAndroidField() throws {
        let payload = #"{"playbackSettings":{"speakChapterChanges":false,"speakTitles":false,"speakFootnotes":true,"speed":175,"bookId":"KJV","bookmarkWasCreated":false,"verseRange":"KJV::Gen.1.1-Gen.1.2"},"sleepTimer":17,"lastSleepTimer":23,"queue":false,"repeat":true,"numPagesToSpeakId":991}"#
        let parsed = SpeakSettings.fromAndroidJSON(payload)

        XCTAssertFalse(parsed.playbackSettings.speakChapterChanges)
        XCTAssertFalse(parsed.playbackSettings.speakTitles)
        XCTAssertTrue(parsed.playbackSettings.speakFootnotes)
        XCTAssertEqual(parsed.playbackSettings.speed, 175)
        XCTAssertEqual(parsed.playbackSettings.bookId, "KJV")
        XCTAssertEqual(parsed.playbackSettings.bookmarkWasCreated, false)
        XCTAssertEqual(parsed.playbackSettings.verseRange?.description, "KJV::Gen.1.1-Gen.1.2")
        XCTAssertEqual(parsed.sleepTimer, 17)
        XCTAssertEqual(parsed.lastSleepTimer, 23)
        XCTAssertFalse(parsed.queue)
        XCTAssertTrue(parsed.repeatPlayback)
        XCTAssertEqual(parsed.numPagesToSpeakId, 991)
        XCTAssertEqual(SpeakSettings.fromAndroidJSON(try parsed.androidJSON()), parsed)

        let defaultObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try SpeakSettings().androidJSON().utf8)) as? [String: Any]
        )
        let defaultPlayback = try XCTUnwrap(defaultObject["playbackSettings"] as? [String: Any])
        XCTAssertEqual(Set(defaultPlayback.keys), [
            "speakChapterChanges", "speakTitles", "speakFootnotes", "speed", "bookId",
            "bookmarkWasCreated", "verseRange",
        ])
        XCTAssertTrue(defaultPlayback["bookId"] is NSNull)
        XCTAssertTrue(defaultPlayback["bookmarkWasCreated"] is NSNull)
        XCTAssertTrue(defaultPlayback["verseRange"] is NSNull)

        let mixed = SpeakSettings.fromAndroidJSON(
            #"{"playbackSettings":"bad","sleepTimer":9,"lastSleepTimer":null,"queue":false,"repeat":"bad","numPagesToSpeakId":44}"#
        )
        XCTAssertEqual(mixed, SpeakSettings())
    }

    /**
     Verifies Android locale selection, legacy aliases, per-array fallback, and explicit empty arrays.
     */
    func testDivineNameCatalogMatchesAndroidLocaleMatrixAndFallback() {
        XCTAssertEqual(
            SpeakDivineNameCatalog.replacements(for: "fr-CA"),
            ["Seigneur": "Yahvé", "Dieu": "Yahvé"]
        )
        XCTAssertEqual(
            SpeakDivineNameCatalog.replacements(for: "de"),
            ["Herr": "Jahwe", "Gott": "Jahweh"]
        )
        XCTAssertEqual(
            SpeakDivineNameCatalog.replacements(for: "iw-IL"),
            ["אדון": "יהוה", "אלוהים": "יהוה"]
        )
        XCTAssertEqual(
            SpeakDivineNameCatalog.replacements(for: "in"),
            ["Tuhan": "Yahweh", "Allah": "Yahweh"]
        )

        XCTAssertEqual(SpeakDivineNameCatalog.arrays(for: "ja").original, ["Lord", "God", "", "", ""])
        XCTAssertEqual(SpeakDivineNameCatalog.arrays(for: "zz").replacement, ["Yahweh", "Yahweh", "", "", ""])
        XCTAssertTrue(SpeakDivineNameCatalog.replacements(for: "pt").isEmpty)
        XCTAssertEqual(SpeakDivineNameCatalog.arrays(for: "af").original, ["Lord", "God", "", "", ""])
        XCTAssertTrue(SpeakDivineNameCatalog.replacements(for: "uz").isEmpty)
    }

    /** Verifies headings, notes, exclusions, pauses, verse markers, and localized divine names. */
    func testCommandBuilderEmitsAndroidContentCommands() {
        let osis = """
        <verse osisID="Gen.1.1"><title>Heading</title>Body
        <reference>hidden reference</reference>
        <note type="study">Study note</note><note type="crossReference">hidden note</note>
        <divineName><w lemma="strong:H3068">Seigneur</w></divineName><p>After paragraph</p></verse>
        """
        let commands = SpeakCommandBuilder.commands(
            rawOSIS: osis,
            fallbackPlainText: "fallback",
            language: "fr",
            playbackSettings: PlaybackSettings(speakTitles: true, speakFootnotes: true),
            advancedSettings: AdvancedSpeakSettings(replaceDivineName: true)
        )

        XCTAssertTrue(commands.contains(.verseNumber(1)))
        XCTAssertTrue(commands.contains(.heading("Heading")))
        XCTAssertTrue(commands.contains(.footnote("Study note")))
        XCTAssertTrue(commands.contains(.excluded(.crossReference)))
        XCTAssertTrue(commands.contains(.excluded(.nonStudyNote)))
        XCTAssertTrue(commands.contains(.text("Yahvé")), "commands: \(commands)")
        XCTAssertFalse(commands.contains(.text("Seigneur")))
        XCTAssertTrue(commands.contains(.pause(milliseconds: 150)))
        XCTAssertTrue(commands.contains(.pause(milliseconds: 500)))

        let excluded = SpeakCommandBuilder.commands(
            rawOSIS: osis,
            fallbackPlainText: "fallback",
            language: "fr",
            playbackSettings: PlaybackSettings(speakTitles: false, speakFootnotes: false),
            advancedSettings: AdvancedSpeakSettings(replaceDivineName: false)
        )
        XCTAssertFalse(excluded.contains { if case .heading = $0 { return true }; return false })
        XCTAssertFalse(excluded.contains { if case .footnote = $0 { return true }; return false })
        XCTAssertTrue(excluded.contains(.text("Seigneur")), "commands: \(excluded)")
    }

    /**
     Verifies Strong's-tagged OSIS speaks as one continuous run with attached punctuation.

     KJV-class modules wrap every word in `<w lemma="strong:...">`, leaving punctuation as bare
     text nodes between elements. Flushing at inline boundaries produced one utterance per word
     with prosody gaps, and lone punctuation runs that the synthesizer narrated aloud as "comma"
     and "full stop". Android's OsisToBibleSpeak accumulates through inline markup, so iOS must
     produce a single text command per verse body.
     */
    func testStrongsTaggedVerseSpeaksAsOneContinuousRun() {
        let osis = #"<verse osisID="Gen.1.1" sID="Gen.1.1"/>"# +
            #"<w lemma="strong:H07225">In the beginning</w> "# +
            #"<w lemma="strong:H0430">God</w> <w lemma="strong:H1254">created</w> "# +
            #"<transChange type="added">the</transChange> "# +
            #"<w lemma="strong:H8064">heaven</w> and "# +
            #"<w lemma="strong:H776">the earth</w>."#
        let commands = SpeakCommandBuilder.commands(
            rawOSIS: osis,
            fallbackPlainText: "",
            language: "en",
            playbackSettings: PlaybackSettings(),
            advancedSettings: AdvancedSpeakSettings()
        )

        XCTAssertEqual(
            commands,
            [
                .verseNumber(1),
                .text("In the beginning God created the heaven and the earth."),
            ],
            "commands: \(commands)"
        )
    }

    /**
     Verifies punctuation stranded by hidden elements never becomes its own spoken command.

     A run containing no letters or digits must merge into the preceding same-kind command or be
     dropped; spoken alone, the synthesizer narrates the punctuation name aloud.
     */
    func testPunctuationOnlyRunsMergeIntoPrecedingTextInsteadOfBeingSpoken() {
        let osis = #"<w lemma="strong:G2424">Jesus wept</w>"# +
            #"<note type="crossReference">hidden</note>."#
        let commands = SpeakCommandBuilder.commands(
            rawOSIS: osis,
            fallbackPlainText: "",
            language: "en",
            playbackSettings: PlaybackSettings(),
            advancedSettings: AdvancedSpeakSettings()
        )

        XCTAssertEqual(
            commands,
            [
                .text("Jesus wept"),
                .excluded(.nonStudyNote),
            ],
            "Expected the stranded period to be dropped rather than spoken; commands: \(commands)"
        )
        XCTAssertFalse(
            commands.contains(.text(".")),
            "A lone punctuation run must never become a spoken command."
        )
    }

    /**
     Reproduces the aggregate ordering that exposed decoder and localized-command contamination.

     The sequence generates localized commands, decodes malformed playback and container settings,
     then generates commands again with replacement disabled. Exact command arrays prove nested
     element boundaries survive catalog reuse; repeated complete-default equality proves process
     ordering cannot weaken Android's whole-object serializer fallback.
     */
    func testAggregateOrderPreservesFieldDefaultsAndLocalizedCommandBoundaries() {
        let osis = #"<divineName>Seigneur</divineName><p>After paragraph</p>"#
        let replaced = SpeakCommandBuilder.commands(
            rawOSIS: osis,
            fallbackPlainText: "fallback",
            language: "fr",
            playbackSettings: PlaybackSettings(),
            advancedSettings: AdvancedSpeakSettings(replaceDivineName: true)
        )
        XCTAssertEqual(replaced, [.text("Yahvé"), .text("After paragraph")])

        let playbackPayload =
            #"{"bookId":"NASB","speed":"fast","speakTitles":false,"verseRange":"KJV::"}"#
        let playback = PlaybackSettings.fromAndroidJSON(playbackPayload)
        XCTAssertEqual(playback, PlaybackSettings())

        let settingsPayload =
            #"{"playbackSettings":"bad","sleepTimer":9,"lastSleepTimer":null,"queue":false,"repeat":"bad","numPagesToSpeakId":44}"#
        let settings = SpeakSettings.fromAndroidJSON(settingsPayload)
        XCTAssertEqual(settings, SpeakSettings())

        let unreplaced = SpeakCommandBuilder.commands(
            rawOSIS: osis,
            fallbackPlainText: "fallback",
            language: "fr",
            playbackSettings: PlaybackSettings(),
            advancedSettings: AdvancedSpeakSettings(replaceDivineName: false)
        )
        XCTAssertEqual(unreplaced, [.text("Seigneur"), .text("After paragraph")])
        XCTAssertEqual(PlaybackSettings.fromAndroidJSON(playbackPayload), playback)
        XCTAssertEqual(SpeakSettings.fromAndroidJSON(settingsPayload), settings)
    }

    /** Verifies every supported document family constructs its own provider category. */
    func testCategoryProvidersRemainDistinctAndMemorizationRepeats() {
        let positions = [makePosition(index: 0, category: .generalBook)]
        let advanced = AdvancedSpeakSettings()
        let loader = makeLoader()

        XCTAssertEqual(CommentarySpeakTextProvider(positions: positions, startIndex: 0, advancedSettings: advanced, loader: loader).category, .commentary)
        XCTAssertEqual(DictionarySpeakTextProvider(positions: positions, startIndex: 0, advancedSettings: advanced, loader: loader).category, .dictionary)
        XCTAssertEqual(GeneralBookSpeakTextProvider(positions: positions, startIndex: 0, advancedSettings: advanced, loader: loader).category, .generalBook)
        XCTAssertEqual(MyDocumentSpeakTextProvider(positions: positions, startIndex: 0, advancedSettings: advanced, loader: loader).category, .myDocument)

        let memorization = MemorizationSpeakTextProvider(
            positions: [makePosition(index: 0, category: .memorization)],
            startIndex: 0,
            bounds: 0...0,
            advancedSettings: advanced,
            loader: loader
        )
        XCTAssertEqual(memorization.category, .memorization)
        XCTAssertFalse(memorization.canAutoBookmark)
        XCTAssertTrue(memorization.isMemorizationLoop)
        XCTAssertTrue(memorization.advance(settings: SpeakSettings()))
        XCTAssertEqual(memorization.currentPosition?.key, "Key.0")
    }

    /** Verifies generic smart and one-unit transport operate only on provider stream units. */
    func testGenericProviderTransportDoesNotUseBibleChapterNavigation() {
        let positions = (0..<20).map { makePosition(index: $0, category: .dictionary) }
        let provider = DictionarySpeakTextProvider(
            positions: positions,
            startIndex: 12,
            advancedSettings: AdvancedSpeakSettings(),
            loader: makeLoader()
        )

        XCTAssertTrue(provider.rewind(.smart))
        XCTAssertEqual(provider.currentPosition?.key, "Key.2")
        XCTAssertTrue(provider.forward(.oneUnit))
        XCTAssertEqual(provider.currentPosition?.key, "Key.3")
        XCTAssertTrue(provider.forward(.smart))
        XCTAssertEqual(provider.currentPosition?.key, "Key.13")
    }

    /**
     Verifies Android verse-range settings become real provider bounds and repeat only that passage.

     The same fixture also proves a range from another versification fails closed instead of being
     reinterpreted as identity coordinates.
     */
    func testBibleProviderAppliesVerseRangeBoundsAndRejectsVersificationMismatch() throws {
        let positions = (1...5).map { verse in
            makeBiblePosition(verse: verse, versification: "KJV")
        }
        let provider = BibleSpeakTextProvider(
            positions: positions,
            startIndex: 0,
            advancedSettings: AdvancedSpeakSettings(),
            verseRangeResolver: { range in
                guard range.versification == "KJV",
                      let endpoints = range.validatedReferences(),
                      let start = positions.firstIndex(where: {
                          $0.osisRef == "\(endpoints.start.osisBookId).\(endpoints.start.chapter).\(endpoints.start.verse)"
                      }),
                      let end = positions.firstIndex(where: {
                          $0.osisRef == "\(endpoints.end.osisBookId).\(endpoints.end.chapter).\(endpoints.end.verse)"
                      }),
                      start <= end else {
                    return nil
                }
                return start...end
            },
            loader: makeLoader()
        )
        var settings = SpeakSettings()
        settings.playbackSettings.verseRange = try XCTUnwrap(
            SpeakVerseRange(versification: "KJV", osisRef: "Gen.1.2-Gen.1.3")
        )

        XCTAssertTrue(provider.prepare(settings: settings))
        XCTAssertEqual(provider.currentPosition?.osisRef, "Gen.1.2")
        XCTAssertTrue(provider.advance(settings: settings))
        XCTAssertEqual(provider.currentPosition?.osisRef, "Gen.1.3")
        XCTAssertTrue(provider.advance(settings: settings))
        XCTAssertEqual(provider.currentPosition?.osisRef, "Gen.1.2")
        XCTAssertEqual(provider.checkpoint()?.lowerBound.key, "Gen.1.2")
        XCTAssertEqual(provider.checkpoint()?.upperBound.key, "Gen.1.3")

        settings.playbackSettings.verseRange = try XCTUnwrap(
            SpeakVerseRange(versification: "LXX", osisRef: "Gen.1.2-Gen.1.3")
        )
        XCTAssertFalse(provider.prepare(settings: settings))
    }

    /**
     Verifies typed Bible and memorization requests use the requested module and strict `toV11n` map.

     Vulgate Psalm 10 maps to KJV Psalm 11, so coordinate identity would fail these assertions. The
     fixture also proves unavailable modules and unknown canons fail before provider construction.
     */
    func testBibleSourceResolverUsesRequestedModuleAndAuthoritativeVersification() throws {
        let manager = try XCTUnwrap(SwordManager(modulePath: repositorySwordFixturePath()))
        let sourceStart = try XCTUnwrap(
            SwordVersification.referenceIndex(
                for: .init(osisBookId: "Ps", chapter: 10, verse: 2),
                versification: "Vulg"
            )
        )
        let sourceEnd = try XCTUnwrap(
            SwordVersification.referenceIndex(
                for: .init(osisBookId: "Ps", chapter: 10, verse: 3),
                versification: "Vulg"
            )
        )

        let bible = try BibleSpeakSourceResolver.resolve(
            request: SpeakSelectionRequest(
                category: .bible,
                bookInitials: "KJV",
                key: "Ps.10.1",
                startOrdinal: sourceStart,
                endOrdinal: sourceEnd,
                versification: "Vulg"
            ),
            manager: manager
        )
        XCTAssertEqual(bible.module.info.name, "KJV")
        XCTAssertEqual(bible.targetVersification, "KJV")
        XCTAssertEqual(bible.positions[bible.startIndex].osisRef, "Ps.11.1")
        XCTAssertNil(bible.bounds)

        let memorization = try BibleSpeakSourceResolver.resolve(
            request: SpeakSelectionRequest(
                category: .memorization,
                bookInitials: "KJV",
                key: "Ps.10.1-Ps.10.2",
                startOrdinal: sourceStart,
                endOrdinal: sourceEnd,
                versification: "Vulg"
            ),
            manager: manager
        )
        let bounds = try XCTUnwrap(memorization.bounds)
        XCTAssertEqual(memorization.positions[bounds.lowerBound].osisRef, "Ps.11.1")
        XCTAssertEqual(memorization.positions[bounds.upperBound].osisRef, "Ps.11.2")

        let missingStartPositions = Array(bible.positions.dropFirst())
        XCTAssertNil(
            BibleSpeakSourceResolver.exactPositionIndex(
                forOrdinal: bible.positions[0].ordinalStart!,
                positions: missingStartPositions
            )
        )
        XCTAssertNil(
            BibleSpeakSourceResolver.positionBounds(
                for: try XCTUnwrap(
                    SpeakVerseRange(versification: "KJV", osisRef: "Gen.1.1-Gen.1.3")
                ),
                module: bible.module,
                positions: missingStartPositions,
                targetVersification: bible.targetVersification
            )
        )

        XCTAssertThrowsError(
            try BibleSpeakSourceResolver.resolve(
                request: SpeakSelectionRequest(
                    category: .bible,
                    bookInitials: "MISSING",
                    key: "Gen.1.1",
                    startOrdinal: sourceStart,
                    endOrdinal: sourceStart,
                    versification: "Vulg"
                ),
                manager: manager
            )
        ) { error in
            XCTAssertEqual(error as? BibleSpeakSourceResolutionError, .moduleUnavailable("MISSING"))
        }
        XCTAssertThrowsError(
            try BibleSpeakSourceResolver.resolve(
                request: SpeakSelectionRequest(
                    category: .bible,
                    bookInitials: "KJV",
                    key: "Gen.1.1",
                    startOrdinal: sourceStart,
                    endOrdinal: sourceStart,
                    versification: "UnknownV11n"
                ),
                manager: manager
            )
        )
    }

    /** Verifies Bible checkpoint reconstruction preserves exact target-module position and bounds. */
    func testBibleCheckpointReconstructionUsesPersistedModuleAndVersification() throws {
        let manager = try XCTUnwrap(SwordManager(modulePath: repositorySwordFixturePath()))
        let start = try XCTUnwrap(
            SwordVersification.referenceIndex(
                for: .init(osisBookId: "Gen", chapter: 1, verse: 1),
                versification: "KJV"
            )
        )
        let end = try XCTUnwrap(
            SwordVersification.referenceIndex(
                for: .init(osisBookId: "Gen", chapter: 1, verse: 3),
                versification: "KJV"
            )
        )
        let resolved = try BibleSpeakSourceResolver.resolve(
            request: SpeakSelectionRequest(
                category: .memorization,
                bookInitials: "KJV",
                key: "Gen.1.1-Gen.1.3",
                startOrdinal: start,
                endOrdinal: end,
                versification: "KJV"
            ),
            manager: manager
        )
        let bounds = try XCTUnwrap(resolved.bounds)
        let provider = MemorizationSpeakTextProvider(
            positions: resolved.positions,
            startIndex: bounds.lowerBound,
            bounds: bounds,
            advancedSettings: AdvancedSpeakSettings(),
            loader: makeLoader()
        )
        XCTAssertTrue(provider.advance(settings: SpeakSettings()))
        let checkpoint = try XCTUnwrap(provider.checkpoint())

        let reconstructed = try BibleSpeakSourceResolver.resolve(
            checkpoint: checkpoint,
            manager: manager
        )
        XCTAssertEqual(reconstructed.module.info.name, "KJV")
        XCTAssertEqual(reconstructed.bounds, bounds)
        XCTAssertEqual(
            reconstructed.positions[reconstructed.startIndex].osisRef,
            provider.currentPosition?.osisRef
        )

        let invalid = SpeakProviderCheckpoint(
            current: checkpoint.current,
            lowerBound: checkpoint.lowerBound,
            upperBound: checkpoint.upperBound,
            isBounded: false,
            isMemorizationLoop: true
        )
        XCTAssertThrowsError(
            try BibleSpeakSourceResolver.resolve(checkpoint: invalid, manager: manager)
        ) { error in
            guard case .invalidCheckpoint = error as? BibleSpeakSourceResolutionError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    /**
     Verifies adding ordered passage queues does not invalidate persisted version-1 pause state.

     Existing users can have checkpoint JSON without the new optional fields. Decoding must leave
     those fields nil so ordinary Bible and generic reconstruction continues through the original
     schema instead of treating an omitted queue as corruption.
     */
    func testVersionOneCheckpointDecodesWithoutOrderedPassageFields() throws {
        let data = try XCTUnwrap(
            #"{"version":1,"current":{"category":"bible","bookInitials":"KJV","key":"Gen.1.1","ordinalStart":4,"ordinalEnd":4,"versification":"KJV"},"lowerBound":{"category":"bible","bookInitials":"KJV","key":"Gen.1.1","ordinalStart":4,"ordinalEnd":4,"versification":"KJV"},"upperBound":{"category":"bible","bookInitials":"KJV","key":"Gen.1.1","ordinalStart":4,"ordinalEnd":4,"versification":"KJV"},"isBounded":false,"isMemorizationLoop":false}"#
                .data(using: .utf8)
        )

        let checkpoint = try JSONDecoder().decode(SpeakProviderCheckpoint.self, from: data)

        XCTAssertEqual(checkpoint.version, 1)
        XCTAssertNil(checkpoint.orderedPositions)
        XCTAssertNil(checkpoint.orderedPositionIndex)
        XCTAssertNil(checkpoint.orderedPassages)
        XCTAssertNil(checkpoint.currentPassageIndex)
        XCTAssertNil(checkpoint.currentPositionIndexInPassage)
        XCTAssertNil(checkpoint.playbackCursor)
    }

    /**
     Verifies raw version-0 checkpoint JSON remains decodable after adding semantic passage fields.

     The fixture omits every version-1 and version-2 optional field, matching an Android legacy
     source cursor. Successful decoding with nil semantic fields proves schema evolution does not
     strand existing paused sessions; failure indicates a backward-compatibility regression.
     */
    func testVersionZeroCheckpointDecodesWithoutSemanticPassageFields() throws {
        let data = try XCTUnwrap(
            #"{"version":0,"current":{"category":"bible","bookInitials":"KJV","key":"Gen.1.1"},"lowerBound":{"category":"bible","bookInitials":"KJV","key":"Gen.1.1"},"upperBound":{"category":"bible","bookInitials":"KJV","key":"Gen.1.1"},"isBounded":false,"isMemorizationLoop":false}"#
                .data(using: .utf8)
        )

        let checkpoint = try JSONDecoder().decode(SpeakProviderCheckpoint.self, from: data)

        XCTAssertEqual(checkpoint.version, 0)
        XCTAssertNil(checkpoint.orderedPositions)
        XCTAssertNil(checkpoint.orderedPositionIndex)
        XCTAssertNil(checkpoint.orderedPassages)
        XCTAssertNil(checkpoint.currentPassageIndex)
        XCTAssertNil(checkpoint.currentPositionIndexInPassage)
        XCTAssertNil(checkpoint.playbackCursor)
    }

    /** Verifies generic checkpoints preserve the exact module, key, and local ordinal cursor. */
    func testGenericProviderCheckpointPreservesExactSourceCursorAndBounds() {
        let positions = (10...12).map { ordinal in
            makeGenericPosition(key: "Entry", ordinal: ordinal, category: .dictionary)
        }
        let provider = DictionarySpeakTextProvider(
            positions: positions,
            startIndex: 1,
            bounds: 1...2,
            advancedSettings: AdvancedSpeakSettings(),
            loader: makeLoader()
        )

        let checkpoint = provider.checkpoint()
        XCTAssertEqual(checkpoint?.current.bookInitials, "TEST")
        XCTAssertEqual(checkpoint?.current.key, "Entry")
        XCTAssertEqual(checkpoint?.current.ordinalStart, 11)
        XCTAssertEqual(checkpoint?.lowerBound.ordinalStart, 11)
        XCTAssertEqual(checkpoint?.upperBound.ordinalEnd, 12)
        XCTAssertEqual(checkpoint?.isBounded, true)
    }

    /**
     Verifies Android's generic provider retains exact local ordinals while crossing document keys.

     The lazy source records every load. Construction must touch only the requested key, transport
     must advance one BVA ordinal at a time, and an unbounded collection must wrap from the final
     ordinal to the first. A failure indicates generic playback was flattened back to page/key units
     or began eagerly loading the whole document.
     */
    func testExactGenericProviderTraversesLocalOrdinalsLazilyAndWraps() throws {
        let fixture = GenericSpeakSourceFixture(category: .dictionary)
        let provider = try XCTUnwrap(
            GenericOrdinalSpeakTextProvider(
                source: fixture.source,
                startKey: "Alpha",
                startOrdinal: 4
            )
        )

        XCTAssertEqual(fixture.loadedKeys, ["Alpha"])
        XCTAssertEqual(provider.currentPosition?.key, "Alpha")
        XCTAssertEqual(provider.currentPosition?.ordinalStart, 4)
        XCTAssertEqual(provider.currentUnit(settings: SpeakSettings())?.commands, [.text("Alpha 4")])

        XCTAssertTrue(provider.advance(settings: SpeakSettings()))
        XCTAssertEqual(provider.currentPosition?.key, "Beta")
        XCTAssertEqual(provider.currentPosition?.ordinalStart, 10)
        XCTAssertEqual(fixture.loadedKeys, ["Alpha", "Beta"])

        XCTAssertTrue(provider.advance(settings: SpeakSettings()))
        XCTAssertEqual(provider.currentPosition?.ordinalStart, 11)
        XCTAssertTrue(provider.advance(settings: SpeakSettings()))
        XCTAssertEqual(provider.currentPosition?.key, "Alpha")
        XCTAssertEqual(provider.currentPosition?.ordinalStart, 3)

        let checkpoint = try XCTUnwrap(provider.checkpoint())
        XCTAssertFalse(checkpoint.isBounded)
        XCTAssertEqual(checkpoint.current.key, "Alpha")
        XCTAssertEqual(checkpoint.current.ordinalStart, 3)
        XCTAssertEqual(checkpoint.lowerBound.ordinalStart, 3)
        XCTAssertEqual(checkpoint.upperBound.ordinalStart, 11)
    }

    /** Verifies a sparse BVA key fails closed instead of skipping an absent local ordinal. */
    func testExactGenericProviderRejectsSparseOrdinalContent() {
        let source = GenericSpeakOrdinalSource(
            category: .dictionary,
            bookInitials: "DICT",
            bookName: "Dictionary",
            language: "en",
            keys: ["Entry"],
            loadContent: { key in
                GenericSpeakKeyContent(
                    key: key,
                    keyName: key,
                    ordinalRange: 4...6,
                    commandsByOrdinal: [4: [.text("Four")], 6: [.text("Six")]]
                )
            }
        )

        XCTAssertNil(
            GenericOrdinalSpeakTextProvider(
                source: source,
                startKey: "Entry",
                startOrdinal: 4
            )
        )
    }

    /**
     Verifies explicit Android generic ordinal bounds terminate and smart rewind returns to a title.

     The range spans two keys and therefore attacks both boundary comparison and local ordinal
     traversal. The title command is marked only when playback starts it, matching Android's rewind
     state rather than treating every key boundary as a Bible chapter.
     */
    func testExactGenericProviderHonorsCrossKeyBoundsAndTitleAwareRewind() throws {
        let fixture = GenericSpeakSourceFixture(category: .commentary)
        let provider = try XCTUnwrap(
            GenericOrdinalSpeakTextProvider(
                source: fixture.source,
                startKey: "Alpha",
                startOrdinal: 4,
                endKey: "Beta",
                endOrdinal: 10
            )
        )

        provider.didStart(command: .heading("Alpha title"))
        XCTAssertTrue(provider.forward(.oneUnit))
        XCTAssertEqual(provider.currentPosition?.key, "Beta")
        XCTAssertEqual(provider.currentPosition?.ordinalStart, 10)
        XCTAssertTrue(provider.rewind(.smart))
        XCTAssertEqual(provider.currentPosition?.key, "Alpha")
        XCTAssertEqual(provider.currentPosition?.ordinalStart, 4)

        XCTAssertTrue(provider.advance(settings: SpeakSettings()))
        XCTAssertFalse(provider.advance(settings: SpeakSettings()))
        XCTAssertFalse(provider.canAutoBookmark)
        XCTAssertEqual(provider.checkpoint()?.lowerBound.ordinalStart, 4)
        XCTAssertEqual(provider.checkpoint()?.upperBound.ordinalStart, 10)
    }

    /** Verifies smart rewind at a key boundary moves once to the previous key's final ordinal. */
    func testExactGenericSmartRewindAtKeyStartMatchesAndroidPreviousKeyRule() throws {
        let fixture = GenericSpeakSourceFixture(category: .generalBook)
        let provider = try XCTUnwrap(
            GenericOrdinalSpeakTextProvider(
                source: fixture.source,
                startKey: "Beta",
                startOrdinal: 10
            )
        )

        XCTAssertTrue(provider.rewind(.smart))
        XCTAssertEqual(provider.currentPosition?.key, "Alpha")
        XCTAssertEqual(provider.currentPosition?.ordinalStart, 4)
    }

    /** Verifies process reconstruction retains exact generic current, lower, and upper cursors. */
    func testExactGenericCheckpointReconstructionPreservesOriginalSelectionBounds() throws {
        let originalFixture = GenericSpeakSourceFixture(category: .dictionary)
        let original = try XCTUnwrap(
            GenericOrdinalSpeakTextProvider(
                source: originalFixture.source,
                startKey: "Alpha",
                startOrdinal: 4,
                endKey: "Beta",
                endOrdinal: 11
            )
        )
        XCTAssertTrue(original.advance(settings: SpeakSettings()))
        XCTAssertEqual(original.currentPosition?.ordinalStart, 10)
        let checkpoint = try XCTUnwrap(original.checkpoint())

        let restoredFixture = GenericSpeakSourceFixture(category: .dictionary)
        let restored = try XCTUnwrap(
            GenericOrdinalSpeakTextProvider(
                source: restoredFixture.source,
                checkpoint: checkpoint
            )
        )
        XCTAssertEqual(restored.currentPosition?.key, "Beta")
        XCTAssertEqual(restored.currentPosition?.ordinalStart, 10)
        XCTAssertEqual(restored.checkpoint(), checkpoint)
        XCTAssertTrue(restored.rewind(.oneUnit))
        XCTAssertEqual(restored.currentPosition?.key, "Alpha")
        XCTAssertEqual(restored.currentPosition?.ordinalStart, 4)
        XCTAssertTrue(restored.forward(.smart))
        XCTAssertEqual(restored.currentPosition?.ordinalStart, 11)
        XCTAssertFalse(restored.advance(settings: SpeakSettings()))

        let wrongModuleSource = GenericSpeakOrdinalSource(
            category: .dictionary,
            bookInitials: "OTHER",
            bookName: "Other",
            language: "en",
            keys: ["Alpha", "Beta"],
            loadContent: restoredFixture.source.loadContent
        )
        XCTAssertNil(
            GenericOrdinalSpeakTextProvider(
                source: wrongModuleSource,
                checkpoint: checkpoint
            )
        )
    }

    /**
     Verifies transformed EPUB BVA elements are the sole authority for page speech ordinals.

     Nested inline markup and whitespace normalize into one value per declared ordinal. Duplicate,
     missing, or out-of-range anchors must fail atomically; accepting them would make resume and
     bounded transport point at text other than the persisted Android cursor.
     */
    func testGenericSpeakOrdinalProjectionRequiresOneStructuredAnchorPerOrdinal() {
        let xhtml = """
        <html xmlns="http://www.w3.org/1999/xhtml"><body>
          <bva ordinal="7">First <em>nested</em> sentence.</bva>
          <bva ordinal="8">Second\n sentence.</bva>
        </body></html>
        """
        XCTAssertEqual(
            GenericSpeakOrdinalProjection.epubOrdinalTexts(xhtml: xhtml, expectedRange: 7...8),
            [7: "First nested sentence.", 8: "Second sentence."]
        )
        XCTAssertNil(
            GenericSpeakOrdinalProjection.epubOrdinalTexts(
                xhtml: #"<html><body><bva ordinal="7">One.</bva><bva ordinal="7">Duplicate.</bva></body></html>"#,
                expectedRange: 7...8
            )
        )
        XCTAssertNil(
            GenericSpeakOrdinalProjection.epubOrdinalTexts(
                xhtml: #"<html><body><bva ordinal="7">Only one.</bva></body></html>"#,
                expectedRange: 7...8
            )
        )
    }

    /** Verifies smart rewind prefers the last title command before generic distance fallback. */
    func testGenericSmartRewindReturnsToLastSpokenTitle() {
        let positions = (0..<20).map { makePosition(index: $0, category: .generalBook) }
        let provider = GeneralBookSpeakTextProvider(
            positions: positions,
            startIndex: 12,
            advancedSettings: AdvancedSpeakSettings(),
            loader: makeLoader()
        )

        provider.didStart(command: .heading("Section"))
        XCTAssertTrue(provider.forward(.oneUnit))
        XCTAssertTrue(provider.forward(.oneUnit))
        XCTAssertTrue(provider.rewind(.smart))
        XCTAssertEqual(provider.currentPosition?.key, "Key.12")
    }

    /** Verifies Android's unbounded collection stream wraps while an explicit bound terminates. */
    func testUnboundedGenericProviderWrapsAndBoundedProviderStops() {
        let positions = (0..<2).map { makePosition(index: $0, category: .dictionary) }
        let unbounded = DictionarySpeakTextProvider(
            positions: positions,
            startIndex: 1,
            advancedSettings: AdvancedSpeakSettings(),
            loader: makeLoader()
        )
        XCTAssertTrue(unbounded.advance(settings: SpeakSettings()))
        XCTAssertEqual(unbounded.currentPosition?.key, "Key.0")

        let bounded = DictionarySpeakTextProvider(
            positions: positions,
            startIndex: 1,
            bounds: 0...1,
            advancedSettings: AdvancedSpeakSettings(),
            loader: makeLoader()
        )
        XCTAssertFalse(bounded.advance(settings: SpeakSettings()))
        XCTAssertEqual(bounded.currentPosition?.key, "Key.1")
    }

    /** Verifies service transport, restored bookmark settings, updates, and pause persistence. */
    func testSpeakServiceAppliesBookmarkSettingsAndPersistsGenericProviderPosition() {
        let synthesizer = FakeSpeechSynthesizer()
        let manager = SpeakParityBookmarkManager()
        manager.restoredSettings = PlaybackSettings(speakTitles: false, speed: 180, bookId: "DICT", bookmarkWasCreated: true)
        let service = SpeakService(synthesizer: synthesizer)
        service.bookmarkManager = manager
        service.updateAdvancedSettings(
            AdvancedSpeakSettings(autoBookmark: true, restoreSettingsFromBookmarks: true)
        )
        let provider = DictionarySpeakTextProvider(
            positions: (0..<4).map { makePosition(index: $0, category: .dictionary) },
            startIndex: 2,
            advancedSettings: service.advancedSettings,
            loader: makeLoader()
        )

        service.speak(provider: provider)
        XCTAssertEqual(service.activeProviderCategory, .dictionary)
        XCTAssertEqual(service.settings.playbackSettings.speed, 180)
        XCTAssertFalse(service.settings.playbackSettings.speakTitles)
        XCTAssertNil(service.settings.playbackSettings.bookId)
        XCTAssertEqual(synthesizer.spokenUtterances.last?.speechString, "Key.2")

        service.previousUnit()
        XCTAssertEqual(service.currentPosition?.key, "Key.1")
        XCTAssertEqual(synthesizer.spokenUtterances.last?.speechString, "Key.1")
        var playback = service.settings.playbackSettings
        playback.speakFootnotes = true
        service.updatePlaybackSettings(playback)
        XCTAssertEqual(manager.persisted.count, 1)
        XCTAssertEqual(manager.persisted.last?.settings.speakFootnotes, true)

        service.pause()
        XCTAssertTrue(service.isPaused)
        XCTAssertEqual(manager.persisted.last?.position.category, .dictionary)
        XCTAssertEqual(manager.persisted.last?.position.key, "Key.1")
        XCTAssertEqual(manager.persisted.last?.autoBookmark, true)
        XCTAssertEqual(manager.persisted.count, 2)

        service.stop()
        XCTAssertEqual(manager.persisted.count, 2, "pause followed by stop must not relocate twice")
    }

    /** Verifies settings restart, pause, stop, and stopped edits target Android's exact bookmark. */
    func testSpeakServiceBookmarkTransitionsPersistAndUpdateExactlyOnce() {
        let manager = SpeakParityBookmarkManager()
        let service = SpeakService(synthesizer: FakeSpeechSynthesizer())
        service.bookmarkManager = manager
        service.updateAdvancedSettings(AdvancedSpeakSettings(autoBookmark: true))
        service.speak(
            provider: DictionarySpeakTextProvider(
                positions: [makePosition(index: 7, category: .dictionary)],
                startIndex: 0,
                advancedSettings: service.advancedSettings,
                loader: makeLoader()
            )
        )

        var playback = service.settings.playbackSettings
        playback.speed = 135
        service.updatePlaybackSettings(playback)
        XCTAssertEqual(manager.persisted.map(\.position.key), ["Key.7"])

        service.pause()
        XCTAssertEqual(manager.persisted.map(\.position.key), ["Key.7", "Key.7"])
        playback.speakFootnotes = true
        service.updatePlaybackSettings(playback)
        XCTAssertEqual(manager.updated.map(\.position.key), ["Key.7"])
        XCTAssertEqual(manager.updated.last?.settings.speakFootnotes, true)

        service.stop()
        XCTAssertEqual(manager.persisted.count, 2, "stop after pause must not persist a third time")
        playback.speakTitles = false
        service.updatePlaybackSettings(playback)
        XCTAssertEqual(manager.updated.map(\.position.key), ["Key.7"])

        service.onRequestStoppedBibleBookmarkPosition = {
            self.makePosition(index: 9, category: .bible)
        }
        playback.speed = 145
        service.updatePlaybackSettings(playback)
        XCTAssertEqual(manager.updated.map(\.position.key), ["Key.7", "Key.9"])
        XCTAssertEqual(manager.updated.last?.position.category, .bible)
        XCTAssertEqual(manager.updated.last?.settings.speakTitles, false)
    }

    /**
     Verifies pause persists Android's exact generic cursor and a new service reconstructs it.

     The in-memory settings store represents process-stable persistence; the fake synthesizer proves
     resume creates a new utterance rather than continuing a destroyed platform utterance.
     */
    func testPauseCheckpointReconstructsExactGenericPositionAfterServiceRecreation() throws {
        let store = try makeInMemorySettingsStore()
        let positions = (20...22).map {
            makeGenericPosition(key: "Entry", ordinal: $0, category: .dictionary)
        }
        let firstSynthesizer = FakeSpeechSynthesizer()
        let first = SpeakService(synthesizer: firstSynthesizer)
        first.settingsStore = store
        first.speak(
            provider: DictionarySpeakTextProvider(
                positions: positions,
                startIndex: 1,
                advancedSettings: AdvancedSpeakSettings(),
                loader: makeLoader()
            )
        )
        first.pause()

        let persistedGenericJSON = try XCTUnwrap(store.getString("SpeakGenKey"))
        let persistedGeneric = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(persistedGenericJSON.utf8)) as? [String: Any]
        )
        XCTAssertEqual(persistedGeneric["document"] as? String, "TEST")
        XCTAssertEqual(persistedGeneric["key"] as? String, "Entry")
        let ordinalRange = try XCTUnwrap(persistedGeneric["ordinalRange"] as? [String: Any])
        XCTAssertEqual(ordinalRange["start"] as? Int, 21)
        XCTAssertTrue(ordinalRange["end"] is NSNull)
        XCTAssertTrue(persistedGeneric["htmlId"] is NSNull)
        XCTAssertEqual(Set(persistedGeneric.keys), ["document", "htmlId", "key", "ordinalRange"])

        let secondSynthesizer = FakeSpeechSynthesizer()
        let second = SpeakService(synthesizer: secondSynthesizer)
        second.settingsStore = store
        var reconstructedCheckpoint: SpeakProviderCheckpoint?
        var restoredCallbackPositions: [(Int, UInt64)] = []
        second.onRequestSessionReconstruction = { checkpoint in
            reconstructedCheckpoint = checkpoint
            guard let provider = self.genericProvider(
                reconstructing: checkpoint,
                positions: positions
            ) else {
                return nil
            }
            return SpeakSessionReconstruction(
                provider: provider,
                callbacks: SpeakSessionCallbacks(onPositionChanged: { position, generation in
                    restoredCallbackPositions.append((position.ordinalStart ?? -1, generation))
                })
            )
        }
        second.restoreSettings()

        XCTAssertTrue(second.isSpeaking)
        XCTAssertTrue(second.isPaused)
        XCTAssertEqual(second.currentPosition?.key, "Entry")
        XCTAssertEqual(second.currentPosition?.ordinalStart, 21)
        XCTAssertEqual(reconstructedCheckpoint?.current.ordinalStart, 21)
        second.resume()
        XCTAssertFalse(second.isPaused)
        XCTAssertEqual(secondSynthesizer.continueCount, 0)
        XCTAssertEqual(secondSynthesizer.spokenUtterances.last?.speechString, "Entry")
        XCTAssertEqual(restoredCallbackPositions.map(\.0), [21])
        XCTAssertEqual(restoredCallbackPositions.map(\.1), [second.currentSessionGeneration])
    }

    /** Verifies remote Play reconstructs the last stopped provider before using a default source. */
    func testStoppedPlayReconstructsLastProviderCheckpoint() throws {
        let store = try makeInMemorySettingsStore()
        let positions = (30...31).map {
            makeGenericPosition(key: "Resume", ordinal: $0, category: .generalBook)
        }
        let first = SpeakService(synthesizer: FakeSpeechSynthesizer())
        first.settingsStore = store
        first.speak(
            provider: GeneralBookSpeakTextProvider(
                positions: positions,
                startIndex: 1,
                advancedSettings: AdvancedSpeakSettings(),
                loader: makeLoader()
            )
        )
        first.stop()

        let synthesizer = FakeSpeechSynthesizer()
        let restored = SpeakService(synthesizer: synthesizer)
        restored.settingsStore = store
        var defaultRequestCount = 0
        restored.onRequestProviderReconstruction = { checkpoint in
            self.genericProvider(reconstructing: checkpoint, positions: positions)
        }
        restored.onRequestDefaultProvider = {
            defaultRequestCount += 1
            return nil
        }
        restored.restoreSettings()
        restored.play()

        XCTAssertTrue(restored.isSpeaking)
        XCTAssertEqual(restored.currentPosition?.ordinalStart, 31)
        XCTAssertEqual(synthesizer.spokenUtterances.last?.speechString, "Resume")
        XCTAssertEqual(defaultRequestCount, 0)
    }

    /** Verifies stopped Play starts the reader's complete default session with owned callbacks. */
    func testStoppedPlayUsesCompleteDefaultSessionBeforeProviderCompatibilityFallback() {
        let synthesizer = FakeSpeechSynthesizer()
        let service = SpeakService(synthesizer: synthesizer)
        var callbackPositions: [(Int, UInt64)] = []
        var compatibilityFallbackCount = 0
        service.onRequestDefaultSession = {
            SpeakSessionReconstruction(
                provider: DictionarySpeakTextProvider(
                    positions: [self.makePosition(index: 6, category: .dictionary)],
                    startIndex: 0,
                    advancedSettings: AdvancedSpeakSettings(),
                    loader: self.makeLoader()
                ),
                callbacks: SpeakSessionCallbacks(onPositionChanged: { position, generation in
                    callbackPositions.append((position.ordinalStart ?? -1, generation))
                }),
                title: "Default entry",
                subtitle: "Dictionary"
            )
        }
        service.onRequestDefaultProvider = {
            compatibilityFallbackCount += 1
            return nil
        }

        service.play()

        XCTAssertTrue(service.isSpeaking)
        XCTAssertEqual(service.currentTitle, "Key.6")
        XCTAssertEqual(service.currentSubtitle, "Test Book")
        XCTAssertEqual(callbackPositions.map(\.0), [6])
        XCTAssertEqual(callbackPositions.map(\.1), [service.currentSessionGeneration])
        XCTAssertEqual(compatibilityFallbackCount, 0)
        XCTAssertEqual(synthesizer.spokenUtterances.last?.speechString, "Key.6")
    }

    /** Verifies Android's module/key pause fields decode without invented v11n or category data. */
    func testAndroidPauseFieldsProduceExplicitLegacyCheckpoints() throws {
        let bibleStore = try makeInMemorySettingsStore()
        bibleStore.setBool("SpeakBibleProvider", value: true)
        bibleStore.setString("SpeakBibleBook", value: "KJV")
        bibleStore.setString("SpeakBibleVerse", value: "Gen.1.2")
        let bibleService = SpeakService(synthesizer: FakeSpeechSynthesizer())
        bibleService.settingsStore = bibleStore
        var bibleCheckpoint: SpeakProviderCheckpoint?
        bibleService.onRequestSessionReconstruction = { checkpoint in
            bibleCheckpoint = checkpoint
            return SpeakSessionReconstruction(
                provider: SelectionSpeakTextProvider(text: "Bible pause", language: "en")
            )
        }
        bibleService.restoreSettings()

        XCTAssertEqual(bibleCheckpoint?.version, 0)
        XCTAssertEqual(bibleCheckpoint?.current.category, .bible)
        XCTAssertEqual(bibleCheckpoint?.current.bookInitials, "KJV")
        XCTAssertEqual(bibleCheckpoint?.current.key, "Gen.1.2")
        XCTAssertNil(bibleCheckpoint?.current.ordinalStart)
        XCTAssertNil(bibleCheckpoint?.current.versification)
        XCTAssertTrue(bibleService.isPaused)

        let genericStore = try makeInMemorySettingsStore()
        genericStore.setBool("SpeakBibleProvider", value: false)
        genericStore.setString("SpeakGenBook", value: "DICT")
        genericStore.setString(
            "SpeakGenKey",
            value: #"{"key":"alpha","document":"DICT","ordinalRange":{"start":7,"end":7},"htmlId":null}"#
        )
        let genericService = SpeakService(synthesizer: FakeSpeechSynthesizer())
        genericService.settingsStore = genericStore
        var genericCheckpoint: SpeakProviderCheckpoint?
        genericService.onRequestSessionReconstruction = { checkpoint in
            genericCheckpoint = checkpoint
            return SpeakSessionReconstruction(
                provider: SelectionSpeakTextProvider(text: "Generic pause", language: "en")
            )
        }
        genericService.restoreSettings()

        XCTAssertEqual(genericCheckpoint?.version, 0)
        XCTAssertEqual(genericCheckpoint?.current.category, .generalBook)
        XCTAssertEqual(genericCheckpoint?.current.bookInitials, "DICT")
        XCTAssertEqual(genericCheckpoint?.current.key, "alpha")
        XCTAssertEqual(genericCheckpoint?.current.ordinalStart, 7)
        XCTAssertEqual(genericCheckpoint?.current.ordinalEnd, 7)
        XCTAssertNil(genericCheckpoint?.current.versification)
        XCTAssertTrue(genericService.isPaused)
    }

    /** Verifies cancelled callbacks from a replaced generation cannot advance or notify the new stream. */
    func testReplacedSessionRejectsStaleUtteranceAndCallbackGeneration() throws {
        let synthesizer = FakeSpeechSynthesizer()
        let service = SpeakService(synthesizer: synthesizer)
        var firstStoppedGenerations: [UInt64] = []
        var secondPositions: [(Int, UInt64)] = []
        let firstGeneration = service.speak(
            provider: DictionarySpeakTextProvider(
                positions: [makePosition(index: 1, category: .dictionary)],
                startIndex: 0,
                bounds: 0...0,
                advancedSettings: AdvancedSpeakSettings(),
                loader: makeLoader()
            ),
            callbacks: SpeakSessionCallbacks(onStopped: { firstStoppedGenerations.append($0) })
        )
        let staleUtterance = try XCTUnwrap(synthesizer.spokenUtterances.last)

        let secondGeneration = service.speak(
            provider: DictionarySpeakTextProvider(
                positions: [makePosition(index: 2, category: .dictionary)],
                startIndex: 0,
                bounds: 0...0,
                advancedSettings: AdvancedSpeakSettings(),
                loader: makeLoader()
            ),
            callbacks: SpeakSessionCallbacks(onPositionChanged: { position, generation in
                secondPositions.append((position.ordinalStart ?? -1, generation))
            })
        )
        service.speechSynthesizer(AVSpeechSynthesizer(), didFinish: staleUtterance)

        XCTAssertEqual(firstStoppedGenerations, [firstGeneration])
        XCTAssertNotEqual(firstGeneration, secondGeneration)
        XCTAssertEqual(secondPositions.map(\.0), [2])
        XCTAssertEqual(secondPositions.map(\.1), [secondGeneration])
        XCTAssertEqual(service.currentPosition?.key, "Key.2")
        XCTAssertEqual(synthesizer.spokenUtterances.map(\.speechString), ["Key.1", "Key.2"])
    }

    /**
     Verifies queued media commands cannot mutate a replacement and use Android smart transport.

     The first generation models an event captured before a new source starts. The accepted media
     next/previous actions must move ten generic provider units, while the stale event changes none.
     */
    func testRemoteCommandsRejectStaleGenerationAndUseSmartProviderTransport() {
        let service = SpeakService(synthesizer: FakeSpeechSynthesizer())
        let positions = (0...20).map {
            makePosition(index: $0, category: .dictionary)
        }
        let firstGeneration = service.speak(
            provider: DictionarySpeakTextProvider(
                positions: positions,
                startIndex: 0,
                advancedSettings: AdvancedSpeakSettings(),
                loader: makeLoader()
            )
        )
        let replacementGeneration = service.speak(
            provider: DictionarySpeakTextProvider(
                positions: positions,
                startIndex: 0,
                advancedSettings: AdvancedSpeakSettings(),
                loader: makeLoader()
            )
        )

        XCTAssertFalse(service.performRemoteCommand(
            .nextTrack,
            expectedSessionGeneration: firstGeneration
        ))
        XCTAssertEqual(service.currentPosition?.ordinalStart, 0)

        XCTAssertTrue(service.performRemoteCommand(
            .nextTrack,
            expectedSessionGeneration: replacementGeneration
        ))
        XCTAssertEqual(service.currentPosition?.ordinalStart, 10)

        XCTAssertTrue(service.performRemoteCommand(
            .previousTrack,
            expectedSessionGeneration: replacementGeneration
        ))
        XCTAssertEqual(service.currentPosition?.ordinalStart, 0)
    }

    /** Verifies queued stop cleanup cannot clear a replacement or a later stopped generation. */
    func testStoppedCleanupGenerationIsValidOnlyUntilReplacementStarts() {
        let service = SpeakService(synthesizer: FakeSpeechSynthesizer())
        let firstGeneration = service.speak(
            provider: DictionarySpeakTextProvider(
                positions: [makePosition(index: 1, category: .dictionary)],
                startIndex: 0,
                advancedSettings: AdvancedSpeakSettings(),
                loader: makeLoader()
            )
        )
        service.stop()
        XCTAssertTrue(service.mayApplyStoppedSessionCleanup(firstGeneration))

        let replacementGeneration = service.speak(
            provider: DictionarySpeakTextProvider(
                positions: [makePosition(index: 2, category: .dictionary)],
                startIndex: 0,
                advancedSettings: AdvancedSpeakSettings(),
                loader: makeLoader()
            )
        )
        XCTAssertFalse(service.mayApplyStoppedSessionCleanup(firstGeneration))
        service.stop()
        XCTAssertFalse(service.mayApplyStoppedSessionCleanup(firstGeneration))
        XCTAssertTrue(service.mayApplyStoppedSessionCleanup(replacementGeneration))
    }

    /** Verifies restored global and workspace settings affect a live provider in one restart. */
    func testBackupRestoreReloadsLiveSpeechSettingsBeforeNextSynthesis() throws {
        let store = try makeInMemorySettingsStore()
        let synthesizer = FakeSpeechSynthesizer()
        let service = SpeakService(synthesizer: synthesizer)
        service.settingsStore = store
        let position = makePosition(index: 5, category: .dictionary)
        service.speak(
            provider: DictionarySpeakTextProvider(
                positions: [position],
                startIndex: 0,
                advancedSettings: service.advancedSettings,
                loader: { position, settings, advanced in
                    [
                        .text(
                            "\(position.key)|\(settings.playbackSettings.speed)|"
                                + "\(advanced.replaceDivineName)"
                        ),
                    ]
                }
            )
        )
        XCTAssertEqual(synthesizer.spokenUtterances.map(\.speechString), ["Key.5|100|false"])

        store.setBool("speak_autoBookmark", value: true)
        store.setBool("speak_synchronize", value: false)
        store.setBool("speak_replaceDivineName", value: true)
        store.setBool("speak_restoreSettingsFromBookmarks", value: true)
        var workspaceSettings = SpeakSettings()
        workspaceSettings.playbackSettings.speed = 175
        workspaceSettings.sleepTimer = 12
        workspaceSettings.lastSleepTimer = 12
        service.reloadAfterBackupRestore(activeWorkspaceSettings: workspaceSettings)

        XCTAssertEqual(service.settings, workspaceSettings)
        XCTAssertEqual(
            service.advancedSettings,
            AdvancedSpeakSettings(
                autoBookmark: true,
                synchronize: false,
                replaceDivineName: true,
                restoreSettingsFromBookmarks: true
            )
        )
        XCTAssertEqual(
            synthesizer.spokenUtterances.map(\.speechString),
            ["Key.5|100|false", "Key.5|175|true"]
        )
    }

    /** Verifies bounded generic exhaustion stops cleanly without creating an Android Speak bookmark. */
    func testBoundedGenericCompletionClearsSessionWithoutAutoBookmark() throws {
        let synthesizer = FakeSpeechSynthesizer()
        let manager = SpeakParityBookmarkManager()
        let service = SpeakService(synthesizer: synthesizer)
        service.bookmarkManager = manager
        service.updateAdvancedSettings(AdvancedSpeakSettings(autoBookmark: true))
        let provider = DictionarySpeakTextProvider(
            positions: [makePosition(index: 3, category: .dictionary)],
            startIndex: 0,
            bounds: 0...0,
            advancedSettings: service.advancedSettings,
            loader: makeLoader()
        )
        var finishedCount = 0
        service.onFinishedSpeaking = { finishedCount += 1 }

        service.speak(provider: provider)
        let utterance = try XCTUnwrap(synthesizer.spokenUtterances.last)
        service.speechSynthesizer(AVSpeechSynthesizer(), didFinish: utterance)

        XCTAssertFalse(service.isSpeaking)
        XCTAssertFalse(service.isPaused)
        XCTAssertNil(service.activeProviderCategory)
        XCTAssertNil(service.currentPosition)
        XCTAssertTrue(manager.persisted.isEmpty)
        XCTAssertEqual(finishedCount, 1)
    }

    /** Verifies manual pause and timer expiry match Android sleep-timer persistence semantics. */
    func testSleepTimerPauseExpiryAndResumeUseConfiguredDuration() {
        let synthesizer = FakeSpeechSynthesizer()
        let scheduler = SpeakParityTimerScheduler()
        let service = SpeakService(synthesizer: synthesizer, timerScheduler: scheduler)
        service.setSleepTimer(minutes: 1)
        service.speak(text: "Timer text")

        XCTAssertEqual(service.sleepTimerRemaining, 60)
        scheduler.fire(times: 10)
        XCTAssertEqual(service.sleepTimerRemaining, 50)
        service.pause()
        XCTAssertNil(service.sleepTimerRemaining)
        XCTAssertEqual(service.settings.sleepTimer, 1)
        XCTAssertEqual(service.settings.lastSleepTimer, 1)

        service.resume()
        XCTAssertEqual(service.sleepTimerRemaining, 60)
        scheduler.fire(times: 60)
        XCTAssertTrue(service.isPaused)
        XCTAssertEqual(service.settings.sleepTimer, 0)
        XCTAssertEqual(service.settings.lastSleepTimer, 1)
        XCTAssertNil(service.sleepTimerRemaining)
        XCTAssertEqual(synthesizer.stopBoundaries.last, .immediate)
    }

    /**
     Verifies a callback queued by an invalidated timer cannot pause or mutate a replacement session.

     The controllable scheduler deliberately invokes the old closure after `SpeakService` replaces
     the provider. A failure means timer invalidation alone permits stale lifecycle work to affect the
     current provider, violating the same generation ownership enforced for speech callbacks.
     */
    func testStaleSleepTimerCallbackCannotAffectReplacementSession() {
        let synthesizer = FakeSpeechSynthesizer()
        let scheduler = SpeakParityTimerScheduler()
        let service = SpeakService(synthesizer: synthesizer, timerScheduler: scheduler)
        service.setSleepTimer(minutes: 1)
        service.speak(text: "First session")
        let firstTimer = scheduler.latestScheduleIndex

        service.speak(text: "Replacement session")
        XCTAssertEqual(service.sleepTimerRemaining, 60)
        XCTAssertFalse(service.isPaused)

        scheduler.fire(scheduleAt: firstTimer, times: 60, ignoringInvalidation: true)

        XCTAssertEqual(service.sleepTimerRemaining, 60)
        XCTAssertTrue(service.isSpeaking)
        XCTAssertFalse(service.isPaused)
        XCTAssertEqual(synthesizer.spokenUtterances.last?.speechString, "Replacement session")
    }

    /**
     Verifies Android `queue=true` appends complete semantic passages without replacing playback.

     The incoming queue deliberately repeats verse two. Draining the fake synthesizer proves titles,
     duplicate positions, and content remain ordered while the first session generation and callbacks
     continue to own playback.
     */
    func testPassageQueueAppendPreservesRemainderDuplicatesBoundariesAndOwnership() throws {
        let synthesizer = FakeSpeechSynthesizer()
        let service = SpeakService(synthesizer: synthesizer)
        let firstProvider = try makePassageProvider([
            ("Gen.1.1-Gen.1.2", "Genesis 1:1-2", [1, 2]),
        ])
        let appendedProvider = try makePassageProvider([
            ("Gen.1.2", "Genesis 1:2", [2]),
            ("Gen.1.3", "Genesis 1:3", [3]),
        ])
        var firstOwnedPositions: [String] = []
        var appendedCallbackCount = 0

        let firstResult = service.start(
            provider: firstProvider,
            callbacks: SpeakSessionCallbacks(onPositionChanged: { position, _ in
                firstOwnedPositions.append(position.key)
            })
        )
        let firstGeneration = try XCTUnwrap(firstResult.generation)
        let firstTitle = try XCTUnwrap(synthesizer.spokenUtterances.last)
        service.speechSynthesizer(AVSpeechSynthesizer(), didFinish: firstTitle)
        let firstBody = try XCTUnwrap(synthesizer.spokenUtterances.last)
        service.speechSynthesizer(AVSpeechSynthesizer(), didFinish: firstBody)
        let activeRemainderUtterance = try XCTUnwrap(synthesizer.spokenUtterances.last)
        let acceptedUtteranceCount = synthesizer.spokenUtterances.count

        XCTAssertEqual(service.currentPosition?.key, "Gen.1.2")

        let appendResult = service.start(
            provider: appendedProvider,
            callbacks: SpeakSessionCallbacks(onPositionChanged: { _, _ in
                appendedCallbackCount += 1
            }),
            queue: true
        )

        XCTAssertEqual(appendResult, .queued(generation: firstGeneration))
        XCTAssertEqual(service.currentSessionGeneration, firstGeneration)
        XCTAssertEqual(service.currentPosition?.key, "Gen.1.2")
        XCTAssertEqual(synthesizer.spokenUtterances.count, acceptedUtteranceCount)
        XCTAssertIdentical(synthesizer.spokenUtterances.last, activeRemainderUtterance)
        XCTAssertEqual(
            firstProvider.availablePositions.map(\.key),
            ["Gen.1.1", "Gen.1.2", "Gen.1.2", "Gen.1.3"]
        )
        XCTAssertEqual(Set(firstProvider.availablePositions.map(\.id)).count, 4)

        var finishedUtteranceIndex = acceptedUtteranceCount - 1
        while service.isSpeaking, finishedUtteranceIndex < 20 {
            guard synthesizer.spokenUtterances.indices.contains(finishedUtteranceIndex) else {
                return XCTFail("Speech stopped producing utterances before the appended queue exhausted")
            }
            let utterance = synthesizer.spokenUtterances[finishedUtteranceIndex]
            finishedUtteranceIndex += 1
            service.speechSynthesizer(AVSpeechSynthesizer(), didFinish: utterance)
        }

        XCTAssertFalse(service.isSpeaking)
        XCTAssertEqual(
            firstOwnedPositions,
            ["Gen.1.1", "Gen.1.2", "Gen.1.2", "Gen.1.3"]
        )
        XCTAssertEqual(appendedCallbackCount, 0)
        XCTAssertEqual(
            synthesizer.spokenUtterances.map(\.speechString),
            [
                "Genesis 1:1-2.", "Body Gen.1.1", "Body Gen.1.2",
                "Genesis 1:2.", "Body Gen.1.2",
                "Genesis 1:3.", "Body Gen.1.3",
            ]
        )
    }

    /**
     Verifies the typed start result is returned only after the first utterance is submitted.

     - Side effects: Starts one deterministic selection session against the fake synthesizer.
     - Failure modes: The assertion fails if startup reports success without an accepted utterance or
       returns a generation other than the active session owner.
     */
    func testTypedSpeechStartupAcknowledgesAcceptedFirstUtterance() throws {
        let synthesizer = FakeSpeechSynthesizer()
        let service = SpeakService(synthesizer: synthesizer)

        let result = service.start(
            provider: SelectionSpeakTextProvider(text: "Accepted first utterance", language: "en-US")
        )
        let generation = try XCTUnwrap(result.generation)

        XCTAssertEqual(result, .started(generation: generation))
        XCTAssertEqual(generation, service.currentSessionGeneration)
        XCTAssertEqual(synthesizer.spokenUtterances.map(\.speechString), ["Accepted first utterance"])
        XCTAssertNil(service.lastStartupFailure)
    }

    /** Verifies typed startup distinguishes preparation, empty content, and unavailable voice. */
    func testTypedSpeechStartupReportsEverySynchronousFailure() throws {
        var settings = SpeakSettings()
        settings.playbackSettings.verseRange = try XCTUnwrap(
            SpeakVerseRange(versification: "KJV", osisRef: "Gen.1.1-Gen.1.2")
        )
        let preparationService = SpeakService(synthesizer: FakeSpeechSynthesizer())
        preparationService.applySettings(settings, persist: false)
        let preparationProvider = BibleSpeakTextProvider(
            positions: [makeBiblePosition(verse: 1, versification: "KJV")],
            startIndex: 0,
            advancedSettings: AdvancedSpeakSettings(),
            verseRangeResolver: { _ in nil },
            loader: makeLoader()
        )
        XCTAssertEqual(
            preparationService.start(provider: preparationProvider),
            .failed(.preparationFailed)
        )
        XCTAssertFalse(preparationService.isSpeaking)
        XCTAssertEqual(preparationService.lastStartupFailure, .preparationFailed)
        XCTAssertNotNil(preparationService.currentTitle)

        let emptyService = SpeakService(synthesizer: FakeSpeechSynthesizer())
        let emptyProvider = IndexedSpeakTextProvider(
            category: .selection,
            positions: [makePosition(index: 1, category: .selection)],
            startIndex: 0,
            bounds: 0...0,
            canAutoBookmark: false,
            advancedSettings: AdvancedSpeakSettings(),
            loader: { _, _, _ in [.pause(milliseconds: 100)] }
        )
        XCTAssertEqual(emptyService.start(provider: emptyProvider), .failed(.noSpeakableContent))
        XCTAssertFalse(emptyService.isSpeaking)
        XCTAssertEqual(emptyService.lastStartupFailure, .noSpeakableContent)
        XCTAssertNotNil(emptyService.currentTitle)

        let voiceService = SpeakService(
            synthesizer: FakeSpeechSynthesizer(),
            voiceResolver: SpeakParityUnavailableVoiceResolver()
        )
        XCTAssertEqual(
            voiceService.start(provider: SelectionSpeakTextProvider(text: "Text", language: "zz")),
            .failed(.unsupportedLanguage("zz"))
        )
        XCTAssertEqual(voiceService.lastFailure, .unsupportedLanguage("zz"))
        XCTAssertEqual(voiceService.lastStartupFailure, .unsupportedLanguage("zz"))
        XCTAssertNotNil(voiceService.currentTitle)
        XCTAssertFalse(voiceService.isSpeaking)
    }

    /**
     Verifies pause persistence recreates a duplicate occurrence and resumes at its exact word.

     The first service reaches the repeated final Genesis verse and pauses at the final word. A new
     service must restore that duplicate occurrence, command, and raw UTF-16 progress without
     replaying earlier content or skipping the current word.
     */
    func testPassageCheckpointResumesExactCommandAndCharacterProgress() throws {
        let store = try makeInMemorySettingsStore()
        let firstSynthesizer = FakeSpeechSynthesizer()
        let first = SpeakService(synthesizer: firstSynthesizer)
        first.settingsStore = store
        let firstProvider = try makePassageProvider(
            [
                ("Gen.1.1", "Genesis 1:1", [1]),
                ("Gen.1.2", "Genesis 1:2", [2]),
                ("Gen.1.1", "Genesis 1:1", [1]),
            ],
            text: "First sentence. Second sentence."
        )

        XCTAssertTrue(first.start(provider: firstProvider).succeeded)
        for _ in 0..<5 {
            let utterance = try XCTUnwrap(firstSynthesizer.spokenUtterances.last)
            first.speechSynthesizer(AVSpeechSynthesizer(), didFinish: utterance)
        }
        let contentUtterance = try XCTUnwrap(firstSynthesizer.spokenUtterances.last)
        XCTAssertEqual(first.currentPosition?.key, "Gen.1.1")
        XCTAssertEqual(contentUtterance.speechString, "First sentence. Second sentence.")
        first.speechSynthesizer(
            AVSpeechSynthesizer(),
            willSpeakRangeOfSpeechString: NSRange(location: 23, length: 8),
            utterance: contentUtterance
        )
        first.pause()

        let checkpointJSON = try XCTUnwrap(store.getString("SpeakProviderCheckpoint"))
        let checkpoint = try JSONDecoder().decode(
            SpeakProviderCheckpoint.self,
            from: Data(checkpointJSON.utf8)
        )
        XCTAssertEqual(checkpoint.version, 2)
        XCTAssertEqual(checkpoint.orderedPassages?.map { $0.positions.map(\.key) }, [
            ["Gen.1.1"], ["Gen.1.2"], ["Gen.1.1"],
        ])
        XCTAssertEqual(checkpoint.currentPassageIndex, 2)
        XCTAssertEqual(checkpoint.currentPositionIndexInPassage, 0)
        XCTAssertEqual(checkpoint.playbackCursor?.commandIndex, 1)
        XCTAssertEqual(checkpoint.playbackCursor?.characterOffset, 23)
        XCTAssertEqual(checkpoint.playbackCursor?.commandTextLength, 32)
        XCTAssertEqual(checkpoint.playbackCursor?.characterFraction, 23.0 / 32.0)

        let secondSynthesizer = FakeSpeechSynthesizer()
        let second = SpeakService(synthesizer: secondSynthesizer)
        second.settingsStore = store
        second.onRequestSessionReconstruction = { restoredCheckpoint in
            guard let passageIndex = restoredCheckpoint.currentPassageIndex,
                  let positionIndex = restoredCheckpoint.currentPositionIndexInPassage,
                  let provider = try? self.makePassageProvider(
                      [
                          ("Gen.1.1", "Genesis 1:1", [1]),
                          ("Gen.1.2", "Genesis 1:2", [2]),
                          ("Gen.1.1", "Genesis 1:1", [1]),
                      ],
                      startPassageIndex: passageIndex,
                      startPositionIndexInPassage: positionIndex,
                      resumePlaybackCursor: restoredCheckpoint.playbackCursor,
                      text: "First sentence. Second sentence."
                  ) else {
                return nil
            }
            return SpeakSessionReconstruction(provider: provider)
        }
        second.restoreSettings()
        XCTAssertTrue(second.isPaused)
        second.resume()

        XCTAssertEqual(second.currentPosition?.key, "Gen.1.1")
        XCTAssertEqual(secondSynthesizer.spokenUtterances.last?.speechString, "sentence.")
        XCTAssertFalse(second.isPaused)
    }

    /**
     Verifies adjacent original ranges retain an independent title/content/separator sequence.

     - Side effects: Materializes two deterministic one-verse passage units.
     - Failure modes: The assertion fails if same-chapter adjacency merges a boundary, repeats a
       title, moves the title after content, or omits the terminal Android separator pause.
     */
    func testPassageBoundariesEmitExactCommandOrderForAdjacentSameChapterRanges() throws {
        let provider = try makePassageProvider([
            ("Gen.1.1", "Genesis 1:1", [1]),
            ("Gen.1.2", "Genesis 1:2", [2]),
        ])
        let settings = SpeakSettings()

        XCTAssertEqual(
            provider.currentUnit(settings: settings)?.commands,
            [
                .announcement("Genesis 1:1."),
                .text("Body Gen.1.1"),
                .pause(milliseconds: 500),
            ]
        )
        XCTAssertTrue(provider.advance(settings: settings))
        XCTAssertEqual(
            provider.currentUnit(settings: settings)?.commands,
            [
                .announcement("Genesis 1:2."),
                .text("Body Gen.1.2"),
                .pause(milliseconds: 500),
            ]
        )
    }

    /** Verifies bounded passage queues hide and reject repeated-range mutation at the service layer. */
    func testPassageProviderDisablesVerseRangeEditingAndServiceMutation() throws {
        let service = SpeakService(synthesizer: FakeSpeechSynthesizer())
        var settings = SpeakSettings()
        settings.playbackSettings.verseRange = try XCTUnwrap(
            SpeakVerseRange(versification: "KJV", osisRef: "Rev.22.21")
        )
        service.applySettings(settings, persist: false)
        let provider = try makePassageProvider([
            ("Gen.1.1-Gen.1.2", "Genesis 1:1-2", [1, 2]),
        ])
        XCTAssertTrue(service.start(provider: provider).succeeded)
        XCTAssertFalse(provider.supportsVerseRangeEditing)
        XCTAssertFalse(service.supportsVerseRangeEditing)
        XCTAssertFalse(service.setVerseRange(start: nil, end: nil))
        XCTAssertFalse(
            service.setVerseRange(
                start: provider.availablePositions[0],
                end: provider.availablePositions[1]
            )
        )
        XCTAssertEqual(
            service.settings.playbackSettings.verseRange,
            settings.playbackSettings.verseRange
        )

        let ordinary = BibleSpeakTextProvider(
            positions: (1...2).map { makeBiblePosition(verse: $0, versification: "KJV") },
            startIndex: 0,
            advancedSettings: AdvancedSpeakSettings(),
            verseRangeResolver: { _ in 0...1 },
            loader: makeLoader()
        )
        XCTAssertTrue(ordinary.supportsVerseRangeEditing)
    }

    /** Verifies iOS-authored bookmark snapshots synthesize the complete Android playback payload. */
    func testBookmarkSnapshotSynthesizesCompleteStructuredPlaybackSettings() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let context = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: context)
        let trust = PersistedOrdinalTrustPolicy.androidImportMetadata(
            sourceVersification: "KJV",
            sourceOrdinalStart: 4,
            sourceOrdinalEnd: 4,
            kjvaOrdinalStart: 4,
            kjvaOrdinalEnd: 4
        )
        let bookmark = BibleBookmark(
            kjvOrdinalStart: 4,
            kjvOrdinalEnd: 4,
            ordinalStart: 4,
            ordinalEnd: 4,
            v11n: "KJV",
            bookInitials: "KJV",
            ordinalTrustMetadata: trust
        )
        bookmark.playbackSettings = PlaybackSettings(
            speakChapterChanges: false,
            speakTitles: false,
            speakFootnotes: true,
            speed: 155,
            bookId: "KJV",
            bookmarkWasCreated: true,
            verseRange: SpeakVerseRange(versification: "KJV", osisRef: "Gen.1.1")
        )
        context.insert(bookmark)
        try context.save()

        let snapshot = RemoteSyncBookmarkSnapshotService().snapshotCurrentState(
            modelContext: context,
            settingsStore: settingsStore
        )
        let row = try XCTUnwrap(snapshot.bibleBookmarkRowsByKey.values.first)
        let json = try XCTUnwrap(row.playbackSettingsJSON)
        let decoded = PlaybackSettings.fromAndroidJSON(json)
        XCTAssertEqual(decoded, bookmark.playbackSettings)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), [
            "speakChapterChanges", "speakTitles", "speakFootnotes", "speed", "bookId",
            "bookmarkWasCreated", "verseRange",
        ])
    }

    /** Verifies persisted Bible Speak rows retain the source canon required by strict resume. */
    func testBibleSpeakResumeBookmarkCarriesPersistedSourceVersification() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let context = ModelContext(container)
        let service = BookmarkService(store: BookmarkStore(modelContext: context))
        let verifiedRange = try XCTUnwrap(
            VerifiedKJVAOrdinalRange(
                resolvingSourceBookInitials: "KJV",
                sourceVersification: "KJV",
                sourceOrdinalStart: 4,
                sourceOrdinalEnd: 4
            )
        )
        let position = SpeakStreamPosition(
            id: "KJV:KJV:4",
            category: .bible,
            bookInitials: "KJV",
            key: "Gen.1.1",
            osisRef: "Gen.1.1",
            keyName: "Genesis 1:1",
            bookName: "Genesis",
            ordinalStart: 4,
            ordinalEnd: 4,
            chapter: 1,
            verse: 1,
            groupIdentifier: "Gen.1",
            language: "en",
            versification: "KJV",
            verifiedBibleRange: verifiedRange
        )

        service.persistSpeakBookmark(
            at: position,
            settings: PlaybackSettings(bookId: "KJV"),
            autoBookmark: true
        )

        let resumed = try XCTUnwrap(service.speakResumeBookmarks().first)
        XCTAssertEqual(resumed.position.bookInitials, "KJV")
        XCTAssertEqual(resumed.position.ordinalStart, 4)
        XCTAssertEqual(resumed.position.versification, "KJV")
    }

    /** Verifies stopped settings find only the visible Bible bookmark and normalize verse zero. */
    func testStoppedBibleSettingsUpdateFindsVisibleSpeakBookmarkWithoutActiveSession() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let context = ModelContext(container)
        let writer = BookmarkService(store: BookmarkStore(modelContext: context))
        let verseOneRange = try XCTUnwrap(
            VerifiedKJVAOrdinalRange(
                resolvingSourceBookInitials: "KJV",
                sourceVersification: "KJV",
                sourceOrdinalStart: 4,
                sourceOrdinalEnd: 4
            )
        )
        let verseOne = SpeakStreamPosition(
            id: "KJV:KJV:4",
            category: .bible,
            bookInitials: "KJV",
            key: "Gen.1.1",
            osisRef: "Gen.1.1",
            keyName: "Genesis 1:1",
            bookName: "Genesis",
            ordinalStart: 4,
            ordinalEnd: 4,
            chapter: 1,
            verse: 1,
            groupIdentifier: "Gen.1",
            language: "en",
            versification: "KJV",
            verifiedBibleRange: verseOneRange
        )
        writer.persistSpeakBookmark(
            at: verseOne,
            settings: PlaybackSettings(speed: 120, bookId: "KJV", bookmarkWasCreated: true),
            autoBookmark: true
        )

        let stoppedManager = BookmarkService(store: BookmarkStore(modelContext: context))
        let chapterIntroductionRange = try XCTUnwrap(
            VerifiedKJVAOrdinalRange(
                resolvingSourceBookInitials: "KJV",
                sourceVersification: "KJV",
                sourceOrdinalStart: 3,
                sourceOrdinalEnd: 3
            )
        )
        let chapterIntroduction = SpeakStreamPosition(
            id: "KJV:KJV:3",
            category: .bible,
            bookInitials: "KJV",
            key: "Gen.1.0",
            osisRef: "Gen.1.0",
            keyName: "Genesis 1",
            bookName: "Genesis",
            ordinalStart: 3,
            ordinalEnd: 3,
            chapter: 1,
            verse: 0,
            groupIdentifier: "Gen.1",
            language: "en",
            versification: "KJV",
            verifiedBibleRange: chapterIntroductionRange
        )
        stoppedManager.updateSpeakBookmarkPlaybackSettings(
            at: chapterIntroduction,
            settings: PlaybackSettings(speakTitles: false, speed: 155)
        )

        let bookmark = try XCTUnwrap(context.fetch(FetchDescriptor<BibleBookmark>()).first)
        XCTAssertEqual(bookmark.playbackSettings?.speed, 155)
        XCTAssertEqual(bookmark.playbackSettings?.speakTitles, false)
        XCTAssertEqual(bookmark.playbackSettings?.bookId, "KJV")
        XCTAssertEqual(bookmark.playbackSettings?.bookmarkWasCreated, true)
    }

    /** Creates deterministic provider metadata for category and transport tests. */
    private func makePosition(index: Int, category: SpeakDocumentCategory) -> SpeakStreamPosition {
        SpeakStreamPosition(
            id: "\(category.rawValue)-\(index)",
            category: category,
            bookInitials: "TEST",
            key: "Key.\(index)",
            keyName: "Key.\(index)",
            bookName: "Test Book",
            ordinalStart: index,
            ordinalEnd: index,
            groupIdentifier: "Group.\(index / 3)",
            language: "en"
        )
    }

    /** Creates one exact Bible source position with OSIS and versification identity. */
    private func makeBiblePosition(verse: Int, versification: String) -> SpeakStreamPosition {
        SpeakStreamPosition(
            id: "KJV:Gen.1.\(verse)",
            category: .bible,
            bookInitials: "KJV",
            key: "Gen.1.\(verse)",
            osisRef: "Gen.1.\(verse)",
            keyName: "Genesis 1:\(verse)",
            bookName: "Genesis",
            ordinalStart: verse,
            ordinalEnd: verse,
            chapter: 1,
            verse: verse,
            groupIdentifier: "Gen.1",
            language: "en",
            versification: versification
        )
    }

    /** Creates one exact local-ordinal position inside a generic document key. */
    private func makeGenericPosition(
        key: String,
        ordinal: Int,
        category: SpeakDocumentCategory
    ) -> SpeakStreamPosition {
        SpeakStreamPosition(
            id: "TEST:\(key):\(ordinal)",
            category: category,
            bookInitials: "TEST",
            key: key,
            keyName: key,
            bookName: "Test Book",
            ordinalStart: ordinal,
            ordinalEnd: ordinal,
            groupIdentifier: key,
            language: "en"
        )
    }

    /** Reconstructs an exact generic provider from a persisted checkpoint for lifecycle tests. */
    private func genericProvider(
        reconstructing checkpoint: SpeakProviderCheckpoint,
        positions: [SpeakStreamPosition]
    ) -> SpeakTextProviding? {
        guard let startIndex = positions.firstIndex(where: checkpoint.current.matches),
              let lowerIndex = positions.firstIndex(where: checkpoint.lowerBound.matches),
              let upperIndex = positions.firstIndex(where: checkpoint.upperBound.matches),
              lowerIndex <= startIndex,
              startIndex <= upperIndex else {
            return nil
        }
        let bounds = checkpoint.isBounded ? lowerIndex...upperIndex : nil
        switch checkpoint.current.category {
        case .dictionary:
            return DictionarySpeakTextProvider(
                positions: positions,
                startIndex: startIndex,
                bounds: bounds,
                advancedSettings: AdvancedSpeakSettings(),
                loader: makeLoader()
            )
        case .generalBook:
            return GeneralBookSpeakTextProvider(
                positions: positions,
                startIndex: startIndex,
                bounds: bounds,
                advancedSettings: AdvancedSpeakSettings(),
                loader: makeLoader()
            )
        default:
            return nil
        }
    }

    /** Locates the checked-in KJV SWORD fixture without depending on process working directory. */
    private func repositorySwordFixturePath() throws -> String {
        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while candidate.path != "/" {
            let packageURL = candidate.appendingPathComponent("Package.swift", isDirectory: false)
            if FileManager.default.fileExists(atPath: packageURL.path) {
                return candidate
                    .appendingPathComponent("Sources/BibleUI/Tests/BibleUITests/Fixtures/sword", isDirectory: true)
                    .path
            }
            candidate.deleteLastPathComponent()
        }
        throw NSError(
            domain: "SpeakParityTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate the repository SWORD fixture."]
        )
    }

    /** Creates a loader whose utterance text exposes the provider's exact current key. */
    private func makeLoader() -> SpeakStreamUnitLoader {
        { position, _, _ in [.text(position.key)] }
    }

    /**
     Creates a deterministic semantic passage provider without SWORD I/O.

     - Parameters describe original OSIS boundaries, titles, exact verse occurrences, optional resume
       indexes/cursor, and body text.
     - Returns: A bounded provider whose per-passage loader exposes deterministic command content.
     - Side effects: None.
     - Failure modes: Throws when a test supplies an invalid range or empty semantic segment.
     */
    private func makePassageProvider(
        _ definitions: [(osisRef: String, title: String, verses: [Int])],
        startPassageIndex: Int = 0,
        startPositionIndexInPassage: Int = 0,
        resumePlaybackCursor: SpeakPlaybackCursor? = nil,
        text: String? = nil
    ) throws -> BiblePassageListSpeakTextProvider {
        let passages = try definitions.map { definition -> SpeakPassageSegment in
            let range = try XCTUnwrap(
                SpeakVerseRange(versification: "KJV", osisRef: definition.osisRef)
            )
            let positions = definition.verses.map {
                makeBiblePosition(verse: $0, versification: "KJV")
            }
            guard !positions.isEmpty else {
                throw NSError(
                    domain: "SpeakParityTests",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Passage fixtures must not be empty."]
                )
            }
            return SpeakPassageSegment(
                sourceRange: range,
                title: definition.title,
                positions: positions
            )
        }
        let loaders = passages.map { _ in
            { position, _, _ in
                [.text(text ?? "Body \(position.key)")]
            } as SpeakStreamUnitLoader
        }
        return BiblePassageListSpeakTextProvider(
            passages: passages,
            loaders: loaders,
            startPassageIndex: startPassageIndex,
            startPositionIndexInPassage: startPositionIndexInPassage,
            resumePlaybackCursor: resumePlaybackCursor,
            advancedSettings: AdvancedSpeakSettings()
        )
    }
}

/** Voice resolver that deterministically models an unavailable requested language. */
private struct SpeakParityUnavailableVoiceResolver: SpeechVoiceResolving {
    /** Returns no voice without consulting mutable platform voice installation state. */
    func resolveVoice(
        for requestedLanguage: String,
        deviceLocale: Locale
    ) -> AVSpeechSynthesisVoice? {
        _ = requestedLanguage
        _ = deviceLocale
        return nil
    }
}

/**
 Lazy two-key generic source used to verify Android `BookAndKey` traversal.

 The fixture records first-load order while returning immutable exact-ordinal content. It performs
 no I/O and intentionally keeps both keys discontiguous so tests detect accidental global-index or
 page-index substitution.
 */
private final class GenericSpeakSourceFixture: @unchecked Sendable {
    private(set) var loadedKeys: [String] = []
    let category: SpeakDocumentCategory

    /** Creates a fixture for one concrete generic category. */
    init(category: SpeakDocumentCategory) {
        self.category = category
    }

    /** Builds the lazy production source while retaining load observations on this fixture. */
    var source: GenericSpeakOrdinalSource {
        GenericSpeakOrdinalSource(
            category: category,
            bookInitials: "GENERIC",
            bookName: "Generic source",
            language: "en",
            keys: ["Alpha", "Beta"],
            loadContent: { [weak self] key in self?.load(key) }
        )
    }

    /** Records and returns one exact key payload; unknown keys fail closed. */
    private func load(_ key: String) -> GenericSpeakKeyContent? {
        loadedKeys.append(key)
        switch key {
        case "Alpha":
            return GenericSpeakKeyContent(
                key: key,
                keyName: "Alpha",
                ordinalRange: 3...4,
                commandsByOrdinal: [3: [.heading("Alpha title")], 4: [.text("Alpha 4")]]
            )
        case "Beta":
            return GenericSpeakKeyContent(
                key: key,
                keyName: "Beta",
                ordinalRange: 10...11,
                commandsByOrdinal: [10: [.text("Beta 10")], 11: [.text("Beta 11")]]
            )
        default:
            return nil
        }
    }
}

/** Deterministic repeating-timer token used by speech sleep-timer tests. */
private final class SpeakParityTimerToken: SpeakTimerToken {
    private(set) var isInvalidated = false

    /** Marks the scheduled callback inactive. */
    func invalidate() {
        isInvalidated = true
    }
}

/** Controllable repeating scheduler that advances only when a test calls `fire(times:)`. */
private final class SpeakParityTimerScheduler: SpeakTimerScheduling {
    private struct Scheduled {
        let token: SpeakParityTimerToken
        let action: () -> Void
    }

    private var scheduled: [Scheduled] = []

    /// Index of the most recently registered callback for stale-callback simulations.
    var latestScheduleIndex: Int { scheduled.index(before: scheduled.endIndex) }

    /** Records a repeating callback and returns its independently invalidatable token. */
    func scheduleRepeating(every interval: TimeInterval, _ action: @escaping () -> Void) -> SpeakTimerToken {
        XCTAssertEqual(interval, 1)
        let token = SpeakParityTimerToken()
        scheduled.append(Scheduled(token: token, action: action))
        return token
    }

    /** Executes the most recently active timer callback a deterministic number of times. */
    func fire(times: Int) {
        for _ in 0..<times {
            guard let item = scheduled.last(where: { !$0.token.isInvalidated }) else { return }
            item.action()
        }
    }

    /** Invokes one exact registered callback, optionally simulating delivery after invalidation. */
    func fire(scheduleAt index: Int, times: Int, ignoringInvalidation: Bool) {
        guard scheduled.indices.contains(index) else { return }
        let item = scheduled[index]
        for _ in 0..<times {
            guard ignoringInvalidation || !item.token.isInvalidated else { return }
            item.action()
        }
    }
}

/** In-memory Speak-bookmark boundary used to inspect service persistence decisions. */
private final class SpeakParityBookmarkManager: SpeakBookmarkManaging {
    struct Persisted {
        let position: SpeakStreamPosition
        let settings: PlaybackSettings
        let autoBookmark: Bool
    }

    struct Updated {
        let position: SpeakStreamPosition
        let settings: PlaybackSettings
    }

    var restoredSettings: PlaybackSettings?
    var updated: [Updated] = []
    var persisted: [Persisted] = []
    var bookmarks: [SpeakResumeBookmark] = []

    /** Returns the test's configured restored playback value. */
    func playbackSettingsForSpeakBookmark(at position: SpeakStreamPosition) -> PlaybackSettings? {
        _ = position
        return restoredSettings
    }

    /** Records a structured settings update applied to an active Speak bookmark. */
    func updateSpeakBookmarkPlaybackSettings(at position: SpeakStreamPosition, settings: PlaybackSettings) {
        updated.append(Updated(position: position, settings: settings))
    }

    /** Records one pause/stop persistence request with its exact provider identity. */
    func persistSpeakBookmark(
        at position: SpeakStreamPosition,
        settings: PlaybackSettings,
        autoBookmark: Bool
    ) {
        persisted.append(Persisted(position: position, settings: settings, autoBookmark: autoBookmark))
    }

    /** Returns deterministic resume-picker rows. */
    func speakResumeBookmarks() -> [SpeakResumeBookmark] {
        bookmarks
    }
}
