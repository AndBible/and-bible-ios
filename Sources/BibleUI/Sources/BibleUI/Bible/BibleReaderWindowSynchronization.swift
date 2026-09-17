import BibleCore

/** Installs the typed synchronized-window delivery boundary for reader pane controllers. */
@MainActor
enum BibleReaderWindowSynchronization {
    /**
     Binds one window manager to exact registered reader targets.

     `WindowManager` resolves source identity, immutable coordinates, and admitted recipients before
     invoking this callback. The installer consumes only that delivery. It never reconstructs the
     source coordinate from mutable controller state or re-enumerates current group membership.

     - Parameter windowManager: Manager whose synchronized reader delivery callback is replaced.
     - Side Effects: Replaces `onSyncVerseChanged`; each admitted exact registered reader target may
       update its semantic position, persistence, and rendered document through its typed mapper.
     - Failure Modes: Released managers, stale target objects, replaced registrations, non-reader
       controllers, and target-local mapping failures leave the affected target unchanged.
     - Concurrency: Main-actor isolated with reader controller and WindowManager lifecycle ownership.
     */
    static func install(on windowManager: WindowManager) {
        windowManager.onSyncVerseChanged = { [weak windowManager] _, delivery in
            guard let windowManager else { return }
            for target in delivery.targets {
                guard let controller = windowManager.registeredController(for: target)
                    as? BibleReaderController else { continue }
                controller.applyWindowSynchronizationPosition(delivery.position)
            }
        }
    }
}
