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

    /**
     Feature shortcut rows rendered in Android's Application Preferences feature section.

     - Parameters:
       - identifier: Stable accessibility/search identifier used by `SettingsView`.
       - androidKey: Android preference key that owns icon metadata.
       - titleLocalizationKey: Localization key for the visible row title.
       - titleDefault: English fallback used when a localization is missing.
       - summaryLocalizationKey: Localization key for the visible row summary.
       - summaryDefault: English fallback used when a localization is missing.
       - keywords: Search aliases used by the settings search matcher.
     - Returns: Value semantics for package-lane Android parity tests.
     - Side effects: none.
     - Failure modes: Unknown Android keys leave `icon` nil.
     */
    enum FeatureShortcut: Equatable, Sendable {
        /// Device synchronization shortcut backed by Android's sync settings preference row.
        case syncSettings

        /// Reading Progress shortcut backed by Android's progress settings preference row.
        case readingProgressSettings

        /// Stable accessibility/search identifier used by `SettingsView`.
        var identifier: String {
            switch self {
            case .syncSettings:
                return "settingsSyncLink"
            case .readingProgressSettings:
                return "settingsReadingProgressLink"
            }
        }

        /// Android preference key that owns icon metadata.
        var androidKey: String {
            switch self {
            case .syncSettings:
                return "sync_settings_shortcut"
            case .readingProgressSettings:
                return "reading_progress_settings_shortcut"
            }
        }

        /// Android-backed icon metadata for the feature shortcut.
        var icon: AndBibleIcon? {
            AndBibleIconCatalog.settingsIcon(forAndroidKey: androidKey)
        }

        /// Localization key for the visible row title.
        var titleLocalizationKey: String {
            switch self {
            case .syncSettings:
                return "cloud_sync_title"
            case .readingProgressSettings:
                return "reading_progress_settings"
            }
        }

        /// English fallback title used when a localization is missing.
        var titleDefault: String {
            switch self {
            case .syncSettings:
                return "Device synchronization"
            case .readingProgressSettings:
                return "Reading Progress Settings"
            }
        }

        /// Localization key for the visible row summary.
        var summaryLocalizationKey: String {
            switch self {
            case .syncSettings:
                return "icloud_sync_description"
            case .readingProgressSettings:
                return "reading_progress_settings_summary"
            }
        }

        /// English fallback summary used when a localization is missing.
        var summaryDefault: String {
            switch self {
            case .syncSettings:
                return "Sync bookmarks, labels, workspaces, reading plans, and notes across your devices via iCloud. Requires an iCloud account."
            case .readingProgressSettings:
                return "Configure automatic reading and memorization progress tracking."
            }
        }

        /// Search aliases used by the settings search matcher.
        var keywords: [String] {
            switch self {
            case .syncSettings:
                return ["features", "sync", "icloud", "cloud", androidKey]
            case .readingProgressSettings:
                return ["features", "reading", "progress", "memorization", androidKey]
            }
        }

        /// Localized row title used by Settings.
        var title: String {
            switch self {
            case .syncSettings:
                return String(localized: "cloud_sync_title", defaultValue: "Device synchronization")
            case .readingProgressSettings:
                return String(localized: "reading_progress_settings", defaultValue: "Reading Progress Settings")
            }
        }

        /// Localized row summary used by Settings.
        var summary: String {
            switch self {
            case .syncSettings:
                return String(
                    localized: "icloud_sync_description",
                    defaultValue: "Sync bookmarks, labels, workspaces, reading plans, and notes across your devices via iCloud. Requires an iCloud account."
                )
            case .readingProgressSettings:
                return String(
                    localized: "reading_progress_settings_summary",
                    defaultValue: "Configure automatic reading and memorization progress tracking."
                )
            }
        }

        /// Search entry consumed by Settings search and accessibility state exports.
        var searchEntry: AndBibleSettingsSearchEntry {
            AndBibleSettingsSearchEntry(
                identifier: identifier,
                title: title,
                summary: summary,
                keywords: keywords
            )
        }
    }

    /// Sync feature shortcut sourced from Android's settings XML.
    static let syncSettingsShortcut = FeatureShortcut.syncSettings

    /// Reading Progress feature shortcut sourced from Android's settings XML.
    static let readingProgressSettingsShortcut = FeatureShortcut.readingProgressSettings

    /**
     Feature shortcuts currently available from Application Preferences.

     Reading Progress requires an injected progress controller, matching the production
     `SettingsView` destination guard.

     - Parameter canOpenReadingProgressSettings: Whether Reading Progress has a persistence
       controller in this settings instance.
     - Returns: Ordered Android feature shortcuts that should be visible.
     - Side effects: none.
     - Failure modes: none.
     */
    static func featureShortcuts(canOpenReadingProgressSettings: Bool) -> [FeatureShortcut] {
        var shortcuts: [FeatureShortcut] = [syncSettingsShortcut]
        if canOpenReadingProgressSettings {
            shortcuts.append(readingProgressSettingsShortcut)
        }
        return shortcuts
    }

    /**
     Primary settings-link identifiers exported for UI diagnostics.

     - Parameter canOpenReadingProgressSettings: Whether Reading Progress has a persistence
       controller in this settings instance.
     - Returns: Ordered primary link identifiers matching `SettingsView` accessibility state.
     - Side effects: none.
     - Failure modes: none.
     */
    static func primaryLinkIdentifiers(canOpenReadingProgressSettings: Bool) -> [String] {
        ["settingsGlobalTextOptionsLink"] +
            featureShortcuts(canOpenReadingProgressSettings: canOpenReadingProgressSettings).map(\.identifier)
    }
}
