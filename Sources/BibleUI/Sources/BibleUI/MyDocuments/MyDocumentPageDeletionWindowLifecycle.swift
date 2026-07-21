// MyDocumentPageDeletionWindowLifecycle.swift -- active AI page window ownership

import BibleCore

/**
 Describes how a reader should leave an AI My Documents page after that page is deleted.

 Android closes a removable window and returns only its sole non-removable window to the selected
 Bible. The resolution is explicit so `BibleReaderController` does not infer workspace ownership
 from reader-local state.
 */
enum MyDocumentPageDeletionResolution: Equatable {
    /// The owning window was removed, so the deleted reader must not emit replacement content.
    case paneClosed

    /// The owning window cannot be removed and must return to its selected Bible.
    case showBible
}

/**
 Applies Android's removable-window rule after an active AI My Documents page is deleted.

 The lifecycle uses `WindowManager.windowsInPersistedOrder`, matching Android's
 `windowRepository.sortedWindows` check rather than the currently visible subset. It delegates the
 actual mutation to `WindowManager.removeWindow` so controller registration, active-window fallback,
 layout normalization, and persistence remain manager-owned.

 - Side effects: May remove `window` and select a surviving window through `WindowManager`.
 - Failure modes: Missing/last windows resolve to `.showBible`; a no-op removal is detected and also
   resolves to `.showBible` so the caller never leaves a deleted document visible.
 - Note: Callers invoke this synchronously from the reader bridge's main-thread deletion action.
 */
struct MyDocumentPageDeletionWindowLifecycle {
    /**
     Closes a removable window or requests Bible fallback for the sole surviving window.

     - Parameters:
       - window: Pane whose active AI My Documents page was deleted successfully.
       - windowManager: Workspace owner responsible for persisted window lifecycle.
     - Returns: `.paneClosed` only when `window` is no longer in the persisted workspace.
     - Side effects: Calls `WindowManager.removeWindow` when more than one persisted window exists.
     - Failure modes: Foreign windows, races, and the last window return `.showBible`.
     */
    static func resolve(
        window: BibleCore.Window,
        windowManager: WindowManager
    ) -> MyDocumentPageDeletionResolution {
        guard windowManager.windowsInPersistedOrder.count > 1 else {
            return .showBible
        }

        windowManager.removeWindow(window)
        let windowStillExists = windowManager.windowsInPersistedOrder.contains { $0.id == window.id }
        return windowStillExists ? .showBible : .paneClosed
    }
}
