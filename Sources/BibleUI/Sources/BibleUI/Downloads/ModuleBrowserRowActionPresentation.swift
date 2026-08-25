// ModuleBrowserRowActionPresentation.swift - Downloads row action presentation helpers

import Foundation
import SwiftUI
import BibleCore
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

        /// Android `BEING_INSTALLED`, preserving phase and optional percent plus cancel.
        case progress(phase: ModuleInstallPhase, progressPercent: Int?)

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
        case .beingInstalled(let progress):
            kind = .progress(phase: progress.phase, progressPercent: progress.percent)
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
     Exact ported Android drawable used in the shared leading status slot.

     Android `NOT_INSTALLED` and pseudo/unavailable rows clear the status drawable. Active install,
     error, update, and installed states use the packaged vectors from `DocumentListItem` rather than
     substituting platform SF Symbols.

     - Returns: Packaged Android asset name for icon-backed states, otherwise `nil`.
     - Side effects: none.
     - Failure modes: none.
     */
    var statusIconAssetName: String? {
        switch kind {
        case .installed:
            return "DocumentInstalledStatus"
        case .progress:
            return "DocumentDownloadingStatus"
        case .retryError:
            return "DocumentErrorStatus"
        case .update:
            return "DocumentUpdateStatus"
        case .unavailable, .emptyInstallableSlot:
            return nil
        }
    }

    /**
     Exact Android resource color paired with `statusIconAssetName`.

     - Returns: Installed/download green, update amber, error red, or transparent when Android
       clears the status drawable.
     - Side effects: none.
     - Failure modes: none.
     */
    var statusIconColor: Color {
        switch kind {
        case .installed, .progress:
            return AndroidResourcePalette.documentInstalledGreen
        case .retryError:
            return AndroidResourcePalette.documentErrorRed
        case .update:
            return AndroidResourcePalette.documentUpgradeAmber
        case .unavailable, .emptyInstallableSlot:
            return .clear
        }
    }

    /**
     Whether the status slot itself exposes an action control.

     - Returns: `true` only for active progress, whose adjacent cancel control is interactive;
       update and retry icons remain passive because Android owns those operations at row-tap level.
     - Side effects: none.
     - Failure modes: none.
     */
    var isActionControl: Bool {
        switch kind {
        case .progress:
            return true
        case .installed, .retryError, .update, .unavailable, .emptyInstallableSlot:
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

     Current rendered cases mirror Android `CommonUtils.showAbout(...)`. The older category/language
     and install-state cases remain only as regression sentinels in tests so those iOS-only fields are
     not reintroduced as visible rows.
     */
    enum Kind: String, Equatable {
        /// Bad-document warning from Android metadata.
        case warning

        /// Main SWORD `About` text.
        case about

        /// SWORD `ShortPromo` text.
        case shortPromo

        /// Copyright and distribution license text.
        case copyright

        /// Encrypted module unlock information.
        case unlockInfo

        /// Latest/catalog version row.
        case latestVersion

        /// Installed/local version row.
        case installedVersion

        /// Version history values.
        case versionHistory

        /// SWORD versification name.
        case versification

        /// Android OSIS ID row.
        case osisId

        /// Android distribution server/repository row.
        case repository

        /// Deprecated iOS-only module category row.
        case category

        /// Deprecated iOS-only module language row.
        case language

        /// Deprecated iOS-only source row.
        case source

        /// Deprecated iOS-only install-size row.
        case installSize

        /// Deprecated iOS-only installed-state row.
        case installedState

        /// Deprecated iOS-only encrypted lock-state row.
        case encryptionState
    }

    /// Stable metadata field identity.
    let kind: Kind

    /// Localized field label rendered by the dialog.
    let title: String

    /// User-visible metadata value.
    let value: String

    /// Android-style message fragment rendered in the About dialog body.
    let message: String

    /// Stable row identity for SwiftUI and tests.
    var id: Kind { kind }

    /**
     Creates one typed About row and its Android message fragment.

     - Parameters:
       - kind: Stable metadata field identity.
       - title: Field label retained for tests and future accessibility affordances.
       - value: Raw user-visible metadata value.
       - message: Formatted Android-style message fragment. Defaults to `value`.
     - Side effects: none.
     - Failure modes: none.
     */
    init(kind: Kind, title: String, value: String, message: String? = nil) {
        self.kind = kind
        self.title = title
        self.value = value
        self.message = message ?? value
    }
}

/**
 Details payload for Android's module row About action.

 Android expands SWORD metadata for the selected row and displays the available details in
 `CommonUtils.showAbout(...)`. iOS currently has a smaller remote/installed metadata model, so this
 payload preserves every available local field while keeping catalog-only and installed-only metadata
 separate. Reader-picker About actions must not synthesize a repository row because Android reads the
 installed document metadata directly.

 Side effects:
 - none; this value only drives SwiftUI dialog presentation

 Failure modes:
 - missing remote or installed metadata is represented by `nil` and omitted from the dialog
 - empty optional fields are omitted rather than shown as placeholders
 */
struct ModuleBrowserModuleDetails: Identifiable {
    /**
     Java-exact identity for the installed or remote owner shown by the About dialog.

     Cases keep remote repositories, installed SWORD/custom documents, and EPUB generations in
     separate domains while preserving every raw UTF-16 identity component.
     */
    enum ID: Hashable {
        /// Remote catalog owner scoped by repository and module initials.
        case remote(RemoteModuleIdentity)

        /// Installed SWORD/custom owner keyed by exact module initials.
        case installed(SwordJavaExactStringIdentity)

        /// Installed EPUB owner keyed by its stable identifier.
        case epub(SwordJavaExactStringIdentity)
    }

    /// Stable Java-exact dialog identity scoped to the owner that opened the dialog.
    let id: ID

    /// SWORD module initials used as the fallback heading and OSIS identity.
    let moduleName: String

    /// User-facing module description used as Android's `document.name` equivalent when available.
    let moduleDescription: String

    /// Installed or remote metadata that backs Android About rows.
    let aboutMetadata: ModuleAboutMetadata

    /// Android row kind used for the primary version line.
    let primaryVersionKind: ModuleBrowserModuleDetailRow.Kind

    /// Primary version value from the selected document/catalog row.
    let primaryVersion: String?

    /// Date paired with the primary version, when known.
    let primaryVersionDate: String?

    /// Secondary installed version shown only for Downloads rows with a matching installed module.
    let installedVersion: String?

    /// Date paired with the secondary installed version, when known.
    let installedVersionDate: String?

    /// Android-style dialog heading.
    var displayName: String {
        Self.nonEmpty(moduleDescription) ?? moduleName
    }

    /**
     Single Android-style About message rendered by the shared dialog.

     Android's `CommonUtils.showAbout(...)` builds one AlertDialog message instead of a form/table.
     This property keeps that presentation contract visible to tests while `androidAboutRows`
     preserves typed row identities for semantic parity checks.

     - Returns: Message text with blank-line section separation and adjacent version rows.
     - Side effects: none.
     - Failure modes: Empty optional metadata rows are omitted before message assembly.
     */
    var androidAboutMessage: String {
        androidAboutSections(renderingHTML: false)
            .compactMap(Self.nonEmpty)
            .joined(separator: "\n\n")
    }

    /**
     Android-style About message after Android's final HTML newline conversion.

     Android wraps the document name, bad-document warning, and unlock-info heading in `<b>` tags,
     appends raw module metadata, then replaces line breaks with `<br>` before displaying the span.
     This property preserves that presentation contract so links and simple metadata markup render
     instead of appearing as literal HTML in iOS.

     - Returns: HTML body passed to the Swift attributed-string importer.
     - Side effects: none.
     - Failure modes: Empty optional metadata rows are omitted before message assembly.
     */
    var androidAboutHTMLMessage: String {
        androidAboutSections(renderingHTML: true)
            .compactMap(Self.nonEmpty)
            .joined(separator: "\n\n")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    /**
     Attributed About body used by the SwiftUI dialog.

     Android displays the About message through `htmlToSpan(...)`, so iOS imports the same HTML body
     into an attributed string. If Foundation rejects malformed module metadata HTML, the dialog falls
     back to the plain Android message rather than dropping the About content.

     - Returns: Attributed message suitable for `Text`.
     - Side effects: Parses the in-memory HTML string.
     - Failure modes: Malformed HTML falls back to plain text.
     */
    var androidAboutAttributedMessage: AttributedString {
        Self.attributedHTMLString(from: androidAboutHTMLMessage) ?? AttributedString(androidAboutMessage)
    }

    /**
     Builds the ordered About message sections in plain or Android-HTML form.

     - Parameter renderingHTML: Whether section values should include Android's bold wrappers.
     - Returns: Ordered message sections before blank-line joining and final newline conversion.
     - Side effects: none.
     - Failure modes: Empty optional metadata rows are omitted by `androidAboutRows`.
     */
    private func androidAboutSections(renderingHTML: Bool) -> [String] {
        var sections = [displayName]
        var versionMessages: [String] = []

        if renderingHTML {
            sections = ["<b>\(displayName)</b>"]
        }

        func flushVersionMessages() {
            guard !versionMessages.isEmpty else {
                return
            }
            sections.append(versionMessages.joined(separator: "\n"))
            versionMessages.removeAll()
        }

        for row in androidAboutRows {
            switch row.kind {
            case .latestVersion, .installedVersion:
                versionMessages.append(row.message)
            case .warning:
                flushVersionMessages()
                sections.append(renderingHTML ? "<b>\(row.message)</b>" : row.message)
            case .unlockInfo:
                flushVersionMessages()
                sections.append(renderingHTML ? "<b>\(row.title)</b>\n\n\(row.value)" : row.message)
            default:
                flushVersionMessages()
                sections.append(row.message)
            }
        }
        flushVersionMessages()
        return sections
    }

    /**
     Creates a dialog payload for a Downloads catalog row.

     - Parameters:
       - module: Remote catalog row selected from Downloads.
       - installedModule: Matching local module metadata, when the module exists locally.
     - Side effects: none.
     - Failure modes: Missing installed metadata leaves installed-only rows absent.
     */
    init(module: RemoteModuleInfo, installedModule: ModuleInfo?) {
        id = .remote(module.id)
        moduleName = module.name
        moduleDescription = module.description
        aboutMetadata = installedModule?.aboutMetadata.withFallbacks(
            osisId: module.name,
            repository: module.sourceName
        ) ?? ModuleAboutMetadata(
            osisId: module.name,
            repository: module.sourceName
        )
        primaryVersionKind = installedModule == nil ? .installedVersion : .latestVersion
        primaryVersion = module.version
        primaryVersionDate = nil
        installedVersion = installedModule?.version
        installedVersionDate = installedModule?.aboutMetadata.swordVersionDate
    }

    /**
     Creates a dialog payload for a reader-picker installed document.

     Android's reader document picker calls `CommonUtils.showAbout(...)` on the installed document
     metadata and does not add Downloads-only source/latest/install-size rows. This initializer keeps
     that boundary explicit so installed modules never gain artificial repository metadata.

     - Parameter installedModule: Installed module selected from the reader document picker.
     - Side effects: none.
     - Failure modes: Empty installed metadata fields are omitted by `androidAboutRows`.
     */
    init(installedModule: ModuleInfo) {
        id = .installed(SwordJavaExactStringIdentity(installedModule.name))
        moduleName = installedModule.name
        moduleDescription = installedModule.description
        aboutMetadata = installedModule.aboutMetadata
        primaryVersionKind = .latestVersion
        primaryVersion = installedModule.version
        primaryVersionDate = installedModule.aboutMetadata.swordVersionDate
        installedVersion = nil
        installedVersionDate = nil
    }

    /**
     Creates Android's installed-document About payload for one imported EPUB general book.

     Android registers EPUBs as generated `SwordGenBook` documents. `CommonUtils.showAbout(...)`
     therefore displays the package title, Dublin Core description (or source filename fallback),
     optimizer version, and generated OSIS initials through the same dialog used for SWORD modules.

     - Parameter epub: Installed EPUB metadata selected from Choose Document.
     - Side effects: none.
     - Failure modes: Missing optional package fields were resolved by `EpubReader` when the
       immutable index opened, so the shared About renderer can omit no required identity.
     */
    init(epub: EpubInfo) {
        id = .epub(SwordJavaExactStringIdentity(epub.identifier))
        moduleName = epub.initials
        moduleDescription = epub.title
        aboutMetadata = ModuleAboutMetadata(
            about: epub.description,
            osisId: epub.initials
        )
        primaryVersionKind = .latestVersion
        primaryVersion = EpubReader.androidOptimizerVersion
        primaryVersionDate = nil
        installedVersion = nil
        installedVersionDate = nil
    }

    /**
     Android About rows assembled from the metadata iOS can honestly provide.

     - Returns: Ordered dialog rows matching Android's message-first About contract.
     - Side effects: none.
     - Failure modes: Empty optional metadata is omitted.
     */
    var androidAboutRows: [ModuleBrowserModuleDetailRow] {
        var rows: [ModuleBrowserModuleDetailRow] = []

        if aboutMetadata.isBadDocument {
            let warning = String(
                localized: "warn_bad_document",
                defaultValue: "Warning: This document might be (at least partially) bad technical quality."
            )
            rows.append(row(
                kind: .warning,
                title: String(localized: "warning", defaultValue: "Warning"),
                value: warning
            ))
        }

        if let about = Self.nonEmpty(Self.cleanedAboutText(aboutMetadata.about)) {
            rows.append(row(
                kind: .about,
                title: String(localized: "about", defaultValue: "About"),
                value: about
            ))
        }

        if let shortPromo = Self.nonEmpty(aboutMetadata.shortPromo) {
            rows.append(row(
                kind: .shortPromo,
                title: String(localized: "module_short_promo", defaultValue: "Summary"),
                value: shortPromo
            ))
        }

        if let copyright = Self.copyrightText(from: aboutMetadata) {
            rows.append(row(
                kind: .copyright,
                title: String(localized: "copyright", defaultValue: "Copyright"),
                value: copyright,
                message: Self.formattedAndroidString(
                    key: "module_about_copyright",
                    defaultValue: "Copyright: %@",
                    arguments: [copyright]
                )
            ))
        }

        if let unlockInfo = Self.nonEmpty(aboutMetadata.unlockInfo) {
            let title = String(localized: "unlock_info", defaultValue: "Encrypted module unlock info")
            rows.append(row(
                kind: .unlockInfo,
                title: title,
                value: unlockInfo,
                message: "\(title)\n\n\(unlockInfo)"
            ))
        }

        if let primaryVersion = Self.versionParts(primaryVersion, date: primaryVersionDate) {
            rows.append(row(
                kind: primaryVersionKind,
                title: Self.versionTitle(for: primaryVersionKind),
                value: primaryVersion.value,
                message: Self.versionMessage(
                    kind: primaryVersionKind,
                    version: primaryVersion.version,
                    date: primaryVersion.date
                )
            ))
        }

        if let installedVersion = Self.versionParts(installedVersion, date: installedVersionDate) {
            rows.append(row(
                kind: .installedVersion,
                title: Self.versionTitle(for: .installedVersion),
                value: installedVersion.value,
                message: Self.versionMessage(
                    kind: .installedVersion,
                    version: installedVersion.version,
                    date: installedVersion.date
                )
            ))
        }

        if let history = Self.versionHistoryText(aboutMetadata.history) {
            rows.append(row(
                kind: .versionHistory,
                title: String(localized: "module_about_version_history_label", defaultValue: "Version history"),
                value: history,
                message: Self.formattedAndroidString(
                    key: "about_version_history",
                    defaultValue: "Version history: %@",
                    arguments: ["\n\(history)"]
                )
            ))
        }

        if let versification = Self.nonEmpty(aboutMetadata.versification) {
            rows.append(row(
                kind: .versification,
                title: String(localized: "module_about_versification_label", defaultValue: "Versification"),
                value: versification,
                message: Self.formattedAndroidString(
                    key: "module_about_versification",
                    defaultValue: "Versification: %@",
                    arguments: [versification]
                )
            ))
        }

        if let osisId = Self.nonEmpty(aboutMetadata.osisId) {
            rows.append(row(
                kind: .osisId,
                title: String(localized: "module_about_osisId_label", defaultValue: "OSIS ID"),
                value: osisId,
                message: Self.formattedAndroidString(
                    key: "module_about_osisId",
                    defaultValue: "OSIS ID: %@",
                    arguments: [osisId]
                )
            ))
        }

        if let repository = Self.nonEmpty(aboutMetadata.repository) {
            rows.append(row(
                kind: .repository,
                title: String(localized: "module_about_repository_label", defaultValue: "Distribution server"),
                value: repository,
                message: Self.formattedAndroidString(
                    key: "module_about_repository",
                    defaultValue: "Distribution server: %@",
                    arguments: [repository]
                )
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
       - message: Android-style message fragment, or `nil` to use `value`.
     - Returns: Row value consumed by the shared dialog.
     - Side effects: none.
     - Failure modes: none.
     */
    private func row(
        kind: ModuleBrowserModuleDetailRow.Kind,
        title: String,
        value: String,
        message: String? = nil
    ) -> ModuleBrowserModuleDetailRow {
        ModuleBrowserModuleDetailRow(kind: kind, title: title, value: value, message: message)
    }

    /**
     Resolves Android version row parts.

     - Parameters:
       - version: Raw SWORD version.
       - date: Raw SWORD version date.
     - Returns: Parsed row parts, or `nil` when the version is empty.
     - Side effects: none.
     - Failure modes: Missing dates use Android's `-` placeholder.
     */
    private static func versionParts(_ version: String?, date: String?) -> (
        version: String,
        date: String,
        value: String
    )? {
        guard let version = nonEmpty(version) else {
            return nil
        }
        let date = nonEmpty(date) ?? "-"
        return (version: version, date: date, value: "\(version) (\(date))")
    }

    /**
     Resolves Android's localized label for one version row kind.

     - Parameter kind: Version row kind.
     - Returns: Localized row label.
     - Side effects: none.
     - Failure modes: Non-version kinds fall back to latest-version wording.
     */
    private static func versionTitle(for kind: ModuleBrowserModuleDetailRow.Kind) -> String {
        switch kind {
        case .installedVersion:
            return String(localized: "module_about_installed_version_label", defaultValue: "Installed version")
        default:
            return String(localized: "module_about_latest_version_label", defaultValue: "Latest version")
        }
    }

    /**
     Formats one Android version line.

     - Parameters:
       - kind: Version row kind controlling latest-versus-installed wording.
       - version: Version value to interpolate.
       - date: Version date value to interpolate.
     - Returns: Localized Android-compatible version line.
     - Side effects: Reads localized strings from the app bundle.
     - Failure modes: Android `%s` placeholders are normalized before Swift formatting.
     */
    private static func versionMessage(
        kind: ModuleBrowserModuleDetailRow.Kind,
        version: String,
        date: String
    ) -> String {
        switch kind {
        case .installedVersion:
            return formattedAndroidString(
                key: "module_about_installed_version",
                defaultValue: "Installed version: %1$@ (%2$@)",
                arguments: [version, date]
            )
        default:
            return formattedAndroidString(
                key: "module_about_latest_version",
                defaultValue: "Latest version: %1$@ (%2$@)",
                arguments: [version, date]
            )
        }
    }

    /**
     Formats Android string resources with Swift-safe placeholder handling.

     Android translations use `%s`, `%1$s`, and `%2$s` placeholders. Swift's formatter expects object
     placeholders (`%@`) for `String` arguments, so this helper normalizes Android string resources
     before interpolation while preserving the translated wording.

     - Parameters:
       - key: Android/iOS localization key.
       - defaultValue: English fallback format.
       - arguments: Format arguments.
     - Returns: Interpolated localized text.
     - Side effects: Reads localized strings from the app bundle.
     - Failure modes: Missing keys use `defaultValue`.
     */
    private static func formattedAndroidString(
        key: String,
        defaultValue: String,
        arguments: [CVarArg]
    ) -> String {
        let localizedFormat = Bundle.main.localizedString(forKey: key, value: defaultValue, table: nil)
        let format = iosStringFormat(fromAndroidFormat: localizedFormat)
        guard !arguments.isEmpty else {
            return format
        }
        return String(format: format, locale: Locale.current, arguments: arguments)
    }

    /**
     Converts Android `%s` string placeholders into Swift object placeholders.

     - Parameter format: Localized Android-format string.
     - Returns: Swift `String(format:)` compatible format string.
     - Side effects: none.
     - Failure modes: Non-string placeholders are left unchanged.
     */
    private static func iosStringFormat(fromAndroidFormat format: String) -> String {
        var normalized = format
        for index in 1...9 {
            normalized = normalized.replacingOccurrences(of: "%\(index)$s", with: "%\(index)$@")
        }
        return normalized.replacingOccurrences(of: "%s", with: "%@")
    }

    /**
     Imports Android-style HTML into a Swift attributed string.

     - Parameter html: HTML message body produced by `androidAboutHTMLMessage`.
     - Returns: Attributed text when Foundation can parse the HTML, otherwise `nil`.
     - Side effects: none.
     - Failure modes: Invalid UTF-8 or malformed HTML returns `nil`.
     */
    private static func attributedHTMLString(from html: String) -> AttributedString? {
        guard let data = html.data(using: .utf8) else {
            return nil
        }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        guard let attributed = try? NSAttributedString(
            data: data,
            options: options,
            documentAttributes: nil
        ) else {
            return nil
        }
        return AttributedString(attributed)
    }

    /**
     Merges copyright fields using Android's `CommonUtils.showAbout(...)` precedence.

     - Parameter metadata: Source-backed About metadata.
     - Returns: Copyright/distribution text, or `nil` when both fields are empty.
     - Side effects: none.
     - Failure modes: none.
     */
    private static func copyrightText(from metadata: ModuleAboutMetadata) -> String? {
        var merged = ""
        if let shortCopyright = nonEmpty(metadata.shortCopyright) {
            merged += shortCopyright
        } else if let copyright = nonEmpty(metadata.copyright) {
            merged += "\n\n\(copyright)"
        }
        if let distributionLicense = nonEmpty(metadata.distributionLicense) {
            merged += "\n\n\(distributionLicense)"
        }
        return nonEmpty(merged) == nil ? nil : merged
    }

    /**
     Formats JSword version history values in Android display order.

     - Parameter history: Config-order history values.
     - Returns: Newest-first history text, or `nil` when no values exist.
     - Side effects: none.
     - Failure modes: Empty history entries are dropped.
     */
    private static func versionHistoryText(_ history: [String]) -> String? {
        let values = history.compactMap(nonEmpty)
        guard !values.isEmpty else {
            return nil
        }
        return values.reversed().joined(separator: "\n")
    }

    /**
     Applies Android's simple `About` text cleanup before rendering.

     - Parameter value: Raw SWORD About text.
     - Returns: Text with Android-removed RTF paragraph tokens normalized.
     - Side effects: none.
     - Failure modes: none.
     */
    private static func cleanedAboutText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\pard", with: "")
            .replacingOccurrences(of: "\\par", with: "\n")
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
    enum Kind: Hashable {
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

    /**
     Java-exact identity for one destructive module confirmation.

     - Inputs: Confirmation kind and exact module initials.
     - Returns: Hashable owner identity that does not normalize or case-fold initials.
     - Side effects: none.
     - Failure modes: none.
     */
    struct ID: Hashable {
        /// Destructive operation awaiting confirmation.
        let kind: Kind

        /// Raw UTF-16 module owner awaiting the operation.
        let module: SwordJavaExactStringIdentity
    }

    /// Stable Java-exact alert identity.
    var id: ID { ID(kind: kind, module: SwordJavaExactStringIdentity(moduleName)) }

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
        self.init(kind: kind, moduleName: module.name, moduleDescription: module.description)
    }

    /**
     Creates a confirmation payload for an installed reader-picker action.

     - Parameters:
       - kind: Android-equivalent destructive operation.
       - installedModule: Installed module that supplied the action.
     - Side effects: none.
     - Failure modes: none.
     */
    init(kind: Kind, installedModule: ModuleInfo) {
        self.init(kind: kind, moduleName: installedModule.name, moduleDescription: installedModule.description)
    }

    /**
     Creates a confirmation payload from the normalized user-visible module labels.

     - Parameters:
       - kind: Android-equivalent destructive operation.
       - moduleName: SWORD module initials used for repository actions.
       - moduleDescription: User-facing module title used in confirmation copy.
     - Side effects: none.
     - Failure modes: none.
     */
    private init(kind: Kind, moduleName: String, moduleDescription: String) {
        self.kind = kind
        self.moduleName = moduleName
        self.moduleDescription = moduleDescription
    }

    /**
     Empty alert title matching Android's message-only destructive document dialogs.

     - Returns: An empty string for both operations.
     - Side effects: none.
     - Failure modes: none.
     */
    var title: String {
        ""
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
                localized: "delete_doc",
                defaultValue: "Delete %@?"
            )
            return String(format: format, moduleName)
        case .deleteIndex:
            let format = String(
                localized: "delete_search_index_doc",
                defaultValue: "Delete index of %@?"
            )
            return String(format: format, moduleName)
        }
    }

    /**
     Android positive-button label for the selected destructive operation.

     - Returns: `Yes` for document deletion or `OK` for search-index deletion.
     - Side effects: Reads the application localization bundle.
     - Failure modes: Missing translations use the Android English fallback.
     */
    var confirmButtonTitle: String {
        switch kind {
        case .uninstall:
            return String(localized: "yes", defaultValue: "Yes")
        case .deleteIndex:
            return String(localized: "okay", defaultValue: "OK")
        }
    }

    /**
     Android negative-button label for the selected destructive operation.

     - Returns: `No` for document deletion or `Cancel` for search-index deletion.
     - Side effects: Reads the application localization bundle.
     - Failure modes: Missing translations use the Android English fallback.
     */
    var cancelButtonTitle: String {
        switch kind {
        case .uninstall:
            return String(localized: "no", defaultValue: "No")
        case .deleteIndex:
            return String(localized: "cancel", defaultValue: "Cancel")
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
    /// Normalized module metadata to display.
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
        AndroidDialogScaffold(title: "") {
            AndroidAdaptiveDialogScrollView {
                Text(details.androidAboutAttributedMessage)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("moduleDetailsDialogMessage")
                    .padding(.horizontal, 22)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } actions: {
            AndroidDialogTextAction(
                title: String(localized: "okay", defaultValue: "OK"),
                accessibilityIdentifier: "moduleDetailsOKButton",
                action: onDismiss
            )
        }
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
        AndroidDialogWindow(
            colorScheme: colorScheme,
            accessibilityIdentifier: "moduleDetailsDialogScreen",
            allowsOutsideDismissal: false,
            onOutsideTap: {}
        ) {
            ModuleBrowserModuleDetailsDialog(
                details: details,
                onDismiss: onDismiss
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .zIndex(2)
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
