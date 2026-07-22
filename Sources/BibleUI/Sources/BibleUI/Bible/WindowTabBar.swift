// WindowTabBar.swift -- Bottom tab bar showing open document windows

import SwiftUI
import SwiftData
import BibleCore

/**
 Shows all workspace windows in Android-style compact buttons below the reader.

 Android renders the footer from `window_button.xml`: each window is a fixed 40dp button with
 overlaid document/link/sync/pin indicators and tiny title/document labels. Multi-window mode
 prefixes those buttons with the persisted restore-strip hide/show arrow, while true single-window
 mode shows the add-window affordance instead. This view mirrors that structure instead of using
 variable-width iOS text chips. Hidden multi-window mode follows Android's WebView offset contract:
 the full-width footer no longer reserves height, while the trailing restore affordance remains
 reachable as an overlay.

 It also hosts typed-reference navigation for represented windows.
 */
struct WindowTabBar: View {
    /// Shared workspace/window coordinator used to read and mutate tab state.
    @Environment(WindowManager.self) private var windowManager

    /// SwiftData context used to persist workspace restore-strip visibility.
    @Environment(\.modelContext) private var modelContext

    /// Current layout direction, used to mirror Android's restore-strip arrow in RTL locales.
    @Environment(\.layoutDirection) private var layoutDirection

    /// Reader-surface colors shared with the active WebView display settings.
    var surfacePalette: ReaderThemeSurfacePalette = .standard

    /// Whether Android's monochrome/e-ink window-button override should be applied.
    var monochromeMode = false

    /// Presents transient toast feedback in the parent reader.
    var onShowToast: ((String) -> Void)?

    /// Opens the native book chooser when the user selects the browse fallback.
    var onShowBookChooser: (() -> Void)?

    /// Attempts typed-reference navigation for a specific window and reports success/failure.
    var onGoToTypedRef: ((BibleCore.Window, String) -> Bool)?

    /// Controls presentation of the typed-reference alert from the tab context menu.
    @State private var showGoToRefAlert = false

    /// Draft typed-reference text bound to the alert text field.
    @State private var goToRefText = ""

    /// Window targeted by the currently presented typed-reference alert.
    @State private var goToRefWindow: BibleCore.Window?

    /// Whether a visible pane is still opening and should block more user-created windows.
    private var isAddWindowDisabled: Bool {
        // Controller registry updates bump this marker; the pending check is derived from registry state.
        _ = windowManager.controllerVersion
        return windowManager.hasPendingVisibleControllerRegistration
    }

    var body: some View {
        let tabPalette = AndroidWindowTabPalette.resolved(
            for: surfacePalette,
            monochromeMode: monochromeMode
        )
        let restoreButtonsVisible = windowManager.activeWorkspace?.workspaceSettings?.restoreButtonsVisible ?? true
        let singleWindowFooterMode = isSingleWindowFooterMode
        let reservedHeight = WindowTabBarLayout.reservedHeight(
            restoreButtonsVisible: restoreButtonsVisible,
            isSingleWindowFooterMode: singleWindowFooterMode
        )
        let isCollapsed = reservedHeight == WindowTabBarLayout.collapsedBarHeight

        Color.clear
            .frame(height: reservedHeight)
            .overlay(alignment: .bottomTrailing) {
                footerStrip(
                    tabPalette: tabPalette,
                    restoreButtonsVisible: restoreButtonsVisible,
                    isSingleWindowFooterMode: singleWindowFooterMode,
                    isCollapsed: isCollapsed
                )
            }
            .foregroundStyle(surfacePalette.foregroundColor)
            .alert(String(localized: "go_to_reference"), isPresented: $showGoToRefAlert) {
                TextField(String(localized: "go_to_reference_placeholder"), text: $goToRefText)
                Button(String(localized: "go")) {
                    if let w = goToRefWindow {
                        if !(onGoToTypedRef?(w, goToRefText) ?? false) {
                            onShowToast?(String(localized: "go_to_reference_invalid"))
                        }
                    }
                }
                Button(String(localized: "browse"), role: nil) {
                    onShowBookChooser?()
                }
                Button(String(localized: "cancel"), role: .cancel) { }
            } message: {
                Text(String(localized: "go_to_reference_message"))
            }
    }

    /**
     Builds the Android restore-button strip surface.

     - Parameters:
       - tabPalette: Android-derived footer colors.
       - restoreButtonsVisible: Persisted restore-strip visibility flag.
       - isSingleWindowFooterMode: Whether only Android's add-window affordance is shown.
       - isCollapsed: Whether the reader should reserve no bottom footer height.
     - Returns: A footer strip that either fills the screen width or leaves only the restore
       affordance reachable at the trailing edge when collapsed.
     - Side effects: Child button actions may mutate workspace/window state.
     - Failure modes: Child actions are idempotent and no-op when their required workspace/window
       state is unavailable.
     */
    private func footerStrip(
        tabPalette: AndroidWindowTabPalette,
        restoreButtonsVisible: Bool,
        isSingleWindowFooterMode: Bool,
        isCollapsed: Bool
    ) -> some View {
        GeometryReader { geometry in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: WindowTabBarLayout.spacing) {
                    if windowManager.isMaximized {
                        unmaximizeButton(tabPalette: tabPalette)
                    } else if isSingleWindowFooterMode {
                        addWindowButton(tabPalette: tabPalette)
                    } else {
                        restoreButtonsToggle(isExpanded: restoreButtonsVisible, tabPalette: tabPalette)
                        if restoreButtonsVisible {
                            ForEach(windowManager.allWindows, id: \.id) { window in
                                windowTab(for: window, tabPalette: tabPalette)
                            }
                        }
                    }
                }
                .padding(.horizontal, WindowTabBarLayout.horizontalPadding / 2)
                .padding(.vertical, WindowTabBarLayout.verticalPadding)
                .frame(minWidth: geometry.size.width, alignment: .trailing)
            }
            .accessibilityIdentifier("windowTabBar")
            .accessibilityElement(children: .contain)
        }
        .frame(
            width: isCollapsed ? WindowTabBarLayout.collapsedControlWidth : nil,
            height: WindowTabBarLayout.barHeight
        )
        .frame(maxWidth: isCollapsed ? nil : .infinity, alignment: .trailing)
        .background(isCollapsed ? Color.clear : tabPalette.restoreStripBackgroundColor)
    }

    /// Whether Android would show only the add-window footer control.
    private var isSingleWindowFooterMode: Bool {
        !windowManager.isMaximized
            && windowManager.allWindows.count <= 1
            && windowManager.visibleWindows.count <= 1
    }

    // MARK: - Footer Controls

    /**
     Builds Android's single-window add button for the restore strip.

     - Parameter tabPalette: Android-derived footer colors.
     - Returns: Fixed-size add-window button matching Android's single-window footer mode.
     - Side effects: Tapping creates a new window from the active window when controller
       registration is not pending.
     - Failure modes: If no active workspace exists, `WindowManager.addWindow` returns `nil`.
     */
    private func addWindowButton(tabPalette: AndroidWindowTabPalette) -> some View {
        Button {
            guard !isAddWindowDisabled else { return }
            windowManager.addWindow(from: windowManager.activeWindow)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(tabPalette.addButtonBackgroundColor)

                if isAddWindowDisabled {
                    ProgressView()
                        .controlSize(.small)
                        .tint(tabPalette.windowButtonTextColor)
                } else {
                    ToolbarAssetIcon(name: "ToolbarWindowAdd", size: 24)
                        .foregroundStyle(tabPalette.windowButtonTextColor)
                }
            }
            .frame(width: WindowTabBarLayout.fixedButtonSize, height: WindowTabBarLayout.fixedButtonSize)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        tabPalette.strokeColor,
                        lineWidth: tabPalette.footerButtonStrokeWidth(isActive: false)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(isAddWindowDisabled)
        .accessibilityIdentifier("windowTabAddButton")
        .accessibilityLabel(String(localized: "new_window", defaultValue: "New window"))
        .accessibilityValue(
            isAddWindowDisabled
                ? String(localized: "reader_window_opening", defaultValue: "Window opening")
                : ""
        )
    }

    /**
     Builds Android's multi-window restore-strip hide/show arrow.

     - Parameters:
       - isExpanded: Whether the restore buttons are currently visible.
       - tabPalette: Android-derived footer colors.
     - Returns: A 50pt control matching Android's 20dp extension plus 30dp arrow button.
     - Side effects: Persists `WorkspaceSettings.restoreButtonsVisible` and refreshes window state
       so SwiftUI re-renders the footer immediately.
     - Failure modes: If no active workspace exists, the tap is ignored.
     */
    private func restoreButtonsToggle(
        isExpanded: Bool,
        tabPalette: AndroidWindowTabPalette
    ) -> some View {
        let isRTL = layoutDirection == .rightToLeft
        let iconName = isExpanded
            ? (isRTL ? "ToolbarRestoreButtonsLeft" : "ToolbarRestoreButtonsRight")
            : (isRTL ? "ToolbarRestoreButtonsRight" : "ToolbarRestoreButtonsLeft")
        let label = isExpanded
            ? String(localized: "hide_window_buttons_title", defaultValue: "Hide window buttons")
            : String(localized: "show_window_buttons_title", defaultValue: "Show window buttons")
        let hint = isExpanded
            ? String(localized: "hide_window_buttons_hint", defaultValue: "Hides the window button strip")
            : String(localized: "show_window_buttons_hint", defaultValue: "Shows the window button strip")

        return Button {
            setRestoreButtonsVisible(!isExpanded)
        } label: {
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: WindowTabBarLayout.restoreToggleTouchExtensionWidth)

                ToolbarAssetIcon(name: iconName, size: 24)
                    .foregroundStyle(tabPalette.windowButtonTextColor)
                    .frame(
                        width: WindowTabBarLayout.restoreToggleButtonWidth,
                        height: WindowTabBarLayout.fixedButtonSize
                    )
            }
            .frame(
                width: WindowTabBarLayout.multiWindowControlWidth,
                height: WindowTabBarLayout.fixedButtonSize
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("windowTabRestoreToggleButton")
        .accessibilityLabel(label)
        .accessibilityHint(hint)
    }

    /**
     Builds Android's maximized-window unmaximize footer control.

     - Parameter tabPalette: Android-derived footer colors.
     - Returns: Fixed-size unmaximize button.
     - Side effects: Tapping clears maximized layout through `WindowManager`.
     - Failure modes: None; unmaximize is idempotent when no maximized window exists.
     */
    private func unmaximizeButton(tabPalette: AndroidWindowTabPalette) -> some View {
        let foregroundColor = tabPalette.footerButtonForegroundColor(isVisible: true)

        return Button {
            windowManager.unmaximize()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(tabPalette.visibleButtonBackgroundColor)

                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(foregroundColor)
            }
            .frame(width: WindowTabBarLayout.fixedButtonSize, height: WindowTabBarLayout.fixedButtonSize)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        tabPalette.strokeColor,
                        lineWidth: tabPalette.unmaximizeButtonStrokeWidth()
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("windowTabUnmaximizeButton")
        .accessibilityLabel(
            String(localized: "window_unmaximize_accessibility_label", defaultValue: "Restore window")
        )
        .accessibilityHint(
            String(
                localized: "window_unmaximize_accessibility_hint",
                defaultValue: "Restores the maximized window to the workspace"
            )
        )
    }

    /**
     Persists Android's workspace-scoped restore-button visibility flag.

     - Parameter isVisible: Desired restore-button strip expansion state.
     - Side effects: Mutates the active workspace settings, saves through SwiftData, and refreshes
       window state so observers see the change.
     - Failure modes: If no active workspace exists, no mutation is performed. SwiftData save
       failures are intentionally ignored, matching nearby workspace-setting update behavior.
     */
    private func setRestoreButtonsVisible(_ isVisible: Bool) {
        guard let workspace = windowManager.activeWorkspace else { return }
        var settings = workspace.workspaceSettings ?? WorkspaceSettings()
        settings.restoreButtonsVisible = isVisible
        settings.normalizeAutoAssignPrimaryLabel()
        workspace.workspaceSettings = settings
        try? modelContext.save()
        windowManager.refreshWindows()
    }

    // MARK: - Window Tab

    /**
     Builds the Android-style compact button and manager-routed context actions for one window.

     - Parameters:
       - window: Window represented by the tab.
       - tabPalette: Resolved footer colors for visible, hidden, and active states.
     - Returns: A fixed-size tab with content, layout, sync, pin, and close actions.
     - Side Effects: User actions route all window-state mutations through `WindowManager`.
     - Failure Modes: Missing rendered controller state falls back to persisted page-manager labels.
     */
    private func windowTab(
        for window: BibleCore.Window,
        tabPalette: AndroidWindowTabPalette
    ) -> some View {
        let actionDispatcher = WindowTabActionDispatcher(target: windowManager)
        let isMinimized = window.layoutState == "minimized"
        let isActive = !isMinimized && window.id == windowManager.activeWindow?.id
        let renderedState = renderedContentTabState(for: window)
        let isVisible = !isMinimized
        let categoryName = renderedState?.categoryName ?? window.pageManager?.currentCategoryName ?? "bible"
        let icon = iconName(for: window, categoryName: categoryName)
        let moduleName = renderedState?.moduleName ?? persistedModuleName(for: window, categoryName: categoryName)
        let reference = renderedState?.reference ?? shortReference(for: window)
        let buttonForegroundColor = tabPalette.footerButtonForegroundColor(isVisible: isVisible)
        let canCopyReference = !fullReference(for: window).isEmpty
        let moveCandidates = windowManager.windowsInPersistedOrder.filter {
            windowManager.isEffectivelyPinned($0) == windowManager.isEffectivelyPinned(window)
        }
        let currentMoveIndex = moveCandidates.firstIndex(where: { $0.id == window.id })
        let canMoveWindow = !window.isLinksWindow
            && !windowManager.isMaximized
            && moveCandidates.count > 1
        let canSyncWindow = isWindowSyncable(window)
        let autoPinEnabled = windowManager.activeWorkspace?.workspaceSettings?.autoPin
            ?? WorkspaceSettings.defaultAutoPin
        let canPinWindow = !window.isLinksWindow && !windowManager.isMaximized && !autoPinEnabled
        let topCornerRadius: CGFloat = (windowManager.isEffectivelyPinned(window) || window.isLinksWindow) ? 6 : 1
        let tabShape = UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading: topCornerRadius,
                bottomLeading: 0,
                bottomTrailing: 0,
                topTrailing: topCornerRadius
            )
        )

        return Button {
            actionDispatcher.perform(.select(isMinimized: isMinimized), for: window)
        } label: {
            ZStack(alignment: .topLeading) {
                tabShape
                    .fill(tabPalette.backgroundColor(isActive: isActive, isVisible: isVisible))

                VStack(alignment: .leading, spacing: 0) {
                    Color.clear
                        .frame(height: 13)

                    Text(reference.isEmpty ? " " : reference)
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(buttonForegroundColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.45)
                        .frame(height: 10, alignment: .leading)

                    Text(moduleName)
                        .font(.system(size: 12, weight: isMinimized ? .regular : .semibold))
                        .foregroundStyle(buttonForegroundColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.45)
                        .frame(height: 16, alignment: .leading)
                }
                .padding(.leading, 2)
                .padding(.trailing, 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

                ToolbarAssetIcon(name: icon, size: 14)
                    .foregroundStyle(
                        tabPalette.footerIconColor(
                            isLinksWindow: window.isLinksWindow,
                            isVisible: isVisible
                        )
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 2)
                    .padding(.trailing, 2)

                if canSyncWindow && window.isSynchronized {
                    HStack(spacing: 0) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 7, weight: .bold))
                        Text("\(window.syncGroup + 1)")
                            .font(.system(size: 7, weight: .bold))
                    }
                    .foregroundStyle(tabPalette.footerStatusIconColor(isVisible: isVisible))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 2)
                    .padding(.leading, 1)
                }
            }
            .frame(width: WindowTabBarLayout.fixedButtonSize, height: WindowTabBarLayout.fixedButtonSize)
            .clipped()
            .overlay(
                tabShape
                    .strokeBorder(
                        isActive ? tabPalette.activeStrokeColor : tabPalette.strokeColor,
                        style: isMinimized
                            ? StrokeStyle(lineWidth: 1, dash: [4, 3])
                            : StrokeStyle(lineWidth: tabPalette.footerButtonStrokeWidth(isActive: isActive))
                    )
            )
            .opacity(isMinimized ? 0.62 : 1.0)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("windowTabButton::\(window.orderNumber)")
        .accessibilityValue(windowTabAccessibilityValue(
            isActive: isActive,
            isMinimized: isMinimized,
            categoryName: categoryName,
            moduleName: moduleName,
            reference: reference
        ))
        .contextMenu {
            // Content actions
            if !isMinimized {
                if canCopyReference {
                    Button(String(localized: "copy_reference"), systemImage: "doc.on.clipboard") {
                        copyReference(for: window)
                    }
                }

                Button(String(localized: "go_to_reference"), systemImage: "arrow.right.doc.on.clipboard") {
                    actionDispatcher.perform(.activate, for: window)
                    goToRefWindow = window
                    goToRefText = ""
                    showGoToRefAlert = true
                }
            }

            Divider()

            if isMinimized {
                Button(String(localized: "restore"), systemImage: "arrow.up.left.and.arrow.down.right") {
                    actionDispatcher.perform(.restore, for: window)
                }
            } else {
                // Move window actions
                if canMoveWindow {
                    Button(String(localized: "move_up"), systemImage: "arrow.up") {
                        guard let index = currentMoveIndex, index > 0 else { return }
                        actionDispatcher.perform(.move(toPosition: index - 1), for: window)
                    }
                    .disabled(currentMoveIndex == nil || currentMoveIndex == 0)

                    Button(String(localized: "move_down"), systemImage: "arrow.down") {
                        guard let index = currentMoveIndex, index < moveCandidates.count - 1 else { return }
                        actionDispatcher.perform(.move(toPosition: index + 1), for: window)
                    }
                    .disabled(currentMoveIndex == nil || currentMoveIndex == moveCandidates.count - 1)

                    Divider()
                }

                Button(String(localized: "minimize"), systemImage: "minus") {
                    actionDispatcher.perform(.minimize, for: window)
                }
                .disabled(windowManager.visibleWindows.count <= 1)

                if windowManager.isMaximized {
                    Button(String(localized: "restore_size"), systemImage: "arrow.down.right.and.arrow.up.left") {
                        actionDispatcher.perform(.unmaximize, for: window)
                    }
                } else {
                    Button(String(localized: "maximize"), systemImage: "arrow.up.left.and.arrow.down.right") {
                        actionDispatcher.perform(.maximize, for: window)
                    }
                }
            }

            Divider()

            if canSyncWindow || canPinWindow {
                if canSyncWindow {
                    Toggle(isOn: Binding(
                        get: { window.isSynchronized },
                        set: { actionDispatcher.perform(.setSynchronized($0), for: window) }
                    )) {
                        SwiftUI.Label(String(localized: "sync_scrolling"), systemImage: "arrow.triangle.2.circlepath")
                    }
                }

                if canPinWindow {
                    Toggle(isOn: Binding(
                        get: { window.isPinMode },
                        set: { actionDispatcher.perform(.setPinMode($0), for: window) }
                    )) {
                        SwiftUI.Label(String(localized: "pin"), systemImage: "pin")
                    }
                }

                if canSyncWindow {
                    Menu(String(localized: "sync_group")) {
                        ForEach(WindowSyncGroupPresentation.storedGroups, id: \.self) { group in
                            Button {
                                actionDispatcher.perform(.changeSyncGroup(group), for: window)
                            } label: {
                                let groupTitle = WindowSyncGroupPresentation.title(forStoredGroup: group)
                                if window.syncGroup == group {
                                    SwiftUI.Label(groupTitle, systemImage: "checkmark")
                                } else {
                                    Text(groupTitle)
                                }
                            }
                        }
                    }
                }

                Divider()
            }

            Button(String(localized: "close"), systemImage: "xmark", role: .destructive) {
                actionDispatcher.perform(.close, for: window)
            }
            .disabled(windowManager.allWindows.count <= 1)
        }
    }

    /// Display identity from the controller's last rendered-content token.
    private struct RenderedContentTabState {
        /// Page-manager style category key, such as `dictionary`.
        let categoryName: String

        /// Primary tab label.
        let moduleName: String

        /// Secondary tab label.
        let reference: String
    }

    /**
     Returns non-Bible document tab labels from the active controller's rendered-content token.

     Android links-window results use the fake general-book document `Multi`. For that identity, the
     bottom tab displays the document initials without a secondary Bible reference because the
     underlying key is a `BookAndKeyList`, not a user-facing chapter label. Other non-Bible rendered
     documents keep their existing module/reference token display.

     - Parameter window: Window whose controller may have rendered non-Bible content.
     - Returns: Display labels for non-Bible rendered content, or `nil` for ordinary Bible content.
     - Side effects: None.
     - Failure modes: Missing controller state, malformed tokens, or empty module labels return
       `nil` so the tab uses persisted `PageManager` fields.
     */
    private func renderedContentTabState(for window: BibleCore.Window) -> RenderedContentTabState? {
        guard let ctrl = windowManager.controllers[window.id] as? BibleReaderController else { return nil }
        let tokens = BibleReaderRenderedContentState.tokens(from: ctrl.renderedContentState)

        guard let category = tokens["category"],
              category != "none",
              category != DocumentCategory.bible.pageManagerKey,
              let moduleName = nonEmptyToken(tokens["module"]) else {
            return nil
        }

        let reference = AndroidSpecialDocumentIdentity.isMultiDocument(
            categoryName: category,
            moduleName: moduleName
        ) ? "" : nonEmptyToken(tokens["book"]) ?? nonEmptyToken(tokens["key"]) ?? ""
        return RenderedContentTabState(
            categoryName: category,
            moduleName: moduleName,
            reference: reference
        )
    }

    /**
     Returns the persisted module label for a window/category pair.

     - Parameters:
       - window: Window whose `PageManager` stores category-specific module choices.
       - categoryName: Page-manager style category key.
     - Returns: Module initials for the category, falling back to `KJV` for Bible tabs.
     - Side effects: None.
     */
    private func persistedModuleName(for window: BibleCore.Window, categoryName: String) -> String {
        guard let pageManager = window.pageManager else { return "KJV" }
        switch categoryName {
        case DocumentCategory.commentary.pageManagerKey:
            return pageManager.commentaryDocument ?? "Commentary"
        case DocumentCategory.dictionary.pageManagerKey:
            return pageManager.dictionaryDocument ?? "Dictionary"
        case DocumentCategory.generalBook.pageManagerKey:
            return pageManager.generalBookDocument ?? "General Book"
        case DocumentCategory.map.pageManagerKey:
            return pageManager.mapDocument ?? "Map"
        case DocumentCategory.epub.pageManagerKey:
            return pageManager.epubIdentifier ?? "EPUB"
        default:
            return pageManager.bibleDocument ?? "KJV"
        }
    }

    /**
     Returns the icon asset used for a tab's primary document role.

     Android shows the link icon for links-window tabs, including the synthetic `Multi` result
     document. Non-links windows keep the existing category icon behavior.

     - Parameters:
       - window: Window represented by the tab.
       - categoryName: Page-manager style category key currently displayed by the tab.
     - Returns: Asset-catalog icon name for `ToolbarAssetIcon`.
     - Side effects: None.
     */
    private func iconName(for window: BibleCore.Window, categoryName: String) -> String {
        if window.isLinksWindow {
            return "SettingsIconLink"
        }
        return categoryName == DocumentCategory.commentary.pageManagerKey ? "ToolbarCommentary" : "ToolbarBible"
    }

    /**
     Converts rendered-content token values into optional display strings.

     - Parameter token: Token emitted by `BibleReaderController.renderedContentState`.
     - Returns: Non-empty token value unless it is the sentinel `none`.
     - Side effects: None.
     */
    private func nonEmptyToken(_ token: String?) -> String? {
        guard let token, token != "none", !token.isEmpty else { return nil }
        return token
    }

    /// Stable XCUITest summary of one tab's current state.
    private func windowTabAccessibilityValue(
        isActive: Bool,
        isMinimized: Bool,
        categoryName: String,
        moduleName: String,
        reference: String
    ) -> String {
        func token(_ raw: String) -> String {
            raw
                .replacingOccurrences(of: ";", with: "_")
                .replacingOccurrences(of: ",", with: "_")
                .replacingOccurrences(of: "\n", with: " ")
        }

        return [
            "state=\(isActive ? "active" : "inactive")",
            "minimized=\(isMinimized)",
            "category=\(categoryName)",
            "module=\(token(moduleName))",
            "reference=\(token(reference))",
        ].joined(separator: ";")
    }

    /// Returns a compact OSIS-style reference summary for display inside the tab pill.
    private func shortReference(for window: BibleCore.Window) -> String {
        guard !isAndroidMultiDocument(window) else { return "" }

        // Use controller's dynamic book list if available, otherwise fallback to static
        if let ctrl = windowManager.controllers[window.id] as? BibleReaderController {
            return "\(ctrl.osisBookId(for: ctrl.currentBook)) \(ctrl.currentChapter)"
        }
        guard let pm = window.pageManager else { return "" }
        let books = BibleReaderController.defaultBooks
        guard let bookIndex = pm.bibleBibleBook,
              bookIndex >= 0, bookIndex < books.count else { return "" }
        let book = books[bookIndex]
        let chapter = pm.bibleChapterNo ?? 1
        return "\(book.osisId) \(chapter)"
    }

    /// Copies the current reference for the given window and triggers toast feedback.
    private func copyReference(for window: BibleCore.Window) {
        let ref = fullReference(for: window)
        guard !ref.isEmpty else { return }
        #if os(iOS)
        UIPasteboard.general.string = ref
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ref, forType: .string)
        #endif
        onShowToast?(String(localized: "reference_copied"))
    }

    /// Returns the full human-readable reference string for copy-to-clipboard actions.
    private func fullReference(for window: BibleCore.Window) -> String {
        guard !isAndroidMultiDocument(window) else { return "" }

        // Try to get reference from controller if available
        if let ctrl = windowManager.controllers[window.id] as? BibleReaderController {
            return "\(ctrl.currentBook) \(ctrl.currentChapter) (\(ctrl.activeModuleName))"
        }
        // Fallback to PageManager data
        guard let pm = window.pageManager else { return "" }
        let books = BibleReaderController.defaultBooks
        let moduleName = pm.bibleDocument ?? "KJV"
        guard let bookIndex = pm.bibleBibleBook,
              bookIndex >= 0, bookIndex < books.count else { return "" }
        let book = books[bookIndex]
        let chapter = pm.bibleChapterNo ?? 1
        return "\(book.name) \(chapter) (\(moduleName))"
    }

    /**
     Identifies the Android synthetic `Multi` page for one tab.

     The controller is authoritative while attached because it may have just rendered a transient
     document. The persisted PageManager identity covers restored windows before controller
     registration completes.

     - Parameter window: Window represented by the tab.
     - Returns: `true` when the tab is showing Android's `general_book` + `Multi` fake document.
     - Side effects: None.
     */
    private func isAndroidMultiDocument(_ window: BibleCore.Window) -> Bool {
        if let ctrl = windowManager.controllers[window.id] as? BibleReaderController,
           ctrl.isShowingAndroidMultiDocument {
            return true
        }

        guard let pm = window.pageManager else { return false }
        return AndroidSpecialDocumentIdentity.isMultiDocument(
            categoryName: pm.currentCategoryName,
            moduleName: pm.generalBookDocument
        )
    }

    /**
     Resolves Android page-level syncability for the tab's current document.

     Attached controllers are authoritative because transient links-window content may be rendered
     before persisted PageManager fields settle. Restored windows fall back to PageManager category
     state; Android marks general-book pages, including `Multi` and EPUB-like content, as
     non-syncable while dictionary/map/default pages remain syncable.

     - Parameter window: Window represented by the tab.
     - Returns: `true` when sync controls should be visible for the tab's current page.
     - Side effects: None.
     */
    private func isWindowSyncable(_ window: BibleCore.Window) -> Bool {
        if let ctrl = windowManager.controllers[window.id] as? BibleReaderController {
            return ctrl.isCurrentPageSyncable
        }

        guard let pm = window.pageManager else { return true }
        let categoryName = pm.currentCategoryName
        return categoryName != DocumentCategory.generalBook.pageManagerKey
            && categoryName != DocumentCategory.epub.pageManagerKey
    }
}
