// SyncSettingsPresentation.swift - Android-backed sync settings row metadata

import BibleCore

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
        .deferred(.progress),
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
        case .progress:
            return Row(androidKey: "sync_reading_progress")
        }
    }
}

/**
 Android-visible sync categories that iOS intentionally displays as disabled deferred rows.

 Android exposes AI Settings and Reading Progress toggles in `sync_settings.xml` and wires both
 through `SyncSettings.kt`. iOS does not yet have those category-specific sync engines, so these
 values preserve the visible parity surface without letting users start unsupported sync streams.

 - Returns: Value semantics for visible settings rows and tests.
 - Side effects: none.
 - Failure modes: Deferred categories cannot start synchronization until their follow-up issue
   provides a real `RemoteSyncCategory` implementation.
 */
enum RemoteSyncDeferredCategory: String, CaseIterable, Sendable {
    /// Android `sync_enable_ai_settings`; iOS implementation tracked by issue #74.
    case aiSettings = "ai_settings"

    /// Android `sync_enable_progress`; iOS implementation tracked by issue #73.
    case progress

    /// Stable Android-compatible toggle key reserved for the future category implementation.
    var androidSyncEnabledKey: String {
        "sync_enable_\(rawValue)"
    }

    /// GitHub issue that owns implementing this deferred category's sync engine.
    var trackingIssueNumber: Int {
        switch self {
        case .aiSettings:
            return 74
        case .progress:
            return 73
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
