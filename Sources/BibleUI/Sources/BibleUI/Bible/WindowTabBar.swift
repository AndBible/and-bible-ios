// WindowTabBar.swift — Bottom tab bar showing open document windows

import SwiftUI
import BibleCore

/// Horizontal scrollable tab bar at the bottom of BibleReaderView showing all windows.
/// Active window has accent highlight, visible windows have normal styling,
/// minimized windows appear dimmed with dashed borders. Tap minimized tabs to restore.
struct WindowTabBar: View {
    @Environment(WindowManager.self) private var windowManager

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
            if isMinimized {
                Button(String(localized: "restore"), systemImage: "arrow.up.left.and.arrow.down.right") {
                    windowManager.restoreWindow(window)
                }
            } else {
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
                            SwiftUI.Label("Group \(group)", systemImage: "checkmark")
                        } else {
                            Text("Group \(group)")
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
        guard let pm = window.pageManager else { return "" }
        guard let bookIndex = pm.bibleBibleBook,
              bookIndex >= 0, bookIndex < BibleReaderController.allBooks.count else { return "" }
        let book = BibleReaderController.allBooks[bookIndex]
        let chapter = pm.bibleChapterNo ?? 1
        let osisId = BibleReaderController.osisBookId(for: book)
        return "\(osisId) \(chapter)"
    }
}
