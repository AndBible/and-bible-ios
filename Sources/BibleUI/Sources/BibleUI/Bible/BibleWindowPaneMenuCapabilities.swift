import BibleCore

/**
 Resolves pane-menu action visibility from Android page identity semantics.

 The SwiftUI pane can render before its `BibleReaderController` is registered with the window
 manager, but the `Window.pageManager` may already contain Android's persisted `general_book/Multi`
 identity. Keeping this resolver separate from the view lets tests cover that pre-registration state
 directly instead of relying on menu introspection.
 */
struct BibleWindowPaneMenuCapabilities {
    /// Whether the pane menu should expose a copy-reference action.
    let canCopyReference: Bool

    /// Whether the pane menu should expose synchronized-scroll controls.
    let canSyncWindow: Bool

    /**
     Builds menu capabilities for one pane.

     - Parameters:
       - window: Pane window whose persisted page state may already be available.
       - controller: Registered controller for the pane, if SwiftUI has wired it yet.
     - Side effects: None.
     - Failure modes: Missing controller state falls back to `PageManager` category/document fields.
     */
    init(window: Window, controller: BibleReaderController?) {
        if let controller {
            canCopyReference = !controller.isShowingAndroidMultiDocument
            canSyncWindow = controller.isCurrentPageSyncable
        } else {
            canCopyReference = false
            canSyncWindow = Self.pageManagerSyncable(window.pageManager)
        }
    }

    /**
     Resolves Android syncability from persisted PageManager state.

     Android marks general-book pages, including the synthetic `Multi` fake document, as non-syncable.
     EPUB content is represented by a separate iOS category but behaves like a non-syncable
     general-book page for this menu. Other categories keep sync controls until a controller can provide
     a more specific runtime answer.

     - Parameter pageManager: Persisted page manager for the pane, if one exists.
     - Returns: `true` when sync controls may be shown before controller registration.
     - Side effects: None.
     */
    private static func pageManagerSyncable(_ pageManager: PageManager?) -> Bool {
        guard let pageManager else { return true }
        return pageManager.currentCategoryName != DocumentCategory.generalBook.pageManagerKey
            && pageManager.currentCategoryName != DocumentCategory.epub.pageManagerKey
    }
}
