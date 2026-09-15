import AVFoundation
import XCTest
@testable import BibleCore

/**
 BibleCore speech service behavior formerly hosted by the app test bundle.

 These tests exercise only `SpeakService` and its injected `SpeechSynthesizing` dependency, so they
 belong in `BibleCoreTests` rather than the app-host or BibleUI package lane.
 */
@MainActor
final class SpeakServiceTests: XCTestCase {
    func testSpeakServiceMemorizationLoopRepeatsUntilStopped() {
        let synthesizer = FakeSpeechSynthesizer()
        let service = SpeakService(synthesizer: synthesizer)

        service.speakMemorizationLoop(text: "In the beginning", language: "en-US")

        XCTAssertTrue(service.isMemorizationLoop)
        XCTAssertTrue(service.isSpeaking)
        XCTAssertEqual(synthesizer.spokenUtterances.map(\.speechString), ["In the beginning"])

        let firstUtterance = synthesizer.spokenUtterances[0]
        service.speechSynthesizer(AVSpeechSynthesizer(), didFinish: firstUtterance)

        XCTAssertTrue(service.isMemorizationLoop)
        XCTAssertTrue(service.isSpeaking)
        XCTAssertEqual(
            synthesizer.spokenUtterances.map(\.speechString),
            ["In the beginning", "In the beginning"]
        )

        service.stop()

        XCTAssertFalse(service.isMemorizationLoop)
        XCTAssertFalse(service.isSpeaking)
        XCTAssertEqual(synthesizer.stopBoundaries.last, .immediate)
    }

    func testSpeakServiceRegularSpeechClearsMemorizationLoop() {
        let synthesizer = FakeSpeechSynthesizer()
        let service = SpeakService(synthesizer: synthesizer)

        service.speakMemorizationLoop(text: "Remember this", language: "en-US")
        service.speak(text: "Read once", language: "en-US")

        XCTAssertFalse(service.isMemorizationLoop)
        XCTAssertTrue(service.isSpeaking)
        XCTAssertEqual(
            synthesizer.spokenUtterances.map(\.speechString),
            ["Remember this", "Read once"]
        )
    }

    func testSpeakServiceMemorizationLoopIgnoresCancelledReplacedUtterance() {
        let synthesizer = FakeSpeechSynthesizer()
        let service = SpeakService(synthesizer: synthesizer)

        service.speak(text: "Read once", language: "en-US")
        let replacedUtterance = synthesizer.spokenUtterances[0]

        service.speakMemorizationLoop(text: "Repeat this", language: "en-US")
        service.speechSynthesizer(AVSpeechSynthesizer(), didCancel: replacedUtterance)

        XCTAssertTrue(service.isMemorizationLoop)
        XCTAssertTrue(service.isSpeaking)
        XCTAssertEqual(
            synthesizer.spokenUtterances.map(\.speechString),
            ["Read once", "Repeat this"]
        )

        let loopUtterance = synthesizer.spokenUtterances[1]
        service.speechSynthesizer(AVSpeechSynthesizer(), didFinish: loopUtterance)

        XCTAssertTrue(service.isMemorizationLoop)
        XCTAssertTrue(service.isSpeaking)
        XCTAssertEqual(
            synthesizer.spokenUtterances.map(\.speechString),
            ["Read once", "Repeat this", "Repeat this"]
        )
    }
}
