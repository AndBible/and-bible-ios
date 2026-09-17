// WindowSynchronizationSource.swift -- Cross-module synchronized-window source contract

import Foundation

/**
 Carries one pane's current verse with the versification that owns its coordinates.

 The source resolves this immutable value before synchronization admission. `WindowManager` may
 debounce delivery, so consumers must not reconstruct the position later from mutable controller or
 module state. Targets map the typed source coordinate into their own active Bible versification.
 */
public struct WindowSynchronizationPosition: Equatable, Sendable {
    /// Versification that owns `osisBookId`, `chapter`, `verse`, and `sourceOrdinal`.
    public let sourceVersification: String

    /// OSIS book identifier in `sourceVersification`.
    public let osisBookId: String

    /// Chapter in `sourceVersification`, including `0` for a book introduction.
    public let chapter: Int

    /// Verse in `sourceVersification`, including `0` for an introduction.
    public let verse: Int

    /// Optional rendered source ordinal retained for feedback matching and diagnostics only.
    public let sourceOrdinal: Int?

    /// Optional rendered source key retained for feedback matching and diagnostics only.
    public let sourceKey: String?

    /// Whether the typed coordinate has the minimum shape required for synchronization admission.
    public var isStructurallyValid: Bool {
        !sourceVersification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !osisBookId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && chapter >= 0
            && verse >= 0
            && (sourceOrdinal.map { $0 > 0 } ?? true)
            && (sourceKey.map {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } ?? true)
    }

    /** Creates one immutable, source-owned synchronization coordinate. */
    public init(
        sourceVersification: String,
        osisBookId: String,
        chapter: Int,
        verse: Int,
        sourceOrdinal: Int? = nil,
        sourceKey: String? = nil
    ) {
        self.sourceVersification = sourceVersification
        self.osisBookId = osisBookId
        self.chapter = chapter
        self.verse = verse
        self.sourceOrdinal = sourceOrdinal
        self.sourceKey = sourceKey
    }
}


/**
 Carries one admitted typed position and the exact peers authorized to consume it.

 Targets are resolved by `WindowManager` from admission-time membership witnesses. Consumers must
 iterate `targets` directly rather than re-enumerating the current group, which could admit a pane
 that joined after this immutable position was captured.
 */
public struct WindowSynchronizationDelivery {
    public let position: WindowSynchronizationPosition
    public let targets: [Window]

    public init(position: WindowSynchronizationPosition, targets: [Window]) {
        self.position = position
        self.targets = targets
    }
}

/**
 Exposes the minimal reader-controller state needed for immediate sync-group realignment.

 BibleCore owns window transitions but cannot infer a page family's rendered coordinate domain.
 Registered pane controllers therefore return a fully resolved typed position. Bible, commentary,
 and My Notes providers each decide whether their accepted page state can authoritatively participate.
 */
public protocol WindowSynchronizationSource: AnyObject {
    /// Whether the controller's accepted page state can provide a typed verse-key sync source.
    var canProvideWindowSynchronizationPosition: Bool { get }

    /**
     Resolves the current authoritative verse in the accepted page state's source versification.

     - Returns: An immutable typed position, or `nil` when the page cannot resolve one authoritatively.
     - Side Effects: Implementations may temporarily move and restore a module cursor.
     - Failure Modes: Missing modules, unsupported versifications, and non-verse pages return `nil`.
     */
    func currentWindowSynchronizationPosition() -> WindowSynchronizationPosition?
}
