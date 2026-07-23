// AndroidResourcePalette.swift -- Shared named Android color resources

import SwiftUI

/**
 Central SwiftUI projection of named Android color resources used outside theme inheritance.

 These are exact tokens from Android `res/values/colors.xml`, not screenshot samples or
 feature-local approximations. Workspace/window surfaces should continue to use their owner palette;
 this type is only for Android controls that explicitly reference a fixed named resource.
 */
enum AndroidResourcePalette {
    /// Android framework `Color.GRAY` (`#808080`).
    static let gray = color(argb: 0xFF808080)

    /// Android framework `@android:color/darker_gray` (`#aaaaaa`).
    static let darkerGray = color(argb: 0xFFAAAAAA)

    /// Android `R.color.grey_500` (`#9e9e9e`).
    static let grey500 = color(argb: 0xFF9E9E9E)

    /// Android `R.color.grey_600` (`#757575`) used by document category and About icons.
    static let grey600 = color(argb: 0xFF757575)

    /// Android `R.color.blue_200` (`#afbfff`).
    static let blue200 = color(argb: 0xFFAFBFFF)

    /// Android `R.color.yellow_600` (`#fdd835`) used by the recommended-document star.
    static let yellow600 = color(argb: 0xFFFDD835)

    /// Exact tint from Android `ic_star_filled_24` (`#ffb300`).
    static let promptFavoriteFilled = color(argb: 0xFFFFB300)

    /// Exact tint from Android `ic_star_outline_24` (`#808080`).
    static let promptFavoriteOutline = gray

    /// Android `R.color.night_dialog_background` (`#303030`) used by app window surfaces.
    static let nightDialogBackground = color(argb: 0xFF303030)

    /// Exact fill from Android `ic_check_green_24dp` and `ic_arrow_downward_green_24dp`.
    static let documentInstalledGreen = color(argb: 0xFF00D403)

    /// Exact fill from Android `ic_arrow_upward_amber_24dp`.
    static let documentUpgradeAmber = color(argb: 0xFFFF9900)

    /// Exact fill from Android `ic_warning_red_24dp`.
    static let documentErrorRed = color(argb: 0xFFFF0000)

    /// Android `R.color.log_info` used by agent information rows and model links.
    static let agentLogInformation = color(argb: 0xFF2196F3)

    /// Android `R.color.log_action` used by active tool-call rows.
    static let agentLogAction = color(argb: 0xFFFF9800)

    /// Android `R.color.log_permission` used by permission-request rows.
    static let agentLogPermission = color(argb: 0xFF9C27B0)

    /// Android `R.color.log_error` used by failed agent rows.
    static let agentLogError = color(argb: 0xFFF44336)

    /// Android `R.color.log_comment` used by assistant-comment rows.
    static let agentLogComment = color(argb: 0xFF78909C)

    /** Converts one unsigned Android ARGB resource value to SwiftUI color. */
    private static func color(argb: UInt32) -> Color {
        Color(argbInt: Int(Int32(bitPattern: argb)))
    }
}
