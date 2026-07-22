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
#endif
