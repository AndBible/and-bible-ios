// AndroidPopupMenu.swift -- Shared Android-style popup menu primitives

import SwiftUI

/// Environment key carrying the owning app/workspace popup's primary text color into shared rows.
private struct AndroidPopupMenuPrimaryTextKey: EnvironmentKey {
    static let defaultValue = Color.primary
}

/// Environment key carrying the owning app/workspace popup's secondary text color into shared rows.
private struct AndroidPopupMenuSecondaryTextKey: EnvironmentKey {
    static let defaultValue = Color.secondary
}

/// Environment key carrying the owning app/workspace popup's selection accent into shared rows.
private struct AndroidPopupMenuAccentKey: EnvironmentKey {
    static let defaultValue = Color.accentColor
}

private extension EnvironmentValues {
    var androidPopupMenuPrimaryText: Color {
        get { self[AndroidPopupMenuPrimaryTextKey.self] }
        set { self[AndroidPopupMenuPrimaryTextKey.self] = newValue }
    }

    var androidPopupMenuSecondaryText: Color {
        get { self[AndroidPopupMenuSecondaryTextKey.self] }
        set { self[AndroidPopupMenuSecondaryTextKey.self] = newValue }
    }

    var androidPopupMenuAccent: Color {
        get { self[AndroidPopupMenuAccentKey.self] }
        set { self[AndroidPopupMenuAccentKey.self] = newValue }
    }
}

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

 The surface owns Android's common background, shape, elevation, palette propagation, and
 accessibility containment. Callers own only placement, dismissal state, submenu state, and
 command side effects. Centralizing the visual window prevents feature-local menus from inventing
 different corners, shadows, and borders while claiming to use the same application component.
 */
struct AndroidPopupMenuSurface<Content: View>: View {
    /// Active platform color scheme used to mirror Android's darker popup background in night mode.
    let colorScheme: ColorScheme

    /// Accessibility identifier assigned to the complete popup menu container.
    let accessibilityIdentifier: String

    /// Optional workspace/window-owned surface color; nil resolves the global application palette.
    let suppliedBackgroundColor: Color?

    /// Optional workspace/window-owned primary text color.
    let suppliedPrimaryTextColor: Color?

    /// Optional workspace/window-owned secondary text color.
    let suppliedSecondaryTextColor: Color?

    /// Optional workspace/window-owned checked/selected accent color.
    let suppliedAccentColor: Color?

    /// Menu content supplied by the caller.
    private let content: Content

    /**
     Creates a reusable Android-style popup surface.

     - Parameters:
       - colorScheme: Current SwiftUI color scheme used only to resolve the surface background.
       - accessibilityIdentifier: Stable UI-test identifier for the menu container.
       - backgroundColor: Workspace/window surface color, or nil for the global app palette.
       - primaryTextColor: Workspace/window primary text, or nil for the global app palette.
       - secondaryTextColor: Workspace/window secondary text, or nil for the global app palette.
       - accentColor: Workspace/window accent, or nil for the global app palette.
       - content: Rows, dividers, and optional scroll containers rendered inside the surface.
     - Side effects: none; command execution is owned by row actions supplied in `content`.
     - Failure modes: none.
     */
    init(
        colorScheme: ColorScheme,
        accessibilityIdentifier: String,
        backgroundColor: Color? = nil,
        primaryTextColor: Color? = nil,
        secondaryTextColor: Color? = nil,
        accentColor: Color? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.colorScheme = colorScheme
        self.accessibilityIdentifier = accessibilityIdentifier
        suppliedBackgroundColor = backgroundColor
        suppliedPrimaryTextColor = primaryTextColor
        suppliedSecondaryTextColor = secondaryTextColor
        suppliedAccentColor = accentColor
        self.content = content()
    }

    var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .contain)
            .environment(\.androidPopupMenuPrimaryText, resolvedPrimaryTextColor)
            .environment(\.androidPopupMenuSecondaryText, resolvedSecondaryTextColor)
            .environment(\.androidPopupMenuAccent, resolvedAccentColor)
            .background(resolvedBackgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.36 : 0.24),
                radius: 12,
                y: 6
            )
            .androidAccessibilityIdentityMarker(
                label: "",
                accessibilityIdentifier: accessibilityIdentifier,
                surfaceColor: resolvedBackgroundColor
            )
    }

    /// Surface color supplied by the owner or resolved by the shared application palette.
    private var resolvedBackgroundColor: Color {
        suppliedBackgroundColor ?? AndroidDialogSurfacePalette.background(for: colorScheme)
    }

    /// Primary row text supplied by the owner or resolved by the shared application palette.
    private var resolvedPrimaryTextColor: Color {
        suppliedPrimaryTextColor ?? AndroidDialogSurfacePalette.primaryText(for: colorScheme)
    }

    /// Secondary icon/accessory text supplied by the owner or resolved globally.
    private var resolvedSecondaryTextColor: Color {
        suppliedSecondaryTextColor ?? AndroidDialogSurfacePalette.secondaryText(for: colorScheme)
    }

    /// Selection accent supplied by the owner or resolved globally.
    private var resolvedAccentColor: Color {
        suppliedAccentColor ?? AndroidDialogSurfacePalette.accent(for: colorScheme)
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
    /// Owner-resolved primary text inherited from `AndroidPopupMenuSurface`.
    @Environment(\.androidPopupMenuPrimaryText) private var primaryTextColor

    /// Owner-resolved icon/accessory text inherited from `AndroidPopupMenuSurface`.
    @Environment(\.androidPopupMenuSecondaryText) private var secondaryTextColor

    /// Owner-resolved checkbox accent inherited from `AndroidPopupMenuSurface`.
    @Environment(\.androidPopupMenuAccent) private var accentColor

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

    /// Whether the row can execute its command and receives normal enabled emphasis.
    let isEnabled: Bool

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
       - isEnabled: Whether the row is interactive; defaults to true for existing consumers.
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
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.accessory = accessory
        self.accessibilityIdentifier = accessibilityIdentifier
        self.accessibilityValue = accessibilityValue
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            rowLabel
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .androidPopupMenuAccessibility(identifier: accessibilityIdentifier, value: accessibilityValue)
    }

    /// Visual row content shared by toolbar overflow and pane popup menus.
    private var rowLabel: some View {
        HStack(spacing: 12) {
            if let icon {
                iconView(icon)
                    .frame(width: 18, height: 18)
                    .foregroundStyle(secondaryTextColor)
            }

            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(primaryTextColor)
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
                .foregroundStyle(isOn ? accentColor : secondaryTextColor)
        case .disclosure:
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(secondaryTextColor)
        }
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
