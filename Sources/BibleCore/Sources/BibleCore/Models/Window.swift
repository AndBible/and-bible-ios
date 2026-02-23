// Window.swift — Window and PageManager domain models

import Foundation
import SwiftData

/// A window displays a single document (Bible, commentary, dictionary, etc.)
/// within a workspace. Multiple windows can be shown side-by-side.
@Model
public final class Window {
    /// UUID primary key.
    @Attribute(.unique) public var id: UUID

    /// The workspace this window belongs to.
    public var workspace: Workspace?

    /// Whether this window synchronizes scrolling with other windows.
    public var isSynchronized: Bool

    /// Whether this window is in pin mode (stays visible when switching).
    public var isPinMode: Bool

    /// Whether this is a links/cross-reference window.
    public var isLinksWindow: Bool

    /// Display order within the workspace.
    public var orderNumber: Int

    /// Target window ID for links navigation.
    public var targetLinksWindowId: UUID?

    /// Sync group number (windows in the same group scroll together).
    public var syncGroup: Int

    /// Layout weight for proportional sizing.
    public var layoutWeight: Float

    /// Layout state string.
    public var layoutState: String

    /// The page manager tracking this window's current document/position.
    @Relationship(deleteRule: .cascade, inverse: \PageManager.window)
    public var pageManager: PageManager?

    /// Navigation history for this window.
    @Relationship(deleteRule: .cascade, inverse: \HistoryItem.window)
    public var historyItems: [HistoryItem]?

    public init(
        id: UUID = UUID(),
        isSynchronized: Bool = true,
        isPinMode: Bool = false,
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
}

/// Tracks the current document and position for each document type in a window.
@Model
public final class PageManager {
    /// The window this page manager belongs to (same ID, 1:1 relationship).
    @Attribute(.unique) public var id: UUID

    /// Parent window.
    public var window: Window?

    /// Current Bible page state.
    public var bibleDocument: String?
    public var bibleVersification: String?
    public var bibleBibleBook: Int?
    public var bibleChapterNo: Int?
    public var bibleVerseNo: Int?

    /// Current commentary page state.
    public var commentaryDocument: String?
    public var commentaryAnchorOrdinal: Int?

    /// Current dictionary page state.
    public var dictionaryDocument: String?
    public var dictionaryKey: String?

    /// Current general book page state.
    public var generalBookDocument: String?
    public var generalBookKey: String?

    /// Current map page state.
    public var mapDocument: String?
    public var mapKey: String?

    /// Current EPUB page state.
    public var epubIdentifier: String?
    public var epubHref: String?

    /// The currently active document category.
    public var currentCategoryName: String

    /// Window-specific text display settings.
    public var textDisplaySettings: TextDisplaySettings?

    /// Saved JavaScript state for restoring WebView scroll position.
    public var jsState: String?

    public init(
        id: UUID = UUID(),
        currentCategoryName: String = "bible"
    ) {
        self.id = id
        self.currentCategoryName = currentCategoryName
    }
}

/// A navigation history entry for back/forward support.
@Model
public final class HistoryItem {
    /// Auto-generated primary key.
    public var id: UUID

    /// The window this history entry belongs to.
    public var window: Window?

    /// When this history entry was created.
    public var createdAt: Date

    /// The document initials at this history point.
    public var document: String

    /// The document key (verse reference, etc.).
    public var key: String

    /// Scroll position ordinal.
    public var anchorOrdinal: Int?

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
