import AVFoundation
import Foundation
import XCTest
@testable import BibleCore

#if os(iOS)
import MediaPlayer
#endif

/**
 Protects Android-equivalent installed-voice selection and runtime discrete-mode boundaries.

 Pure catalog tests pin locale precedence without relying on simulator voices. Service tests prove
 unsupported languages never reach synthesis and runtime discrete mode never exposes Bible identity
 or spoken content through iOS media surfaces while normal mode retains those integrations.
 */
@MainActor
final class SpeechVoiceAndProductBoundaryTests: XCTestCase {
    /**
     Verifies Android's device-region, native-region, base-language, and Ancient Greek precedence.

     The resolver is pure and uses an ordered installed catalog, so failures identify preference
     drift rather than simulator voice availability.
     */
    func testInstalledVoiceResolutionMatchesAndroidLocalePrecedence() {
        XCTAssertEqual(
            SpeechVoiceResolution.preferredLanguageIdentifiers(
                requestedLanguage: "en",
                deviceLocale: Locale(identifier: "en_CA")
            ),
            ["en-CA", "en-GB", "en"]
        )
        XCTAssertEqual(
            SpeechVoiceResolution.preferredLanguageIdentifiers(
                requestedLanguage: "fr-CA",
                deviceLocale: Locale(identifier: "en_US")
            ),
            ["fr-CA", "fr-FR", "fr"]
        )
        XCTAssertEqual(
            SpeechVoiceResolution.preferredLanguageIdentifiers(
                requestedLanguage: "grc",
                deviceLocale: Locale(identifier: "en_US")
            ),
            ["el"]
        )
        XCTAssertEqual(
            SpeechVoiceResolution.preferredLanguageIdentifiers(
                requestedLanguage: "",
                deviceLocale: Locale(identifier: "en_US")
            ),
            ["en-US", "en-GB", "en"]
        )

        let installed = [
            SpeechVoiceDescriptor(identifier: "us", language: "en-US"),
            SpeechVoiceDescriptor(identifier: "canadian", language: "en-CA"),
            SpeechVoiceDescriptor(identifier: "british", language: "en-GB"),
            SpeechVoiceDescriptor(identifier: "french-canadian", language: "fr-CA"),
            SpeechVoiceDescriptor(identifier: "greek", language: "el-GR"),
            SpeechVoiceDescriptor(identifier: "swedish", language: "sv-SE"),
        ]
        XCTAssertEqual(
            SpeechVoiceResolution.selectedVoiceIdentifier(
                requestedLanguage: "en",
                deviceLocale: Locale(identifier: "en_CA"),
                installedVoices: installed
            ),
            "canadian"
        )
        XCTAssertEqual(
            SpeechVoiceResolution.selectedVoiceIdentifier(
                requestedLanguage: "fr-CA",
                deviceLocale: Locale(identifier: "en_US"),
                installedVoices: installed
            ),
            "french-canadian"
        )
        XCTAssertEqual(
            SpeechVoiceResolution.selectedVoiceIdentifier(
                requestedLanguage: "en",
                deviceLocale: Locale(identifier: "de_DE"),
                installedVoices: installed
            ),
            "british"
        )
        XCTAssertEqual(
            SpeechVoiceResolution.selectedVoiceIdentifier(
                requestedLanguage: "grc",
                deviceLocale: Locale(identifier: "en_US"),
                installedVoices: installed
            ),
            "greek"
        )
        XCTAssertEqual(
            SpeechVoiceResolution.selectedVoiceIdentifier(
                requestedLanguage: "sv",
                deviceLocale: Locale(identifier: "en_US"),
                installedVoices: installed
            ),
            "swedish"
        )
        XCTAssertEqual(
            SpeechVoiceResolution.selectedVoiceIdentifier(
                requestedLanguage: "",
                deviceLocale: Locale(identifier: "en_AU"),
                installedVoices: installed
            ),
            "british",
            "Invalid language input must keep Android's native-region fallback before base voices."
        )
        XCTAssertNil(
            SpeechVoiceResolution.selectedVoiceIdentifier(
                requestedLanguage: "zz",
                deviceLocale: Locale(identifier: "en_US"),
                installedVoices: installed
            )
        )
    }

    /**
     Verifies quality-aware voice selection prefers premium and enhanced voices for long reading.

     The platform catalog lists compact voices first, so first-match selection picked the worst
     installed voice for every language. Failure means Bible reading falls back to a compact voice
     while a better one is installed, or a novelty/Personal voice is chosen for scripture.
     */
    func testVoiceSelectionPrefersHighestQualityAndExcludesNoveltyAndPersonalVoices() {
        let catalog = [
            SpeechVoiceDescriptor(identifier: "us-compact", language: "en-US", qualityRank: 0),
            SpeechVoiceDescriptor(identifier: "us-novelty", language: "en-US", qualityRank: 2, isNoveltyVoice: true),
            SpeechVoiceDescriptor(identifier: "us-personal", language: "en-US", qualityRank: 2, isPersonalVoice: true),
            SpeechVoiceDescriptor(identifier: "us-enhanced", language: "en-US", qualityRank: 1),
            SpeechVoiceDescriptor(identifier: "us-premium", language: "en-US", qualityRank: 2),
            SpeechVoiceDescriptor(identifier: "gb-compact", language: "en-GB", qualityRank: 0),
        ]

        XCTAssertEqual(
            SpeechVoiceResolution.selectedVoiceIdentifier(
                requestedLanguage: "en-US",
                deviceLocale: Locale(identifier: "en_US"),
                installedVoices: catalog
            ),
            "us-premium",
            "Premium must beat enhanced, compact, and excluded high-quality voices."
        )
        XCTAssertEqual(
            SpeechVoiceResolution.selectedVoiceIdentifier(
                requestedLanguage: "en-US",
                deviceLocale: Locale(identifier: "en_US"),
                installedVoices: catalog.filter { $0.identifier != "us-premium" }
            ),
            "us-enhanced",
            "Enhanced must beat compact when premium is absent."
        )
        XCTAssertEqual(
            SpeechVoiceResolution.selectedVoiceIdentifier(
                requestedLanguage: "en-GB",
                deviceLocale: Locale(identifier: "en_GB"),
                installedVoices: catalog
            ),
            "gb-compact",
            "A compact voice remains selectable when it is the only non-excluded match."
        )
        XCTAssertNil(
            SpeechVoiceResolution.selectedVoiceIdentifier(
                requestedLanguage: "en-US",
                deviceLocale: Locale(identifier: "en_US"),
                installedVoices: [
                    SpeechVoiceDescriptor(identifier: "only-novelty", language: "en-US", qualityRank: 2, isNoveltyVoice: true),
                    SpeechVoiceDescriptor(identifier: "only-personal", language: "en-US", qualityRank: 2, isPersonalVoice: true),
                ]
            ),
            "Novelty and Personal voices must never be selected even when nothing else matches."
        )
        XCTAssertEqual(
            SpeechVoiceResolution.selectedVoiceIdentifier(
                requestedLanguage: "en-US",
                deviceLocale: Locale(identifier: "en_US"),
                installedVoices: [
                    SpeechVoiceDescriptor(identifier: "first-enhanced", language: "en-US", qualityRank: 1),
                    SpeechVoiceDescriptor(identifier: "second-enhanced", language: "en-US", qualityRank: 1),
                ]
            ),
            "first-enhanced",
            "Equal quality keeps platform catalog order for deterministic selection."
        )
    }

    /** Unsupported languages stop visibly before the synthesizer receives any spoken content. */
    func testUnsupportedSpeechLanguageStopsWithoutSynthesisAndPublishesFailure() {
        let synthesizer = FakeSpeechSynthesizer()
        let service = SpeakService(
            synthesizer: synthesizer,
            voiceResolver: UnavailableSpeechVoiceResolver(),
            deviceLocale: Locale(identifier: "en_US"),
            systemPresentationPolicy: .standard
        )

        service.speak(text: "Content that must not reach the speech engine", language: "zz")

        XCTAssertTrue(synthesizer.spokenUtterances.isEmpty)
        XCTAssertFalse(service.isSpeaking)
        XCTAssertFalse(service.isPaused)
        XCTAssertNil(service.activeProviderCategory)
        XCTAssertEqual(service.lastFailure, .unsupportedLanguage("zz"))
        XCTAssertEqual(
            service.currentTitle,
            SpeakServiceFailure.unsupportedLanguage("zz").localizedDescription
        )
        XCTAssertNil(service.currentSubtitle)
    }

    /**
     Runtime discrete mode suppresses every system media metadata field while normal mode keeps the
     existing title, module, and playback-rate presentation.
     */
    func testDiscreteModePolicySuppressesNowPlayingContent() {
        let discrete = SpeakSystemPresentationPolicy.resolve(discreteModeEnabled: true)
        XCTAssertFalse(discrete.exposesMediaSession)
        XCTAssertNil(
            discrete.nowPlayingPresentation(
                title: "Genesis 1:1",
                subtitle: "King James Version",
                playbackRate: 1.25
            )
        )

        let standard = SpeakSystemPresentationPolicy.resolve(discreteModeEnabled: false)
        XCTAssertEqual(
            standard.nowPlayingPresentation(
                title: "Genesis 1:1",
                subtitle: "King James Version",
                playbackRate: 1.25
            ),
            SpeakNowPlayingPresentation(
                title: "Genesis 1:1",
                artist: "King James Version",
                playbackRate: 1.25
            )
        )
    }

    #if os(iOS)
    /**
     A discrete-mode service clears stale Now Playing data and never installs media command handlers.

     A real installed English voice drives the normal synthesis path; the assertion concerns only
     external system presentation and restores the global Now Playing center during cleanup.
     */
    func testDiscreteModeSpeechDoesNotCreateSystemMediaSession() throws {
        let voice = try XCTUnwrap(AVSpeechSynthesisVoice(language: "en-US"))
        let center = MPNowPlayingInfoCenter.default()
        let previousInfo = center.nowPlayingInfo
        defer { center.nowPlayingInfo = previousInfo }
        center.nowPlayingInfo = [MPMediaItemPropertyTitle: "stale"]

        let service = SpeakService(
            synthesizer: FakeSpeechSynthesizer(),
            voiceResolver: FixedSpeechVoiceResolver(voice: voice),
            deviceLocale: Locale(identifier: "en_US"),
            systemPresentationPolicy: .discrete
        )
        service.currentTitle = "Genesis 1:1"
        service.currentSubtitle = "King James Version"
        service.speak(text: "In the beginning", language: "en")

        XCTAssertNil(center.nowPlayingInfo)
        XCTAssertFalse(service.hasRegisteredRemoteCommands)
        XCTAssertNil(service.lastFailure)
    }

    /** A live discrete-mode change removes media identity from the same running speech service. */
    func testRuntimeDiscreteModeChangeClearsSystemMediaSession() throws {
        let voice = try XCTUnwrap(AVSpeechSynthesisVoice(language: "en-US"))
        let center = MPNowPlayingInfoCenter.default()
        let previousInfo = center.nowPlayingInfo
        defer { center.nowPlayingInfo = previousInfo }

        let service = SpeakService(
            synthesizer: FakeSpeechSynthesizer(),
            voiceResolver: FixedSpeechVoiceResolver(voice: voice),
            deviceLocale: Locale(identifier: "en_US"),
            systemPresentationPolicy: .standard
        )
        service.currentTitle = "Genesis 1:1"
        service.currentSubtitle = "King James Version"
        service.speak(text: "In the beginning", language: "en")
        XCTAssertNotNil(center.nowPlayingInfo)
        XCTAssertTrue(service.hasRegisteredRemoteCommands)

        service.applySystemPresentationPolicy(.discrete)

        XCTAssertNil(center.nowPlayingInfo)
        XCTAssertFalse(service.hasRegisteredRemoteCommands)
        XCTAssertTrue(service.isSpeaking)
    }

    /** Normal speech keeps its reader identity and system media controls. */
    func testNormalSpeechRetainsNowPlayingIdentityAndRemoteCommands() throws {
        let voice = try XCTUnwrap(AVSpeechSynthesisVoice(language: "en-US"))
        let center = MPNowPlayingInfoCenter.default()
        let previousInfo = center.nowPlayingInfo
        defer { center.nowPlayingInfo = previousInfo }

        let service = SpeakService(
            synthesizer: FakeSpeechSynthesizer(),
            voiceResolver: FixedSpeechVoiceResolver(voice: voice),
            deviceLocale: Locale(identifier: "en_US"),
            systemPresentationPolicy: .standard
        )
        let position = SpeakStreamPosition(
            id: "KJV:Gen.1.1",
            category: .bible,
            bookInitials: "KJV",
            key: "Gen.1.1",
            osisRef: "Gen.1.1",
            keyName: "Genesis 1:1",
            bookName: "King James Version",
            chapter: 1,
            verse: 1,
            groupIdentifier: "KJV:Gen.1",
            language: "en",
            versification: "KJV"
        )
        let provider = IndexedSpeakTextProvider(
            category: .bible,
            positions: [position],
            startIndex: 0,
            canAutoBookmark: false,
            advancedSettings: AdvancedSpeakSettings(),
            loader: { _, _, _ in [.text("In the beginning")] }
        )
        service.speak(provider: provider)

        XCTAssertEqual(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "Genesis 1:1")
        XCTAssertEqual(
            center.nowPlayingInfo?[MPMediaItemPropertyArtist] as? String,
            "King James Version"
        )
        XCTAssertTrue(service.hasRegisteredRemoteCommands)
        XCTAssertNil(service.lastFailure)
    }

    /**
     Verifies an unconfigured service rejects every remote event instead of reporting false success.

     - Side effects: Registers handlers only in the deterministic command-router fixture.
     - Failure modes: Fails if an idle service without a reader provider or reconstruction callback
       claims that any transport command was actionable.
     */
    func testIdleRemoteHandlersRejectCommandsWithoutAReaderSource() {
        let router = RecordingSpeakRemoteCommandCenterRouter()
        let service = SpeakService(
            synthesizer: FakeSpeechSynthesizer(),
            systemPresentationPolicy: .standard,
            remoteCommandCenter: router
        )

        XCTAssertTrue(service.hasRegisteredRemoteCommands)
        for command in SpeakRemoteCommand.allCases {
            XCTAssertEqual(
                router.invokeFirstHandler(for: command),
                .noActionableNowPlayingItem,
                "Unexpected outcome for \(command)"
            )
        }
        XCTAssertFalse(service.isSpeaking)
        XCTAssertFalse(service.isPaused)
    }

    /**
     Verifies system status reflects failed reconstruction and provider-boundary outcomes.

     A nonnil reader reconstruction closure is intentionally unable to construct a source, which
     distinguishes actual command completion from a heuristic callback-presence preflight. The
     one-position provider then rejects both smart movement directions at its real boundaries.

     - Side effects: Registers handlers in the deterministic router and starts one fake synthesis
       session without touching the process-global command center.
     - Failure modes: Fails if Play/toggle report success before reconstruction finishes or if
       next/previous report success when the provider did not move.
     */
    func testRemoteHandlersReportActualReconstructionAndBoundaryOutcomes() throws {
        let router = RecordingSpeakRemoteCommandCenterRouter()
        let voice = try XCTUnwrap(AVSpeechSynthesisVoice(language: "en-US"))
        let synthesizer = FakeSpeechSynthesizer()
        let service = SpeakService(
            synthesizer: synthesizer,
            voiceResolver: FixedSpeechVoiceResolver(voice: voice),
            deviceLocale: Locale(identifier: "en_US"),
            systemPresentationPolicy: .standard,
            remoteCommandCenter: router
        )
        service.onRequestDefaultSession = { nil }

        XCTAssertEqual(router.invokeFirstHandler(for: .play), .noActionableNowPlayingItem)
        XCTAssertEqual(
            router.invokeFirstHandler(for: .togglePlayPause),
            .noActionableNowPlayingItem
        )
        XCTAssertFalse(service.isSpeaking)

        let position = SpeakStreamPosition(
            id: "KJV:Gen.1.1",
            category: .bible,
            bookInitials: "KJV",
            key: "Gen.1.1",
            osisRef: "Gen.1.1",
            keyName: "Genesis 1:1",
            bookName: "King James Version",
            chapter: 1,
            verse: 1,
            groupIdentifier: "KJV:Gen.1",
            language: "en",
            versification: "KJV"
        )
        let makeProvider = {
            IndexedSpeakTextProvider(
                category: .bible,
                positions: [position],
                startIndex: 0,
                canAutoBookmark: false,
                advancedSettings: AdvancedSpeakSettings(),
                loader: { _, _, _ in [.text("In the beginning")] }
            )
        }
        service.onRequestDefaultSession = {
            SpeakSessionReconstruction(provider: makeProvider())
        }

        XCTAssertEqual(router.invokeFirstHandler(for: .play), .success)
        XCTAssertTrue(service.isSpeaking)
        let stopCountBeforeBoundaryCommands = synthesizer.stopBoundaries.count
        let utteranceCountBeforeBoundaryCommands = synthesizer.spokenUtterances.count
        XCTAssertEqual(router.invokeFirstHandler(for: .nextTrack), .noSuchContent)
        XCTAssertEqual(router.invokeFirstHandler(for: .previousTrack), .noSuchContent)
        XCTAssertEqual(service.currentPosition, position)
        XCTAssertEqual(synthesizer.stopBoundaries.count, stopCountBeforeBoundaryCommands)
        XCTAssertEqual(synthesizer.spokenUtterances.count, utteranceCountBeforeBoundaryCommands)
        XCTAssertEqual(router.invokeFirstHandler(for: .stop), .success)

        service.onRequestDefaultSession = {
            SpeakSessionReconstruction(
                provider: UnpreparableIndexedSpeakTextProvider(
                    category: .bible,
                    positions: [position],
                    startIndex: 0,
                    canAutoBookmark: false,
                    advancedSettings: AdvancedSpeakSettings(),
                    loader: { _, _, _ in [.text("In the beginning")] }
                )
            )
        }
        XCTAssertEqual(router.invokeFirstHandler(for: .play), .commandFailed)
        XCTAssertFalse(service.isSpeaking)
    }

    /**
     Verifies remote Play reports audio-session rejection instead of publishing false playback.

     - Side effects: Invokes one reconstructed Play through the in-memory command router and one
       failing injected audio-session configuration attempt.
     - Failure modes: Fails if the service activates state, submits synthesis, loses the typed audio
       failure, or maps platform activation rejection to a successful MediaPlayer result.
     */
    func testAudioSessionFailurePreventsRemoteStartupAndMapsCommandFailure() throws {
        let router = RecordingSpeakRemoteCommandCenterRouter()
        let audioSession = FakeSpeakAudioSessionConfigurator(shouldFail: true)
        let synthesizer = FakeSpeechSynthesizer()
        let voice = try XCTUnwrap(AVSpeechSynthesisVoice(language: "en-US"))
        let position = SpeakStreamPosition(
            id: "KJV:Gen.1.1",
            category: .bible,
            bookInitials: "KJV",
            key: "Gen.1.1",
            osisRef: "Gen.1.1",
            keyName: "Genesis 1:1",
            bookName: "King James Version",
            chapter: 1,
            verse: 1,
            groupIdentifier: "KJV:Gen.1",
            language: "en",
            versification: "KJV"
        )
        let service = SpeakService(
            synthesizer: synthesizer,
            audioSessionConfigurator: audioSession,
            voiceResolver: FixedSpeechVoiceResolver(voice: voice),
            deviceLocale: Locale(identifier: "en_US"),
            systemPresentationPolicy: .standard,
            remoteCommandCenter: router
        )
        service.onRequestDefaultSession = {
            SpeakSessionReconstruction(
                provider: IndexedSpeakTextProvider(
                    category: .bible,
                    positions: [position],
                    startIndex: 0,
                    canAutoBookmark: false,
                    advancedSettings: AdvancedSpeakSettings(),
                    loader: { _, _, _ in [.text("In the beginning")] }
                )
            )
        }

        XCTAssertEqual(router.invokeFirstHandler(for: .play), .commandFailed)
        XCTAssertEqual(audioSession.configureCallCount, 1)
        XCTAssertTrue(synthesizer.spokenUtterances.isEmpty)
        XCTAssertFalse(service.isSpeaking)
        XCTAssertFalse(service.isPaused)
        XCTAssertNil(service.activeProviderCategory)
        XCTAssertEqual(service.lastStartupFailure, .audioSessionFailed)
    }

    /**
     Verifies a resumed provider remains paused when the platform audio session cannot reactivate.

     - Side effects: Starts and pauses one fake session, then changes only the injected audio
       boundary to fail before invoking remote Play.
     - Failure modes: Fails if resume clears pause persistence/state, submits another utterance, or
       reports system success after category/activation failure.
     */
    func testAudioSessionFailureLeavesRemoteResumePaused() throws {
        let router = RecordingSpeakRemoteCommandCenterRouter()
        let audioSession = FakeSpeakAudioSessionConfigurator()
        let synthesizer = FakeSpeechSynthesizer()
        let voice = try XCTUnwrap(AVSpeechSynthesisVoice(language: "en-US"))
        let position = SpeakStreamPosition(
            id: "KJV:Gen.1.1",
            category: .bible,
            bookInitials: "KJV",
            key: "Gen.1.1",
            osisRef: "Gen.1.1",
            keyName: "Genesis 1:1",
            bookName: "King James Version",
            chapter: 1,
            verse: 1,
            groupIdentifier: "KJV:Gen.1",
            language: "en",
            versification: "KJV"
        )
        let provider = IndexedSpeakTextProvider(
            category: .bible,
            positions: [position],
            startIndex: 0,
            canAutoBookmark: false,
            advancedSettings: AdvancedSpeakSettings(),
            loader: { _, _, _ in [.text("In the beginning")] }
        )
        let service = SpeakService(
            synthesizer: synthesizer,
            audioSessionConfigurator: audioSession,
            voiceResolver: FixedSpeechVoiceResolver(voice: voice),
            deviceLocale: Locale(identifier: "en_US"),
            systemPresentationPolicy: .standard,
            remoteCommandCenter: router
        )

        XCTAssertTrue(service.start(provider: provider).succeeded)
        XCTAssertTrue(service.pause())
        audioSession.shouldFail = true

        XCTAssertEqual(router.invokeFirstHandler(for: .play), .commandFailed)
        XCTAssertEqual(audioSession.configureCallCount, 2)
        XCTAssertTrue(service.isSpeaking)
        XCTAssertTrue(service.isPaused)
        XCTAssertEqual(service.activeProviderCategory, .bible)
        XCTAssertEqual(service.currentPosition, position)
        XCTAssertEqual(synthesizer.spokenUtterances.count, 1)
        XCTAssertEqual(service.lastStartupFailure, .audioSessionFailed)
    }

    /**
     Verifies rejected synthesizer cancellation cannot complete Pause, Stop, or provider movement.

     - Side effects: Starts one two-position provider, then configures the fake synthesizer to reject
       three remote cancellation attempts while recording each request.
     - Failure modes: Fails if any command reports success, mutates pause/session/provider position,
       clears the source, or submits replacement synthesis after `stopSpeaking` returned `false`.
     */
    func testRejectedSynthesizerCancellationPreservesRemoteTransportState() throws {
        let router = RecordingSpeakRemoteCommandCenterRouter()
        let synthesizer = FakeSpeechSynthesizer()
        let voice = try XCTUnwrap(AVSpeechSynthesisVoice(language: "en-US"))
        let verses: [Int] = [1, 2]
        let positions = verses.map { verse in
            SpeakStreamPosition(
                id: "KJV:Gen.1.\(verse)",
                category: .bible,
                bookInitials: "KJV",
                key: "Gen.1.\(verse)",
                osisRef: "Gen.1.\(verse)",
                keyName: "Genesis 1:\(verse)",
                bookName: "King James Version",
                chapter: 1,
                verse: verse,
                groupIdentifier: "KJV:Gen.1",
                language: "en",
                versification: "KJV"
            )
        }
        let provider = IndexedSpeakTextProvider(
            category: .bible,
            positions: positions,
            startIndex: 0,
            canAutoBookmark: false,
            advancedSettings: AdvancedSpeakSettings(),
            loader: { position, _, _ in [.text(position.keyName)] }
        )
        let service = SpeakService(
            synthesizer: synthesizer,
            audioSessionConfigurator: FakeSpeakAudioSessionConfigurator(),
            voiceResolver: FixedSpeechVoiceResolver(voice: voice),
            deviceLocale: Locale(identifier: "en_US"),
            systemPresentationPolicy: .standard,
            remoteCommandCenter: router
        )
        XCTAssertTrue(service.start(provider: provider).succeeded)
        synthesizer.stopSpeakingResult = false

        XCTAssertEqual(router.invokeFirstHandler(for: .pause), .commandFailed)
        XCTAssertEqual(router.invokeFirstHandler(for: .stop), .commandFailed)
        XCTAssertEqual(router.invokeFirstHandler(for: .nextTrack), .commandFailed)

        XCTAssertEqual(synthesizer.stopBoundaries, [.immediate, .immediate, .immediate])
        XCTAssertEqual(synthesizer.spokenUtterances.count, 1)
        XCTAssertTrue(service.isSpeaking)
        XCTAssertFalse(service.isPaused)
        XCTAssertEqual(service.activeProviderCategory, .bible)
        XCTAssertEqual(service.currentPosition, positions[0])
        XCTAssertEqual(provider.currentPosition, positions[0])
    }

    /**
     Verifies movement returns the target's real unsupported-language synthesis failure.

     - Side effects: Cancels the first fake utterance, advances one provider position, and asks the
       selective resolver to reject the target language before replacement synthesis.
     - Failure modes: Fails if movement reports success merely because the cursor changed, speaks an
       unsupported target, or collapses the typed target failure into a provider boundary result.
     */
    func testRemoteMovementToUnsupportedTargetReturnsCommandFailure() throws {
        let router = RecordingSpeakRemoteCommandCenterRouter()
        let synthesizer = FakeSpeechSynthesizer()
        let voice = try XCTUnwrap(AVSpeechSynthesisVoice(language: "en-US"))
        let positions = ["en", "zz"].enumerated().map { index, language in
            let verse = index + 1
            return SpeakStreamPosition(
                id: "KJV:Gen.1.\(verse)",
                category: .bible,
                bookInitials: "KJV",
                key: "Gen.1.\(verse)",
                osisRef: "Gen.1.\(verse)",
                keyName: "Genesis 1:\(verse)",
                bookName: "King James Version",
                chapter: 1,
                verse: verse,
                groupIdentifier: "KJV:Gen.1",
                language: language,
                versification: "KJV"
            )
        }
        let service = SpeakService(
            synthesizer: synthesizer,
            audioSessionConfigurator: FakeSpeakAudioSessionConfigurator(),
            voiceResolver: SelectiveSpeechVoiceResolver(
                supportedLanguage: "en",
                voice: voice
            ),
            deviceLocale: Locale(identifier: "en_US"),
            systemPresentationPolicy: .standard,
            remoteCommandCenter: router
        )
        XCTAssertTrue(
            service.start(
                provider: IndexedSpeakTextProvider(
                    category: .bible,
                    positions: positions,
                    startIndex: 0,
                    canAutoBookmark: false,
                    advancedSettings: AdvancedSpeakSettings(),
                    loader: { position, _, _ in [.text(position.keyName)] }
                )
            ).succeeded
        )

        XCTAssertEqual(router.invokeFirstHandler(for: .nextTrack), .commandFailed)
        XCTAssertEqual(synthesizer.stopBoundaries, [.immediate])
        XCTAssertEqual(synthesizer.spokenUtterances.count, 1)
        XCTAssertFalse(service.isSpeaking)
        XCTAssertNil(service.activeProviderCategory)
        XCTAssertEqual(service.lastStartupFailure, .unsupportedLanguage("zz"))
    }

    /**
     Verifies a removed handler cannot become valid again after command registration is recreated.

     - Side effects: Captures one old Pause closure, tears down the registration set through discrete
       mode, creates a new set, then invokes both generations against the same live speech session.
     - Failure modes: Fails if pointer/value reuse creates an ABA hole that lets the old handler pause
       speech, or if the current registration is incorrectly rejected with the stale generation.
     */
    func testOldRemoteHandlerEpochCannotPassAfterRegistrationABA() throws {
        let router = RecordingSpeakRemoteCommandCenterRouter()
        let voice = try XCTUnwrap(AVSpeechSynthesisVoice(language: "en-US"))
        let service = SpeakService(
            synthesizer: FakeSpeechSynthesizer(),
            audioSessionConfigurator: FakeSpeakAudioSessionConfigurator(),
            voiceResolver: FixedSpeechVoiceResolver(voice: voice),
            deviceLocale: Locale(identifier: "en_US"),
            systemPresentationPolicy: .standard,
            remoteCommandCenter: router
        )
        service.speak(text: "In the beginning", language: "en")
        let oldPauseHandler = try XCTUnwrap(router.firstHandler(for: .pause))

        service.applySystemPresentationPolicy(.discrete)
        service.applySystemPresentationPolicy(.standard)

        XCTAssertEqual(oldPauseHandler(), .noActionableNowPlayingItem)
        XCTAssertTrue(service.isSpeaking)
        XCTAssertFalse(service.isPaused)
        XCTAssertEqual(router.invokeFirstHandler(for: .pause), .success)
        XCTAssertTrue(service.isPaused)
    }

    /**
     Verifies off-main MediaPlayer delivery waits for the completed main-domain mutation.

     - Side effects: Starts fake speech, delivers Pause from a global queue, and waits for the
       deterministic command handler to return.
     - Failure modes: Fails if the callback reads speech state off-main, reports before Pause is
       applied, deadlocks while hopping to the main queue, or returns an inactionable status.
     */
    func testRemoteHandlerReturnsCompletedOutcomeFromBackgroundDelivery() throws {
        let router = RecordingSpeakRemoteCommandCenterRouter()
        let voice = try XCTUnwrap(AVSpeechSynthesisVoice(language: "en-US"))
        let service = SpeakService(
            synthesizer: FakeSpeechSynthesizer(),
            voiceResolver: FixedSpeechVoiceResolver(voice: voice),
            deviceLocale: Locale(identifier: "en_US"),
            systemPresentationPolicy: .standard,
            remoteCommandCenter: router
        )
        let position = SpeakStreamPosition(
            id: "KJV:Gen.1.1",
            category: .bible,
            bookInitials: "KJV",
            key: "Gen.1.1",
            osisRef: "Gen.1.1",
            keyName: "Genesis 1:1",
            bookName: "King James Version",
            chapter: 1,
            verse: 1,
            groupIdentifier: "KJV:Gen.1",
            language: "en",
            versification: "KJV"
        )
        service.speak(
            provider: IndexedSpeakTextProvider(
                category: .bible,
                positions: [position],
                startIndex: 0,
                canAutoBookmark: false,
                advancedSettings: AdvancedSpeakSettings(),
                loader: { _, _, _ in [.text("In the beginning")] }
            )
        )
        let completed = expectation(description: "background remote command completed")
        let result = LockedSpeakRemoteCommandOutcome()
        Thread.detachNewThread {
            result.store(router.invokeFirstHandler(for: .pause))
            completed.fulfill()
        }

        wait(for: [completed], timeout: 2.0)
        XCTAssertEqual(result.value, .success)
        XCTAssertTrue(service.isPaused)
    }

    /**
     Verifies a pending command timeout cancels work before the main actor may claim it.

     - Side effects: Advances only the in-memory one-shot handoff state.
     - Failure modes: Fails if timeout reports success, a late executor can claim cancelled work,
       or a late completion changes the fail-closed result.
     */
    func testPendingRemoteCommandTimeoutPreventsLateMutationClaim() {
        let handoff = SpeakRemoteCommandHandoff()

        XCTAssertEqual(handoff.waitForOutcome(timeout: 0), .commandFailed)
        XCTAssertFalse(handoff.claimExecution())
        handoff.complete(with: .success)
        XCTAssertEqual(handoff.waitForOutcome(timeout: 0), .commandFailed)
    }

    /**
     Verifies one service removes only its exact process-global media-command targets.

     Two services model the historical app-owned and reader-owned overlap. Tearing down the first
     must leave every second-owner handler registered and every shared command enabled; only the
     final owner may disable the commands.

     - Side effects: Mutates only the deterministic router fixture.
     - Failure modes: Fails on wildcard removal, shared-command disablement while an owner remains,
       duplicate teardown, or leaked final targets.
     */
    func testRemoteCommandTeardownPreservesAnotherLiveServiceOwner() {
        let router = RecordingSpeakRemoteCommandCenterRouter()
        let firstService = SpeakService(
            synthesizer: FakeSpeechSynthesizer(),
            systemPresentationPolicy: .standard,
            remoteCommandCenter: router
        )
        let firstTargets = router.liveTargetIdentifiers
        let secondService = SpeakService(
            synthesizer: FakeSpeechSynthesizer(),
            systemPresentationPolicy: .standard,
            remoteCommandCenter: router
        )
        let secondTargets = router.liveTargetIdentifiers.subtracting(firstTargets)

        XCTAssertEqual(firstTargets.count, SpeakRemoteCommand.allCases.count)
        XCTAssertEqual(secondTargets.count, SpeakRemoteCommand.allCases.count)
        XCTAssertEqual(router.enabledCommands, Set(SpeakRemoteCommand.allCases))
        for command in SpeakRemoteCommand.allCases {
            XCTAssertEqual(router.liveTargetCount(for: command), 2)
        }

        firstService.applySystemPresentationPolicy(.discrete)

        XCTAssertFalse(firstService.hasRegisteredRemoteCommands)
        XCTAssertTrue(secondService.hasRegisteredRemoteCommands)
        XCTAssertEqual(router.liveTargetIdentifiers, secondTargets)
        XCTAssertEqual(router.removedTargetIdentifiers, firstTargets)
        XCTAssertEqual(router.enabledCommands, Set(SpeakRemoteCommand.allCases))
        for command in SpeakRemoteCommand.allCases {
            XCTAssertEqual(router.liveTargetCount(for: command), 1)
        }

        firstService.applySystemPresentationPolicy(.discrete)
        XCTAssertEqual(router.removedTargetIdentifiers, firstTargets)

        secondService.applySystemPresentationPolicy(.discrete)

        XCTAssertFalse(secondService.hasRegisteredRemoteCommands)
        XCTAssertTrue(router.liveTargetIdentifiers.isEmpty)
        XCTAssertEqual(
            router.removedTargetIdentifiers,
            firstTargets.union(secondTargets)
        )
        XCTAssertTrue(router.enabledCommands.isEmpty)
    }
    #endif
}

/** Deterministic voice resolver that models a device with no voice for the requested language. */
private struct UnavailableSpeechVoiceResolver: SpeechVoiceResolving {
    /**
     Rejects every request without querying platform state.

     - Parameters:
       - requestedLanguage: Ignored requested language.
       - deviceLocale: Ignored device locale.
     - Returns: Always `nil`.
     - Side effects: none.
     - Failure modes: Every request intentionally models unsupported speech.
     */
    func resolveVoice(
        for requestedLanguage: String,
        deviceLocale: Locale
    ) -> AVSpeechSynthesisVoice? {
        _ = requestedLanguage
        _ = deviceLocale
        return nil
    }
}

#if os(iOS)
/** Fixed installed-voice resolver used to isolate Calculator media-session integration tests. */
private struct FixedSpeechVoiceResolver: SpeechVoiceResolving {
    /// Installed voice returned for every deterministic test request.
    let voice: AVSpeechSynthesisVoice

    /**
     Returns the injected installed voice without consulting mutable system preference order.

     - Parameters:
       - requestedLanguage: Ignored requested language.
       - deviceLocale: Ignored device locale.
     - Returns: The fixture voice supplied at construction.
     - Side effects: none.
     - Failure modes: none; test setup fails before construction when no fixture voice exists.
     */
    func resolveVoice(
        for requestedLanguage: String,
        deviceLocale: Locale
    ) -> AVSpeechSynthesisVoice? {
        _ = requestedLanguage
        _ = deviceLocale
        return voice
    }
}

/** Deterministic resolver that supports exactly one source language for movement failure tests. */
private struct SelectiveSpeechVoiceResolver: SpeechVoiceResolving {
    /// Only requested language accepted by the fixture.
    let supportedLanguage: String
    /// Installed voice returned for the accepted language.
    let voice: AVSpeechSynthesisVoice

    /**
     Resolves the fixed voice only for the configured language.

     - Parameters:
       - requestedLanguage: Source language requested by the moved-to provider unit.
       - deviceLocale: Ignored immutable device locale supplied by the service.
     - Returns: The injected voice for an exact supported-language match, otherwise `nil`.
     - Side effects: none.
     - Failure modes: Unsupported target languages deterministically return `nil`.
     */
    func resolveVoice(
        for requestedLanguage: String,
        deviceLocale: Locale
    ) -> AVSpeechSynthesisVoice? {
        _ = deviceLocale
        return requestedLanguage == supportedLanguage ? voice : nil
    }
}

/**
 Deterministic in-memory model of exact MediaPlayer target ownership.

 It retains one closure per opaque target and mirrors command enablement by live-owner count, making
 wildcard removal and premature global disablement observable without mutating the simulator's
 process-global `MPRemoteCommandCenter`.
 */
private final class RecordingSpeakRemoteCommandCenterRouter: SpeakRemoteCommandCenterRouting,
    @unchecked Sendable {
    /// Opaque identity returned to the service exactly as MediaPlayer returns its block target.
    private final class Target {}

    /// Semantic command and executable callback retained for one target.
    private struct Registration {
        /// Command associated with this target.
        let command: SpeakRemoteCommand
        /// Handler whose typed result maps to MediaPlayer command status.
        let handler: () -> SpeakRemoteCommandOutcome
    }

    /// Live registrations keyed by opaque object identity.
    private var registrations: [ObjectIdentifier: Registration] = [:]

    /// Commands currently modeled as globally enabled.
    private(set) var enabledCommands: Set<SpeakRemoteCommand> = []

    /// Exact identities removed through the router.
    private(set) var removedTargetIdentifiers: Set<ObjectIdentifier> = []

    /// Exact identities still registered across every command.
    var liveTargetIdentifiers: Set<ObjectIdentifier> {
        Set(registrations.keys)
    }

    /**
     Registers one opaque target and enables its semantic command.

     - Parameters:
       - command: Semantic command represented by the target.
       - handler: Service callback to invoke for deterministic result checks.
     - Returns: Newly allocated opaque target.
     - Side effects: Retains the callback and marks `command` enabled.
     - Failure modes: none.
     */
    func addHandler(
        for command: SpeakRemoteCommand,
        handler: @escaping () -> SpeakRemoteCommandOutcome
    ) -> AnyObject {
        let target = Target()
        registrations[ObjectIdentifier(target)] = Registration(
            command: command,
            handler: handler
        )
        enabledCommands.insert(command)
        return target
    }

    /**
     Removes only the supplied target and disables its command after the final owner disappears.

     - Parameters:
       - target: Exact opaque identity returned by `addHandler`.
       - command: Expected semantic command for the target.
     - Side effects: Removes one registration and may update modeled global enablement.
     - Failure modes: Unknown, repeated, or mismatched removals are ignored.
     */
    func removeHandler(_ target: AnyObject, for command: SpeakRemoteCommand) {
        let identifier = ObjectIdentifier(target)
        guard registrations[identifier]?.command == command else { return }
        registrations[identifier] = nil
        removedTargetIdentifiers.insert(identifier)
        if registrations.values.contains(where: { $0.command == command }) == false {
            enabledCommands.remove(command)
        }
    }

    /**
     Invokes the first live handler for one command.

     - Parameter command: Semantic command to deliver.
     - Returns: Handler result, or missing-action status when no target remains.
     - Side effects: Runs the selected service callback synchronously.
     - Failure modes: Missing targets are modeled as an inactionable command.
     */
    func invokeFirstHandler(for command: SpeakRemoteCommand) -> SpeakRemoteCommandOutcome {
        registrations.values.first(where: { $0.command == command })?.handler()
            ?? .noActionableNowPlayingItem
    }

    /**
     Captures the first live callback so tests can deliver it after exact target removal.

     - Parameter command: Semantic command whose current closure should be retained by the caller.
     - Returns: Live handler closure, or `nil` when the router has no matching target.
     - Side effects: Copies the closure without invoking or removing its registration.
     - Failure modes: Missing registrations return `nil`.
     */
    func firstHandler(
        for command: SpeakRemoteCommand
    ) -> (() -> SpeakRemoteCommandOutcome)? {
        registrations.values.first(where: { $0.command == command })?.handler
    }

    /** Returns the number of live exact targets for `command`. */
    func liveTargetCount(for command: SpeakRemoteCommand) -> Int {
        registrations.values.count(where: { $0.command == command })
    }
}

/** Lock-protected result box used to return one remote outcome from a dedicated test thread. */
private final class LockedSpeakRemoteCommandOutcome: @unchecked Sendable {
    /// Protects the optional result across the delivery and XCTest threads.
    private let lock = NSLock()
    /// Stored completed result guarded by `lock`.
    private var storedValue: SpeakRemoteCommandOutcome?

    /**
     Stores one completed remote-command result.

     - Parameter outcome: Typed result returned by the deterministic command router.
     - Side effects: Replaces the lock-protected optional value.
     - Failure modes: none.
     */
    func store(_ outcome: SpeakRemoteCommandOutcome) {
        lock.lock()
        storedValue = outcome
        lock.unlock()
    }

    /**
     Reads the completed remote-command result.

     - Returns: Stored outcome, or `nil` before background delivery completes.
     - Side effects: Acquires and releases the result lock.
     - Failure modes: No value before completion is represented as `nil`.
     */
    var value: SpeakRemoteCommandOutcome? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

/** Indexed provider fixture whose stable position exists but whose preparation always fails. */
private final class UnpreparableIndexedSpeakTextProvider: IndexedSpeakTextProvider {
    /**
     Rejects every preparation request without changing the retained source position.

     - Parameter settings: Effective speech settings intentionally ignored by the failure fixture.
     - Returns: Always `false`.
     - Side effects: none.
     - Failure modes: Deterministically models a provider execution failure after source discovery.
     */
    override func prepare(settings: SpeakSettings) -> Bool {
        _ = settings
        return false
    }
}
#endif
