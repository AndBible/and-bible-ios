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
 One visible row in Android's module About dialog.

 Android assembles a message from the selected module's actual metadata and omits fields that are not
 available. iOS keeps the same contract as typed rows so tests and both SwiftUI call sites can verify
 the payload without depending on form or sheet internals.

 Side effects:
 - none; this value is a pure presentation projection

 Failure modes:
 - none; unavailable metadata is omitted before rows are created
 */
struct ModuleBrowserModuleDetailRow: Identifiable, Equatable {
    /**
     Stable field identifiers for the module About dialog.

     Cases are intentionally limited to metadata iOS currently owns. Android-only `BookMetaData`
     fields such as copyright, history, unlock info text, repository raw properties, and versification
     are not represented until iOS stores those values honestly.
     */
    enum Kind: String, Equatable {
        /// SWORD module initials.
        case initials

        /// User-facing module name/description.
        case name

        /// SWORD module category.
        case category

        /// Module language display name.
        case language

        /// Remote or installed source label.
        case source

        /// Latest remote catalog version.
        case latestVersion

        /// Installed local module version.
        case installedVersion

        /// Remote install size when the catalog reports it.
        case installSize

        /// Local installed-state marker.
        case installedState

        /// Local encrypted module lock state.
        case encryptionState
    }

    /// Stable metadata field identity.
    let kind: Kind

    /// Localized field label rendered by the dialog.
    let title: String

    /// User-visible metadata value.
    let value: String

    /// Stable row identity for SwiftUI and tests.
    var id: Kind { kind }
}

/**
 Details payload for Android's module row About action.

 Android expands SWORD metadata for the selected row and displays the available details in
 `CommonUtils.showAbout(...)`. iOS currently has a smaller remote/installed metadata model, so this
 payload preserves every available local field while deliberately omitting values iOS does not store.

 Side effects:
 - none; this value only drives SwiftUI dialog presentation

 Failure modes:
 - missing installed metadata is represented by `nil` and omitted from the dialog
 - empty optional fields are omitted rather than shown as placeholders
 */
struct ModuleBrowserModuleDetails: Identifiable {
    /// Remote catalog row selected from Downloads, or a remote-shaped installed snapshot in picker.
    let module: RemoteModuleInfo

    /// Matching installed module metadata, when the module exists locally.
    let installedModule: ModuleInfo?

    /// Stable dialog identity scoped to the repository row.
    var id: String { module.id }

    /**
     Android About rows assembled from the metadata iOS can honestly provide.

     - Returns: Ordered dialog rows matching Android's message-first About contract while preserving
       every available remote and installed iOS field.
     - Side effects: none.
     - Failure modes: Empty optional metadata is omitted.
     */
    var androidAboutRows: [ModuleBrowserModuleDetailRow] {
        var rows: [ModuleBrowserModuleDetailRow] = [
            row(
                kind: .initials,
                title: String(localized: "module_initials", defaultValue: "Initials"),
                value: module.name
            )
        ]

        if let description = Self.nonEmpty(module.description) {
            rows.append(row(
                kind: .name,
                title: String(localized: "module_name", defaultValue: "Name"),
                value: description
            ))
        }
        rows.append(row(
            kind: .category,
            title: String(localized: "module_category", defaultValue: "Category"),
            value: Self.categoryTitle(module.category)
        ))
        if let language = Self.nonEmpty(module.language) {
            rows.append(row(
                kind: .language,
                title: String(localized: "module_language", defaultValue: "Language"),
                value: Self.displayName(for: language)
            ))
        }

        if let source = Self.nonEmpty(module.sourceName) {
            rows.append(row(
                kind: .source,
                title: String(localized: "module_source", defaultValue: "Source"),
                value: source
            ))
        }
        if let latestVersion = Self.nonEmpty(module.version) {
            rows.append(row(
                kind: .latestVersion,
                title: String(localized: "module_latest_version", defaultValue: "Latest version"),
                value: latestVersion
            ))
        }
        if let installedVersion = installedModule.flatMap({ Self.nonEmpty($0.version) }) {
            rows.append(row(
                kind: .installedVersion,
                title: String(localized: "module_installed_version", defaultValue: "Installed version"),
                value: installedVersion
            ))
        }
        if let installSize = Self.installSizeText(for: module.installSizeBytes) {
            rows.append(row(
                kind: .installSize,
                title: String(localized: "module_install_size", defaultValue: "Install size"),
                value: installSize
            ))
        }
        if installedModule != nil {
            rows.append(row(
                kind: .installedState,
                title: String(localized: "module_installed", defaultValue: "Installed"),
                value: String(localized: "module_installed", defaultValue: "Installed")
            ))
        }
        if let installedModule, installedModule.isEncrypted {
            rows.append(row(
                kind: .encryptionState,
                title: String(localized: "module_encrypted", defaultValue: "Encrypted"),
                value: installedModule.isUnlocked
                    ? String(localized: "module_unlocked", defaultValue: "Unlocked")
                    : String(localized: "module_locked", defaultValue: "Locked")
            ))
        }

        return rows
    }

    /**
     Creates a typed dialog row.

     - Parameters:
       - kind: Stable metadata field identity.
       - title: Localized field label.
       - value: User-visible metadata value.
     - Returns: Row value consumed by the shared dialog.
     - Side effects: none.
     - Failure modes: none.
     */
    private func row(kind: ModuleBrowserModuleDetailRow.Kind, title: String, value: String) -> ModuleBrowserModuleDetailRow {
        ModuleBrowserModuleDetailRow(kind: kind, title: title, value: value)
    }

    /**
     Resolves a module category to the same user-facing buckets used by the Downloads filter.

     - Parameter category: SWORD module category.
     - Returns: Localized category title.
     - Side effects: none.
     - Failure modes: Unknown categories fall back to the raw category value.
     */
    private static func categoryTitle(_ category: ModuleCategory) -> String {
        switch category {
        case .bible:
            return String(localized: "bibles", defaultValue: "Bibles")
        case .commentary:
            return String(localized: "commentaries", defaultValue: "Commentaries")
        case .dictionary:
            return String(localized: "dictionaries", defaultValue: "Dictionaries")
        case .generalBook:
            return String(localized: "category_books", defaultValue: "Books")
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
    private static func displayName(for languageCode: String) -> String {
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
    private static func installSizeText(for bytes: Int64?) -> String? {
        guard let bytes else {
            return nil
        }
        let megabytes = Double(bytes) / 1_000_000
        return String(format: "%.1f MB", megabytes)
    }

    /**
     Trims optional catalog text before rendering.

     - Parameter value: Optional raw metadata value.
     - Returns: Trimmed text, or `nil` when the value is empty.
     - Side effects: none.
     - Failure modes: none.
     */
    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
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

     Cases intentionally stay narrow: About is a dialog and Unlock is hidden until iOS has a real
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
 Android-compatible module details dialog for Downloads and the reader document picker.

 Android uses `CommonUtils.showAbout(...)`, which shows module metadata in an AppCompat
 `AlertDialog` with a message body and a single OK action. This SwiftUI surface keeps the same
 in-place dialog ownership while rendering only the metadata rows iOS can provide honestly.

 Data dependencies:
 - a `ModuleBrowserModuleDetails` payload from the selected row
 - an explicit dismiss closure supplied by the owning screen

 Side effects:
 - tapping OK invokes `onDismiss`

 Failure modes:
 - missing optional metadata rows are omitted by `ModuleBrowserModuleDetails.androidAboutRows`
 */
struct ModuleBrowserModuleDetailsDialog: View {
    /// Current system color scheme used by the shared Android dialog palette.
    @Environment(\.colorScheme) private var colorScheme

    /// Remote and installed module metadata to display.
    let details: ModuleBrowserModuleDetails

    /// Callback that clears the owning screen's selected details state.
    let onDismiss: () -> Void

    /**
     Renders the Android-style About dialog.

     - Returns: Centered dialog panel with a scrollable metadata message and OK action.
     - Side effects: OK invokes `onDismiss`.
     - Failure modes: Empty row lists render only the module heading and OK action.
     */
    var body: some View {
        VStack(spacing: 0) {
            Text(details.module.name)
                .font(.headline)
                .foregroundStyle(dialogPrimaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .padding(.bottom, 12)

            Divider()
                .background(dialogSecondaryText.opacity(0.25))

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(details.androidAboutRows) { row in
                        detailRow(row)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 420)
            .accessibilityIdentifier("moduleDetailsDialogRows")

            Divider()
                .background(dialogSecondaryText.opacity(0.25))

            HStack {
                Spacer()
                Button(String(localized: "okay", defaultValue: "OK")) {
                    onDismiss()
                }
                .fontWeight(.semibold)
                .foregroundStyle(dialogAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .accessibilityIdentifier("moduleDetailsOKButton")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: 430)
        .background(dialogBackground, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(dialogSecondaryText.opacity(0.28), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 20, x: 0, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("moduleDetailsDialogScreen")
        .tint(dialogAccent)
    }

    /**
     Renders one field/value row in the dialog message.

     - Parameter row: Metadata row assembled from the shared About payload.
     - Returns: Vertically stacked label and value text.
     - Side effects: none.
     - Failure modes: Long values wrap within the dialog width.
     */
    private func detailRow(_ row: ModuleBrowserModuleDetailRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(dialogSecondaryText)
            Text(row.value)
                .font(.body)
                .foregroundStyle(dialogPrimaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("moduleDetailsRow::\(row.kind.rawValue)")
    }

    /// Android-dialog background color for the current system appearance.
    private var dialogBackground: Color {
        AndroidDialogSurfacePalette.background(for: colorScheme)
    }

    /// Android-dialog primary text color for the current system appearance.
    private var dialogPrimaryText: Color {
        AndroidDialogSurfacePalette.primaryText(for: colorScheme)
    }

    /// Android-dialog secondary text color for the current system appearance.
    private var dialogSecondaryText: Color {
        AndroidDialogSurfacePalette.secondaryText(for: colorScheme)
    }

    /// Android-dialog accent color for the OK action.
    private var dialogAccent: Color {
        AndroidDialogSurfacePalette.accent(for: colorScheme)
    }
}

/**
 Full-screen dimmed overlay hosting the module About dialog.

 Android marks the About `AlertDialog` non-cancelable and closes it through the positive button. The
 dimmer therefore blocks interaction with the underlying screen without dismissing on background tap.

 Side effects:
 - the nested dialog may invoke `onDismiss`

 Failure modes:
 - none; missing details are handled by the view modifier before this overlay is created
 */
private struct ModuleBrowserModuleDetailsDialogOverlay: View {
    /// Current system color scheme used for the dimmer opacity.
    @Environment(\.colorScheme) private var colorScheme

    /// Metadata payload to render in the dialog.
    let details: ModuleBrowserModuleDetails

    /// Callback that clears the owning screen's selected details state.
    let onDismiss: () -> Void

    /**
     Renders the blocking dimmer and centered dialog.

     - Returns: Full-screen overlay with the Android-style module details dialog.
     - Side effects: OK inside the dialog invokes `onDismiss`.
     - Failure modes: none.
     */
    var body: some View {
        ZStack {
            Color.black.opacity(colorScheme == .dark ? 0.52 : 0.32)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}
                .accessibilityHidden(true)

            ModuleBrowserModuleDetailsDialog(
                details: details,
                onDismiss: onDismiss
            )
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .zIndex(2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("moduleDetailsDialogOverlay")
    }
}

/**
 Shared presenter for module About details.

 Downloads and the reader document picker both originate from Android document rows and must show the
 same dialog instead of separate SwiftUI sheets. Keeping the presenter as a `View` extension prevents
 call-site drift while each owner still controls its selected details state.
 */
extension View {
    /**
     Presents Android-compatible module About details above the receiving view.

     - Parameters:
       - details: Currently selected module details, or `nil` when no dialog should be visible.
       - onDismiss: Callback used to clear the selected details state.
     - Returns: The receiving view with an optional blocking dialog overlay.
     - Side effects: OK in the dialog invokes `onDismiss`.
     - Failure modes: `nil` details produce no overlay.
     */
    func moduleBrowserModuleDetailsDialog(
        details: ModuleBrowserModuleDetails?,
        onDismiss: @escaping () -> Void
    ) -> some View {
        overlay {
            if let details {
                ModuleBrowserModuleDetailsDialogOverlay(
                    details: details,
                    onDismiss: onDismiss
                )
            }
        }
    }
}
