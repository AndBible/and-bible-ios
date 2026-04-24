// Workspace.swift -- Workspace domain model

import Foundation
import SwiftData

/**
 Persists one named study workspace and the windows it contains.

 A workspace groups multiple `Window` panes, carries workspace-wide display/settings
 defaults, and stores layout-level metadata such as the maximized pane and target links
 window. Deleting a workspace cascades to its windows and their owned state.
 */
@Model
public final class Workspace {
    /// Unique identifier mirrored from Android's workspace IdType contract.
    @Attribute(.unique) public var id: UUID

    /// User-visible workspace name shown in workspace pickers and headers.
    public var name: String

    /// Optional summary text describing the workspace contents for list UI.
    public var contentsText: String?

    /// Zero-based display order among all persisted workspaces.
    public var orderNumber: Int

    /// Workspace-scoped text display overrides inherited by windows that do not override them.
    public var textDisplaySettings: TextDisplaySettings?

    /// Workspace-scoped behavioral settings shared by the windows in this workspace.
    public var workspaceSettings: WorkspaceSettings?

    /// Cached layout weight reserved for unpinned windows when split layouts are recomputed.
    public var unPinnedWeight: Float?

    /// Identifier of the currently maximized window, if one pane is expanded.
    public var maximizedWindowId: UUID?

    /// Identifier of the primary links target window for cross-reference routing.
    public var primaryTargetLinksWindowId: UUID?

    /// Optional signed ARGB accent color associated with the workspace.
    public var workspaceColor: Int?

    /// Child windows owned by this workspace and cascade-deleted with it.
    @Relationship(deleteRule: .cascade, inverse: \Window.workspace)
    public var windows: [Window]?

    /**
     Creates a workspace shell.

     - Parameters:
       - id: Stable identifier for persistence and cross-entity references.
       - name: User-visible workspace name.
       - orderNumber: Zero-based workspace order in the workspace list.
     - Note: Related windows and optional settings are attached after insertion.
     */
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

/**
 Stores workspace-scoped behavioral settings that are not tied to a single window.

 These values are serialized inside `Workspace` and read by workspace management, StudyPad,
 and compare-mode UI. The struct has no side effects on its own; persistence occurs when the
 owning `Workspace` is saved.
 */
public struct WorkspaceSettings: Codable, Sendable {
    /// Enables tilt-to-scroll behavior for windows in this workspace when supported.
    public var enableTiltToScroll: Bool

    /// Reverses split ordering semantics for workspace layouts.
    public var enableReverseSplitMode: Bool

    /// Automatically pins new or updated windows according to workspace behavior rules.
    public var autoPin: Bool

    /// Most recently used labels, ordered by access time for quick-pick UI.
    public var recentLabels: [RecentLabel]

    /// Labels that should be auto-assigned to newly created bookmarks in this workspace.
    public var autoAssignLabels: Set<UUID>

    /// Optional label that should become the primary label on new bookmarks.
    public var autoAssignPrimaryLabel: UUID?

    /// StudyPad cursor positions keyed by label identifier.
    public var studyPadCursors: [UUID: Int]

    /// Module initials hidden from compare-document pickers in this workspace.
    public var hideCompareDocuments: Set<String>

    /// Reduces modal size for ambiguous compare/document chooser flows.
    public var limitAmbiguousModalSize: Bool

    /**
     Creates workspace-scoped settings.

     - Parameters:
       - enableTiltToScroll: Whether tilt-to-scroll is enabled for the workspace.
       - enableReverseSplitMode: Whether split ordering is reversed.
       - autoPin: Whether windows should auto-pin by default.
       - recentLabels: Recently used labels for quick selection UI.
       - autoAssignLabels: Labels automatically assigned to new bookmarks.
       - autoAssignPrimaryLabel: Primary label automatically assigned to new bookmarks.
       - studyPadCursors: Stored StudyPad cursor positions keyed by label id.
       - hideCompareDocuments: Module initials hidden from compare pickers.
       - limitAmbiguousModalSize: Whether ambiguous chooser modals should be size-limited.
     */
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

/**
 Records one recent-label access event for workspace quick-pick ordering.

 The value type is embedded inside `WorkspaceSettings`, so changes are persisted only when the
 owning workspace is saved.
 */
public struct RecentLabel: Codable, Sendable {
    /// Identifier of the label that was recently used.
    public var labelId: UUID

    /// Timestamp of the last observed use for ordering recent-label lists.
    public var lastAccess: Date

    /**
     Creates a recent-label record.

     - Parameters:
       - labelId: Identifier of the label that was used.
       - lastAccess: Timestamp of the use event.
     */
    public init(labelId: UUID, lastAccess: Date = Date()) {
        self.labelId = labelId
        self.lastAccess = lastAccess
    }
}

/**
 Stores optional text-display overrides used by the app's inheritance chain.

 Each property is optional by design. `nil` means "inherit from the next level up" using the
 chain `window -> workspace -> global -> app defaults`. The struct itself performs no persistence or UI
 updates; those side effects occur when a containing `Workspace` or `PageManager` is saved and
 the resolved values are pushed into native/web readers.
 */
public struct TextDisplaySettings: Codable, Sendable, Equatable {
    /// Font size in points for the rendered document text.
    public var fontSize: Int?

    /// Font family identifier understood by the renderer.
    public var fontFamily: String?

    /// Additional line spacing applied by the renderer.
    public var lineSpacing: Int?

    /// Left margin in renderer-specific units.
    public var marginLeft: Int?

    /// Right margin in renderer-specific units.
    public var marginRight: Int?

    /// Maximum readable content width for centered layouts.
    public var maxWidth: Int?

    /// Extra top margin applied above the document body.
    public var topMargin: Int?

    /// Strong's display mode integer consumed by the Vue/native reading layer.
    public var strongsMode: Int?

    /// Whether morphology data is shown when available.
    public var showMorphology: Bool?

    /// Whether footnotes are rendered at all.
    public var showFootNotes: Bool?

    /// Whether footnotes are expanded inline instead of using modal presentation.
    public var showFootNotesInline: Bool?

    /// Whether cross-references are expanded inline.
    public var expandXrefs: Bool?

    /// Whether cross-reference markers are shown.
    public var showXrefs: Bool?

    /// Whether words of Christ are styled using red-letter treatment.
    public var showRedLetters: Bool?

    /// Whether section titles are rendered.
    public var showSectionTitles: Bool?

    /// Whether verse numbers are rendered in the reading view.
    public var showVerseNumbers: Bool?

    /// Whether each verse begins on a new line.
    public var showVersePerLine: Bool?

    /// Whether bookmark highlights and indicators are rendered.
    public var showBookmarks: Bool?

    /// Whether the user's own notes are rendered inline.
    public var showMyNotes: Bool?

    /// Whether paragraph text is justified.
    public var justifyText: Bool?

    /// Whether hyphenation is enabled when supported by the renderer.
    public var hyphenation: Bool?

    /// Whether page numbers are shown in paged reading modes.
    public var showPageNumber: Bool?

    /// Signed ARGB text color used in day mode.
    public var dayTextColor: Int?

    /// Signed ARGB background color used in day mode.
    public var dayBackground: Int?

    /// Day-mode noise/texture intensity value consumed by the renderer.
    public var dayNoise: Int?

    /// Signed ARGB text color used in night mode.
    public var nightTextColor: Int?

    /// Signed ARGB background color used in night mode.
    public var nightBackground: Int?

    /// Night-mode noise/texture intensity value consumed by the renderer.
    public var nightNoise: Int?

    /// Label identifiers whose bookmark visuals should be hidden in the renderer.
    public var bookmarksHideLabels: [UUID]?

    /// Whether verse-selection gestures and menus are enabled.
    public var enableVerseSelection: Bool?

    /// Creates an empty override set where every value inherits from a parent/default source.
    public init() {}

    /**
     Resolves one optional setting through the inheritance chain.

     - Parameters:
       - keyPath: Property to resolve.
       - window: Window-level overrides, checked first.
       - workspace: Workspace-level overrides, checked second.
       - global: App-level overrides, checked third.
       - defaults: Fully populated app defaults, checked last.
     - Returns: The first non-nil value in the chain, or `nil` when the default is also nil.
     - Note: This helper is pure and has no persistence or rendering side effects.
     */
    public static func resolved<T>(
        _ keyPath: KeyPath<TextDisplaySettings, T?>,
        window: TextDisplaySettings?,
        workspace: TextDisplaySettings?,
        global: TextDisplaySettings? = nil,
        defaults: TextDisplaySettings
    ) -> T? {
        window?[keyPath: keyPath] ?? workspace?[keyPath: keyPath] ?? global?[keyPath: keyPath] ?? defaults[keyPath: keyPath]
    }

    /**
     Provides the fully populated application-level fallback settings.

     The values are encoded using the same conventions expected by the Vue reader and the
     Android-compatible settings model. Accessing this constant does not read or write user
     defaults; it is an in-memory baseline used by resolution helpers.
     */
    public static let appDefaults: TextDisplaySettings = {
        var s = TextDisplaySettings()
        s.fontSize = 18
        s.fontFamily = "sans-serif"
        s.lineSpacing = 10
        s.marginLeft = 2
        s.marginRight = 2
        s.maxWidth = 600
        s.topMargin = 0
        s.strongsMode = 0
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
        // Colors use signed ARGB Int32 values shared with the Vue.js renderer.
        s.dayTextColor = -16777216
        s.dayBackground = -1
        s.dayNoise = 0
        s.nightTextColor = -1
        s.nightBackground = -16777216
        s.nightNoise = 0
        s.bookmarksHideLabels = []
        s.enableVerseSelection = true
        return s
    }()

    internal struct FieldDescriptor {
        let changed: (TextDisplaySettings, TextDisplaySettings) -> Bool
        let clearIfMatchingParent: (inout TextDisplaySettings, TextDisplaySettings) -> Bool
    }

    private static func field<T: Equatable>(
        _ keyPath: WritableKeyPath<TextDisplaySettings, T?>
    ) -> FieldDescriptor {
        FieldDescriptor(
            changed: { previous, current in
                previous[keyPath: keyPath] != current[keyPath: keyPath]
            },
            clearIfMatchingParent: { child, parent in
                guard let childValue = child[keyPath: keyPath],
                      let parentValue = parent[keyPath: keyPath],
                      childValue == parentValue else {
                    return false
                }
                child[keyPath: keyPath] = nil
                return true
            }
        )
    }

    internal static let trackedFields: [FieldDescriptor] = [
        field(\.fontSize),
        field(\.fontFamily),
        field(\.lineSpacing),
        field(\.marginLeft),
        field(\.marginRight),
        field(\.maxWidth),
        field(\.topMargin),
        field(\.strongsMode),
        field(\.showMorphology),
        field(\.showFootNotes),
        field(\.showFootNotesInline),
        field(\.expandXrefs),
        field(\.showXrefs),
        field(\.showRedLetters),
        field(\.showSectionTitles),
        field(\.showVerseNumbers),
        field(\.showVersePerLine),
        field(\.showBookmarks),
        field(\.showMyNotes),
        field(\.justifyText),
        field(\.hyphenation),
        field(\.showPageNumber),
        field(\.dayTextColor),
        field(\.dayBackground),
        field(\.dayNoise),
        field(\.nightTextColor),
        field(\.nightBackground),
        field(\.nightNoise),
        field(\.bookmarksHideLabels),
        field(\.enableVerseSelection),
    ]

    internal static func changedFields(
        from previous: TextDisplaySettings,
        to current: TextDisplaySettings
    ) -> [FieldDescriptor] {
        trackedFields.filter { $0.changed(previous, current) }
    }

    @discardableResult
    internal mutating func clearOverridesMatchingParent(
        _ parent: TextDisplaySettings,
        only fields: [FieldDescriptor]? = nil
    ) -> Bool {
        var anyChanged = false
        for field in fields ?? Self.trackedFields {
            anyChanged = field.clearIfMatchingParent(&self, parent) || anyChanged
        }
        return anyChanged
    }

    /// Clears overrides that already match the current effective parent value.
    @discardableResult
    public mutating func clearRedundantOverrides(matching parent: TextDisplaySettings) -> Bool {
        clearOverridesMatchingParent(parent)
    }

    /**
     Clears overrides that match the current parent for fields changed by another source scope.

     Use this when the fields that changed come from one scope, but the child should be compared
     against an already-resolved current parent value.
     */
    @discardableResult
    public mutating func clearOverridesMatchingParent(
        _ parent: TextDisplaySettings,
        changedFrom previousSource: TextDisplaySettings,
        to currentSource: TextDisplaySettings
    ) -> Bool {
        clearOverridesMatchingParent(
            parent,
            only: Self.changedFields(from: previousSource, to: currentSource)
        )
    }

    /**
     Resolves every display property into a fully populated settings struct.

     - Parameters:
       - window: Window-level overrides, checked before workspace values.
       - workspace: Workspace-level overrides, checked before global values.
       - global: App-level overrides, checked before `appDefaults`.
     - Returns: A new `TextDisplaySettings` containing no inherited gaps for the supported
       fields.
     - Note: The method is deterministic and side-effect free. Callers remain responsible for
       persisting any changes or pushing the resolved values into the renderer.
     */
    public static func fullyResolved(
        window: TextDisplaySettings?,
        workspace: TextDisplaySettings?,
        global: TextDisplaySettings? = nil
    ) -> TextDisplaySettings {
        let d = appDefaults
        var r = TextDisplaySettings()
        r.fontSize = window?.fontSize ?? workspace?.fontSize ?? global?.fontSize ?? d.fontSize
        r.fontFamily = window?.fontFamily ?? workspace?.fontFamily ?? global?.fontFamily ?? d.fontFamily
        r.lineSpacing = window?.lineSpacing ?? workspace?.lineSpacing ?? global?.lineSpacing ?? d.lineSpacing
        r.marginLeft = window?.marginLeft ?? workspace?.marginLeft ?? global?.marginLeft ?? d.marginLeft
        r.marginRight = window?.marginRight ?? workspace?.marginRight ?? global?.marginRight ?? d.marginRight
        r.maxWidth = window?.maxWidth ?? workspace?.maxWidth ?? global?.maxWidth ?? d.maxWidth
        r.topMargin = window?.topMargin ?? workspace?.topMargin ?? global?.topMargin ?? d.topMargin
        r.strongsMode = window?.strongsMode ?? workspace?.strongsMode ?? global?.strongsMode ?? d.strongsMode
        r.showMorphology = window?.showMorphology ?? workspace?.showMorphology ?? global?.showMorphology ?? d.showMorphology
        r.showFootNotes = window?.showFootNotes ?? workspace?.showFootNotes ?? global?.showFootNotes ?? d.showFootNotes
        r.showFootNotesInline = window?.showFootNotesInline ?? workspace?.showFootNotesInline ?? global?.showFootNotesInline ?? d.showFootNotesInline
        r.expandXrefs = window?.expandXrefs ?? workspace?.expandXrefs ?? global?.expandXrefs ?? d.expandXrefs
        r.showXrefs = window?.showXrefs ?? workspace?.showXrefs ?? global?.showXrefs ?? d.showXrefs
        r.showRedLetters = window?.showRedLetters ?? workspace?.showRedLetters ?? global?.showRedLetters ?? d.showRedLetters
        r.showSectionTitles = window?.showSectionTitles ?? workspace?.showSectionTitles ?? global?.showSectionTitles ?? d.showSectionTitles
        r.showVerseNumbers = window?.showVerseNumbers ?? workspace?.showVerseNumbers ?? global?.showVerseNumbers ?? d.showVerseNumbers
        r.showVersePerLine = window?.showVersePerLine ?? workspace?.showVersePerLine ?? global?.showVersePerLine ?? d.showVersePerLine
        r.showBookmarks = window?.showBookmarks ?? workspace?.showBookmarks ?? global?.showBookmarks ?? d.showBookmarks
        r.showMyNotes = window?.showMyNotes ?? workspace?.showMyNotes ?? global?.showMyNotes ?? d.showMyNotes
        r.justifyText = window?.justifyText ?? workspace?.justifyText ?? global?.justifyText ?? d.justifyText
        r.hyphenation = window?.hyphenation ?? workspace?.hyphenation ?? global?.hyphenation ?? d.hyphenation
        r.showPageNumber = window?.showPageNumber ?? workspace?.showPageNumber ?? global?.showPageNumber ?? d.showPageNumber
        r.dayTextColor = window?.dayTextColor ?? workspace?.dayTextColor ?? global?.dayTextColor ?? d.dayTextColor
        r.dayBackground = window?.dayBackground ?? workspace?.dayBackground ?? global?.dayBackground ?? d.dayBackground
        r.dayNoise = window?.dayNoise ?? workspace?.dayNoise ?? global?.dayNoise ?? d.dayNoise
        r.nightTextColor = window?.nightTextColor ?? workspace?.nightTextColor ?? global?.nightTextColor ?? d.nightTextColor
        r.nightBackground = window?.nightBackground ?? workspace?.nightBackground ?? global?.nightBackground ?? d.nightBackground
        r.nightNoise = window?.nightNoise ?? workspace?.nightNoise ?? global?.nightNoise ?? d.nightNoise
        r.bookmarksHideLabels = window?.bookmarksHideLabels ?? workspace?.bookmarksHideLabels ?? global?.bookmarksHideLabels ?? d.bookmarksHideLabels
        r.enableVerseSelection = window?.enableVerseSelection ?? workspace?.enableVerseSelection ?? global?.enableVerseSelection ?? d.enableVerseSelection
        return r
    }

    /**
     Removes day/night theme color fields so the value inherits theme colors from its parent scope.

     The remaining text-display fields are left untouched. This mirrors Android's split where global
     text colors are a parent default and workspaces only override them when explicitly edited at the
     workspace level.
     */
    public mutating func clearThemeColors() {
        dayTextColor = nil
        dayBackground = nil
        dayNoise = nil
        nightTextColor = nil
        nightBackground = nil
        nightNoise = nil
    }

    /// Whether this value explicitly overrides any day/night theme color field.
    public var hasThemeColorOverrides: Bool {
        dayTextColor != nil ||
            dayBackground != nil ||
            dayNoise != nil ||
            nightTextColor != nil ||
            nightBackground != nil ||
            nightNoise != nil
    }

    /// Copies day/night theme color fields from another settings value.
    public mutating func restoreThemeColors(from source: TextDisplaySettings) {
        dayTextColor = source.dayTextColor
        dayBackground = source.dayBackground
        dayNoise = source.dayNoise
        nightTextColor = source.nightTextColor
        nightBackground = source.nightBackground
        nightNoise = source.nightNoise
    }

    /// Returns a copy with day/night theme color overrides removed.
    public func clearingThemeColors() -> TextDisplaySettings {
        var copy = self
        copy.clearThemeColors()
        return copy
    }
}
