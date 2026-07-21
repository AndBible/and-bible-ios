// Window.swift -- Window and PageManager domain models

import Foundation
import SwiftData

/**
 Persists one visible study pane within a workspace.

 A `Window` owns a `PageManager` for its current document state and a list of `HistoryItem`
 records for back/forward navigation. Deleting the window cascades to both relationships.
 */
@Model
public final class Window {
    /// Stable identifier used for persistence and cross-entity references.
    public var id: UUID = UUID()

    /// Parent workspace that owns this window.
    public var workspace: Workspace?

    /// Enables synchronized navigation and scroll behavior with peer windows in the same group.
    public var isSynchronized: Bool = true

    /// Keeps the window fixed in the layout when the user switches other panes or documents.
    public var isPinMode: Bool = true

    /// Marks this window as the dedicated links/cross-reference destination.
    public var isLinksWindow: Bool = false

    /// Zero-based display order within the parent workspace.
    public var orderNumber: Int = 0

    /// Optional explicit target window for link routing inside the workspace.
    public var targetLinksWindowId: UUID?

    /// Integer sync group identifier used by synchronized scrolling/navigation features.
    public var syncGroup: Int = 0

    /// Relative split-view weight used to size the pane compared with sibling windows.
    public var layoutWeight: Float = 1.0

    /// Serialized layout mode string consumed by the workspace layout engine.
    public var layoutState: String = "split"

    /// 1:1 page-state record for the current document/category selections in this window.
    @Relationship(deleteRule: .cascade, inverse: \PageManager.window)
    public var pageManager: PageManager?

    /// Back/forward navigation history owned by this window.
    @Relationship(deleteRule: .cascade, inverse: \HistoryItem.window)
    public var historyItems: [HistoryItem]?

    /**
     Creates a persisted window record.

     - Parameters:
       - id: Stable identifier for persistence and related `PageManager` creation.
       - isSynchronized: Whether the pane participates in sync-group behavior.
       - isPinMode: Whether the pane remains fixed while other panes change.
       - isLinksWindow: Whether the pane is reserved for link navigation targets.
       - orderNumber: Zero-based order within the workspace.
       - syncGroup: Sync-group identifier shared with peer windows.
       - layoutWeight: Relative split ratio used by the layout engine.
       - layoutState: Serialized layout mode string.
     */
    public init(
        id: UUID = UUID(),
        isSynchronized: Bool = true,
        isPinMode: Bool = true,
        isLinksWindow: Bool = false,
        orderNumber: Int = 0,
        syncGroup: Int = 0,
        layoutWeight: Float = 1.0,
        layoutState: String = "split"
    ) {
        self.id = id
        self.isSynchronized = isSynchronized
        self.isPinMode = isPinMode
        self.isLinksWindow = isLinksWindow
        self.orderNumber = orderNumber
        self.syncGroup = syncGroup
        self.layoutWeight = layoutWeight
        self.layoutState = layoutState
    }

    /**
     Resolves the pin state Android exposes after applying workspace auto-pin behavior.

     - Parameter autoPin: Current workspace auto-pin setting.
     - Returns: `autoPin` for links windows, `true` for normal windows while auto-pin is enabled,
       and the persisted raw pin value otherwise.
     - Side Effects: None.
     - Failure Modes: None.
     - Note: `isPinMode` remains the raw persisted value so disabling auto-pin restores the user's
       prior per-window choices.
     */
    public func effectivePinMode(autoPin: Bool) -> Bool {
        if isLinksWindow {
            return autoPin
        }
        return autoPin || isPinMode
    }

    /**
     Returns the Android-compatible pin state for this window's current workspace.

     - Returns: Effective pin mode derived from the owning workspace's auto-pin setting.
     - Side Effects: None.
     - Failure Modes: A detached window falls back to auto-pin disabled and therefore uses its raw
       pin value unless it is a links window.
     */
    public var isEffectivelyPinned: Bool {
        effectivePinMode(autoPin: workspace?.workspaceSettings?.autoPin ?? false)
    }
}

/**
 Persists category-specific navigation state for a window.

 The page manager stores a parallel set of document and location fields for each
 `DocumentCategory` so the app can switch categories without losing the last position in each
 one. The record intentionally shares the same identifier as its owning `Window`.
 */
@Model
public final class PageManager {
    /// Stable identifier that mirrors the owning window's identifier for the intended 1:1 link.
    public var id: UUID = UUID()

    /// Back-reference to the owning window.
    public var window: Window?

    /// Selected Bible module initials for the Bible category.
    public var bibleDocument: String?

    /// Persisted versification name for the Bible position.
    public var bibleVersification: String?

    /// Book index for the persisted Bible position.
    public var bibleBibleBook: Int?

    /// Chapter number for the persisted Bible position.
    public var bibleChapterNo: Int?

    /// Verse number for the persisted Bible position.
    public var bibleVerseNo: Int?

    /// Selected commentary module initials for the commentary category.
    public var commentaryDocument: String?

    /// Commentary anchor ordinal used to reopen commentary near the prior verse.
    public var commentaryAnchorOrdinal: Int?

    /// Selected dictionary module initials for the dictionary category.
    public var dictionaryDocument: String?

    /// Dictionary key or headword for the persisted dictionary position.
    public var dictionaryKey: String?

    /// Selected general-book module initials for the general-book category.
    public var generalBookDocument: String?

    /// General-book key used to reopen the prior location.
    public var generalBookKey: String?

    /// Selected map module initials for the map category.
    public var mapDocument: String?

    /// Map entry key used to restore the prior position.
    public var mapKey: String?

    /// EPUB identifier used to reopen the selected book file.
    public var epubIdentifier: String?

    /// EPUB chapter/resource href used to restore the current section.
    public var epubHref: String?

    /// Raw category name that identifies which of the persisted category states is active.
    public var currentCategoryName: String = "bible"

    /// Window-scoped text display overrides applied before workspace/app defaults.
    public var textDisplaySettings: TextDisplaySettings?

    /// Serialized JavaScript/UI state used to restore in-webview scroll and expansion state.
    public var jsState: String?

    /**
     Creates a page manager for a window.

     - Parameters:
       - id: Identifier that should match the owning `Window`.
       - currentCategoryName: Raw category name that should be active when the window opens.
     - Note: Category-specific fields are left nil until the user first visits that category.
     */
    public init(
        id: UUID = UUID(),
        currentCategoryName: String = "bible"
    ) {
        self.id = id
        self.currentCategoryName = currentCategoryName
    }
}

/**
 Persists one back/forward navigation checkpoint for a window.

 History rows are append-only snapshots of the document and key the user visited. They are
 owned by a `Window` and cascade-delete with it.
 */
@Model
public final class HistoryItem {
    /// Unique identifier for the navigation snapshot.
    public var id: UUID = UUID()

    /// Owning window that uses this row for back/forward navigation.
    public var window: Window?

    /// Timestamp captured when the history row was recorded.
    public var createdAt: Date = Date()

    /// Module initials that were active at this history checkpoint.
    public var document: String = ""

    /// Persisted document key or reference for the checkpoint.
    public var key: String = ""

    /// Optional anchor ordinal used to restore scroll position more precisely.
    public var anchorOrdinal: Int?

    /**
     Creates a window history snapshot.

     - Parameters:
       - id: Stable identifier for the history row.
       - createdAt: Timestamp for insertion ordering.
       - document: Module initials active at the checkpoint.
       - key: Persisted document key or reference.
     */
    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        document: String = "",
        key: String = ""
    ) {
        self.id = id
        self.createdAt = createdAt
        self.document = document
        self.key = key
    }
}
