// AndroidDatabaseBackupPresentationLocalization.swift -- Android backup UI localization helpers

import BibleCore
import Foundation

/**
 Adds localized Android backup labels for the SwiftUI settings surface.

 BibleCore keeps Android category and mode display names as stable English fallback labels because
 it also uses them for sorting and low-level diagnostics. BibleUI resolves localized strings at the
 presentation boundary so the backup sheet and completion status can participate in the app's
 localization system without making the core restore service depend on UI resources.
 */
extension AndroidDatabaseBackupCategory {
    /**
     Localized category label for Android backup section rows and summaries.

     - Returns: Localized category label with the stable Android English category label as the
       default fallback.
     - Side effects: reads localization resources through Foundation lookup.
    - Failure modes: Missing localization keys fall back to `displayName`.
     */
    var localizedBackupSectionName: String {
        let resource: (key: String, fallback: String) = switch self {
        case .bookmarks:
            ("db_bookmarks", "Bookmarks, My Notes, Labels and Study Pads")
        case .workspaces:
            ("help_workspaces_title", "Workspaces")
        case .readingPlans:
            ("reading_plans_plural", "Reading Plans")
        case .settings:
            ("settings", "Application preferences")
        case .repositories:
            ("db_repositories", "Repositories and related settings")
        case .myDocuments:
            ("my_documents_title", "My Documents")
        case .aiSettings:
            ("ai_settings_sync_title", "AI Settings")
        case .progress:
            ("progress_sync_title", "Reading Progress")
        case .modules, .epubs:
            ("android_backup_category_\(rawValue.lowercased())", displayName)
        }
        return NSLocalizedString(
            resource.key,
            value: resource.fallback,
            comment: "Android backup category label"
        )
    }
}

/**
 Adds localized operation labels for Android backup Restore/Import controls.

 The raw mode display names remain stable English fallbacks in BibleCore; this extension performs
 UI localization where the app has access to string resources.
 */
extension AndroidDatabaseBackupApplyMode {
    /**
     Localized Restore/Import label for segmented pickers and completion summaries.

     - Returns: Localized operation label with the stable Android English operation label as the
       default fallback.
     - Side effects: reads localization resources through Foundation lookup.
     - Failure modes: Missing localization keys fall back to Android's English resource text.
     */
    var localizedBackupModeName: String {
        switch self {
        case .restore:
            return NSLocalizedString(
                "android_backup_mode_restore",
                value: displayName,
                comment: "Android backup Restore mode label"
            )
        case .import:
            return NSLocalizedString(
                "android_backup_mode_import",
                value: displayName,
                comment: "Android backup Import mode label"
            )
        }
    }
}

/**
 Adds localized user-facing explanations for Android backup support states.

 BibleCore exposes support state as structured values plus English fallback diagnostics. The
 settings surface rehydrates those structured values into localized strings so unsupported rows
 remain visible without leaking core-only English diagnostics into localized UI.
 */
extension AndroidDatabaseBackupSectionSupport {
    /**
     Localized unsupported-section explanation for the backup section picker.

     - Parameter category: Category whose support state is being explained.
     - Returns: Localized explanation for unsupported states, or `nil` for supported sections.
     - Side effects: reads localization resources through Foundation lookup.
     - Failure modes: Missing localization keys fall back to the built-in English defaults.
     */
    func localizedBackupExplanation(for category: AndroidDatabaseBackupCategory) -> String? {
        switch self {
        case .supported:
            return nil
        case .unsupportedVersion(let version, let supported):
            return String(
                format: NSLocalizedString(
                    "android_backup_unsupported_version_%d_%d",
                    value: "Requires database version %d; this app supports up to %d.",
                    comment: "Android backup unsupported database version explanation"
                ),
                version,
                supported
            )
        case .unsupportedCategory:
            return String(
                format: NSLocalizedString(
                    "android_backup_unsupported_category_%@",
                    value: "iOS does not yet have a safe mapper for Android %@ data.",
                    comment: "Android backup unsupported category explanation"
                ),
                category.localizedBackupSectionName
            )
        }
    }
}
