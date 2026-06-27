// ModuleBrowserRowActionPresentation.swift - Downloads row action presentation helpers

import SwiftUI
import SwordKit

/**
 Android-compatible presentation contract for the Downloads status slot.

 Android keeps row action behavior separate from the status icon: `NOT_INSTALLED` rows are
 installable when tapped, but `DocumentListItem.updateControlState` clears the status icon rather
 than showing an update affordance. iOS uses this value to keep the SwiftUI row controls and tests
 anchored to that platform contract instead of coupling tests to private view internals.

 Side effects:
 - none; the value is a pure projection of `ModuleBrowserDownloadStatus`

 Failure modes:
 - none; unknown states are not representable by `ModuleBrowserDownloadStatus`
 */
struct ModuleBrowserStatusSlotPresentation: Equatable {
    /**
     Canonical status-slot branch used by the SwiftUI row.

     Cases intentionally mirror Android's row rendering branches. `emptyInstallableSlot` represents
     Android `NOT_INSTALLED`, where the row remains installable through the row action but the status
     icon drawable is `null`.
     */
    enum Kind: Equatable {
        /// Android `INSTALLED`, shown as a completed status icon.
        case installed

        /// Android `BEING_INSTALLED`, shown with progress and a cancel affordance.
        case progress(progressPercent: Int)

        /// Android `ERROR_DOWNLOADING`, shown with a warning and retry affordance.
        case retryError

        /// Android `UPGRADE_AVAILABLE`, shown with the update arrow affordance.
        case update

        /// Non-installable metadata row.
        case unavailable

        /// Android `NOT_INSTALLED`, which has no status icon in the trailing slot.
        case emptyInstallableSlot
    }

    /// Canonical Android row-rendering branch for the status slot.
    let kind: Kind

    /**
     Creates a status-slot presentation from the Android-equivalent download status.

     - Parameter status: Resolved row status from `ModuleBrowserView.displayStatus`.
     - Returns: A presentation value for the row's status slot.
     - Side effects: none.
     - Failure modes: none.
     */
    init(status: ModuleBrowserDownloadStatus) {
        switch status {
        case .installed:
            kind = .installed
        case .beingInstalled(let progressPercent):
            kind = .progress(progressPercent: progressPercent)
        case .errorDownloading:
            kind = .retryError
        case .updateAvailable:
            kind = .update
        case .unavailable:
            kind = .unavailable
        case .installable:
            kind = .emptyInstallableSlot
        }
    }

    /**
     System image used for standalone status-icon states.

     Composite branches that render progress/cancel controls return `nil`. Android
     `NOT_INSTALLED` also returns `nil` because that branch intentionally clears the status icon.

     - Returns: SF Symbol name for standalone icon-backed states, otherwise `nil`.
     - Side effects: none.
     - Failure modes: none.
     */
    var statusIconSystemName: String? {
        switch kind {
        case .installed:
            return "checkmark.circle.fill"
        case .progress:
            return nil
        case .retryError:
            return "exclamationmark.triangle.fill"
        case .update:
            return "arrow.up.circle.fill"
        case .unavailable:
            return "lock.slash"
        case .emptyInstallableSlot:
            return nil
        }
    }

    /**
     Whether the status slot itself exposes an action control.

     - Returns: `true` for retry, update, and cancel controls; `false` for passive or empty slots.
     - Side effects: none.
     - Failure modes: none.
     */
    var isActionControl: Bool {
        switch kind {
        case .progress, .retryError, .update:
            return true
        case .installed, .unavailable, .emptyInstallableSlot:
            return false
        }
    }
}

/**
 Details payload for Android's Downloads row About action.

 Android expands SWORD metadata for the selected row and displays its about/copyright/version
 details. iOS currently has a smaller remote catalog model, so the sheet carries the remote row
 plus any installed row snapshot that can supply local version/encryption state.

 Side effects:
 - none; this value only drives SwiftUI sheet presentation

 Failure modes:
 - missing installed metadata is represented by `nil` and omitted from the sheet
 */
struct ModuleBrowserModuleDetails: Identifiable {
    /// Remote catalog row selected from Downloads.
    let module: RemoteModuleInfo

    /// Matching installed module metadata, when the module exists locally.
    let installedModule: ModuleInfo?

    /// Stable sheet identity scoped to the repository row.
    var id: String { module.id }
}

/**
 Destructive row action awaiting Android-style confirmation.

 Android prompts before deleting a document or deleting its search index. iOS stores the pending
 action as data so the shared alert can render copy and invoke the matching side effect after the
 user confirms.

 Side effects:
 - none until the alert's confirmation button dispatches the action

 Failure modes:
 - none; invalid actions are not represented
 */
struct ModuleBrowserRowActionConfirmation: Identifiable {
    /**
     Confirmation operation matching Android's contextual document menu.

     Cases intentionally stay narrow: About is a sheet and Unlock is hidden until iOS has a real
     cipher-key coordinator.
     */
    enum Kind {
        /// Remove the installed module from local SWORD storage.
        case uninstall

        /// Remove the local full-text search index for the installed module.
        case deleteIndex
    }

    /// Operation to run after the user confirms.
    let kind: Kind

    /// Module initials used by repository and search-index services.
    let moduleName: String

    /// Human-readable module title used in confirmation copy.
    let moduleDescription: String

    /// Stable alert identity.
    var id: String { "\(kind)-\(moduleName)" }

    /**
     Best available user-facing module label for confirmation copy.

     - Returns: Module description when present, otherwise module initials.
     - Side effects: none.
     - Failure modes: none.
     */
    var displayName: String {
        let trimmedDescription = moduleDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedDescription.isEmpty ? moduleName : trimmedDescription
    }

    /**
     Creates a confirmation payload for one row action.

     - Parameters:
       - kind: Android-equivalent destructive operation.
       - module: Remote catalog row that supplied the action.
     - Side effects: none.
     - Failure modes: none.
     */
    init(kind: Kind, module: RemoteModuleInfo) {
        self.kind = kind
        self.moduleName = module.name
        self.moduleDescription = module.description
    }

    /**
     Alert title for the pending operation.

     - Returns: Localized title text.
     - Side effects: none.
     - Failure modes: none.
     */
    var title: String {
        switch kind {
        case .uninstall:
            return String(localized: "uninstall_module_title", defaultValue: "Uninstall Module")
        case .deleteIndex:
            return String(localized: "delete_module_index_title", defaultValue: "Delete Search Index")
        }
    }

    /**
     Alert message matching Android's document/delete-index confirmation intent.

     - Returns: Localized message text with the selected module display name.
     - Side effects: none.
     - Failure modes: none.
     */
    var message: String {
        switch kind {
        case .uninstall:
            let format = String(
                localized: "uninstall_module_message_format",
                defaultValue: "Remove %@ from this device?"
            )
            return String(format: format, displayName)
        case .deleteIndex:
            let format = String(
                localized: "delete_module_index_message_format",
                defaultValue: "Delete the search index for %@?"
            )
            return String(format: format, displayName)
        }
    }
}

/**
 Android-compatible module details sheet for the Downloads About action.

 Android loads richer `SwordBookMetaData` before showing About. The iOS catalog currently stores a
 smaller metadata subset, so this sheet presents every available remote and installed field without
 inventing unavailable copyright/unlock content.

 Data dependencies:
 - a `ModuleBrowserModuleDetails` payload from the selected row
 - SwiftUI dismiss environment for the Done toolbar action

 Side effects:
 - tapping Done dismisses the sheet

 Failure modes:
 - missing optional metadata rows are omitted
 */
struct ModuleBrowserModuleDetailsView: View {
    /// Dismiss action supplied by SwiftUI's sheet environment.
    @Environment(\.dismiss) private var dismiss

    /// Remote and installed module metadata to display.
    let details: ModuleBrowserModuleDetails

    /**
     Renders the module details form.

     - Returns: SwiftUI form with Android About-equivalent metadata fields available on iOS.
     - Side effects: Done toolbar button dismisses the sheet.
     - Failure modes: Optional fields with empty values are not rendered.
     */
    var body: some View {
        Form {
            Section {
                LabeledContent(String(localized: "module_initials", defaultValue: "Initials")) {
                    Text(details.module.name)
                }
                LabeledContent(String(localized: "module_name", defaultValue: "Name")) {
                    Text(details.module.description)
                }
                LabeledContent(String(localized: "module_category", defaultValue: "Category")) {
                    Text(categoryTitle(details.module.category))
                }
                LabeledContent(String(localized: "module_language", defaultValue: "Language")) {
                    Text(displayName(for: details.module.language))
                }
                LabeledContent(String(localized: "module_source", defaultValue: "Source")) {
                    Text(details.module.sourceName)
                }
            }

            Section(String(localized: "module_versions", defaultValue: "Versions")) {
                if !details.module.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    LabeledContent(String(localized: "module_latest_version", defaultValue: "Latest")) {
                        Text(details.module.version)
                    }
                }
                if let installedModule = details.installedModule,
                   !installedModule.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    LabeledContent(String(localized: "module_installed_version", defaultValue: "Installed")) {
                        Text(installedModule.version)
                    }
                }
                if details.module.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   details.installedModule?.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    Text(String(localized: "module_version_unavailable", defaultValue: "No version metadata available."))
                        .foregroundStyle(.secondary)
                }
            }

            if let installSize = installSizeText(for: details.module.installSizeBytes) {
                Section {
                    LabeledContent(String(localized: "module_install_size", defaultValue: "Install size")) {
                        Text(installSize)
                    }
                }
            }

            if let installedModule = details.installedModule {
                Section(String(localized: "module_local_state", defaultValue: "Local State")) {
                    LabeledContent(String(localized: "module_installed", defaultValue: "Installed")) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    if installedModule.isEncrypted {
                        LabeledContent(String(localized: "module_encrypted", defaultValue: "Encrypted")) {
                            Text(installedModule.isUnlocked
                                ? String(localized: "module_unlocked", defaultValue: "Unlocked")
                                : String(localized: "module_locked", defaultValue: "Locked"))
                        }
                    }
                }
            }
        }
        .navigationTitle(String(localized: "about"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "done", defaultValue: "Done")) {
                    dismiss()
                }
            }
        }
    }

    /**
     Resolves a module category to the same user-facing buckets used by the Downloads filter.

     - Parameter category: SWORD module category.
     - Returns: Localized category title.
     - Side effects: none.
     - Failure modes: Unknown categories fall back to the raw category value.
     */
    private func categoryTitle(_ category: ModuleCategory) -> String {
        switch category {
        case .bible:
            return String(localized: "bibles")
        case .commentary:
            return String(localized: "commentaries")
        case .dictionary:
            return String(localized: "dictionaries")
        case .generalBook:
            return String(localized: "category_books")
        case .map:
            return String(localized: "maps", defaultValue: "Maps")
        case .addon:
            return String(localized: "doc_type_addons", defaultValue: "Add-ons")
        default:
            return category.rawValue
        }
    }

    /**
     Resolves a language code to localized display text.

     - Parameter languageCode: ISO-style language code from remote or installed metadata.
     - Returns: Localized language name when available, otherwise the uppercased code.
     - Side effects: none.
     - Failure modes: Invalid or unknown codes fall back to uppercased input.
     */
    private func displayName(for languageCode: String) -> String {
        let baseCode = languageCode.components(separatedBy: "-").first ?? languageCode
        if let name = Locale.current.localizedString(forLanguageCode: baseCode),
           name.lowercased() != baseCode.lowercased() {
            if languageCode.contains("-") {
                let suffix = languageCode.components(separatedBy: "-").dropFirst().joined(separator: "-")
                return "\(name) (\(suffix))"
            }
            return name
        }
        return languageCode.uppercased()
    }

    /**
     Formats the SWORD install-size value shown in Android's download rows.

     - Parameter bytes: Install-size byte count from remote catalog metadata.
     - Returns: One-decimal megabyte text, or `nil` when metadata is absent.
     - Side effects: none.
     - Failure modes: none.
     */
    private func installSizeText(for bytes: Int64?) -> String? {
        guard let bytes else {
            return nil
        }
        let megabytes = Double(bytes) / 1_000_000
        return String(format: "%.1f MB", megabytes)
    }
}
