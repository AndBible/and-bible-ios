// WindowTabBar.swift — Bottom tab bar showing open document windows

import SwiftUI
import BibleCore

/// Horizontal scrollable tab bar at the bottom of BibleReaderView showing all windows.
/// Active window has accent highlight, visible windows have normal styling,
/// minimized windows appear dimmed with dashed borders. Tap minimized tabs to restore.
struct WindowTabBar: View {
    @Environment(WindowManager.self) private var windowManager
    var onShowToast: ((String) -> Void)?
    var onShowBookChooser: (() -> Void)?
    /// Callback to navigate a window to a typed reference. Returns true on success.
    var onGoToTypedRef: ((Window, String) -> Bool)?
    @State private var showGoToRefAlert = false
    @State private var goToRefText = ""
    @State private var goToRefWindow: Window?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(windowManager.allWindows, id: \.id) { window in
                    windowTab(for: window)
                }

                // Add window button
                Button {
                    windowManager.addWindow(from: windowManager.activeWindow)
                } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
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

    private func windowTab(for window: Window) -> some View {
        let isMinimized = window.layoutState == "minimized"
        let isActive = !isMinimized && window.id == windowManager.activeWindow?.id
        let categoryName = window.pageManager?.currentCategoryName ?? "bible"
        let icon = categoryName == "commentary" ? "text.book.closed.fill" : "book.fill"
        let moduleName = (categoryName == "commentary"
            ? window.pageManager?.commentaryDocument
            : window.pageManager?.bibleDocument) ?? "KJV"
        let reference = shortReference(for: window)

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

                Image(systemName: icon)
                    .font(.caption2)

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
