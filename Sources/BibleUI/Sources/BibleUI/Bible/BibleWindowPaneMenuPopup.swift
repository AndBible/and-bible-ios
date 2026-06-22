// BibleWindowPaneMenuPopup.swift -- Custom Android-style per-pane window menu renderer

import SwiftUI

/**
 Custom renderer for the Android-style per-window hamburger popup.

 `BibleWindowPaneMenuModel` owns ordering, visibility, and command semantics. This view owns only
 interactive popup presentation: rendering shared Android-style rows, showing nested submenus
 inside the same popup surface, and forwarding selected actions to the pane. It deliberately avoids
 `SwiftUI.Menu` so iOS cannot substitute platform-native menu behavior for Android's popup model.
 */
struct BibleWindowPaneMenuPopup: View {
    /// Top-level Android-parity menu items for the active pane.
    let items: [BibleWindowPaneMenuItem]

    /// Current color scheme used by the shared popup surface.
    let colorScheme: ColorScheme

    /// Maximum popup height before menu rows scroll.
    let maximumHeight: CGFloat

    /// Callback for command rows selected by the user.
    let onAction: (BibleWindowPaneMenuAction) -> Void

    /// Submenu navigation stack, with the last item providing the currently visible child rows.
    @State private var submenuStack: [BibleWindowPaneMenuItem] = []

    /**
     Creates a pane window-menu popup.

     - Parameters:
       - items: Top-level menu rows resolved by `BibleWindowPaneMenuModel`.
       - colorScheme: Current color scheme for Android-style popup colors.
       - maximumHeight: Height cap used before enabling row scrolling.
       - onAction: Command callback invoked for terminal rows.
     - Side effects: tapping terminal rows invokes `onAction`; submenu rows mutate local stack state.
     - Failure modes: rows without children and without an action are ignored when tapped.
     */
    init(
        items: [BibleWindowPaneMenuItem],
        colorScheme: ColorScheme,
        maximumHeight: CGFloat = 440,
        onAction: @escaping (BibleWindowPaneMenuAction) -> Void
    ) {
        self.items = items
        self.colorScheme = colorScheme
        self.maximumHeight = maximumHeight
        self.onAction = onAction
    }

    var body: some View {
        AndroidPopupMenuSurface(
            colorScheme: colorScheme,
            accessibilityIdentifier: "windowPaneMenu"
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let submenuTitle = submenuStack.last?.title {
                        AndroidPopupMenuRow(
                            title: submenuTitle,
                            icon: .system("chevron.left"),
                            accessibilityIdentifier: "windowPaneMenuBack"
                        ) {
                            _ = submenuStack.popLast()
                        }
                        Divider()
                    }

                    let visibleItems = currentItems
                    ForEach(visibleItems.indices, id: \.self) { index in
                        if index > 0 {
                            Divider()
                        }
                        row(for: visibleItems[index])
                    }
                }
            }
            .frame(maxHeight: maximumHeight)
        }
        .onChange(of: items) { _, _ in
            submenuStack.removeAll()
        }
    }

    /// Rows currently visible at the top level or inside the active submenu.
    private var currentItems: [BibleWindowPaneMenuItem] {
        submenuStack.last?.children ?? items
    }

    /// Builds one custom popup row from the pure Android-parity menu model.
    private func row(for item: BibleWindowPaneMenuItem) -> some View {
        let hasChildren = !item.children.isEmpty
        return AndroidPopupMenuRow(
            title: item.title,
            icon: icon(for: item),
            accessory: hasChildren ? .disclosure : accessory(for: item),
            accessibilityIdentifier: "windowPaneMenuItem::\(item.id)",
            accessibilityValue: item.isCheckable ? (item.isChecked ? "on" : "off") : nil
        ) {
            if hasChildren {
                submenuStack.append(item)
            } else if let action = item.action {
                onAction(action)
            }
        }
    }

    /// Converts menu model icon data into the shared popup row icon representation.
    private func icon(for item: BibleWindowPaneMenuItem) -> AndroidPopupMenuIcon? {
        guard let systemImage = item.systemImage else { return nil }
        return .system(systemImage)
    }

    /// Converts model checkable state into a row accessory without inferring extra behavior.
    private func accessory(for item: BibleWindowPaneMenuItem) -> AndroidPopupMenuAccessory {
        item.isCheckable ? .checkbox(isOn: item.isChecked) : .none
    }
}
