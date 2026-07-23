// BibleWindowPaneMenuModel.swift -- Android parity model for pane hamburger menus

import BibleCore
import Foundation

/**
 Android-style action emitted by the per-window hamburger menu.

 The enum mirrors the stable behavior in Android's `window_popup_menu.xml` and
 `SplitBibleArea.getItemOptions`: the SwiftUI view renders rows, while the parent reader/window
 manager owns the side effects.
 */
enum BibleWindowPaneMenuAction: Equatable {
    case newWindow
    case maximize
    case minimize
    case changeToNormalWindow
    case moveToPosition(Int)
    case togglePin
    case disableSync
    case selectSyncGroup(Int)
    case addWholePageBookmark
    case exportHTML
    case exportStudyPad
    case exportStudyPadCSV
    case editTextSetting(AndroidTextDisplaySettingType)
    case openAllTextOptions
    case copySettingsToWindow(UUID)
    case copySettingsToWorkspace
    case copySettingsToGlobal
    case openAIActions
    case copyLink
    case openCopiedReference
    case openSpeakReference
    case close
}

/**
 One renderable row in the Android-style pane hamburger menu.

 Menu rows are recursive so submenus can be tested without SwiftUI introspection. `title` is already
 presentation-ready because several Android rows are dynamically formatted with window position and
 document/reference summaries.
 */
struct BibleWindowPaneMenuItem: Equatable, Identifiable {
    let id: String
    let title: String
    let iconAssetName: String?
    let systemImage: String?
    let isCheckable: Bool
    let isChecked: Bool
    let action: BibleWindowPaneMenuAction?
    let children: [BibleWindowPaneMenuItem]

    init(
        id: String,
        title: String,
        iconAssetName: String? = nil,
        systemImage: String? = nil,
        isCheckable: Bool = false,
        isChecked: Bool = false,
        action: BibleWindowPaneMenuAction? = nil,
        children: [BibleWindowPaneMenuItem] = []
    ) {
        self.id = id
        self.title = title
        self.iconAssetName = iconAssetName
        self.systemImage = systemImage
        self.isCheckable = isCheckable
        self.isChecked = isChecked
        self.action = action
        self.children = children
    }
}

/**
 Lightweight summary of one workspace window used to build dynamic Android submenus.

 Android builds Move-to rows from all windows in the same pin bucket and Copy-settings rows from
 visible windows. The full SwiftData `Window` object is intentionally not needed here.
 */
struct BibleWindowPaneMenuWindowSummary: Equatable, Identifiable {
    let id: UUID
    let position: Int
    let documentAbbreviation: String?
    let referenceName: String?
    let isPinned: Bool
}

/**
 Complete state needed to resolve Android pane-menu visibility.

 The snapshot is intentionally explicit: callers translate app/controller state into this value,
 then the pure model applies Android's ordering and visibility rules.
 */
struct BibleWindowPaneMenuSnapshot: Equatable {
    let windowID: UUID
    let isLinksWindow: Bool
    let isPinned: Bool
    let isSynchronized: Bool
    let syncGroup: Int
    let isVisible: Bool
    let isMaximized: Bool
    let canMinimize: Bool
    let canClose: Bool
    let canSync: Bool
    let canCopyLink: Bool
    let canAddWholePageBookmark: Bool
    let canExportHTML: Bool
    let canExportStudyPad: Bool
    let canExportStudyPadCSV: Bool
    let copiedReferenceName: String?
    let speakReferenceName: String?
    let recentTextSettings: [AndroidTextDisplaySettingType]
    let resolvedTextDisplaySettings: TextDisplaySettings
    let isBibleShown: Bool
    let isMyNotesShown: Bool
    let moduleHasRedLetterWords: Bool
    let autoPinEnabled: Bool
    let moduleHasStrongs: Bool
    let sectionTitlesEnabled: Bool
    let verseNumbersEnabled: Bool
    let isAIConfigured: Bool
    let allWindowsInPersistedOrder: [BibleWindowPaneMenuWindowSummary]
    let visibleWindows: [BibleWindowPaneMenuWindowSummary]
}

/**
 Pure Android-parity menu model for one pane's hamburger button.

 This model follows Android's window popup structure:
 - normal window creation/layout rows are hidden for links windows and maximized state
 - move targets are zero-based positions in the current pin-mode bucket
 - sync rows are a submenu with Disable synchronize and Group 1...6
 - text options are grouped under one submenu with copy-settings targets
 */
struct BibleWindowPaneMenuModel: Equatable {
    let items: [BibleWindowPaneMenuItem]

    init(snapshot: BibleWindowPaneMenuSnapshot) {
        var resolvedItems: [BibleWindowPaneMenuItem] = []

        if !snapshot.isMaximized && !snapshot.isLinksWindow {
            resolvedItems.append(.action(
                id: "newWindow",
                title: Self.localized("new_window", default: "New window"),
                systemImage: "plus.rectangle.on.rectangle",
                action: .newWindow
            ))
        }

        if !snapshot.isMaximized {
            resolvedItems.append(.action(
                id: "maximize",
                title: Self.localized("windowMaximise", default: "Maximise"),
                systemImage: "arrow.up.left.and.arrow.down.right",
                action: .maximize
            ))
        }

        if !snapshot.isMaximized && snapshot.canMinimize {
            resolvedItems.append(.action(
                id: "minimize",
                title: Self.localized("windowMinimise", default: "Minimise"),
                systemImage: "minus",
                action: .minimize
            ))
        }

        if snapshot.isLinksWindow {
            resolvedItems.append(.action(
                id: "changeToNormal",
                title: Self.localized("change_to_normal", default: "Change to normal window"),
                systemImage: "link",
                action: .changeToNormalWindow
            ))
        }

        if let moveMenu = Self.moveMenu(snapshot: snapshot) {
            resolvedItems.append(moveMenu)
        }

        if !snapshot.isLinksWindow && !snapshot.isMaximized && !snapshot.autoPinEnabled {
            resolvedItems.append(.action(
                id: "pin",
                title: Self.localized("window_pin_mode", default: "Pin"),
                systemImage: "pin",
                isCheckable: true,
                isChecked: snapshot.isPinned,
                action: .togglePin
            ))
        }

        if snapshot.canSync {
            resolvedItems.append(Self.syncMenu(snapshot: snapshot))
        }

        if snapshot.canAddWholePageBookmark {
            resolvedItems.append(.action(
                id: "addWholePageBookmark",
                title: Self.localized(
                    "add_whole_page_bookmark",
                    default: "Add bookmark for whole page"
                ),
                systemImage: "bookmark",
                action: .addWholePageBookmark
            ))
        }

        if snapshot.canExportHTML {
            resolvedItems.append(.action(
                id: "exportHTML",
                title: String(
                    format: Self.localized("export_fileformat", default: "Export as %@"),
                    "HTML"
                ),
                systemImage: "square.and.arrow.up",
                action: .exportHTML
            ))
        }

        if snapshot.canExportStudyPad {
            resolvedItems.append(.action(
                id: "exportStudyPad",
                title: String(
                    format: Self.localized("export_something", default: "Export %@"),
                    Self.localized("studypad", default: "Study Pad")
                ),
                systemImage: "square.and.arrow.up",
                action: .exportStudyPad
            ))
        }

        if snapshot.canExportStudyPadCSV {
            resolvedItems.append(.action(
                id: "exportStudyPadCSV",
                title: String(
                    format: Self.localized(
                        "export_bookmarks_csv",
                        default: "Export Bookmarks as %@"
                    ),
                    "CSV"
                ),
                systemImage: "square.and.arrow.up",
                action: .exportStudyPadCSV
            ))
        }

        if snapshot.isVisible && !snapshot.recentTextSettings.isEmpty {
            resolvedItems.append(Self.textOptionsMenu(snapshot: snapshot))
        }

        if snapshot.isVisible && snapshot.isAIConfigured {
            resolvedItems.append(.action(
                id: "aiActions",
                title: Self.localized("llm_actions", default: "AI actions"),
                systemImage: "sparkles",
                action: .openAIActions
            ))
        }

        if snapshot.canCopyLink {
            resolvedItems.append(.action(
                id: "copyLink",
                title: Self.localized("copyReference", default: "Copy link to clipboard"),
                systemImage: "doc.on.clipboard",
                action: .copyLink
            ))
        }

        if let copiedReferenceName = snapshot.copiedReferenceName {
            resolvedItems.append(.action(
                id: "goToReference",
                title: String(
                    format: Self.localized("go_to_ref", default: "Open %@"),
                    copiedReferenceName
                ),
                systemImage: "doc.on.clipboard",
                action: .openCopiedReference
            ))
        }

        if let speakReferenceName = snapshot.speakReferenceName {
            resolvedItems.append(.action(
                id: "goToSpeak",
                title: String(
                    format: Self.localized("go_to_ref", default: "Open %@"),
                    speakReferenceName
                ),
                systemImage: "headphones",
                action: .openSpeakReference
            ))
        }

        if snapshot.isVisible && snapshot.recentTextSettings.isEmpty {
            resolvedItems.append(.action(
                id: "allTextOptions",
                title: Self.ellipsis(
                    Self.localized(
                        "all_text_options_window_menutitle",
                        default: "All text options"
                    )
                ),
                iconAssetName: "OverflowTextOptions",
                action: .openAllTextOptions
            ))
        }

        if !snapshot.isMaximized && snapshot.canClose {
            resolvedItems.append(.action(
                id: "close",
                title: Self.localized("close", default: "Close"),
                systemImage: "xmark",
                action: .close
            ))
        }

        items = resolvedItems
    }

    private static func moveMenu(snapshot: BibleWindowPaneMenuSnapshot) -> BibleWindowPaneMenuItem? {
        guard !snapshot.isLinksWindow, !snapshot.isMaximized else { return nil }
        let candidates = snapshot.allWindowsInPersistedOrder.filter { $0.isPinned == snapshot.isPinned }
        guard candidates.count > 1 else { return nil }

        let children = candidates.enumerated().compactMap { bucketIndex, candidate -> BibleWindowPaneMenuItem? in
            guard candidate.id != snapshot.windowID else { return nil }
            let title = String(
                format: localized("move_window_to_position2", default: "Position %1$d (%2$@:%3$@)"),
                bucketIndex + 1,
                candidate.documentAbbreviation ?? "",
                candidate.referenceName ?? ""
            )
            return .action(
                id: "moveTo::\(bucketIndex)",
                title: title,
                systemImage: "arrow.up.and.down",
                action: .moveToPosition(bucketIndex)
            )
        }

        guard !children.isEmpty else { return nil }
        return BibleWindowPaneMenuItem(
            id: "moveTo",
            title: localized("move_window", default: "Move to"),
            systemImage: "arrow.up.and.down.square",
            children: children
        )
    }

    private static func syncMenu(snapshot: BibleWindowPaneMenuSnapshot) -> BibleWindowPaneMenuItem {
        var children: [BibleWindowPaneMenuItem] = []

        if snapshot.isSynchronized {
            children.append(.action(
                id: "disableSync",
                title: localized("window_disable_sync", default: "Disable synchronize"),
                action: .disableSync
            ))
        }

        for group in 0..<6 where !(snapshot.isSynchronized && group == snapshot.syncGroup) {
            children.append(.action(
                id: "syncGroup::\(group)",
                title: String(format: localized("sync_group_n", default: "Group %d"), group + 1),
                isChecked: snapshot.isSynchronized && group == snapshot.syncGroup,
                action: .selectSyncGroup(group)
            ))
        }

        return BibleWindowPaneMenuItem(
            id: "synchronize",
            title: localized("windowSynchronise", default: "Synchronise"),
            systemImage: "arrow.triangle.2.circlepath",
            children: children
        )
    }

    private static func textOptionsMenu(snapshot: BibleWindowPaneMenuSnapshot) -> BibleWindowPaneMenuItem {
        var children = snapshot.recentTextSettings.compactMap { type in
            textSettingItem(type, snapshot: snapshot)
        }
        children.append(contentsOf: [
            .action(
                id: "allTextOptions",
                title: ellipsis(localized("all_text_options_window_menutitle", default: "All text options")),
                iconAssetName: "OverflowTextOptions",
                action: .openAllTextOptions
            ),
            copySettingsMenu(snapshot: snapshot),
        ])

        return BibleWindowPaneMenuItem(
            id: "textOptions",
            title: ellipsis(localized("text_options_window_menutitle", default: "Text options")),
            iconAssetName: "OverflowTextOptions",
            children: children
        )
    }

    /** Builds one Android recent-setting row after applying the target window's enabled/visible rules. */
    private static func textSettingItem(
        _ type: AndroidTextDisplaySettingType,
        snapshot: BibleWindowPaneMenuSnapshot
    ) -> BibleWindowPaneMenuItem? {
        guard type.isAvailableOnIOS, isTextSettingAvailable(type, snapshot: snapshot) else {
            return nil
        }
        let baseTitle = type.localizedTitle(settings: snapshot.resolvedTextDisplaySettings)
        return .action(
            id: "textSetting::\(type.rawValue)",
            title: type.isBoolean ? baseTitle : ellipsis(baseTitle),
            iconAssetName: AndBibleIconCatalog.settingsIcon(forAndroidKey: type.rawValue)?.assetName,
            isCheckable: type.isBoolean,
            isChecked: booleanTextSettingValue(type, snapshot: snapshot),
            action: .editTextSetting(type)
        )
    }

    /** Mirrors Android `getPrefItem(...).enabled && visible` filtering for recent window rows. */
    private static func isTextSettingAvailable(
        _ type: AndroidTextDisplaySettingType,
        snapshot: BibleWindowPaneMenuSnapshot
    ) -> Bool {
        switch type {
        case .strongs, .morphology, .nonStrongsWordItalic:
            return snapshot.moduleHasStrongs
        case .footnotesInline:
            return snapshot.resolvedTextDisplaySettings.showFootNotes ?? true
        case .expandXrefs:
            return snapshot.resolvedTextDisplaySettings.showXrefs ?? true
        case .redLetters:
            return snapshot.isBibleShown && snapshot.moduleHasRedLetterWords
        case .topMargin:
            return snapshot.isBibleShown
        case .myNotes:
            return !snapshot.isMyNotesShown
        default:
            return true
        }
    }

    /** Resolves the checkmark value for every iOS-backed Boolean Android text-setting type. */
    private static func booleanTextSettingValue(
        _ type: AndroidTextDisplaySettingType,
        snapshot: BibleWindowPaneMenuSnapshot
    ) -> Bool {
        let settings = snapshot.resolvedTextDisplaySettings
        switch type {
        case .justify: return settings.justifyText ?? true
        case .hyphenation: return settings.hyphenation ?? true
        case .morphology: return settings.showMorphology ?? false
        case .footnotes: return settings.showFootNotes ?? true
        case .footnotesInline: return settings.showFootNotesInline ?? false
        case .expandXrefs: return settings.expandXrefs ?? false
        case .xrefs: return settings.showXrefs ?? true
        case .redLetters: return settings.showRedLetters ?? true
        case .sectionTitles: return settings.showSectionTitles ?? true
        case .verseNumbers: return settings.showVerseNumbers ?? true
        case .versePerLine: return settings.showVersePerLine ?? false
        case .bookmarksShow: return settings.showBookmarks ?? true
        case .myNotes: return settings.showMyNotes ?? true
        case .pageNumber: return settings.showPageNumber ?? false
        case .infiniteScroll: return settings.infiniteScroll ?? true
        case .nonStrongsWordItalic: return settings.nonStrongsWordItalic ?? false
        case .markAsReadButton: return settings.showMarkAsReadButton ?? true
        case .titleScrollButton: return settings.showTitleScrollButton ?? false
        case .memorizationIndicators: return settings.showMemorizationIndicators ?? false
        case .aiDocumentMarkers: return settings.showAiDocMarkers ?? true
        case .ordinals: return settings.showOrdinals ?? false
        default: return false
        }
    }

    private static func copySettingsMenu(snapshot: BibleWindowPaneMenuSnapshot) -> BibleWindowPaneMenuItem {
        var children = snapshot.visibleWindows.compactMap { target -> BibleWindowPaneMenuItem? in
            guard target.id != snapshot.windowID else { return nil }
            let title = String(
                format: localized("copy_settings_to_window", default: "Window %1$d (%2$@:%3$@)"),
                target.position + 1,
                target.documentAbbreviation ?? "",
                target.referenceName ?? ""
            )
            return .action(
                id: "copySettingsToWindow::\(target.id.uuidString)",
                title: title,
                action: .copySettingsToWindow(target.id)
            )
        }

        children.append(.action(
            id: "copySettingsToWorkspace",
            title: localized("copy_settings_to_workspace", default: "Workspace"),
            action: .copySettingsToWorkspace
        ))
        children.append(.action(
            id: "copySettingsToGlobal",
            title: localized("copy_settings_to_global", default: "Global defaults"),
            action: .copySettingsToGlobal
        ))

        return BibleWindowPaneMenuItem(
            id: "copySettingsTo",
            title: localized("copy_settings", default: "Copy settings to"),
            iconAssetName: "ActivityCopy",
            children: children
        )
    }

    private static func localized(_ key: String, default defaultValue: String) -> String {
        let value = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
        return value == key ? defaultValue : value
    }

    private static func ellipsis(_ title: String) -> String {
        String(format: localized("add_ellipsis", default: "%@..."), title)
    }
}

private extension BibleWindowPaneMenuItem {
    static func action(
        id: String,
        title: String,
        iconAssetName: String? = nil,
        systemImage: String? = nil,
        isCheckable: Bool = false,
        isChecked: Bool = false,
        action: BibleWindowPaneMenuAction
    ) -> BibleWindowPaneMenuItem {
        BibleWindowPaneMenuItem(
            id: id,
            title: title,
            iconAssetName: iconAssetName,
            systemImage: systemImage,
            isCheckable: isCheckable,
            isChecked: isChecked,
            action: action
        )
    }
}

/**
 Builds Android-compatible `read.andbible.org` reference URLs for copy-link actions.

 Android delegates to `CommonUtils.makeAndBibleUrl`; this builder keeps the iOS pane and tab menus
 from copying human display strings where Android copies a durable URL.
 */
enum AndBibleReferenceURLBuilder {
    static func urlString(osisRef: String?, documentInitials: String?, ordinal: Int? = nil) -> String? {
        guard let osisRef = osisRef?.trimmingCharacters(in: .whitespacesAndNewlines),
              !osisRef.isEmpty,
              let documentInitials = documentInitials?.trimmingCharacters(in: .whitespacesAndNewlines),
              !documentInitials.isEmpty else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "read.andbible.org"
        components.path = "/" + osisRef
        var queryItems = [URLQueryItem(name: "document", value: documentInitials)]
        if let ordinal {
            queryItems.append(URLQueryItem(name: "ordinal", value: String(ordinal)))
        }
        components.queryItems = queryItems
        return components.url?.absoluteString
    }
}
