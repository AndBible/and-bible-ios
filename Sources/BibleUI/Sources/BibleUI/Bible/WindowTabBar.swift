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
 variable-width iOS text chips.

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

    /// Presents transient toast feedback in the parent reader.
    var onShowToast: ((String) -> Void)?

    /// Opens the native book chooser when the user selects the browse fallback.
    var onShowBookChooser: (() -> Void)?

    /// Attempts typed-reference navigation for a specific window and reports success/failure.
    var onGoToTypedRef: ((Window, String) -> Bool)?

    /// Controls presentation of the typed-reference alert from the tab context menu.
    @State private var showGoToRefAlert = false

    /// Draft typed-reference text bound to the alert text field.
    @State private var goToRefText = ""

    /// Window targeted by the currently presented typed-reference alert.
    @State private var goToRefWindow: Window?

    /// Whether a visible pane is still opening and should block more user-created windows.
    private var isAddWindowDisabled: Bool {
        // Controller registry updates bump this marker; the pending check is derived from registry state.
        _ = windowManager.controllerVersion
        return windowManager.hasPendingVisibleControllerRegistration
    }

    var body: some View {
        let tabPalette = AndroidWindowTabPalette.resolved(for: surfacePalette)
        let restoreButtonsVisible = windowManager.activeWorkspace?.workspaceSettings?.restoreButtonsVisible ?? true

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
        }
        .frame(height: WindowTabBarLayout.barHeight)
        .accessibilityIdentifier("windowTabBar")
        .foregroundStyle(surfacePalette.foregroundColor)
        .background(surfacePalette.backgroundColor)
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
                    .strokeBorder(tabPalette.strokeColor, lineWidth: 1)
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
        Button {
            windowManager.unmaximize()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(tabPalette.visibleButtonBackgroundColor)

                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(tabPalette.windowButtonTextColor)
            }
            .frame(width: WindowTabBarLayout.fixedButtonSize, height: WindowTabBarLayout.fixedButtonSize)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(tabPalette.strokeColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("windowTabUnmaximizeButton")
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

    /// Builds the Android-style compact button for one window, including context menu actions.
    private func windowTab(for window: Window, tabPalette: AndroidWindowTabPalette) -> some View {
        let isMinimized = window.layoutState == "minimized"
        let isActive = !isMinimized && window.id == windowManager.activeWindow?.id
        let renderedState = renderedContentTabState(for: window)
        let categoryName = renderedState?.categoryName ?? window.pageManager?.currentCategoryName ?? "bible"
        let icon = iconName(for: window, categoryName: categoryName)
        let moduleName = renderedState?.moduleName ?? persistedModuleName(for: window, categoryName: categoryName)
        let reference = renderedState?.reference ?? shortReference(for: window)
        let canCopyReference = !fullReference(for: window).isEmpty
        let canMoveWindow = !window.isLinksWindow && !windowManager.isMaximized
        let canSyncWindow = isWindowSyncable(window)
        let autoPinEnabled = windowManager.activeWorkspace?.workspaceSettings?.autoPin ?? false
        let canPinWindow = !window.isLinksWindow && !windowManager.isMaximized && !autoPinEnabled
        let topCornerRadius: CGFloat = (window.isPinMode || window.isLinksWindow) ? 6 : 1
        let tabShape = UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading: topCornerRadius,
                bottomLeading: 0,
                bottomTrailing: 0,
                topTrailing: topCornerRadius
            )
        )

        return Button {
            if isMinimized {
                windowManager.restoreWindow(window)
            } else {
                windowManager.activeWindow = window
            }
        } label: {
            ZStack(alignment: .topLeading) {
                tabShape
                    .fill(tabPalette.backgroundColor(isActive: isActive, isVisible: !isMinimized))

                if windowManager.isMaximized {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(tabPalette.windowButtonTextColor)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear
                            .frame(height: 13)

                        Text(reference.isEmpty ? " " : reference)
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(tabPalette.windowButtonTextColor)
                            .lineLimit(1)
                            .minimumScaleFactor(0.45)
                            .frame(height: 10, alignment: .leading)

                        Text(moduleName)
                            .font(.system(size: 12, weight: isMinimized ? .regular : .semibold))
                            .foregroundStyle(tabPalette.windowButtonTextColor)
                            .lineLimit(1)
                            .minimumScaleFactor(0.45)
                            .frame(height: 16, alignment: .leading)
                    }
                    .padding(.leading, 2)
                    .padding(.trailing, 1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

                    ToolbarAssetIcon(name: icon, size: 14)
                        .foregroundStyle(window.isLinksWindow ? tabPalette.linksIconColor : tabPalette.categoryIconColor)
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
                        .foregroundStyle(tabPalette.statusIconColor)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.top, 2)
                        .padding(.leading, 1)
                    }

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
                            : StrokeStyle(lineWidth: isActive ? 3 : 1)
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
                    windowManager.activeWindow = window
                    goToRefWindow = window
                    goToRefText = ""
                    showGoToRefAlert = true
                }
            }

            Divider()

            if isMinimized {
                Button(String(localized: "restore"), systemImage: "arrow.up.left.and.arrow.down.right") {
                    windowManager.restoreWindow(window)
                }
            } else {
                // Move window actions
                if canMoveWindow && windowManager.visibleWindows.count > 1 {
                    let sorted = windowManager.visibleWindows.sorted { $0.orderNumber < $1.orderNumber }
                    let currentIndex = sorted.firstIndex(where: { $0.id == window.id })

                    Button(String(localized: "move_up"), systemImage: "arrow.up") {
                        guard let idx = currentIndex, idx > 0 else { return }
                        windowManager.swapWindowOrder(window, sorted[idx - 1])
                    }
                    .disabled(currentIndex == nil || currentIndex == 0)

                    Button(String(localized: "move_down"), systemImage: "arrow.down") {
                        guard let idx = currentIndex, idx < sorted.count - 1 else { return }
                        windowManager.swapWindowOrder(window, sorted[idx + 1])
                    }
                    .disabled(currentIndex == nil || currentIndex == sorted.count - 1)

                    Divider()
                }

                Button(String(localized: "minimize"), systemImage: "minus") {
                    windowManager.minimizeWindow(window)
                }
                .disabled(windowManager.visibleWindows.count <= 1)

                if windowManager.isMaximized {
                    Button(String(localized: "restore_size"), systemImage: "arrow.down.right.and.arrow.up.left") {
                        windowManager.unmaximize()
                    }
                } else {
                    Button(String(localized: "maximize"), systemImage: "arrow.up.left.and.arrow.down.right") {
                        windowManager.maximizeWindow(window)
                    }
                }
            }

            Divider()

            if canSyncWindow || canPinWindow {
                if canSyncWindow {
                    Toggle(isOn: Binding(
                        get: { window.isSynchronized },
                        set: { window.isSynchronized = $0 }
                    )) {
                        SwiftUI.Label(String(localized: "sync_scrolling"), systemImage: "arrow.triangle.2.circlepath")
                    }
                }

                if canPinWindow {
                    Toggle(isOn: Binding(
                        get: { window.isPinMode },
                        set: { window.isPinMode = $0 }
                    )) {
                        SwiftUI.Label(String(localized: "pin"), systemImage: "pin")
                    }
                }

                if canSyncWindow {
                    Menu(String(localized: "sync_group")) {
                        ForEach(0..<6) { group in
                            Button {
                                window.syncGroup = group
                            } label: {
                                if window.syncGroup == group {
                                    SwiftUI.Label(String(localized: "Group \(group)"), systemImage: "checkmark")
                                } else {
                                    Text(String(localized: "Group \(group)"))
                                }
                            }
                        }
                    }
                }

                Divider()
            }

            Button(String(localized: "close"), systemImage: "xmark", role: .destructive) {
                windowManager.removeWindow(window)
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
    private func renderedContentTabState(for window: Window) -> RenderedContentTabState? {
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
    private func persistedModuleName(for window: Window, categoryName: String) -> String {
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
    private func iconName(for window: Window, categoryName: String) -> String {
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
    private func shortReference(for window: Window) -> String {
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
    private func copyReference(for window: Window) {
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
    private func fullReference(for window: Window) -> String {
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
    private func isAndroidMultiDocument(_ window: Window) -> Bool {
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
    private func isWindowSyncable(_ window: Window) -> Bool {
        if let ctrl = windowManager.controllers[window.id] as? BibleReaderController {
            return ctrl.isCurrentPageSyncable
        }

        guard let pm = window.pageManager else { return true }
        let categoryName = pm.currentCategoryName
        return categoryName != DocumentCategory.generalBook.pageManagerKey
            && categoryName != DocumentCategory.epub.pageManagerKey
    }
}

/**
 Maps Android window-button resource colors into SwiftUI colors for the reader footer.

 Android defines separate day/night resource values for bottom restore buttons and the add-window
 button. This helper resolves the same colors from the active reader surface brightness so the iOS
 footer follows Android's visual semantics without hard-coding unrelated SwiftUI accent colors.

 Inputs:
 - `ReaderThemeSurfacePalette`: active reader background/foreground pair used to infer whether the
   Android day or night resource tuple should be used.

 Outputs:
 - button fill, stroke, text, category-icon, link-icon, and sync/status-icon colors

 Side effects: none.
 Failure modes: malformed ARGB inputs are handled by truncating to the same 32-bit representation
   used elsewhere in the app's Android color bridge.
 Determinism: pure color derivation; no user defaults, file I/O, or environment reads.
 */
private struct AndroidWindowTabPalette {
    /// Fill used by visible window restore buttons.
    let visibleButtonBackgroundColor: Color

    /// Fill used by minimized or otherwise non-visible restore buttons.
    let hiddenButtonBackgroundColor: Color

    /// Fill used by the add-window button.
    let addButtonBackgroundColor: Color

    /// Neutral restore-button border color.
    let strokeColor: Color

    /// Active restore-button border color.
    let activeStrokeColor: Color

    /// Text color for compact title/document labels.
    let windowButtonTextColor: Color

    /// Tint for ordinary document category icons.
    let categoryIconColor: Color

    /// Tint for Android links-window icons.
    let linksIconColor: Color

    /// Tint for sync and pin overlays.
    let statusIconColor: Color

    /**
     Resolves Android day/night window-button colors from the active reader surface.

     - Parameter surfacePalette: Reader chrome palette derived from text display settings.
     - Returns: An Android resource color tuple represented as SwiftUI colors.
     - Side effects: None.
     - Failure modes: None; color integer parsing is deterministic for all inputs.
     */
    static func resolved(for surfacePalette: ReaderThemeSurfacePalette) -> AndroidWindowTabPalette {
        if isDarkSurface(surfacePalette.backgroundColorInt) {
            return AndroidWindowTabPalette(
                visibleButtonBackgroundColor: color(argb: 0xFF6A6A6A),
                hiddenButtonBackgroundColor: color(argb: 0xFF2E2E2E),
                addButtonBackgroundColor: color(argb: 0xB7525252),
                strokeColor: color(argb: 0xFF686868),
                activeStrokeColor: color(argb: 0xFF002AFF),
                windowButtonTextColor: color(argb: 0xFF939393),
                categoryIconColor: color(argb: 0xFF939393),
                linksIconColor: color(argb: 0xFF7088FF),
                statusIconColor: color(argb: 0xFF939393)
            )
        }

        return AndroidWindowTabPalette(
            visibleButtonBackgroundColor: color(argb: 0xFF535353),
            hiddenButtonBackgroundColor: color(argb: 0xFF878787),
            addButtonBackgroundColor: color(argb: 0xB7525252),
            strokeColor: color(argb: 0xFF686868),
            activeStrokeColor: color(argb: 0xFF002AFF),
            windowButtonTextColor: color(argb: 0xFFE8E8E8),
            categoryIconColor: color(argb: 0xFFAAAAAA),
            linksIconColor: color(argb: 0xFF7088FF),
            statusIconColor: color(argb: 0xFFE8E8E8)
        )
    }

    /**
     Returns the fill color for a document window button.

     - Parameters:
       - isActive: Whether the represented window is the active reader window.
       - isVisible: Whether the represented window is currently visible rather than minimized.
     - Returns: Android visible or hidden button fill color.
     - Side effects: None.
     - Failure modes: None.
     */
    func backgroundColor(isActive: Bool, isVisible: Bool) -> Color {
        isActive || isVisible ? visibleButtonBackgroundColor : hiddenButtonBackgroundColor
    }

    /**
     Converts an Android unsigned ARGB resource value into SwiftUI `Color`.

     - Parameter argb: Android ARGB resource value, including alpha.
     - Returns: SwiftUI color using the app's signed-ARGB bridge initializer.
     - Side effects: None.
     - Failure modes: None; bit-pattern conversion preserves all 32 bits.
     */
    private static func color(argb: UInt32) -> Color {
        Color(argbInt: Int(Int32(bitPattern: argb)))
    }

    /**
     Classifies the active reader surface as dark or light for Android resource selection.

     - Parameter argbInt: Signed Android ARGB integer from `ReaderThemeSurfacePalette`.
     - Returns: `true` when relative luminance is below the midpoint.
     - Side effects: None.
     - Failure modes: None; invalid sign-extension cases are normalized by truncating to 32 bits.
     */
    private static func isDarkSurface(_ argbInt: Int) -> Bool {
        let value = UInt32(bitPattern: Int32(truncatingIfNeeded: argbInt))
        let red = Double((value >> 16) & 0xFF)
        let green = Double((value >> 8) & 0xFF)
        let blue = Double(value & 0xFF)
        let luminance = ((0.2126 * red) + (0.7152 * green) + (0.0722 * blue)) / 255
        return luminance < 0.5
    }
}
