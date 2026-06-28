import AVFoundation
import SwiftData
@testable import BibleCore

/**
 Test double for `SpeakService` package tests.

 The fake records utterances and transport controls without invoking the platform speech engine,
 allowing `SpeakService` state transitions to run deterministically in the BibleCore package lane.
 */
final class FakeSpeechSynthesizer: SpeechSynthesizing {
    weak var delegate: AVSpeechSynthesizerDelegate?

    private(set) var spokenUtterances: [AVSpeechUtterance] = []
    private(set) var stopBoundaries: [AVSpeechBoundary] = []
    private(set) var pauseBoundaries: [AVSpeechBoundary] = []
    private(set) var continueCount = 0

    /**
     Records one utterance requested by the service.

     - Parameter utterance: Speech utterance supplied by `SpeakService`.
     - Side effects: Appends the utterance to `spokenUtterances`.
     - Failure modes: This fake cannot fail.
     */
    func speak(_ utterance: AVSpeechUtterance) {
        spokenUtterances.append(utterance)
    }

    /**
     Records a stop request.

     - Parameter boundary: Boundary passed through from `SpeakService.stop()`.
     - Returns: Always `true`, matching a successful platform stop request.
     - Side effects: Appends the boundary to `stopBoundaries`.
     - Failure modes: This fake cannot fail.
     */
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        stopBoundaries.append(boundary)
        return true
    }

    /**
     Records a pause request.

     - Parameter boundary: Boundary passed through from `SpeakService.pause()`.
     - Returns: Always `true`, matching a successful platform pause request.
     - Side effects: Appends the boundary to `pauseBoundaries`.
     - Failure modes: This fake cannot fail.
     */
    func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        pauseBoundaries.append(boundary)
        return true
    }

    /**
     Records a resume request.

     - Returns: Always `true`, matching a successful platform continue request.
     - Side effects: Increments `continueCount`.
     - Failure modes: This fake cannot fail.
     */
    func continueSpeaking() -> Bool {
        continueCount += 1
        return true
    }
}

/**
 Creates an in-memory settings store for BibleCore package tests.

 - Returns: A `SettingsStore` backed by an in-memory SwiftData container containing only `Setting`.
 - Side effects: Allocates a transient model container for the test process.
 - Failure modes: Throws if SwiftData cannot create the in-memory container.
 */
func makeInMemorySettingsStore() throws -> SettingsStore {
    SettingsStore(modelContext: ModelContext(try makeInMemorySettingsContainer()))
}

/**
 Creates an in-memory SwiftData settings container.

 - Returns: A transient `ModelContainer` with the `Setting` schema.
 - Side effects: Allocates in-process SwiftData storage.
 - Failure modes: Throws if SwiftData cannot initialize the model container.
 */
func makeInMemorySettingsContainer() throws -> ModelContainer {
    let schema = Schema([Setting.self])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [configuration])
}
