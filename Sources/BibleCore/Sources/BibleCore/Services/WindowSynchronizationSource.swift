// WindowSynchronizationSource.swift -- Cross-module synchronized-window source contract

import Foundation

/**
 Carries one pane's current verse in the source pane's own ordinal space.

 `WindowManager` forwards this payload through its existing synchronization callback. The reader
 shell then resolves `ordinal` back to a stable verse identity in the source controller before each
 target controller converts that identity into its own versification.
 */
public struct WindowSynchronizationPosition: Equatable, Sendable {
    /// Source-local SWORD/JSword ordinal used only to recover the source verse identity.
    public let ordinal: Int

    /// OSIS-style source key retained for the existing navigation fallback path.
    public let key: String

    /**
     Creates a source-local synchronization payload.

     - Parameters:
       - ordinal: Positive source-pane verse ordinal.
       - key: OSIS-style key such as `Gen.1.1`.
     - Side Effects: None.
     - Failure Modes: Validation belongs to the source provider; this value preserves its inputs.
     */
    public init(ordinal: Int, key: String) {
        self.ordinal = ordinal
        self.key = key
    }
}

/**
 Exposes the minimal reader-controller state needed for immediate sync-group realignment.

 BibleCore owns window transitions but cannot import BibleUI. Registered pane controllers conform
 to this protocol so `WindowManager.changeSyncGroup` can select Android's first visible, synchronized,
 verse-key peer and feed that peer through the established synchronized-reference callback.
 */
public protocol WindowSynchronizationSource: AnyObject {
    /// Whether the controller's currently displayed page can provide a verse-key sync source.
    var canProvideWindowSynchronizationPosition: Bool { get }

    /**
     Resolves the currently visible verse in this controller's local ordinal space.

     - Returns: A source-local ordinal and OSIS key, or `nil` when the current verse cannot be
       resolved authoritatively.
     - Side Effects: Implementations may temporarily move and restore a module cursor.
     - Failure Modes: Missing modules, unsupported versifications, and non-verse pages return `nil`.
     */
    func currentWindowSynchronizationPosition() -> WindowSynchronizationPosition?
}
