// SyncSettingsPresentation.swift - Android-backed sync settings row metadata

import BibleCore

/**
 Android string resource descriptor for one localized sync settings label.

 The descriptor keeps the Android resource key and English default together so native iOS callers
 can share one category copy contract without duplicating switch statements across settings rows
 and lifecycle error messages.

 - Returns: Localized text through `localized`.
 - Side effects: none.
 - Failure modes: Missing localization resources fall back to `defaultValue`.
 */
public struct RemoteSyncLocalizedString: Equatable, Sendable {
    /// Android string resource key mirrored by the iOS localization catalog.
    public let key: String

    /// English fallback copied from Android's default `strings.xml`.
    public let defaultValue: String

    /**
     Creates a reusable Android string descriptor.

     - Parameters:
       - key: Android string resource key.
       - defaultValue: English fallback from Android's default resources.
     - Returns: Value semantics suitable for production localization and parity tests.
     - Side effects: none.
     - Failure modes: none.
     */
    public init(key: String, defaultValue: String) {
        self.key = key
        self.defaultValue = defaultValue
    }

    /**
     Resolves the descriptor through Swift localization.

     - Returns: Localized text for `key`, falling back to `defaultValue`.
     - Side effects: Reads the process localization bundle.
     - Failure modes: Missing localization resources fall back to `defaultValue`.
     */
    public var localized: String {
        let localized = String(localized: String.LocalizationValue(key))
        return localized == key ? defaultValue : localized
    }
}

/**
 Android-backed title and content strings for one remote sync category.

 Android exposes each sync category as a preference title plus summary. iOS uses this descriptor
 to keep visible settings text and lifecycle sync messages on the same Android source keys.

 - Returns: Value semantics for UI composition and parity tests.
 - Side effects: none.
 - Failure modes: Individual string descriptors handle localization fallback independently.
 */
public struct RemoteSyncCategoryText: Equatable, Sendable {
    /// Android preference title string.
    public let title: RemoteSyncLocalizedString

    /// Android preference summary/content string.
    public let contents: RemoteSyncLocalizedString

    /**
     Creates one title/content descriptor pair.

     - Parameters:
       - title: Android title string descriptor.
       - contents: Android summary string descriptor.
     - Returns: Value semantics for category copy.
     - Side effects: none.
     - Failure modes: none.
     */
    public init(title: RemoteSyncLocalizedString, contents: RemoteSyncLocalizedString) {
        self.title = title
        self.contents = contents
    }
}

/**
 Android-backed localization catalog for remote sync categories.

 The catalog centralizes category title and summary keys so active settings rows, deferred rows,
 and app lifecycle error copy cannot drift independently.

 - Returns: Android string descriptors for sync category copy.
 - Side effects: none.
 - Failure modes: none; every supported category has an explicit Android string mapping.
 */
public enum RemoteSyncCategoryLocalization {
    /**
     Returns Android title and summary descriptors for an implemented sync category.

     - Parameter category: Implemented remote sync category.
     - Returns: Android-backed title/content descriptors.
     - Side effects: none.
     - Failure modes: This helper cannot fail because all active categories are mapped.
     */
    public static func text(for category: RemoteSyncCategory) -> RemoteSyncCategoryText {
        switch category {
        case .bookmarks:
            return RemoteSyncCategoryText(
                title: .init(key: "bookmarks", defaultValue: "Bookmarks"),
                contents: .init(key: "bookmarks_contents", defaultValue: "Bookmarks, Labels and Study Pads")
            )
        case .workspaces:
            return RemoteSyncCategoryText(
                title: .init(key: "help_workspaces_title", defaultValue: "Workspaces"),
                contents: .init(key: "workspaces_contents", defaultValue: "Workspaces and Windows")
            )
        case .readingPlans:
            return RemoteSyncCategoryText(
                title: .init(key: "reading_plans_plural", defaultValue: "Reading Plans"),
                contents: .init(key: "reading_plans_content", defaultValue: "Reading plans and their statuses")
            )
        case .myDocuments:
            return RemoteSyncCategoryText(
                title: .init(key: "my_documents", defaultValue: "My Documents"),
                contents: .init(key: "my_documents_contents", defaultValue: "My Documents and their content")
            )
        case .progress:
            return RemoteSyncCategoryText(
                title: .init(key: "progress_sync_title", defaultValue: "Reading Progress"),
                contents: .init(
                    key: "progress_sync_contents",
                    defaultValue: "Memorized verses and chapter reading records"
                )
            )
        }
    }

    /**
     Returns Android title and summary descriptors for a visible deferred sync category.

     Deferred categories use the same Android title/content resources as the future active
     implementation so the visible parity surface does not change when the engine lands.

     - Parameter category: Android-visible category whose iOS sync engine is not implemented yet.
     - Returns: Android-backed title/content descriptors.
     - Side effects: none.
     - Failure modes: This helper cannot fail because all deferred categories are mapped.
     */
    static func deferredText(for category: RemoteSyncDeferredCategory) -> RemoteSyncCategoryText {
        switch category {
        case .aiSettings:
            return RemoteSyncCategoryText(
                title: .init(key: "ai_settings_sync_title", defaultValue: "AI Settings"),
                contents: .init(
                    key: "ai_settings_sync_contents",
                    defaultValue: "AI prompts and provider configurations"
                )
            )
        }
    }
}

/**
 Android-backed presentation metadata for the native SwiftUI sync settings screen.

 The sync settings workflow remains native SwiftUI on iOS, but the rows should not choose ad hoc
 glyphs or identifiers. This catalog maps each iOS row to the Android `sync_settings.xml` key that
 owns the corresponding icon, keeping the visual contract honest while preserving platform controls
 for pickers, text fields, and toggles.

 - Returns: Row metadata consumed by `SyncSettingsView` and parity tests.
 - Side effects: none.
 - Failure modes: Missing catalog entries return `nil` icons so unsupported rows remain aligned but
   do not crash.
 */
enum SyncSettingsPresentation {
    /**
     One Android-backed sync settings row.

     - Parameters:
       - androidKey: Android `sync_settings.xml` preference key used as the presentation source.
       - icon: Optional icon metadata resolved from `AndBibleIconCatalog`.
     - Returns: Value semantics suitable for tests and SwiftUI row composition.
     - Side effects: none.
     - Failure modes: Unknown Android keys produce `nil` icons.
     */
    struct Row: Equatable, Sendable {
        /// Android `sync_settings.xml` preference key used as the presentation source.
        let androidKey: String

        /// Optional Android-sourced icon metadata for this row.
        let icon: AndBibleIcon?

        /**
         Creates a row from one Android sync-settings key.

         - Parameter androidKey: Android `sync_settings.xml` preference key.
         - Returns: A row whose icon is resolved from the shared Android icon catalog.
         - Side effects: none.
         - Failure modes: Unknown keys leave `icon` as `nil`.
         */
        init(androidKey: String) {
            self.androidKey = androidKey
            self.icon = AndBibleIconCatalog.settingsIcon(forAndroidKey: androidKey)
        }
    }

    /// Backend picker row sourced from Android `sync_adapter`.
    static let backend = Row(androidKey: "sync_adapter")

    /// Remote credential rows sourced from Android `remote_storage`.
    static let nextCloudCredential = Row(androidKey: "remote_storage")

    /// Backend status and connection-test rows sourced from Android `sync_info`.
    static let syncInfo = Row(androidKey: "sync_info")

    /// Sign-out/reset row sourced from Android `reset_or_sign_out`.
    static let resetOrSignOut = Row(androidKey: "reset_or_sign_out")

    /**
     Android runtime-visible category rows, excluding Reading Plans because `SyncSettings.kt`
     hides that XML-declared preference and including deferred rows whose iOS sync engines are
     tracked separately.
     */
    static let visibleCategoryRows: [SyncSettingsCategoryRow] = [
        .active(.bookmarks),
        .active(.workspaces),
        .active(.myDocuments),
        .deferred(.aiSettings),
        .active(.progress),
    ]

    /**
     Returns the Android presentation row for a remote sync category.

     - Parameter category: Remote sync category shown in the sync settings toggle list.
     - Returns: Android-backed row metadata for the category.
     - Side effects: none.
     - Failure modes: This helper cannot fail; every active iOS sync category has an Android row.
     */
    static func category(_ category: RemoteSyncCategory) -> Row {
        switch category {
        case .bookmarks:
            return Row(androidKey: "sync_bookmarks")
        case .workspaces:
            return Row(androidKey: "sync_workspaces")
        case .readingPlans:
            return Row(androidKey: "sync_reading_plans")
        case .myDocuments:
            return Row(androidKey: "sync_documents")
        case .progress:
            return Row(androidKey: "sync_reading_progress")
        }
    }

    /**
     Returns the Android presentation row for a deferred remote sync category.

     Deferred rows are visible because Android shows their toggles, but iOS keeps them disabled
     until the category-specific sync implementation exists. Keeping their Android icon mapping
     here prevents the UI from drifting while those follow-up issues remain open.

     - Parameter category: Deferred Android-visible category shown in the sync settings list.
     - Returns: Android-backed row metadata for the deferred category.
     - Side effects: none.
     - Failure modes: This helper cannot fail; every deferred category has an Android row mapping.
     */
    static func deferredCategory(_ category: RemoteSyncDeferredCategory) -> Row {
        switch category {
        case .aiSettings:
            return Row(androidKey: "sync_ai")
        }
    }
}

/**
 Android-visible sync categories that iOS intentionally displays as disabled deferred rows.

 Android exposes AI Settings in `sync_settings.xml` and wires it through `SyncSettings.kt`. iOS
 does not yet have that category-specific sync engine, so this value preserves the visible parity
 surface without letting users start an unsupported sync stream.

 - Returns: Value semantics for visible settings rows and tests.
 - Side effects: none.
 - Failure modes: Deferred categories cannot start synchronization until their follow-up issue
   provides a real `RemoteSyncCategory` implementation.
 */
enum RemoteSyncDeferredCategory: String, CaseIterable, Sendable {
    /// Android `sync_enable_ai_settings`; iOS implementation tracked by issue #74.
    case aiSettings = "ai_settings"

    /// Stable Android-compatible toggle key reserved for the future category implementation.
    var androidSyncEnabledKey: String {
        "sync_enable_\(rawValue)"
    }

    /// GitHub issue that owns implementing this deferred category's sync engine.
    var trackingIssueNumber: Int {
        switch self {
        case .aiSettings:
            return 74
        }
    }
}

/**
 One row in the Android-runtime-visible sync category section.

 Active rows map to implemented iOS `RemoteSyncCategory` values and can start synchronization.
 Deferred rows map to Android-visible categories whose iOS sync implementation is intentionally
 pending, so the settings screen can disclose the gap without mutating unsupported state.

 - Returns: Identifiable row values for `SyncSettingsView` and parity tests.
 - Side effects: none.
 - Failure modes: This enum itself cannot fail; consumers decide how to render active versus
   deferred rows.
 */
enum SyncSettingsCategoryRow: Identifiable, Equatable, Sendable {
    /// Implemented category with an interactive toggle.
    case active(RemoteSyncCategory)

    /// Android-visible category rendered as disabled until its sync implementation lands.
    case deferred(RemoteSyncDeferredCategory)

    /// Stable row identity used by SwiftUI lists and tests.
    var id: String {
        switch self {
        case .active(let category):
            return category.rawValue
        case .deferred(let category):
            return category.rawValue
        }
    }
}
