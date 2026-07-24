import SwiftUI

/**
 Shared spacing and alignment metrics for Android-shaped native SwiftUI preference screens.

 These constants keep Application Preferences, All Text Options, and related settings surfaces on
 the same visual grid while letting each screen own its controls, navigation, and persistence. The
 metrics intentionally mirror Android preference-list geometry rather than SwiftUI `Form` density:
 row labels have a stable icon column, section headers align to the text column, and rows keep
 enough vertical breathing room for wrapped summaries.

 - Inputs: none; values are fixed layout constants used by sibling SwiftUI settings views.
 - Outputs: CGFloat metrics consumed by row labels, section wrappers, and divider alignment.
 - Side effects: none.
 - Failure modes: none; callers can still override spacing locally when a platform-specific
   control requires it.
 */
enum AndBibleSettingsPreferenceLayout {
    /// Fixed icon column width matching Android preference row geometry.
    static let iconColumnWidth: CGFloat = 48

    /// Default Android-style preference icon size in points.
    static let iconSize: CGFloat = 32

    /// Horizontal gap between the icon column and the row text column.
    static let contentSpacing: CGFloat = 16

    /// Horizontal padding used by full-width flat preference rows.
    static let rowHorizontalPadding: CGFloat = 16

    /// Gap between the row label and trailing controls such as switches or chevrons.
    static let accessorySpacing: CGFloat = 18

    /// Vertical gap between title, summary, and detail labels in one preference row.
    static let labelTextSpacing: CGFloat = 5

    /// Vertical padding applied to the shared label block inside each preference row.
    static let rowVerticalPadding: CGFloat = 11

    /// Spacing below a section header before the first row begins.
    static let sectionHeaderBottomPadding: CGFloat = 14

    /// Spacing after each section before the next section header begins.
    static let sectionBottomPadding: CGFloat = 20

    /// Divider inset that starts row separators at the text column instead of the icon column.
    static var dividerLeadingInset: CGFloat {
        rowHorizontalPadding + iconColumnWidth + contentSpacing
    }
}

/**
 Shared label layout for Android-shaped app-owned settings rows.

 The view keeps the Android preference-screen geometry, icon placement, row density, and
 title/summary hierarchy. Callers may supply the owning reader/workspace palette so a destination
 does not silently fall back to the device color scheme; default values preserve existing global
 settings callers until they also receive an owner palette. Interaction remains with the shared
 app-owned preference row that wraps this label.

 - Parameters:
   - title: Primary row title shown beside the icon column.
   - summary: Optional secondary text shown below the title.
   - detail: Optional tertiary status text shown below the summary.
   - icon: Optional Android-sourced icon metadata from `AndBibleIconCatalog`.
   - isEnabled: Whether text and icon styling should use enabled or disabled emphasis.
 - Returns: A row label suitable for use in `Form` controls and navigation links.
 - Side effects: Renders an image from the module bundle when `icon` is non-nil.
 - Failure modes: Missing image assets follow SwiftUI image placeholder behavior through
   `AndBibleIconView`; long text wraps instead of clipping.
 */
struct AndBibleSettingsRowLabel: View {
    /// Primary row title shown beside the icon column.
    let title: String

    /// Optional secondary text shown below the title.
    var summary: String?

    /// Optional tertiary status text shown below the summary.
    var detail: String?

    /// Optional Android-sourced icon metadata from the shared icon catalog.
    var icon: AndBibleIcon?

    /// Whether text and icon styling should use enabled or disabled emphasis.
    var isEnabled = true

    /// Owner-resolved title color.
    var foregroundColor: Color = .primary

    /// Owner-resolved summary and disabled color.
    var secondaryColor: Color = .secondary

    /// Owner-resolved icon color.
    var iconColor: Color? = nil

    /// Fixed icon column width matching Android preference row geometry.
    static let iconColumnWidth = AndBibleSettingsPreferenceLayout.iconColumnWidth

    /// Default Android-style preference icon size in points.
    static let iconSize = AndBibleSettingsPreferenceLayout.iconSize

    /// Horizontal gap between the icon column and the row text column.
    static let contentSpacing = AndBibleSettingsPreferenceLayout.contentSpacing

    /// Complete title/summary/detail label with a stable leading icon column.
    var body: some View {
        HStack(alignment: .top, spacing: Self.contentSpacing) {
            iconColumn

            VStack(alignment: .leading, spacing: AndBibleSettingsPreferenceLayout.labelTextSpacing) {
                Text(title)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(isEnabled ? foregroundColor : secondaryColor.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)

                if let summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(isEnabled ? secondaryColor : secondaryColor.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(secondaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, AndBibleSettingsPreferenceLayout.rowVerticalPadding)
        .contentShape(Rectangle())
    }

    /// Leading icon column, or an empty spacer for rows without Android icon metadata.
    @ViewBuilder
    private var iconColumn: some View {
        if let icon {
            AndBibleIconView(name: icon.assetName, size: Self.iconSize)
                .foregroundStyle(
                    isEnabled
                        ? (iconColor ?? secondaryColor)
                        : secondaryColor.opacity(0.55)
                )
                .frame(width: Self.iconColumnWidth, alignment: .center)
                .accessibilityHidden(true)
        } else {
            Color.clear
                .frame(width: Self.iconColumnWidth, height: Self.iconSize)
                .accessibilityHidden(true)
        }
    }
}

/**
 Shared section header layout for Android-shaped native SwiftUI settings sections.

 The header aligns with the settings row text column rather than the icon column and uses the active
 app accent color, so dark/light treatment follows the iOS theme instead of hardcoding Android dark
 screenshots.

 - Parameter title: User-visible section title.
 - Returns: A header view suitable for SwiftUI `Section` headers.
 - Side effects: none.
 - Failure modes: Long titles wrap within the available form width.
 */
struct AndBibleSettingsSectionHeader: View {
    /// User-visible section title.
    let title: String

    /// Owner-resolved section accent; defaults to the application accent for legacy callers.
    var accentColor: Color = .accentColor

    /// Leading space reserved for row icons, matching `AndBibleSettingsRowLabel`.
    private let textOffset = AndBibleSettingsRowLabel.iconColumnWidth + AndBibleSettingsRowLabel.contentSpacing

    /// Accent-colored section title aligned to the row text column.
    var body: some View {
        Text(title)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(accentColor)
            .textCase(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, textOffset)
            .padding(.top, AndBibleSettingsPreferenceLayout.sectionHeaderBottomPadding)
            .fixedSize(horizontal: false, vertical: true)
    }
}
