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
        }
    }
}
