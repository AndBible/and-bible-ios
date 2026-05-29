// WindowTabBar.swift -- Bottom tab bar showing open document windows

import SwiftUI
import BibleCore

/**
 Shows all workspace windows in a horizontal tab strip below the reader.

 The tab bar reflects three window states:
 - active visible window: accent-highlighted border and green status dot
 - inactive visible window: neutral border and gray status dot
 - minimized window: dimmed pill with dashed border and restore-on-tap behavior

 It also hosts typed-reference navigation and the add-window affordance.
 */
struct WindowTabBar: View {
    /// Shared workspace/window coordinator used to read and mutate tab state.
    @Environment(WindowManager.self) private var windowManager

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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(windowManager.allWindows, id: \.id) { window in
                    windowTab(for: window)
                }

                // Add window button
                Button {
                    guard !isAddWindowDisabled else { return }
                    windowManager.addWindow(from: windowManager.activeWindow)
                } label: {
                    Group {
                        if isAddWindowDisabled {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "plus")
                                .font(.caption)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(isAddWindowDisabled)
                .accessibilityIdentifier("windowTabAddButton")
                .accessibilityValue(
                    isAddWindowDisabled
                        ? String(localized: "reader_window_opening", defaultValue: "Window opening")
                        : ""
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .accessibilityIdentifier("windowTabBar")
        .background(.bar)
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

    // MARK: - Window Tab

    /// Builds the tab pill for one window, including context menu actions and state styling.
    private func windowTab(for window: Window) -> some View {
        let isMinimized = window.layoutState == "minimized"
        let isActive = !isMinimized && window.id == windowManager.activeWindow?.id
        let renderedState = renderedContentTabState(for: window)
        let categoryName = renderedState?.categoryName ?? window.pageManager?.currentCategoryName ?? "bible"
        let icon = categoryName == "commentary" ? "ToolbarCommentary" : "ToolbarBible"
        let moduleName = renderedState?.moduleName ?? persistedModuleName(for: window, categoryName: categoryName)
        let reference = renderedState?.reference ?? shortReference(for: window)

        return Button {
            if isMinimized {
                windowManager.restoreWindow(window)
            } else {
                windowManager.activeWindow = window
            }
        } label: {
            HStack(spacing: 4) {
                // Status indicator dot
                if isMinimized {
                    // Minimized: small "eye.slash" icon instead of dot
                    Image(systemName: "eye.slash")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                } else {
                    Circle()
                        .fill(isActive ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 6, height: 6)
                }

                ToolbarAssetIcon(name: icon, size: 12)

                Text(moduleName)
                    .font(.caption.weight(isMinimized ? .regular : .semibold))
                    .lineLimit(1)

                if !isMinimized && !reference.isEmpty {
                    Text(reference)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isActive ? Color.accentColor
                            : isMinimized ? Color.secondary.opacity(0.15)
                            : Color.secondary.opacity(0.3),
                        style: isMinimized
                            ? StrokeStyle(lineWidth: 1, dash: [4, 3])
                            : StrokeStyle(lineWidth: 1)
                    )
            )
            .opacity(isMinimized ? 0.5 : 1.0)
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
                Button(String(localized: "copy_reference"), systemImage: "doc.on.clipboard") {
                    copyReference(for: window)
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
                if windowManager.visibleWindows.count > 1 {
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

            Toggle(isOn: Binding(
                get: { window.isSynchronized },
                set: { window.isSynchronized = $0 }
            )) {
                SwiftUI.Label(String(localized: "sync_scrolling"), systemImage: "arrow.triangle.2.circlepath")
            }

            Toggle(isOn: Binding(
                get: { window.isPinMode },
                set: { window.isPinMode = $0 }
            )) {
                SwiftUI.Label(String(localized: "pin"), systemImage: "pin")
            }

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

            Divider()

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
     Returns transient document tab labels from the active controller when it is not showing Bible text.

     The persisted `PageManager` intentionally remains on the source Bible location for link-result
     documents. Strong's and dictionary documents still need the bottom tab to mirror Android's
     active document label, so this reads the controller's rendered-content token before falling
     back to persisted window state.

     - Parameter window: Window whose controller may have transient rendered content.
     - Returns: Display labels for non-Bible rendered content, or `nil` for ordinary Bible content.
     - Side effects: None.
     - Failure modes: Missing controller state, malformed tokens, or empty module labels return
       `nil` so the tab uses persisted `PageManager` fields.
     */
    private func renderedContentTabState(for window: Window) -> RenderedContentTabState? {
        guard let ctrl = windowManager.controllers[window.id] as? BibleReaderController else { return nil }
        let tokens = Dictionary(uniqueKeysWithValues: ctrl.renderedContentState
            .split(separator: ";")
            .compactMap { part -> (String, String)? in
                let pieces = part.split(separator: "=", maxSplits: 1).map(String.init)
                guard pieces.count == 2 else { return nil }
                return (pieces[0], pieces[1])
            })

        guard let category = tokens["category"],
              category != "none",
              category != DocumentCategory.bible.pageManagerKey,
              let moduleName = nonEmptyToken(tokens["module"]) else {
            return nil
        }

        let reference = nonEmptyToken(tokens["book"]) ?? nonEmptyToken(tokens["key"]) ?? ""
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
}
