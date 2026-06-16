// ApplicationSettingsPresentation.swift - Android-backed application settings row metadata

/**
 Android-backed presentation metadata for the native SwiftUI Application Preferences screen.

 The root settings screen is native SwiftUI on iOS, but rows that exist in Android's
 `settings.xml` should stay tied to their Android keys and icon metadata. Keeping this small
 catalog makes visible parity rows testable without rendering SwiftUI.

 - Returns: Row metadata consumed by `SettingsView` and parity tests.
 - Side effects: none.
 - Failure modes: Missing icon mappings leave `icon` nil rather than crashing.
 */
enum ApplicationSettingsPresentation {
    /**
     One Android-backed root Application Preferences row.

     - Parameters:
       - androidKey: Android `settings.xml` preference key used as the presentation source.
       - icon: Optional icon metadata resolved from `AndBibleIconCatalog`.
     - Returns: Value semantics suitable for tests and SwiftUI row composition.
     - Side effects: none.
     - Failure modes: Unknown Android keys leave `icon` nil.
     */
    struct Row: Equatable, Sendable {
        /// Android `settings.xml` preference key used as the presentation source.
        let androidKey: String

        /// Optional Android-sourced icon metadata for this row.
        let icon: AndBibleIcon?

        /**
         Creates a row from one Android application-settings key.

         - Parameter androidKey: Android `settings.xml` preference key.
         - Returns: A row whose icon is resolved from the shared Android icon catalog.
         - Side effects: none.
         - Failure modes: Unknown keys leave `icon` as `nil`.
         */
        init(androidKey: String) {
            self.androidKey = androidKey
            self.icon = AndBibleIconCatalog.settingsIcon(forAndroidKey: androidKey)
        }
    }

    /// Global text-display settings row sourced from Android `global_text_display_settings`.
    static let globalTextOptions = Row(androidKey: "global_text_display_settings")

    /**
     Android root "Look & feel" rows that iOS exposes as navigation shortcuts.

     Scalar preferences in this category are already represented by `AppPreferenceKey`; this list
     covers structured settings rows that do not fit that scalar registry but still belong in the
     same Android category.
     */
    static let lookAndFeelRows: [Row] = [
        globalTextOptions,
    ]
}
