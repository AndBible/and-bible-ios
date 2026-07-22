// SyncSettingsPresentation.swift - Android-backed sync settings row metadata

import Foundation
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
 Android-aligned user-facing classification for remote synchronization failures.

 Both the settings screen and app lifecycle route errors through this value so initial-backup and
 incremental schema incompatibilities cannot drift into different messages. The initializer keeps
 transport and schema types out of view-specific switch statements while preserving an underlying
 localized message for failures Android does not classify specially.

 - Side effects: none.
 - Failure modes: Empty underlying messages resolve to Android's generic sync error text.
 */
public enum RemoteSyncFailurePresentation: Equatable, Sendable {
    /// Backend URL or saved WebDAV configuration is invalid.
    case invalidURL

    /// A required device-local WebDAV password is absent.
    case signInFailed

    /// Remote initial or incremental data requires a newer app schema.
    case updateRequired

    /// Transport or domain failure that should retain its supplied localized description.
    case underlying(String)

    /**
     Classifies one core synchronization error using Android's visible failure groups.

     - Parameter error: Error emitted by backend construction, bootstrap, staging, or patch replay.
     - Returns: Stable presentation category shared by manual and lifecycle synchronization.
     - Side effects: Reads only the error's localized description.
     - Failure modes: Unknown errors become `.underlying`; an empty description is handled by
       `localizedMessage`.
     */
    public init(error: Error) {
        switch error {
        case WebDAVClientError.invalidURL,
             RemoteSyncSynchronizationServiceFactoryError.invalidWebDAVConfiguration:
            self = .invalidURL
        case RemoteSyncSynchronizationServiceFactoryError.missingWebDAVPassword:
            self = .signInFailed
        case RemoteSyncArchiveStagingError.incompatibleInitialBackupVersion,
             RemoteSyncPatchDiscoveryError.incompatiblePatchVersion,
             RemoteSyncSchemaCompatibilityPolicyError.disabledForCurrentVersion:
            self = .updateRequired
        default:
            self = .underlying(
                error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    /**
     Resolves the classified failure through Android-backed localization keys.

     - Returns: Localized alert text with checked-in English fallbacks.
     - Side effects: Reads the process localization bundle.
     - Failure modes: Missing keys use the documented English fallback; empty underlying errors use
       Android's generic cloud-sync error.
     */
    public var localizedMessage: String {
        switch self {
        case .invalidURL:
            return RemoteSyncLocalizedString(
                key: "invalid_url_message",
                defaultValue: "The URL you entered is invalid. Please enter a valid URL (e.g., https://nextcloud.example.com)"
            ).localized
        case .signInFailed:
            return RemoteSyncLocalizedString(
                key: "sign_in_failed",
                defaultValue: "Signing in to synchronization backend service failed."
            ).localized
        case .updateRequired:
            return [
                RemoteSyncLocalizedString(
                    key: "sync_cant_fetch",
                    defaultValue: "The version of database or patch file stored in Cloud is higher than the one supported by this app."
                ).localized,
                RemoteSyncLocalizedString(
                    key: "sync_update_app",
                    defaultValue: "Please update the app to continue synchronization."
                ).localized,
            ]
            .joined(separator: " ")
        case .underlying(let message):
            guard !message.isEmpty else {
                return RemoteSyncLocalizedString(
                    key: "sync_error",
                    defaultValue: "Error occurred in Cloud synchronization"
                ).localized
            }
            return message
        }
    }
}

/**
 Determines how the settings screen reconciles its optimistic category-toggle state after failure.

 Configuration failures occur before the persisted toggle is enabled and must turn the visible
 switch off. Failures after synchronization starts may have changed the persisted value through
 schema policy, so the UI must reload that authoritative value instead of retaining its optimistic
 state.
 */
enum RemoteSyncFailureEnablementResolution: Equatable, Sendable {
    /// Persist and display the category as disabled.
    case disable

    /// Reload the displayed state from the already-authoritative persisted toggle.
    case reloadPersisted

    /**
     Maps the caller's failure phase to one deterministic toggle reconciliation action.

     - Parameter revertEnablement: `true` when setup failed before the toggle was persisted.
     - Returns: Disable for setup failure, otherwise reload persisted state.
     - Side effects: none.
     - Failure modes: none.
     */
    init(revertEnablement: Bool) {
        self = revertEnablement ? .disable : .reloadPersisted
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

 The catalog centralizes category title and summary keys so settings rows and app lifecycle error
 copy cannot drift independently.

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
        case .aiSettings:
            return RemoteSyncCategoryText(
                title: .init(key: "ai_settings_sync_title", defaultValue: "AI Settings"),
                contents: .init(
                    key: "ai_settings_sync_contents",
                    defaultValue: "AI prompts and provider configurations"
                )
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
     hides that XML-declared preference.
     */
    static let visibleCategoryRows: [RemoteSyncCategory] = [
        .bookmarks,
        .workspaces,
        .myDocuments,
        .aiSettings,
        .progress,
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
        case .aiSettings:
            return Row(androidKey: "sync_ai")
        case .progress:
            return Row(androidKey: "sync_reading_progress")
        }
    }
}
