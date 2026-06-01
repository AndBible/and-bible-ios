import SwiftUI

/**
 Shared label layout for Android-shaped native SwiftUI settings rows.

 The view keeps the Android preference-screen geometry, icon placement, and title/summary hierarchy
 while inheriting iOS system text colors and accent tint from the active app theme. It intentionally
 does not own controls such as `Toggle`, `Picker`, or `NavigationLink`; those native controls wrap
 the label so interaction, accessibility, and platform theming stay SwiftUI-native.

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

    /// Fixed icon column width matching Android preference row geometry.
    private let iconColumnWidth: CGFloat = 48

    /// Default Android-style preference icon size in points.
    private let iconSize: CGFloat = 34

    /// Complete title/summary/detail label with a stable leading icon column.
    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            iconColumn

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(isEnabled ? .primary : .tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if let summary, !summary.isEmpty {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(isEnabled ? .secondary : .tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    /// Leading icon column, or an empty spacer for rows without Android icon metadata.
    @ViewBuilder
    private var iconColumn: some View {
        if let icon {
            AndBibleIconView(name: icon.assetName, size: iconSize)
                .foregroundStyle(isEnabled ? .secondary : .tertiary)
                .frame(width: iconColumnWidth, alignment: .center)
                .accessibilityHidden(true)
        } else {
            Color.clear
                .frame(width: iconColumnWidth, height: iconSize)
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

    /// Leading space reserved for row icons, matching `AndBibleSettingsRowLabel`.
    private let textOffset: CGFloat = 66

    /// Accent-colored section title aligned to the row text column.
    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(Color.accentColor)
            .textCase(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, textOffset)
            .padding(.top, 6)
            .fixedSize(horizontal: false, vertical: true)
    }
}
