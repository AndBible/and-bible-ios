// Workspace.swift — Workspace domain model

import Foundation
import SwiftData

/// A workspace contains a set of windows displaying different Bible documents.
/// Users can switch between workspaces to maintain different study contexts.
@Model
public final class Workspace {
    /// UUID primary key matching Android's IdType.
    @Attribute(.unique) public var id: UUID

    /// User-visible workspace name.
    public var name: String

    /// Descriptive text for the workspace contents.
    public var contentsText: String?

    /// Display order among workspaces.
    public var orderNumber: Int

    /// Text display settings for this workspace (inherited by windows).
    public var textDisplaySettings: TextDisplaySettings?

    /// Workspace-level settings.
    public var workspaceSettings: WorkspaceSettings?

    /// Weight for unpinned windows layout.
    public var unPinnedWeight: Float?

    /// ID of the currently maximized window, if any.
    public var maximizedWindowId: UUID?

    /// ID of the primary target links window.
    public var primaryTargetLinksWindowId: UUID?

    /// Workspace accent color as ARGB integer.
    public var workspaceColor: Int?

    /// Windows belonging to this workspace.
    @Relationship(deleteRule: .cascade, inverse: \Window.workspace)
    public var windows: [Window]?

    public init(
        id: UUID = UUID(),
        name: String = "",
        orderNumber: Int = 0
    ) {
        self.id = id
        self.name = name
        self.orderNumber = orderNumber
    }
}

/// Workspace-level settings that apply to all windows unless overridden.
public struct WorkspaceSettings: Codable, Sendable {
    public var enableTiltToScroll: Bool
    public var enableReverseSplitMode: Bool
    public var autoPin: Bool
    public var recentLabels: [RecentLabel]
    public var autoAssignLabels: Set<UUID>
    public var autoAssignPrimaryLabel: UUID?
    public var studyPadCursors: [UUID: Int]
    public var hideCompareDocuments: Set<String>
    public var limitAmbiguousModalSize: Bool

    public init(
        enableTiltToScroll: Bool = false,
        enableReverseSplitMode: Bool = false,
        autoPin: Bool = false,
        recentLabels: [RecentLabel] = [],
        autoAssignLabels: Set<UUID> = [],
        autoAssignPrimaryLabel: UUID? = nil,
        studyPadCursors: [UUID: Int] = [:],
        hideCompareDocuments: Set<String> = [],
        limitAmbiguousModalSize: Bool = false
    ) {
        self.enableTiltToScroll = enableTiltToScroll
        self.enableReverseSplitMode = enableReverseSplitMode
        self.autoPin = autoPin
        self.recentLabels = recentLabels
        self.autoAssignLabels = autoAssignLabels
        self.autoAssignPrimaryLabel = autoAssignPrimaryLabel
        self.studyPadCursors = studyPadCursors
        self.hideCompareDocuments = hideCompareDocuments
        self.limitAmbiguousModalSize = limitAmbiguousModalSize
    }
}

/// A recently-used label with timestamp for sorting.
public struct RecentLabel: Codable, Sendable {
    public var labelId: UUID
    public var lastAccess: Date

    public init(labelId: UUID, lastAccess: Date = Date()) {
        self.labelId = labelId
        self.lastAccess = lastAccess
    }
}

/// Text display settings with optional values for inheritance chain.
/// When a value is nil, it inherits from the parent level:
/// Window → Workspace → App defaults.
public struct TextDisplaySettings: Codable, Sendable, Equatable {
    public var fontSize: Int?
    public var fontFamily: String?
    public var lineSpacing: Int?
    public var marginLeft: Int?
    public var marginRight: Int?
    public var maxWidth: Int?
    public var topMargin: Int?
    public var strongsMode: Int?
    public var showMorphology: Bool?
    public var showFootNotes: Bool?
    public var showFootNotesInline: Bool?
    public var expandXrefs: Bool?
    public var showXrefs: Bool?
    public var showRedLetters: Bool?
    public var showSectionTitles: Bool?
    public var showVerseNumbers: Bool?
    public var showVersePerLine: Bool?
    public var showBookmarks: Bool?
    public var showMyNotes: Bool?
    public var justifyText: Bool?
    public var hyphenation: Bool?
    public var showPageNumber: Bool?
    public var dayTextColor: Int?
    public var dayBackground: Int?
    public var dayNoise: Int?
    public var nightTextColor: Int?
    public var nightBackground: Int?
    public var nightNoise: Int?
    public var bookmarksHideLabels: [UUID]?
    public var enableVerseSelection: Bool?

    public init() {}

    /// Resolve the actual value by checking this level, then fallback.
    /// Used for the Window → Workspace → App defaults inheritance chain.
    public static func resolved<T>(_ keyPath: KeyPath<TextDisplaySettings, T?>,
                                   window: TextDisplaySettings?,
                                   workspace: TextDisplaySettings?,
                                   defaults: TextDisplaySettings) -> T? {
        window?[keyPath: keyPath] ?? workspace?[keyPath: keyPath] ?? defaults[keyPath: keyPath]
    }

    /// App-level default settings (used when window/workspace values are nil).
    public static let appDefaults: TextDisplaySettings = {
        var s = TextDisplaySettings()
        s.fontSize = 18
        s.fontFamily = "sans-serif"
        s.lineSpacing = 10
        s.marginLeft = 2
        s.marginRight = 2
        s.maxWidth = 600
        s.topMargin = 0
        s.strongsMode = 2
        s.showMorphology = false
        s.showFootNotes = false
        s.showFootNotesInline = false
        s.expandXrefs = false
        s.showXrefs = false
        s.showRedLetters = true
        s.showSectionTitles = true
        s.showVerseNumbers = true
        s.showVersePerLine = false
        s.showBookmarks = true
        s.showMyNotes = true
        s.justifyText = false
        s.hyphenation = true
        s.showPageNumber = false
        // Colors: ARGB signed Int32 format (Vue.js convention)
        // -1 = 0xFFFFFFFF (white), -16777216 = 0xFF000000 (black)
        s.dayTextColor = -16777216     // black
        s.dayBackground = -1           // white
        s.dayNoise = 0
        s.nightTextColor = -1          // white
        s.nightBackground = -16777216  // black
        s.nightNoise = 0
        s.bookmarksHideLabels = []
        s.enableVerseSelection = true
        return s
    }()

    /// Resolve all fields against the inheritance chain, returning a fully populated settings.
    public static func fullyResolved(
        window: TextDisplaySettings?,
        workspace: TextDisplaySettings?
    ) -> TextDisplaySettings {
        let d = appDefaults
        var r = TextDisplaySettings()
        r.fontSize = window?.fontSize ?? workspace?.fontSize ?? d.fontSize
        r.fontFamily = window?.fontFamily ?? workspace?.fontFamily ?? d.fontFamily
        r.lineSpacing = window?.lineSpacing ?? workspace?.lineSpacing ?? d.lineSpacing
        r.marginLeft = window?.marginLeft ?? workspace?.marginLeft ?? d.marginLeft
        r.marginRight = window?.marginRight ?? workspace?.marginRight ?? d.marginRight
        r.maxWidth = window?.maxWidth ?? workspace?.maxWidth ?? d.maxWidth
        r.topMargin = window?.topMargin ?? workspace?.topMargin ?? d.topMargin
        r.strongsMode = window?.strongsMode ?? workspace?.strongsMode ?? d.strongsMode
        r.showMorphology = window?.showMorphology ?? workspace?.showMorphology ?? d.showMorphology
        r.showFootNotes = window?.showFootNotes ?? workspace?.showFootNotes ?? d.showFootNotes
        r.showFootNotesInline = window?.showFootNotesInline ?? workspace?.showFootNotesInline ?? d.showFootNotesInline
        r.expandXrefs = window?.expandXrefs ?? workspace?.expandXrefs ?? d.expandXrefs
        r.showXrefs = window?.showXrefs ?? workspace?.showXrefs ?? d.showXrefs
        r.showRedLetters = window?.showRedLetters ?? workspace?.showRedLetters ?? d.showRedLetters
        r.showSectionTitles = window?.showSectionTitles ?? workspace?.showSectionTitles ?? d.showSectionTitles
        r.showVerseNumbers = window?.showVerseNumbers ?? workspace?.showVerseNumbers ?? d.showVerseNumbers
        r.showVersePerLine = window?.showVersePerLine ?? workspace?.showVersePerLine ?? d.showVersePerLine
        r.showBookmarks = window?.showBookmarks ?? workspace?.showBookmarks ?? d.showBookmarks
        r.showMyNotes = window?.showMyNotes ?? workspace?.showMyNotes ?? d.showMyNotes
        r.justifyText = window?.justifyText ?? workspace?.justifyText ?? d.justifyText
        r.hyphenation = window?.hyphenation ?? workspace?.hyphenation ?? d.hyphenation
        r.showPageNumber = window?.showPageNumber ?? workspace?.showPageNumber ?? d.showPageNumber
        r.dayTextColor = window?.dayTextColor ?? workspace?.dayTextColor ?? d.dayTextColor
        r.dayBackground = window?.dayBackground ?? workspace?.dayBackground ?? d.dayBackground
        r.dayNoise = window?.dayNoise ?? workspace?.dayNoise ?? d.dayNoise
        r.nightTextColor = window?.nightTextColor ?? workspace?.nightTextColor ?? d.nightTextColor
        r.nightBackground = window?.nightBackground ?? workspace?.nightBackground ?? d.nightBackground
        r.nightNoise = window?.nightNoise ?? workspace?.nightNoise ?? d.nightNoise
        r.bookmarksHideLabels = window?.bookmarksHideLabels ?? workspace?.bookmarksHideLabels ?? d.bookmarksHideLabels
        r.enableVerseSelection = window?.enableVerseSelection ?? workspace?.enableVerseSelection ?? d.enableVerseSelection
        return r
    }
}
