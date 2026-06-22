// AndroidPopupMenu.swift -- Shared Android-style popup menu primitives

import SwiftUI

/// Icon source for a row in an Android-parity popup menu.
enum AndroidPopupMenuIcon: Equatable {
    /// Uses a ported AndBible toolbar/drawer asset by asset catalog name.
    case asset(String)

    /// Uses an SF Symbol when the corresponding Android drawable has not been ported yet.
    case system(String)
}

/// Trailing accessory rendered at the end of an Android-parity popup row.
enum AndroidPopupMenuAccessory: Equatable {
    /// No trailing accessory.
    case none

    /// A square checkbox whose filled state is controlled by the caller.
    case checkbox(isOn: Bool)

    /// A right chevron used for rows that drill into a submenu.
    case disclosure
}

/**
 Shared popup surface used by Android-style toolbar and pane menus.

 The surface owns only the common background and accessibility container styling. Callers own
 placement, clipping, shadowing, dismissal, submenu state, and command side effects so the same
 row/surface contract can be reused by toolbar overflow, pane menus, and future Android-parity
 popups without tying them to one presentation strategy.
 */
struct AndroidPopupMenuSurface<Content: View>: View {
    /// Active platform color scheme used to mirror Android's darker popup background in night mode.
    let colorScheme: ColorScheme

    /// Accessibility identifier assigned to the complete popup menu container.
    let accessibilityIdentifier: String

    /// Menu content supplied by the caller.
    private let content: Content

    /**
     Creates a reusable Android-style popup surface.

     - Parameters:
       - colorScheme: Current SwiftUI color scheme used only to resolve the surface background.
       - accessibilityIdentifier: Stable UI-test identifier for the menu container.
       - content: Rows, dividers, and optional scroll containers rendered inside the surface.
     - Side effects: none; command execution is owned by row actions supplied in `content`.
     - Failure modes: none.
     */
    init(
        colorScheme: ColorScheme,
        accessibilityIdentifier: String,
        @ViewBuilder content: () -> Content
    ) {
        self.colorScheme = colorScheme
        self.accessibilityIdentifier = accessibilityIdentifier
        self.content = content()
    }

    var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(accessibilityIdentifier)
            .background(backgroundColor)
    }

    /// Surface color matching the existing Android-style overflow popup behavior.
    private var backgroundColor: Color {
        if colorScheme == .dark {
            return Color(red: 0.22, green: 0.22, blue: 0.22)
        }
        #if os(iOS)
        return Color(uiColor: .systemBackground)
        #elseif os(macOS)
        return Color(nsColor: .windowBackgroundColor)
        #endif
    }
}

/**
 One tappable row in an Android-style popup menu.

 The row preserves Android menu layout concerns in one place: optional leading icon, title text,
 optional trailing checkbox or disclosure chevron, stable accessibility metadata, and a plain
 tap action. It intentionally does not decide which rows are visible, checkable, or submenus; those
 semantics come from the caller's Android-parity menu model.
 */
struct AndroidPopupMenuRow: View {
    /// Localized display title shown in the row.
    let title: String

    /// Optional leading icon source. Omitted when Android row data has no icon.
    let icon: AndroidPopupMenuIcon?

    /// Optional trailing accessory such as a checkbox or submenu chevron.
    let accessory: AndroidPopupMenuAccessory

    /// Stable UI-test identifier for this row.
    let accessibilityIdentifier: String?

    /// Optional accessibility value, primarily used for checkable rows.
    let accessibilityValue: String?

    /// Command executed when the row is tapped.
    let action: () -> Void

    /**
     Creates a reusable Android-style popup row.

     - Parameters:
       - title: Localized title already resolved by the caller.
       - icon: Optional Android asset or fallback symbol to draw before the title.
       - accessory: Optional trailing checkbox or submenu chevron.
       - accessibilityIdentifier: Optional stable identifier for UI automation.
       - accessibilityValue: Optional value such as `on`/`off` for checkable rows.
       - action: Main-actor command to run when the user taps the row.
     - Side effects: invoking `action` may mutate reader/window state; the row itself has none.
     - Failure modes: none; callers decide whether an action should be present.
     */
    init(
        title: String,
        icon: AndroidPopupMenuIcon? = nil,
        accessory: AndroidPopupMenuAccessory = .none,
        accessibilityIdentifier: String? = nil,
        accessibilityValue: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.accessory = accessory
        self.accessibilityIdentifier = accessibilityIdentifier
        self.accessibilityValue = accessibilityValue
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            rowLabel
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .androidPopupMenuAccessibility(identifier: accessibilityIdentifier, value: accessibilityValue)
    }

    /// Visual row content shared by toolbar overflow and pane popup menus.
    private var rowLabel: some View {
        HStack(spacing: 12) {
            if let icon {
                iconView(icon)
                    .frame(width: 18, height: 18)
                    .foregroundStyle(.secondary)
            }

            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.9)

            Spacer(minLength: 12)

            accessoryView
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    /// Resolves either a ported Android asset or a temporary SF Symbol fallback.
    @ViewBuilder
    private func iconView(_ icon: AndroidPopupMenuIcon) -> some View {
        switch icon {
        case .asset(let name):
            ToolbarAssetIcon(name: name, size: 16)
        case .system(let name):
            Image(systemName: name)
                .font(.system(size: 16, weight: .semibold))
        }
    }

    /// Draws the optional trailing checkbox/disclosure affordance.
    @ViewBuilder
    private var accessoryView: some View {
        switch accessory {
        case .none:
            EmptyView()
        case .checkbox(let isOn):
            Image(systemName: isOn ? "checkmark.square.fill" : "square")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isOn ? checkboxTint : .secondary)
        case .disclosure:
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    /// Android-style checkbox tint reused from the existing reader overflow menu.
    private var checkboxTint: Color {
        Color(red: 111.0 / 255.0, green: 214.0 / 255.0, blue: 209.0 / 255.0)
    }
}

private extension View {
    /**
     Applies optional menu-row accessibility metadata without creating empty identifiers.

     - Parameters:
       - identifier: Stable UI-test identifier, when the caller has one.
       - value: Optional accessibility value such as `on` or `off`.
     - Returns: The original view with only the non-empty accessibility metadata applied.
     - Side effects: none.
     - Failure modes: none.
     */
    @ViewBuilder
    func androidPopupMenuAccessibility(identifier: String?, value: String?) -> some View {
        if let identifier, let value {
            self
                .accessibilityIdentifier(identifier)
                .accessibilityValue(value)
        } else if let identifier {
            self.accessibilityIdentifier(identifier)
        } else if let value {
            self.accessibilityValue(value)
        } else {
            self
        }
    }
}
