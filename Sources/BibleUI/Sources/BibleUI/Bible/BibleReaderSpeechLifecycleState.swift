// BibleReaderSpeechLifecycleState.swift -- reader speech setup lifecycle gate

/**
 Distinguishes the reader's one-time speech initialization from repeat destination reactivation.

 SwiftUI can fire the reader root's `onAppear` after every navigation pop while preserving the same
 `BibleReaderView` identity and `SpeakService`. This value records whether heavyweight restoration
 and callback binding have already run so navigation returns perform only lightweight work.

 The value has no external side effects and is deterministic under the reader's main-actor SwiftUI
 lifecycle. A recreated reader identity receives a fresh value and therefore performs setup once.
 */
struct BibleReaderSpeechLifecycleState {
    /// Whether this reader identity has already consumed its initial setup requirement.
    private(set) var didPerformInitialSetup = false

    /**
     Records one reader activation and reports whether heavyweight setup is required.

     - Returns: `true` for the first activation and `false` for every later activation.
     - Side effects: Sets `didPerformInitialSetup` on the first call only.
     - Failure modes: This synchronous state transition cannot fail.
     - Note: SwiftUI invokes the owning reader lifecycle on the main actor, so no locking is needed.
     */
    mutating func beginActivation() -> Bool {
        guard !didPerformInitialSetup else {
            return false
        }
        didPerformInitialSetup = true
        return true
    }
}
