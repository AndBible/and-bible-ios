// BibleWindowPaneMenuModel.swift -- Android parity model for pane hamburger menus

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
    case openColorSettings
    case toggleSectionTitles
    case openStrongsMode
    case toggleVerseNumbers
    case openAllTextOptions
    case copySettingsToWindow(UUID)
    case copySettingsToWorkspace
    case copySettingsToGlobal
    case copyLink
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
    let systemImage: String?
    let isChecked: Bool
    let action: BibleWindowPaneMenuAction?
    let children: [BibleWindowPaneMenuItem]

    init(
        id: String,
        title: String,
        systemImage: String? = nil,
        isChecked: Bool = false,
        action: BibleWindowPaneMenuAction? = nil,
        children: [BibleWindowPaneMenuItem] = []
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
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
    let autoPinEnabled: Bool
    let moduleHasStrongs: Bool
    let sectionTitlesEnabled: Bool
    let verseNumbersEnabled: Bool
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
                isChecked: snapshot.isPinned,
                action: .togglePin
            ))
        }

        if snapshot.canSync {
            resolvedItems.append(Self.syncMenu(snapshot: snapshot))
        }

        if snapshot.isVisible {
            resolvedItems.append(Self.textOptionsMenu(snapshot: snapshot))
        }

        if snapshot.canCopyLink {
            resolvedItems.append(.action(
                id: "copyLink",
                title: Self.localized("copyReference", default: "Copy link to clipboard"),
                systemImage: "doc.on.clipboard",
                action: .copyLink
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
        var children: [BibleWindowPaneMenuItem] = [
            .action(
                id: "colorSettings",
                title: ellipsis(localized("prefs_text_colors_menutitle", default: "Color settings")),
                systemImage: "paintpalette",
                action: .openColorSettings
            ),
            .action(
                id: "sectionTitles",
                title: localized("prefs_section_title_title", default: "Section titles"),
                systemImage: "textformat.size",
                isChecked: snapshot.sectionTitlesEnabled,
                action: .toggleSectionTitles
            ),
        ]

        if snapshot.moduleHasStrongs {
            children.append(.action(
                id: "strongsNumbers",
                title: ellipsis(localized("prefs_show_strongs_title", default: "Strong's numbers")),
                systemImage: "character.book.closed",
                action: .openStrongsMode
            ))
        }

        children.append(contentsOf: [
            .action(
                id: "verseNumbers",
                title: localized("prefs_show_verseno_title", default: "Chapter & verse numbers"),
                systemImage: "number",
                isChecked: snapshot.verseNumbersEnabled,
                action: .toggleVerseNumbers
            ),
            .action(
                id: "allTextOptions",
                title: ellipsis(localized("all_text_options_window_menutitle", default: "All text options")),
                systemImage: "textformat",
                action: .openAllTextOptions
            ),
            copySettingsMenu(snapshot: snapshot),
        ])

        return BibleWindowPaneMenuItem(
            id: "textOptions",
            title: ellipsis(localized("text_options_window_menutitle", default: "Text options")),
            systemImage: "textformat",
            children: children
        )
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
            systemImage: "doc.on.doc",
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
        systemImage: String? = nil,
        isChecked: Bool = false,
        action: BibleWindowPaneMenuAction
    ) -> BibleWindowPaneMenuItem {
        BibleWindowPaneMenuItem(
            id: id,
            title: title,
            systemImage: systemImage,
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
