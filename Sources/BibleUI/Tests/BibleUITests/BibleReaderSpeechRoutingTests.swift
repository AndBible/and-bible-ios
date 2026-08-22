import AVFoundation
import BibleView
import Foundation
import SwiftData
import SwordKit
import XCTest
@testable import BibleCore
@testable import BibleUI

/** End-to-end contracts for reader entry-point routing into typed Android speech providers. */
final class BibleReaderSpeechRoutingTests: BibleUISwordFixtureTestCase {
    /**
     Verifies explicit Bible identity, fail-closed missing modules, and bounded memorization repeat.

     The second module shares fixture data deliberately: the assertion is about module identity and
     source-versification routing, not textual differences between translations.
     */
    @MainActor
    func testExplicitBibleAndMemorizationBridgePreserveRequestedSourceAndBounds() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedBibleAlias(named: "RequestedBible", in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let requestedModule = try XCTUnwrap(manager.module(named: "RequestedBible"))
        let start = try XCTUnwrap(
            requestedModule.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1)
        )
        let end = try XCTUnwrap(
            requestedModule.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 2)
        )
        let controller = BibleReaderController(bridge: BibleBridge(), swordManagerOverride: manager)
        let service = makeSpeechService()
        controller.speakService = service

        controller.bridge(
            controller.bridge,
            speak: "RequestedBible",
            v11n: "KJV",
            startOrdinal: start,
            endOrdinal: end
        )

        XCTAssertEqual(service.activeProviderCategory, .bible)
        XCTAssertEqual(service.currentPosition?.bookInitials, "RequestedBible")
        XCTAssertEqual(service.currentPosition?.versification, "KJV")
        XCTAssertEqual(service.currentPosition?.osisRef, "Gen.1.1")
        let bibleGeneration = service.currentSessionGeneration
        service.nextUnit()
        service.nextUnit()
        XCTAssertEqual(service.currentPosition?.osisRef, "Gen.1.3")

        controller.bridge(
            controller.bridge,
            speak: "MissingBible",
            v11n: "KJV",
            startOrdinal: start,
            endOrdinal: end
        )
        XCTAssertEqual(service.currentSessionGeneration, bibleGeneration)
        XCTAssertEqual(service.currentPosition?.bookInitials, "RequestedBible")

        let resumePosition = SpeakStreamPosition(
            id: "RequestedBible:Gen.1.2",
            category: .bible,
            bookInitials: "RequestedBible",
            key: "Gen.1.2",
            osisRef: "Gen.1.2",
            keyName: "Genesis 1:2",
            bookName: "Genesis",
            ordinalStart: end,
            ordinalEnd: end,
            chapter: 1,
            verse: 2,
            groupIdentifier: "Gen.1",
            language: "en-US",
            versification: "KJV"
        )
        controller.resumeSpeech(
            from: SpeakResumeBookmark(
                id: UUID(),
                position: resumePosition,
                playbackSettings: PlaybackSettings()
            )
        )
        XCTAssertEqual(service.currentPosition?.bookInitials, "RequestedBible")
        XCTAssertEqual(service.currentPosition?.osisRef, "Gen.1.2")

        controller.bridge(
            controller.bridge,
            speakMemorizationLoop: "RequestedBible",
            v11n: "KJV",
            startOrdinal: start,
            endOrdinal: end
        )
        XCTAssertEqual(service.activeProviderCategory, .memorization)
        XCTAssertEqual(service.currentPosition?.osisRef, "Gen.1.1")
        service.nextUnit()
        XCTAssertEqual(service.currentPosition?.osisRef, "Gen.1.2")
        service.nextUnit()
        XCTAssertEqual(service.currentPosition?.osisRef, "Gen.1.2")
    }

    /**
     Rejects a persisted Bible speech checkpoint when its source becomes locked before restore.

     - Setup: Builds a real readable provider/checkpoint, then marks the same installed alias locked
       and reconstructs through a fresh manager and reader controller.
     - Expected result: Readable resolution succeeds before relock; both the shared source resolver
       and controller reconstruction fail closed afterward without borrowing active KJV content.
     - Failure meaning: Remote Play or paused-session restore can enumerate and speak a cached native
       handle after the source's content authorization has been revoked.
     - Side effects: Rewrites only an inherited temporary fixture descriptor.
     */
    @MainActor
    func testPersistedBibleSpeechCheckpointFailsAfterSourceRelock() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let moduleName = "SpeechRelock"
        try seedBibleAliasModule(
            named: moduleName,
            description: "Speech relock Bible",
            in: modulePath
        )
        let readableManager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let readableModule = try XCTUnwrap(readableManager.readableModule(named: moduleName))
        let ordinal = try XCTUnwrap(readableModule.verseOrdinal(
            osisBookId: "Gen",
            chapter: 1,
            verse: 1
        ))
        let build = try BibleReaderSpeechProviderFactory.bible(
            request: SpeakSelectionRequest(
                category: .bible,
                bookInitials: moduleName,
                key: "Gen.1.1",
                startOrdinal: ordinal,
                endOrdinal: ordinal,
                versification: "KJV"
            ),
            manager: readableManager,
            displaySettings: TextDisplaySettings(),
            advancedSettings: AdvancedSpeakSettings()
        )
        let checkpoint = try XCTUnwrap(build.provider.checkpoint())
        XCTAssertEqual(
            try BibleSpeakSourceResolver.resolve(
                checkpoint: checkpoint,
                manager: readableManager
            ).module.info.name,
            moduleName
        )

        let configURL = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mods.d/\(moduleName.lowercased()).conf")
        var configuration = try String(contentsOf: configURL, encoding: .utf8)
        configuration.append("\nCipherKey=\n")
        try configuration.write(to: configURL, atomically: true, encoding: .utf8)
        let moduleCacheURL = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mods.d/modules-conf.cache")
        if FileManager.default.fileExists(atPath: moduleCacheURL.path) {
            try FileManager.default.removeItem(at: moduleCacheURL)
        }
        let lockedManager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        XCTAssertNil(lockedManager.readableModule(named: moduleName))
        XCTAssertThrowsError(try BibleSpeakSourceResolver.resolve(
            checkpoint: checkpoint,
            manager: lockedManager
        )) { error in
            XCTAssertEqual(
                error as? BibleSpeakSourceResolutionError,
                .moduleUnavailable(moduleName)
            )
        }

        let controller = BibleReaderController(
            bridge: BibleBridge(),
            swordManagerOverride: lockedManager
        )
        XCTAssertNil(controller.reconstructSpeechSession(
            from: checkpoint,
            service: makeSpeechService()
        ))
    }

    /** Verifies typed native selection routing, atomic metadata, and stale-session rejection. */
    @MainActor
    func testNativeSelectionRoutesMyDocumentAndRejectsPartialOrStaleIdentity() throws {
        let container = try makeMyDocumentModelContainer()
        let context = ModelContext(container)
        let document = MyDocument(name: "Notes", initials: "MyNotes")
        let page = MyDocumentPage(title: "Page", pageKey: "page", contentType: .markdown)
        let content = MyDocumentPageContent(pageId: page.id, content: "Selected source text")
        page.pageContent = content
        page.document = document
        document.pages = [page]
        context.insert(document)
        context.insert(page)
        context.insert(content)
        try context.save()

        let controller = BibleReaderController(bridge: BibleBridge(), initializesSword: false)
        controller.myDocumentStore = MyDocumentStore(modelContext: context)
        let service = makeSpeechService()
        controller.speakService = service
        let selection = BibleReaderSpeechSelection(
            text: "Selected source text",
            bookInitials: "MyNotes",
            osisRef: "page",
            bookCategory: DocumentCategory.generalBook.rawValue,
            versification: nil,
            startOrdinal: 0,
            endOrdinal: 0,
            startOffset: 0,
            endOffset: 20
        )

        XCTAssertTrue(
            controller.startSpeech(
                for: selection,
                expectedSessionGeneration: service.currentSessionGeneration,
                service: service
            )
        )
        XCTAssertEqual(service.activeProviderCategory, .myDocument)
        XCTAssertEqual(service.currentPosition?.bookInitials, "MyNotes")
        XCTAssertEqual(service.currentPosition?.key, "page")
        XCTAssertEqual(service.currentPosition?.ordinalStart, 0)

        let activeGeneration = service.currentSessionGeneration
        let partial = BibleReaderSpeechSelection(
            text: "Selected source text",
            bookInitials: "MyNotes",
            osisRef: "page",
            bookCategory: nil,
            versification: nil,
            startOrdinal: 0,
            endOrdinal: 0,
            startOffset: 0,
            endOffset: 20
        )
        XCTAssertFalse(
            controller.startSpeech(
                for: partial,
                expectedSessionGeneration: activeGeneration,
                service: service
            )
        )
        XCTAssertEqual(service.currentSessionGeneration, activeGeneration)
        XCTAssertEqual(service.activeProviderCategory, .myDocument)

        service.speak(text: "Newer request")
        XCTAssertFalse(
            controller.startSpeech(
                for: selection,
                expectedSessionGeneration: activeGeneration,
                service: service
            )
        )
        XCTAssertEqual(service.activeProviderCategory, .selection)
    }

    /** Verifies stopped Play starts at the visible verse and callbacks reconstruct exact checkpoints. */
    func testSessionBindingUsesVisibleVerseAndExactCheckpointSource() throws {
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let controller = BibleReaderController(bridge: BibleBridge(), swordManagerOverride: manager)
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 2)
        let service = makeSpeechService()
        controller.speakService = service
        BibleReaderSpeechSessionBinding.install(on: service) { controller }

        service.play()

        XCTAssertEqual(service.activeProviderCategory, .bible)
        XCTAssertEqual(service.currentPosition?.bookInitials, "KJV")
        XCTAssertEqual(service.currentPosition?.osisRef, "Gen.1.2")
        let checkpoint = try XCTUnwrap(
            controller.defaultSpeechSession(service: service)?.provider.checkpoint()
        )
        let reconstruction = try XCTUnwrap(
            service.onRequestSessionReconstruction?(checkpoint)
        )
        XCTAssertEqual(reconstruction.provider.checkpoint(), checkpoint)
        XCTAssertEqual(reconstruction.provider.currentPosition?.osisRef, "Gen.1.2")

        service.stop()
        XCTAssertEqual(
            service.onRequestStoppedBibleBookmarkPosition?()?.osisRef,
            "Gen.1.2"
        )

        let missingCursor = SpeakStreamCursor(
            category: .bible,
            bookInitials: "MissingBible",
            key: "Gen.1.2",
            ordinalStart: checkpoint.current.ordinalStart,
            ordinalEnd: checkpoint.current.ordinalEnd,
            versification: "KJV"
        )
        let missingCheckpoint = SpeakProviderCheckpoint(
            current: missingCursor,
            lowerBound: missingCursor,
            upperBound: missingCursor,
            isBounded: false,
            isMemorizationLoop: false
        )
        XCTAssertNil(service.onRequestSessionReconstruction?(missingCheckpoint))
    }

    /**
     Verifies the production callback-after-restore order reconstructs a persisted paused session.

     The reader shell assigns its settings store and restores process state before installing the
     active-controller binding. `SpeakService` must retain the unresolved checkpoint and retry it
     when the reconstruction callback is assigned; a failure means cold-launch pause/resume depends
     incorrectly on setup order. The in-memory settings store has no external side effects.
     */
    func testSessionBindingReconstructsCheckpointWhenInstalledAfterRestore() throws {
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let controller = BibleReaderController(bridge: BibleBridge(), swordManagerOverride: manager)
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 2)
        let sourceService = makeSpeechService()
        controller.speakService = sourceService
        let checkpoint = try XCTUnwrap(
            controller.defaultSpeechSession(service: sourceService)?.provider.checkpoint()
        )
        let checkpointData = try JSONEncoder().encode(checkpoint)
        let store = try makeInMemorySettingsStore()
        store.setString(
            "SpeakProviderCheckpoint",
            value: try XCTUnwrap(String(data: checkpointData, encoding: .utf8))
        )

        let restoredService = makeSpeechService()
        controller.speakService = restoredService
        restoredService.settingsStore = store
        restoredService.restoreSettings()
        XCTAssertFalse(restoredService.isSpeaking)

        BibleReaderSpeechSessionBinding.install(on: restoredService) { controller }

        XCTAssertTrue(restoredService.isSpeaking)
        XCTAssertTrue(restoredService.isPaused)
        XCTAssertEqual(restoredService.activeProviderCategory, .bible)
        XCTAssertEqual(restoredService.currentPosition?.bookInitials, "KJV")
        XCTAssertEqual(restoredService.currentPosition?.osisRef, "Gen.1.2")
        XCTAssertEqual(restoredService.currentPosition?.ordinalStart, checkpoint.current.ordinalStart)
    }

    /** Verifies page-level Bible Speak clears a saved repeat range that excludes the visible verse. */
    @MainActor
    func testPageSpeakOutsideRepeatRangeStartsVisibleVerseAndClearsRange() throws {
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let controller = BibleReaderController(bridge: BibleBridge(), swordManagerOverride: manager)
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 1)
        let service = makeSpeechService()
        var settings = SpeakSettings()
        settings.playbackSettings.verseRange = try XCTUnwrap(
            SpeakVerseRange(versification: "KJV", osisRef: "Gen.1.2-Gen.1.3")
        )
        service.applySettings(settings, persist: false)
        controller.speakService = service

        controller.speakCurrentChapter()

        XCTAssertEqual(service.currentPosition?.osisRef, "Gen.1.1")
        XCTAssertNil(service.settings.playbackSettings.verseRange)
        XCTAssertEqual(service.activeProviderCategory, .bible)
    }

    /**
     Verifies the coordinator's selected-range entry point is bounded by the supplied end ordinal.

     The third verse is addressable in the fixture but must never enter the provider queue. This
     protects selection speech from silently widening into ordinary unbounded chapter playback.
     */
    func testVerseRangeEntryPointHonorsEndOrdinalWithoutChapterWidening() throws {
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let start = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1))
        let end = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 2))
        let service = SpeakService(synthesizer: ReaderSpeechSynthesizer())

        BibleReaderSpeechCoordinator().speakVerseRange(
            startOrdinal: start,
            endOrdinal: end,
            service: service,
            context: makeBibleSpeechContext(manager: manager, module: module)
        )

        XCTAssertEqual(service.availableBiblePositions.map(\.osisRef), ["Gen.1.1", "Gen.1.2"])
        XCTAssertEqual(service.currentPosition?.osisRef, "Gen.1.1")
        service.nextUnit()
        XCTAssertEqual(service.currentPosition?.osisRef, "Gen.1.2")
        service.nextUnit()
        XCTAssertEqual(service.currentPosition?.osisRef, "Gen.1.2")
    }

    /**
     Verifies repeated Daily Reading requests append exact passage ranges in caller order.

     The second request crosses books and repeats Genesis 1:2. Android's `queue=true` behavior keeps
     the active generation and first utterance while preserving both the duplicate and every passage
     boundary in the appended queue.
     */
    func testDailyReadingPassageListsAppendInExactOrder() throws {
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let synthesizer = ReaderSpeechSynthesizer()
        let service = SpeakService(synthesizer: synthesizer)
        let coordinator = BibleReaderSpeechCoordinator()
        let context = makeBibleSpeechContext(manager: manager, module: module)
        let first = try XCTUnwrap(
            SpeakVerseRange(versification: "KJV", osisRef: "Gen.1.1-Gen.1.2")
        )
        let appended = [
            try XCTUnwrap(SpeakVerseRange(versification: "KJV", osisRef: "Matt.1.1")),
            try XCTUnwrap(SpeakVerseRange(versification: "KJV", osisRef: "Gen.1.2")),
        ]

        XCTAssertTrue(
            coordinator.speakBiblePassageList(
                ranges: [first],
                service: service,
                context: context
            )
        )
        let generation = service.currentSessionGeneration
        XCTAssertTrue(
            coordinator.speakBiblePassageList(
                ranges: appended,
                service: service,
                context: context
            )
        )

        XCTAssertEqual(service.currentSessionGeneration, generation)
        XCTAssertEqual(
            service.availableBiblePositions.map(\.osisRef),
            ["Gen.1.1", "Gen.1.2", "Matt.1.1", "Gen.1.2"]
        )
        XCTAssertEqual(synthesizer.acceptedUtterances.count, 1)
    }

    /**
     Verifies Daily Reading success is observed only after its first utterance reaches synthesis.

     The acceptance callback executes synchronously inside the injected speech-engine boundary. A
     typed voice failure must return false before that boundary, leave synthesis untouched, and give
     the reading-progress caller no successful result to mark.
     */
    func testCoordinatorReportsStartupSuccessOnlyAfterFirstUtteranceAcceptance() throws {
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let range = try XCTUnwrap(
            SpeakVerseRange(versification: "KJV", osisRef: "Gen.1.1")
        )
        let coordinator = BibleReaderSpeechCoordinator()
        let context = makeBibleSpeechContext(manager: manager, module: module)
        let acceptedSynthesizer = ReaderSpeechSynthesizer()
        var didAcceptBeforeReturn = false
        acceptedSynthesizer.onAccept = { _ in didAcceptBeforeReturn = true }
        let acceptedService = SpeakService(synthesizer: acceptedSynthesizer)

        XCTAssertTrue(
            coordinator.speakBiblePassageList(
                ranges: [range],
                service: acceptedService,
                context: context
            )
        )
        XCTAssertTrue(didAcceptBeforeReturn)
        XCTAssertEqual(acceptedSynthesizer.acceptedUtterances.count, 1)

        let failedSynthesizer = ReaderSpeechSynthesizer()
        let failedService = SpeakService(
            synthesizer: failedSynthesizer,
            voiceResolver: ReaderUnavailableVoiceResolver()
        )
        XCTAssertFalse(
            coordinator.speakBiblePassageList(
                ranges: [range],
                service: failedService,
                context: context
            )
        )
        XCTAssertTrue(failedSynthesizer.acceptedUtterances.isEmpty)
        XCTAssertEqual(
            failedService.lastStartupFailure,
            .unsupportedLanguage(module.info.language)
        )
        XCTAssertNotNil(failedService.currentTitle)
    }

    /**
     Verifies a queued resume-picker selection cannot replace a newer speech request.

     The callback deliberately suspends on the main actor after capturing its generation. Starting
     another source first must leave that replacement active when the queued callback executes.
     */
    @MainActor
    func testSessionBindingRejectsStaleQueuedResumeBookmark() async throws {
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let controller = BibleReaderController(bridge: BibleBridge(), swordManagerOverride: manager)
        let service = makeSpeechService()
        controller.speakService = service
        BibleReaderSpeechSessionBinding.install(on: service) { controller }
        let position = try XCTUnwrap(
            controller.defaultSpeechSession(service: service)?.provider.currentPosition
        )

        service.onRequestResumeBookmark?(
            SpeakResumeBookmark(
                id: UUID(),
                position: position,
                playbackSettings: PlaybackSettings()
            )
        )
        service.speak(text: "Newer selection", language: "en-US")
        let replacementGeneration = service.currentSessionGeneration
        await Task.yield()

        XCTAssertEqual(service.currentSessionGeneration, replacementGeneration)
        XCTAssertEqual(service.activeProviderCategory, .selection)
        XCTAssertEqual(service.currentPosition?.key, "selection")
    }

    /** Verifies Android map pages use the generic provider while retaining map-owned navigation. */
    @MainActor
    func testMapSpeechUsesGenericProviderAndMapNavigation() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedEmptyRawMapModule(named: "SpeechMap", in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let module = try XCTUnwrap(manager.module(named: "SpeechMap"))
        let controller = BibleReaderController(bridge: BibleBridge(), swordManagerOverride: manager)

        XCTAssertEqual(BibleReaderSpeechProviderFactory.category(for: .map), .generalBook)
        let context = try XCTUnwrap(
            controller.makeGenericSpeechContext(
                module: module,
                moduleName: "SpeechMap",
                category: .generalBook,
                currentKey: nil
            )
        )
        context.synchronizeKey("World/Ancient", 0)

        XCTAssertEqual(controller.currentCategory, .map)
        XCTAssertEqual(controller.activeMapModuleName, "SpeechMap")
        XCTAssertTrue(controller.isCurrentPageSpeakable)
        XCTAssertNil(controller.activeGeneralBookModuleName)
    }

    /**
     Routes readable generic SWORD speech and rejects a sibling locked source before provider build.

     - Setup: Installs one readable and one plaintext-but-locked RawLD dictionary, starts speech from
       the readable entry, then requests the locked entry through the same bridge route.
     - Expected result: Readable speech owns the dictionary identity and cursor; the locked request
       creates no provider, performs no replacement speech, and leaves the active generation intact.
     - Failure meaning: Generic bridge, checkpoint, or bookmark speech can read an inclusive native
       handle after its content credentials are unavailable.
     - Side effects: Writes only inherited temporary SWORD fixtures and records synthetic speech.
     */
    @MainActor
    func testGenericSwordSpeechRequiresFreshReadableSource() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try writeSpeechRawLDModule(
            named: "SpeechReadable",
            entryKey: "ENTRY",
            xml: "<div><p>Readable generic speech.</p></div>",
            in: modulePath
        )
        try writeSpeechRawLDModule(
            named: "SpeechLocked",
            entryKey: "ENTRY",
            xml: "<div><p>Locked generic speech must not play.</p></div>",
            in: modulePath,
            locked: true
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        XCTAssertNotNil(manager.module(named: "SpeechLocked"))
        XCTAssertNil(manager.readableModule(named: "SpeechLocked"))
        let controller = BibleReaderController(bridge: BibleBridge(), swordManagerOverride: manager)
        let service = makeSpeechService()
        controller.speakService = service

        controller.bridge(
            controller.bridge,
            speakGeneric: "SpeechReadable",
            osisRef: "ENTRY",
            startOrdinal: 0,
            endOrdinal: 0
        )
        XCTAssertEqual(service.activeProviderCategory, .dictionary)
        XCTAssertEqual(service.currentPosition?.bookInitials, "SpeechReadable")
        XCTAssertEqual(service.currentPosition?.key, "ENTRY")
        let readableGeneration = service.currentSessionGeneration

        controller.bridge(
            controller.bridge,
            speakGeneric: "SpeechLocked",
            osisRef: "ENTRY",
            startOrdinal: 0,
            endOrdinal: 0
        )
        XCTAssertEqual(service.currentSessionGeneration, readableGeneration)
        XCTAssertEqual(service.activeProviderCategory, .dictionary)
        XCTAssertEqual(service.currentPosition?.bookInitials, "SpeechReadable")
        XCTAssertEqual(service.currentPosition?.key, "ENTRY")
    }

    /**
     Preserves locked native speech ownership over a colliding My Documents identity.

     - Setup: Installs a locked RawLD dictionary and a readable My Documents page with the same
       initials/key, while retaining a known readable SWORD speech session as mutation baseline.
     - Expected result: The native registration blocks local-document/EPUB fallback and the bridge
       leaves provider generation, category, and cursor unchanged.
     - Failure meaning: Locking a native book can redirect persisted Speak content to a different
       backend that happens to reuse its initials.
     - Side effects: Writes an inherited temporary module and an in-memory SwiftData document.
     */
    @MainActor
    func testLockedNativeGenericSpeechDoesNotFallThroughToMyDocument() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try writeSpeechRawLDModule(
            named: "SpeechBaseline",
            entryKey: "ENTRY",
            xml: "<div><p>Baseline speech.</p></div>",
            in: modulePath
        )
        try writeSpeechRawLDModule(
            named: "SpeechCollision",
            entryKey: "ENTRY",
            xml: "<div><p>Locked native collision.</p></div>",
            in: modulePath,
            locked: true
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let container = try makeMyDocumentModelContainer()
        let context = ModelContext(container)
        let document = MyDocument(name: "Speech Collision", initials: "SpeechCollision")
        let page = MyDocumentPage(title: "Entry", pageKey: "ENTRY", contentType: .markdown)
        let content = MyDocumentPageContent(pageId: page.id, content: "Local collision speech")
        page.pageContent = content
        page.document = document
        document.pages = [page]
        context.insert(document)
        context.insert(page)
        context.insert(content)
        try context.save()

        let controller = BibleReaderController(bridge: BibleBridge(), swordManagerOverride: manager)
        controller.myDocumentStore = MyDocumentStore(modelContext: context)
        let service = makeSpeechService()
        controller.speakService = service
        controller.bridge(
            controller.bridge,
            speakGeneric: "SpeechBaseline",
            osisRef: "ENTRY",
            startOrdinal: 0,
            endOrdinal: 0
        )
        let baselineGeneration = service.currentSessionGeneration
        XCTAssertEqual(service.currentPosition?.bookInitials, "SpeechBaseline")

        controller.bridge(
            controller.bridge,
            speakGeneric: "SpeechCollision",
            osisRef: "ENTRY",
            startOrdinal: 0,
            endOrdinal: 0
        )

        XCTAssertEqual(service.currentSessionGeneration, baselineGeneration)
        XCTAssertEqual(service.activeProviderCategory, .dictionary)
        XCTAssertEqual(service.currentPosition?.bookInitials, "SpeechBaseline")
        XCTAssertEqual(service.currentPosition?.key, "ENTRY")
    }

    /** Verifies a MyDocument process checkpoint retains exact page and local ordinal identity. */
    @MainActor
    func testMyDocumentCheckpointReconstructsExactGenericCursor() throws {
        let container = try makeMyDocumentModelContainer()
        let context = ModelContext(container)
        let document = MyDocument(name: "Notes", initials: "MyNotes")
        let first = MyDocumentPage(title: "First", pageKey: "first", orderNumber: 0)
        let second = MyDocumentPage(title: "Second", pageKey: "second", orderNumber: 1)
        let firstContent = MyDocumentPageContent(pageId: first.id, content: "First page")
        let secondContent = MyDocumentPageContent(pageId: second.id, content: "Second page")
        first.pageContent = firstContent
        second.pageContent = secondContent
        first.document = document
        second.document = document
        document.pages = [first, second]
        context.insert(document)
        context.insert(first)
        context.insert(second)
        context.insert(firstContent)
        context.insert(secondContent)
        try context.save()

        let controller = BibleReaderController(bridge: BibleBridge(), initializesSword: false)
        controller.myDocumentStore = MyDocumentStore(modelContext: context)
        XCTAssertTrue(controller.loadMyDocumentPage(bookInitials: "MyNotes", pageKey: "second"))
        let service = makeSpeechService()
        controller.speakService = service
        let session = try XCTUnwrap(controller.defaultSpeechSession(service: service))
        let checkpoint = try XCTUnwrap(session.provider.checkpoint())

        XCTAssertEqual(checkpoint.current.category, .myDocument)
        XCTAssertEqual(checkpoint.current.bookInitials, "MyNotes")
        XCTAssertEqual(checkpoint.current.key, "second")
        XCTAssertEqual(checkpoint.current.ordinalStart, 0)
        let reconstructed = try XCTUnwrap(
            controller.reconstructSpeechSession(from: checkpoint, service: service)
        )
        XCTAssertEqual(reconstructed.provider.checkpoint(), checkpoint)
        XCTAssertEqual(reconstructed.provider.currentPosition?.key, "second")

        let resumePosition = try XCTUnwrap(reconstructed.provider.currentPosition)
        controller.resumeSpeech(
            from: SpeakResumeBookmark(
                id: UUID(),
                position: resumePosition,
                playbackSettings: PlaybackSettings()
            )
        )
        XCTAssertEqual(service.activeProviderCategory, .myDocument)
        XCTAssertEqual(service.currentPosition?.bookInitials, "MyNotes")
        XCTAssertEqual(service.currentPosition?.key, "second")
        XCTAssertEqual(service.currentPosition?.ordinalStart, 0)
    }

    /** Creates a deterministic service that records synthesis without platform audio. */
    private func makeSpeechService() -> SpeakService {
        SpeakService(synthesizer: ReaderSpeechSynthesizer())
    }

    /** Creates deterministic Bible speech context without involving reader-controller state. */
    private func makeBibleSpeechContext(
        manager: SwordManager,
        module: SwordModule
    ) -> BibleReaderSpeechContext {
        BibleReaderSpeechContext(
            module: module,
            swordManager: manager,
            currentBook: "Genesis",
            currentChapter: 1,
            currentVerse: 1,
            activeModuleName: module.info.name,
            displaySettings: TextDisplaySettings(),
            osisBookId: { $0 == "Genesis" ? "Gen" : $0 },
            parseVerseKey: { _ in nil },
            verseOrdinal: { book, chapter, verse in
                module.verseOrdinal(osisBookId: book, chapter: chapter, verse: verse)
            },
            evaluateJavaScript: { _ in },
            synchronizePosition: { _, _, _ in }
        )
    }

    /** Publishes a second Bible identity backed by the fixture's KJV data. */
    private func seedBibleAlias(named moduleName: String, in modulePath: String) throws {
        let conf = """
        [\(moduleName)]
        Description=Requested Bible
        DataPath=./modules/texts/ztext/kjv/
        ModDrv=zText
        SourceType=OSIS
        Encoding=UTF-8
        CompressType=ZIP
        BlockType=BOOK
        Versification=KJV
        Lang=en
        """
        let url = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mods.d", isDirectory: true)
            .appendingPathComponent("\(moduleName.lowercased()).conf", isDirectory: false)
        try conf.write(to: url, atomically: true, encoding: .utf8)
    }
}

/** Errors raised while writing test-only generic speech fixtures. */
private enum SpeechRoutingFixtureError: Error {
    /// RawLD index widths cannot represent the generated record.
    case recordTooLarge
}

/**
 Writes one exact RawLD entry for generic speech authorization tests.

 - Parameters:
   - moduleName: Stable module initials.
   - entryKey: Exact lexical entry key.
   - xml: Structural entry body consumed by the generic speech projector.
   - modulePath: Existing inherited temporary SWORD root.
   - locked: Whether the descriptor should expose installed ownership without readable access.
 - Side effects: Writes one descriptor plus RawLD data/index files under the temporary root.
 - Failure modes: Propagates filesystem errors and rejects records outside RawLD index widths.
 */
private func writeSpeechRawLDModule(
    named moduleName: String,
    entryKey: String,
    xml: String,
    in modulePath: String,
    locked: Bool = false
) throws {
    let moduleKey = moduleName.lowercased()
    let moduleRoot = URL(fileURLWithPath: modulePath, isDirectory: true)
    let dataDirectory = moduleRoot.appendingPathComponent(
        "modules/lexdict/rawld/\(moduleKey)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
    let record = Data("\(entryKey)\r\n\(xml)".utf8)
    guard record.count <= Int(UInt16.max) else {
        throw SpeechRoutingFixtureError.recordTooLarge
    }
    var data = record
    data.append(0x0A)
    try data.write(to: dataDirectory.appendingPathComponent("\(moduleKey).dat"))
    var index = Data()
    index.appendSpeechRoutingLittleEndian(UInt32(0))
    index.appendSpeechRoutingLittleEndian(UInt16(record.count))
    try index.write(to: dataDirectory.appendingPathComponent("\(moduleKey).idx"))
    let cipherLine = locked ? "CipherKey=" : ""
    try """
    [\(moduleName)]
    Description=Speech Routing Dictionary
    Abbreviation=\(moduleName)
    Category=Lexicons / Dictionaries
    DataPath=./modules/lexdict/rawld/\(moduleKey)/\(moduleKey)
    ModDrv=RawLD
    SourceType=OSIS
    Encoding=UTF-8
    Lang=en
    \(cipherLine)
    """.write(
        to: moduleRoot.appendingPathComponent("mods.d/\(moduleKey).conf"),
        atomically: true,
        encoding: .utf8
    )
}

private extension Data {
    /** Appends one RawLD speech-fixture integer in little-endian order. */
    mutating func appendSpeechRoutingLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}

/** Deterministic BibleUI speech-engine double. */
private final class ReaderSpeechSynthesizer: SpeechSynthesizing {
    weak var delegate: AVSpeechSynthesizerDelegate?
    private(set) var acceptedUtterances: [AVSpeechUtterance] = []
    var onAccept: ((AVSpeechUtterance) -> Void)?

    /** Records synchronous acceptance before returning control to `SpeakService`. */
    func speak(_ utterance: AVSpeechUtterance) {
        acceptedUtterances.append(utterance)
        onAccept?(utterance)
    }

    /** Reports a successful immediate stop. */
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool { true }

    /** Reports a successful pause. */
    func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool { true }

    /** Reports a successful resume. */
    func continueSpeaking() -> Bool { true }
}

/** Deterministic resolver used to keep coordinator startup on the typed voice-failure path. */
private struct ReaderUnavailableVoiceResolver: SpeechVoiceResolving {
    /** Returns no voice for every requested language without consulting device state. */
    func resolveVoice(
        for requestedLanguage: String,
        deviceLocale: Locale
    ) -> AVSpeechSynthesisVoice? {
        nil
    }
}
