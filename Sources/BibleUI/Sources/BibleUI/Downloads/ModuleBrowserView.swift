// ModuleBrowserView.swift — Module download browser

import Foundation
import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import BibleCore
import SwordKit

/**
 Tracks one active or failed Downloads row operation using Android's document-status shape.

 Android exposes `BEING_INSTALLED` as a durable job and `ERROR_DOWNLOADING` as row state rather
 than a global spinner. iOS keeps the same contract locally: active rows preserve download,
 extraction, and commit phases with determinate or indeterminate progress, while failed rows remain
 in the list with a retry action.

 Side effects:
 - none; values are immutable snapshots of row state

 Failure modes:
 - none; `ModuleInstallProgress` normalizes malformed fractions before they reach the UI
 */
struct ModuleBrowserDownloadActivity: Equatable {
    /**
     Operation phase for a download row.

     Cases mirror Android's install-status branch points: progress for `BEING_INSTALLED`, and
     retained failure details for `ERROR_DOWNLOADING`.
     */
    enum Phase: Equatable {
        /// Module files are queued, downloading, extracting, or committing.
        case inProgress

        /// The latest install attempt failed and can be retried from the row.
        case failed
    }

    /// Current Android-equivalent row phase.
    let phase: Phase

    /// Structured installer phase for active rows; absent for retained failures.
    let installProgress: ModuleInstallProgress?

    /// User-visible failure detail for failed rows.
    let message: String?

    /**
     Creates an in-progress activity snapshot.

     - Parameter progressFraction: Normalized completion ratio. Values outside `0.0...1.0` are
       clamped before storage.
     - Returns: An activity representing Android `BEING_INSTALLED`.
     - Side effects: none.
     - Failure modes: none.
     */
    static func inProgress(_ progressFraction: Double) -> ModuleBrowserDownloadActivity {
        inProgress(ModuleInstallProgress(phase: .downloading, fraction: progressFraction))
    }

    /**
     Creates an active row from structured repository progress.

     - Parameter installProgress: Current queued/download/extract/commit/complete snapshot.
     - Returns: An activity representing Android `BEING_INSTALLED` until the owner clears it after
       successful completion.
     - Side effects: none.
     - Failure modes: none; fractions were normalized by `ModuleInstallProgress`.
     */
    static func inProgress(_ installProgress: ModuleInstallProgress) -> ModuleBrowserDownloadActivity {
        ModuleBrowserDownloadActivity(
            phase: .inProgress,
            installProgress: installProgress,
            message: nil
        )
    }

    /**
     Creates a retained failed-download activity snapshot.

     - Parameter message: Failure text from the repository install attempt.
     - Returns: An activity representing Android `ERROR_DOWNLOADING`.
     - Side effects: none.
     - Failure modes: empty messages are normalized by the row to the generic download-failed text.
     */
    static func failed(_ message: String) -> ModuleBrowserDownloadActivity {
        ModuleBrowserDownloadActivity(
            phase: .failed,
            installProgress: nil,
            message: message
        )
    }

    /**
     Integer percent displayed beside the row progress indicator.

     - Returns: A clamped `0...100` percent derived from `progressFraction`.
     - Side effects: none.
     - Failure modes: none.
     */
    var progressPercent: Int? {
        installProgress?.percent
    }
}

/**
 Captures the Android Downloads state used for list ordering.

 Android rebuilds sort order when `DocumentSelectionBase.filterDocuments()` runs, but starting a
 row install only calls `notifyDataSetChanged()`, which updates that row in place. iOS uses this
 snapshot to keep row ordering stable during live progress updates while still allowing explicit
 filter/catalog rebuilds to apply Android's active-download-first sort.

 Side effects:
 - none; values are immutable ordering inputs

 Failure modes:
 - none; stale snapshots are intentional until the next filter/catalog rebuild
 */
struct ModuleBrowserDownloadSortSnapshot {
    /// Installed modules used to determine installed/update sort rank.
    let installedModules: [ModuleInfo]

    /// Row activities used to determine Android `BEING_INSTALLED`/error sort rank.
    let downloadActivities: [RemoteModuleIdentity: ModuleBrowserDownloadActivity]
}

/**
 Staged Downloads confirmation matching Android's two download dialog paths.

 Android shows a simple `Download <name>` confirmation for new/retry installs, but installed
 modules with generic bookmarks or notes use a stronger update warning before `doDownload(...)`.
 iOS keeps both cases in one payload so every row entry point (tap, retry, update icon) commits
 through the same Android-equivalent confirmation branch.

 Side effects:
 - none; this value only describes pending UI state

 Failure modes:
 - none; installing after confirmation is handled by `ModuleBrowserView.installModule(_:)`
 */
private struct ModuleBrowserDownloadConfirmation: Identifiable {
    /**
     Android confirmation variant for the staged document action.

     Cases mirror `DownloadActivity.manageDownload`: normal rows use the download prefix message,
     while installed rows with generic bookmarks route through `documentUpgradeConfirmation`.
     */
    enum Kind: String {
        /// Standard install, retry, or update confirmation without bookmark risk.
        case download

        /// Update confirmation warning that generic bookmarks or notes may move or disappear.
        case genericBookmarkUpdateWarning
    }

    /// Remote module row selected by the user.
    let module: RemoteModuleInfo

    /// Android confirmation branch selected for this row.
    let kind: Kind

    /// Stable SwiftUI identity for the pending alert.
    var id: String { "\(kind.rawValue)::\(module.id)" }

    /// Android alert title for the selected confirmation branch.
    var title: String {
        switch kind {
        case .download:
            return ""
        case .genericBookmarkUpdateWarning:
            return String(
                localized: "bookmark_warning",
                defaultValue: "There are bookmarks and/or notes for this document."
            )
        }
    }

    /// Android positive-button label for the selected confirmation branch.
    var confirmButtonTitle: String {
        switch kind {
        case .download:
            return String(localized: "okay", defaultValue: "OK")
        case .genericBookmarkUpdateWarning:
            return String(localized: "yes", defaultValue: "Yes")
        }
    }

    /// Android alert message for the selected confirmation branch.
    var message: String {
        switch kind {
        case .download:
            return ModuleBrowserView.downloadConfirmationMessage(for: module)
        case .genericBookmarkUpdateWarning:
            return ModuleBrowserView.genericBookmarkUpdateWarningMessage()
        }
    }
}

/**
 Local SWORD archive waiting for Android-equivalent overwrite consent.

 The repository repeats inspection at install time; this value exists only to preserve the selected
 request and present the exact conflicts found during the read-only preflight.
 */
private struct ModuleBrowserLocalOverwriteConfirmation: Identifiable {
    /// Selected external document request retained across alert presentation.
    let request: ExternalDocumentImportRequest

    /// Validated archive summary and existing destination paths.
    let inspection: LocalSwordZipInspection

    /// Stable alert identity derived from the selected file URL.
    var id: String { request.url.standardizedFileURL.path }
}

/**
 Android download-row status used by `ModuleBrowserView`.

 The enum mirrors Android `DocumentStatus.DocumentInstallStatus` closely enough for sorting and
 row controls: in-progress rows sort first with determinate progress, failed rows keep a retry
 affordance, updates sort before already-installed rows, installed rows show completed state,
 unavailable pseudo rows stay visible but disabled, and installable rows expose the normal install
 action.
 */
enum ModuleBrowserDownloadStatus: Equatable {
    /// The module is currently queued, downloading, extracting, or committing.
    case beingInstalled(progress: ModuleInstallProgress)

    /// The previous module install attempt failed and can be retried.
    case errorDownloading(message: String)

    /// A repository module has a newer version than the installed module.
    case updateAvailable

    /// The same module version is already installed.
    case installed

    /// The row is Android pseudo/unavailable metadata and cannot be installed.
    case unavailable

    /// The row can be installed.
    case installable

    /**
     Whether this row is in Android's active `BEING_INSTALLED` branch.

     - Returns: `true` only for rows actively downloading or installing.
     - Side effects: none.
     - Failure modes: none.
     */
    var isBeingInstalled: Bool {
        if case .beingInstalled = self {
            return true
        }
        return false
    }
}

/**
 Controls whether `ModuleBrowserView` should consume Android startup default metadata.

 Normal Downloads entry points keep this disabled. The reader startup Easy Start prompt enables
 the English mode so iOS follows Android's `download-recommended` path: refresh metadata/catalogs,
 read `default_documents_v2.json`, and request the configured English defaults once.
 */
public enum ModuleBrowserDefaultDownloadMode: Sendable, Equatable {
    /// Render normal Downloads without automatically requesting default documents.
    case disabled

    /// Consume Android's English startup defaults, matching `StartupActivity.easyStart()`.
    case englishStartup

    /**
     Whether this mode should trigger startup default installation.
     - Returns: `true` for modes that consume default metadata.
     - Side effects: none.
     - Failure modes: none.
     */
    var shouldInstallDefaultDocuments: Bool {
        self == .englishStartup
    }

    /**
     Android metadata language bucket consumed by this mode.
     - Returns: The metadata language code, or `nil` when defaults are disabled.
     - Side effects: none.
     - Failure modes: none.
     */
    var languageCode: String? {
        switch self {
        case .disabled:
            return nil
        case .englishStartup:
            return "en"
        }
    }
}

/**
 Browses installed and remote SWORD modules, then coordinates install and uninstall actions.

 The view combines locally installed module metadata from `SwordManager` with cached or refreshed
 remote catalogs from `ModuleRepository`, then renders Android-style download rows filtered by
 category, language, and free-text search.

 Data dependencies:
 - `SwordManager` is created lazily to read installed module metadata from the local module store
 - `ModuleRepository` loads configured remote sources, cached catalogs, and install/uninstall side
   effects from disk
 - local state tracks in-flight refresh and install operations so the UI can show progress and
   disable duplicate actions

 Side effects:
 - `onAppear` initializes repository-backed state, loads configured sources, and restores cached
   catalogs when available
 - refreshing the catalog performs network-backed repository fetches, merges results, and surfaces
   partial failures through local error state
 - when launched in startup default mode, refresh consumes `default_documents_v2.json` and requests
   selected English defaults once
 - installing or uninstalling a module mutates the local module store on disk, rebuilds the
   `SwordManager`, and refreshes the installed state shown in the download rows
 */
public struct ModuleBrowserView: View {
    /// Shared popup anchor used by the Downloads activity overflow action.
    private enum PopupAnchor {
        static let overflow = "moduleBrowserOverflowAnchor"
    }

    /// Android's repository list staleness window before Downloads refreshes catalogs on open.
    nonisolated static let downloadCatalogStaleInterval: TimeInterval = 24 * 60 * 60

    /// Persisted Android-style document type filter index.
    private static let selectedDocumentFilterIndexKey = "downloads.selectedDocumentFilterIndex"

    /// Android-style sticky Downloads language for the current app process.
    private static var lastSelectedLanguageCode: String?

    /// Dismisses the Android-style Downloads destination back to the reader stack.
    @Environment(\.dismiss) private var dismiss

    /// Active scheme used by shared popup elevation and accent resolution.
    @Environment(\.colorScheme) private var colorScheme

    /// Shared full-text search index service used for Android's Delete Index row action.
    @Environment(SearchIndexService.self) private var searchIndexService

    /// Startup/default-document behavior requested by the caller.
    private let defaultDownloadMode: ModuleBrowserDefaultDownloadMode

    /// Colors inherited from the launching reader workspace/window.
    private let surfacePalette: ReaderThemeSurfacePalette

    /// Reports whether startup default refresh/install work is still active.
    private let onDefaultDownloadActivityChanged: (Bool) -> Void

    /// Selected remote/local module category segment, or `nil` for Android's "All types" filter.
    @State private var selectedCategory: ModuleCategory?

    /// Selected language filter, or an empty string when all languages should be shown.
    @State private var selectedLanguage: String = ""

    /// Free-text query applied to the Android-style download list.
    @State private var searchText = ""

    /// Remote row selected by Android's single-choice contextual action mode.
    @State private var contextualModuleIdentity: RemoteModuleIdentity?

    /// Whether a remote catalog refresh is currently in progress.
    @State private var isRefreshing = false

    /// Whether initial local SWORD/cache restoration is running after the sheet appears.
    @State private var isLoadingInitialState = false

    /// Guards the initial load task so SwiftUI body updates do not restart local setup work.
    @State private var didStartInitialStateLoad = false

    /// De-duplicated remote modules loaded from configured sources or the local cache.
    @State private var availableModules: [RemoteModuleInfo] = []

    /// Installed module metadata resolved from the current local SWORD manager.
    @State private var installedModules: [ModuleInfo] = []

    /// Android recommended-document metadata used for badges and language-specific ordering.
    @State private var recommendedDocuments: ModuleDownloadConfiguration?

    /// Android bad-document metadata used to hide or warn about known problematic modules.
    @State private var badDocuments: ModuleDownloadConfiguration?

    /// Android default-document metadata used by the startup Easy Start flow.
    @State private var defaultDocuments: ModuleDownloadConfiguration?

    /// Lazily created SWORD manager used to query locally installed modules.
    @State private var swordManager: SwordManager?

    /// Repository facade used for source loading, catalog refresh, and install actions.
    @State private var repository = ModuleRepository()

    /// Configured remote source definitions loaded from repository configuration.
    @State private var sources: [SourceConfig] = []

    /// Per-module row activity for Android-style progress, cancel, and retry state.
    @State private var downloadActivities: [RemoteModuleIdentity: ModuleBrowserDownloadActivity] = [:]

    /// Whether Downloads has captured Android's current filter/sort inputs for visible row order.
    @State private var didCaptureDownloadSortSnapshot = false

    /// Installed/activity state used for Android-style row ordering until the next filter rebuild.
    @State private var downloadSortSnapshot = ModuleBrowserDownloadSortSnapshot(
        installedModules: [],
        downloadActivities: [:]
    )

    /// Running install tasks keyed exactly like Android's repository-scoped download queue.
    @State private var installTasks: [RemoteModuleIdentity: Task<Void, Never>] = [:]

    /// Monotonic task identifiers that prevent stale cancelled tasks from clearing newer retries.
    @State private var installTaskIDs: [RemoteModuleIdentity: UUID] = [:]

    /// User-visible error text for refresh, install, or uninstall failures.
    @State private var errorMessage: String?

    /// Android overflow-menu download errors accumulated from repositories, metadata, and installs.
    @State private var downloadErrors: [String] = []

    /// Whether the Android-equivalent Download errors alert is visible.
    @State private var showDownloadErrors = false

    /// Whether Android's top-right Downloads overflow popup is visible.
    @State private var showOverflowMenu = false

    /// Module details currently presented from Android's row About action.
    @State private var selectedModuleDetails: ModuleBrowserModuleDetails?

    /// Installed encrypted module whose Android passphrase prompt is visible.
    @State private var pendingUnlockModule: ModuleInfo?

    /// Cipher key entered for the pending Downloads unlock action.
    @State private var unlockCipherKey = ""

    /// Rejected-key feedback retained while the passphrase prompt is presented again.
    @State private var unlockFailureMessage: String?

    /// Whether the custom repository manager is pushed from the Downloads overflow menu.
    @State private var showRepositoryManager = false

    /// Whether Android's Install ZIP file picker is visible.
    @State private var showInstallZipImporter = false

    /// Whether a selected ZIP/EPUB/font import is currently installing.
    @State private var isImportingExternalDocument = false

    /// Current durable phase for a local SWORD ZIP import.
    @State private var externalDocumentImportProgress: ModuleInstallProgress?

    /// Local SWORD ZIP waiting for explicit replacement consent.
    @State private var pendingLocalModuleOverwrite: ModuleBrowserLocalOverwriteConfirmation?

    /// Feedback from Android's Install ZIP equivalent.
    @State private var externalDocumentImportMessage: String?

    /// SwiftData context used to check Android's generic-bookmark update warning condition.
    @Environment(\.modelContext) private var modelContext

    /// Ensures Android's startup/default language is applied once after catalog state exists.
    @State private var didApplyAndroidDefaultLanguage = false

    /// Destructive row action waiting for Android-style confirmation.
    @State private var pendingRowActionConfirmation: ModuleBrowserRowActionConfirmation?

    /// Install/update row waiting for Android's download confirmation dialog.
    @State private var pendingDownloadConfirmation: ModuleBrowserDownloadConfirmation?

    /// Progress text describing which remote source is being refreshed.
    @State private var refreshProgress: String?

    /// Guards Android startup defaults so they are requested at most once per Downloads session.
    @State private var didRequestDefaultDocuments = false

    /// Startup default modules whose asynchronous installs have not reached a terminal row state.
    @State private var defaultDownloadInstallingModules: Set<RemoteModuleIdentity> = []

    /// Remote catalog row currently driving Android's contextual document menu.
    private var contextualModule: RemoteModuleInfo? {
        guard let contextualModuleIdentity else { return nil }
        return availableModules.first { $0.installIdentity == contextualModuleIdentity }
    }

    /// Installed metadata paired with the selected contextual catalog row, when present.
    private var contextualInstalledModule: ModuleInfo? {
        guard let contextualModule else { return nil }
        return Self.installedModuleLookup(from: installedModules)[contextualModule.name]
    }

    /// Android-ordered contextual actions for the selected Downloads row.
    private var contextualModuleActions: [ModuleDownloadRowAction] {
        guard let contextualModule else { return [] }
        let status = Self.displayStatus(
            for: contextualModule,
            installedModulesByName: Self.installedModuleLookup(from: installedModules),
            downloadActivities: downloadActivities
        )
        return Self.rowActions(
            installedModule: contextualInstalledModule,
            isBeingInstalled: status.isBeingInstalled,
            installedModules: installedModules
        )
    }

    /**
     Creates the module browser with optional Android-compatible search and default-download state.

     - Parameters:
       - initialSearchText: Optional module initials that should pre-populate search. Empty or
         whitespace-only values are normalized to an empty query. A non-empty value starts on
         Android's "All types" category so Bibles, commentaries, dictionaries, and books can all
         satisfy a module-initials link.
       - defaultDownloadMode: Optional startup/default-document mode. Normal Downloads callers use
         `.disabled`; the startup Easy Start flow uses `.englishStartup`.
       - onDefaultDownloadActivityChanged: Optional callback that reports startup default refresh and
         install activity so callers can avoid prompting while Easy Start is still running.

     Side effects:
     - initializes local SwiftUI state with the standard palette only; reader-owned routes use the
       module-internal palette overload below
     - repository and installed-module data are still loaded lazily in `onAppear`
     - when a default-download mode is supplied, `onAppear` later refreshes metadata/catalogs and
       requests Android defaults once

     Failure modes:
     - invalid or unknown initials simply behave as a free-text all-types search with no matching
       rows until catalog data contains that module
     */
    public init(
        initialSearchText: String = "",
        defaultDownloadMode: ModuleBrowserDefaultDownloadMode = .disabled,
        onDefaultDownloadActivityChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.init(
            initialSearchText: initialSearchText,
            defaultDownloadMode: defaultDownloadMode,
            surfacePalette: .standard,
            onDefaultDownloadActivityChanged: onDefaultDownloadActivityChanged
        )
    }

    /**
     Creates a reader-owned Downloads activity with the launching workspace/window palette.

     This module-internal overload keeps the public Downloads API source-compatible while allowing
     reader routes to pass the same resolved palette used by Choose Document. The palette remains an
     internal BibleUI implementation type rather than leaking reader-shell internals into the public
     package interface.

     - Parameters:
       - initialSearchText: Optional module initials used to pre-populate Android's search field.
       - defaultDownloadMode: Optional startup/default-document behavior.
       - surfacePalette: Owner-resolved reader/workspace colors shared with Choose Document.
       - onDefaultDownloadActivityChanged: Startup work-state callback.
     - Side effects: Initializes local view state only; repository loading remains lazy.
     - Failure modes: Empty or unknown search values produce the normal filtered list behavior.
     */
    init(
        initialSearchText: String = "",
        defaultDownloadMode: ModuleBrowserDefaultDownloadMode = .disabled,
        surfacePalette: ReaderThemeSurfacePalette,
        onDefaultDownloadActivityChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.defaultDownloadMode = defaultDownloadMode
        self.surfacePalette = surfacePalette
        self.onDefaultDownloadActivityChanged = onDefaultDownloadActivityChanged
        let normalizedSearchText = initialSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedFilterIndex = Self.persistedDocumentFilterIndex()
        _selectedCategory = State(
            initialValue: Self.initialSelectedCategory(
                initialSearchText: normalizedSearchText,
                defaultDownloadMode: defaultDownloadMode,
                storedFilterIndex: storedFilterIndex
            )
        )
        _searchText = State(initialValue: normalizedSearchText)
    }

    // MARK: - Computed Properties

    /**
     All unique languages from available and installed modules, sorted by display name.

     English is placed first, then alphabetical by resolved name, then unresolved codes last.
     */
    private var availableLanguages: [String] {
        var langs = Set<String>()
        for m in availableModules where Self.matchesDownloadCategory(m.category, selectedCategory: selectedCategory) {
            langs.insert(m.language)
        }
        for m in installedModules where Self.matchesDownloadCategory(m.category, selectedCategory: selectedCategory) {
            langs.insert(m.language)
        }
        return langs.sorted { a, b in
            let nameA = displayName(for: a)
            let nameB = displayName(for: b)
            let resolvedA = nameA != a.uppercased()
            let resolvedB = nameB != b.uppercased()
            // English first (exact "en" or "en-XX" variants only)
            let isEnA = a.lowercased() == "en" || a.lowercased().hasPrefix("en-")
            let isEnB = b.lowercased() == "en" || b.lowercased().hasPrefix("en-")
            if isEnA && !isEnB { return true }
            if !isEnA && isEnB { return false }
            // Resolved names before unresolved codes
            if resolvedA && !resolvedB { return true }
            if !resolvedA && resolvedB { return false }
            return nameA.localizedCaseInsensitiveCompare(nameB) == .orderedAscending
        }
    }

    /// Available (remote) modules filtered by category, language, and search text.
    private var filteredAvailableModules: [RemoteModuleInfo] {
        let sortSnapshot = currentDownloadSortSnapshot
        return Self.filteredDownloadModules(
            availableModules,
            selectedCategory: selectedCategory,
            selectedLanguage: selectedLanguage,
            searchText: searchText,
            installedModules: sortSnapshot.installedModules,
            downloadActivities: sortSnapshot.downloadActivities,
            recommendedDocuments: recommendedDocuments,
            badDocuments: badDocuments
        )
    }

    /**
     Current installed/activity state that should influence Downloads row order.

     Android does not rerun `filterDocuments()` when a row begins installing; it updates the row in
     place. Until iOS has captured a filter/catalog rebuild snapshot, this falls back to live state
     so previews/tests that exercise the helper without loading state still behave deterministically.
     */
    private var currentDownloadSortSnapshot: ModuleBrowserDownloadSortSnapshot {
        didCaptureDownloadSortSnapshot
            ? downloadSortSnapshot
            : Self.downloadListSortSnapshot(
                installedModules: installedModules,
                downloadActivities: downloadActivities
            )
    }

    /**
     Captures the state Android would use after rerunning `DocumentSelectionBase.filterDocuments()`.

     Side effects:
     - updates the Downloads sort snapshot used by `filteredAvailableModules`
     - marks the snapshot as initialized for this view lifetime

     Failure modes:
     - none; the snapshot intentionally remains stale during row-only install progress changes
     */
    private func captureDownloadListSortSnapshot() {
        downloadSortSnapshot = Self.downloadListSortSnapshot(
            installedModules: installedModules,
            downloadActivities: downloadActivities
        )
        didCaptureDownloadSortSnapshot = true
    }

    // MARK: - Body

    /**
     Builds the filtered Android-style download list and repository-management toolbar actions.
     */
    public var body: some View {
        androidDownloadsScreen
    }

    /**
     Builds Android's full-screen Downloads route.

     iOS previously reused a modal `List` sheet. Android opens a full-screen activity with a dark
     app bar, inline filters, and document rows. Keeping this as the root screen body avoids carrying
     iOS sheet chrome into a route whose UX is platform-shared in AndBible.

     - Returns: Full-screen Downloads content with app bar, filters, and rows.
     - Side effects: Toolbar buttons can dismiss, show Android overflow actions, or push repository
       management.
     - Failure modes: Repository errors are rendered in the list and do not prevent the route from
       opening.
     */
    private var androidDownloadsLayout: some View {
        let visibleModules = filteredAvailableModules
        let installedModulesByName = Self.installedModuleLookup(from: installedModules)

        return ZStack(alignment: .topTrailing) {
            AndroidActivityAccessibilityMarker(
                label: String(localized: "download_documents", defaultValue: "Download Documents"),
                accessibilityIdentifier: "moduleBrowserScreen",
                surfaceColor: surfacePalette.backgroundColor
            )
            moduleBrowserStateExport(
                visibleModules: visibleModules,
                installedModulesByName: installedModulesByName
            )
            AndroidDocumentSelectionActivityScreen(surfacePalette: surfacePalette) {
                androidTopAppBar
            } filterBar: {
                androidFilterBar(visibleModuleCount: visibleModules.count)
            } rows: {
                androidDownloadsContent(
                    visibleModules: visibleModules,
                    installedModulesByName: installedModulesByName
                )
            }
        }
        .androidAnchoredPopupMenu(
            anchorID: PopupAnchor.overflow,
            isPresented: $showOverflowMenu,
            menuWidth: 310,
            estimatedMenuHeight: 96,
            accessibilityIdentifier: "moduleBrowserOverflowMenu"
        ) {
            androidOverflowMenu
        }
        .onChange(of: searchText) {
            clearContextualModuleSelection()
            alignFiltersWithAndroidSearchState(searchText)
            captureDownloadListSortSnapshot()
        }
        .onChange(of: visibleModules.map(\.installIdentity)) { _, visibleIdentities in
            guard let contextualModuleIdentity,
                  !visibleIdentities.contains(contextualModuleIdentity) else { return }
            clearContextualModuleSelection()
        }
    }

    /**
     Attaches repository navigation, local-file import, and module details presentation.

     - Returns: Downloads layout with non-alert document-management presenters.
     - Side effects: Presented controls can navigate, import a file, or clear selected details.
     - Failure modes: Import failures are retained for the later feedback-alert stage.
     */
    private var documentManagementPresentedDownloadsScreen: some View {
        androidDownloadsLayout
        .navigationDestination(isPresented: $showRepositoryManager) {
            RepositoryManagerView(surfacePalette: surfacePalette)
        }
        .fileImporter(
            isPresented: $showInstallZipImporter,
            allowedContentTypes: ExternalDocumentImportService.supportedContentTypes,
            allowsMultipleSelection: false,
            onCompletion: handleInstallZipSelection
        )
        .moduleBrowserModuleDetailsDialog(details: selectedModuleDetails) {
            selectedModuleDetails = nil
        }
    }

    /**
     Attaches encrypted-module unlock and accumulated download-error presentation.

     - Returns: Document-management content with module-access alerts.
     - Side effects: Actions can apply a cipher key, clear unlock state, or dismiss error history.
     - Failure modes: Rejected keys retain retry feedback; download errors remain in their list.
     */
    private var moduleAccessPresentedDownloadsScreen: some View {
        documentManagementPresentedDownloadsScreen
        .overlay {
            if let module = pendingUnlockModule {
                ModulePickerUnlockDialog(title: ModuleUnlockActionCoordinator.promptTitle(for: module), message: unlockFailureMessage ?? String(localized: "enter_module_passphrase", defaultValue: "Enter the module passphrase."), cipherKey: $unlockCipherKey, showUnlockInfo: !module.aboutMetadata.unlockInfo.isEmpty, onUnlock: { attemptUnlock(module) }, onShowUnlockInfo: { showUnlockInformation(for: module) }, onCancel: clearUnlockPrompt)
            } else if showDownloadErrors {
                ModulePickerDecisionDialog(title: String(localized: "download_errors", defaultValue: "Download errors"), message: downloadErrors.joined(separator: "\n"), actions: [
                    .init(id: "okay", title: String(localized: "okay", defaultValue: "OK"), role: nil) { showDownloadErrors = false }
                ])
            }
        }
    }

    /**
     Attaches overwrite consent and external-file import completion feedback.

     - Returns: Module-access content with local import alerts.
     - Side effects: Consent can start a replacement install; dismissals clear retained import state.
     - Failure modes: Import failures remain visible until the feedback alert is dismissed.
     */
    private var importFeedbackPresentedDownloadsScreen: some View {
        moduleAccessPresentedDownloadsScreen
        .overlay {
            if let confirmation = pendingLocalModuleOverwrite {
                ModulePickerDecisionDialog(title: String(localized: "android_module_backup_overwrite_title", defaultValue: "Overwrite existing module files?"), message: Self.localModuleOverwriteMessage(confirmation.inspection), actions: [
                    .init(id: "cancel", title: String(localized: "cancel"), role: nil) { pendingLocalModuleOverwrite = nil },
                    .init(id: "overwrite", title: String(localized: "overwrite", defaultValue: "Overwrite"), role: .destructive) { pendingLocalModuleOverwrite = nil; importExternalDocument(confirmation.request, overwritePolicy: .replaceExisting(confirmation.inspection.overwriteAuthorization)) }
                ])
            } else if let message = externalDocumentImportMessage {
                ModulePickerDecisionDialog(title: String(localized: "install_zip", defaultValue: "Load Documents From Files"), message: message, actions: [
                    .init(id: "okay", title: String(localized: "okay", defaultValue: "OK"), role: nil) { externalDocumentImportMessage = nil }
                ])
            }
        }
    }

    /**
     Attaches download confirmation and destructive installed-row action confirmation.

     - Returns: Import-feedback content with all row-action alerts.
     - Side effects: Confirmed actions can install, uninstall, or delete a search index.
     - Failure modes: Cancelling clears only the pending confirmation and leaves module state intact.
     */
    private var downloadActionPresentedDownloadsScreen: some View {
        importFeedbackPresentedDownloadsScreen
        .overlay {
            if let confirmation = pendingDownloadConfirmation {
                ModulePickerDecisionDialog(title: confirmation.title, message: confirmation.message, actions: [
                    .init(id: "install", title: confirmation.confirmButtonTitle, role: nil) { pendingDownloadConfirmation = nil; installModule(confirmation.module) },
                    .init(id: "cancel", title: String(localized: "cancel"), role: nil) { pendingDownloadConfirmation = nil }
                ])
            } else if let confirmation = pendingRowActionConfirmation {
                ModulePickerDecisionDialog(title: confirmation.title, message: confirmation.message, actions: [
                    .init(id: "confirm", title: confirmation.confirmButtonTitle, role: .destructive) {
                        switch confirmation.kind {
                        case .uninstall: uninstallModuleAfterCancellingInstall(confirmation.moduleName)
                        case .deleteIndex: deleteModuleIndex(confirmation.moduleName)
                        }
                        pendingRowActionConfirmation = nil
                    },
                    .init(id: "cancel", title: confirmation.cancelButtonTitle, role: nil) { pendingRowActionConfirmation = nil }
                ])
            }
        }
    }

    /**
     Attaches initial loading and repository/module change observers to the presented Downloads route.

     - Returns: Fully interactive Android-style Downloads screen.
     - Side effects: Loads initial state and refreshes sources or installed rows after notifications.
     - Failure modes: Existing loading and refresh handlers preserve their user-visible error paths.
     */
    private var androidDownloadsScreen: some View {
        downloadActionPresentedDownloadsScreen
        .task {
            await loadInitialStateIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: RepositorySourceManager.sourcesDidChangeNotification)) { _ in
            Task { @MainActor in
                reloadRepositorySources()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: SwordModuleStore.modulesDidChangeNotification)) { _ in
            Task { @MainActor in
                refreshInstalledList()
            }
        }
    }

    /**
     Builds the compact Downloads state probe consumed by targeted UI smoke tests.

     The export intentionally reports semantic row order and status tokens instead of full row text or
     layout geometry. That keeps the test anchored to Android's download-list behavior while avoiding
     brittle pixel or string-wrapping assertions.

     - Parameters:
       - visibleModules: The currently filtered row sequence shown in Downloads.
       - installedModulesByName: Installed modules keyed by initials for live row-status lookup.
     - Returns: A one-pixel hidden state export when detailed UI-test accessibility is enabled.
     - Side effects: none.
     - Failure modes: none.
     */
    @ViewBuilder
    private func moduleBrowserStateExport(
        visibleModules: [RemoteModuleInfo],
        installedModulesByName: [String: ModuleInfo]
    ) -> some View {
        if UITestRuntimeConfiguration.enablesDetailedAccessibilityExports {
            let value = moduleBrowserAccessibilityValue(
                visibleModules: visibleModules,
                installedModulesByName: installedModulesByName
            )
            Text(value)
                .font(.system(size: 1))
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityIdentifier("moduleBrowserStateExport")
                .accessibilityValue(value)
        }
    }

    /**
     Produces a stable, parseable Downloads state summary for UI automation.

     - Parameters:
       - visibleModules: The currently filtered row sequence shown in Downloads.
       - installedModulesByName: Installed modules keyed by initials for live row-status lookup.
     - Returns: A semicolon-delimited state string containing row count, order, and row status tokens.
     - Side effects: none.
     - Failure modes: none.
     */
    private func moduleBrowserAccessibilityValue(
        visibleModules: [RemoteModuleInfo],
        installedModulesByName: [String: ModuleInfo]
    ) -> String {
        let rowLimit = UITestRuntimeConfiguration.detailedAccessibilityRowTokenLimit
        let limitedModules = visibleModules.prefix(rowLimit)
        let order = limitedModules.map(\.name).joined(separator: "|")
        let rowTokens = limitedModules
            .map { module in
                let status = Self.displayStatus(
                    for: module,
                    installedModulesByName: installedModulesByName,
                    downloadActivities: downloadActivities
                )
                return "\(module.name):\(Self.downloadStatusAccessibilityToken(status))"
            }
            .joined(separator: ",")
        return "visible=\(visibleModules.count);refreshing=\(isRefreshing);order=\(order);rows=\(rowTokens)"
    }

    /**
     Builds the Android Downloads top app bar with back navigation and overflow actions.

     - Returns: Dark app bar matching Android's `Download Documents` activity title row.
     - Side effects: Back dismisses the pushed route; the overflow button shows Android's Downloads
       action menu.
     - Failure modes: none.
     */
    @ViewBuilder
    private var androidTopAppBar: some View {
        if let contextualModule {
            AndroidDocumentContextActionBar(
                actions: contextualModuleActions,
                surfacePalette: surfacePalette,
                accessibilityPrefix: "moduleBrowser",
                onClose: clearContextualModuleSelection,
                onAbout: {
                    let installedModule = contextualInstalledModule
                    clearContextualModuleSelection()
                    selectedModuleDetails = ModuleBrowserModuleDetails(
                        module: contextualModule,
                        installedModule: installedModule
                    )
                },
                onDelete: {
                    clearContextualModuleSelection()
                    pendingRowActionConfirmation = ModuleBrowserRowActionConfirmation(
                        kind: .uninstall,
                        module: contextualModule
                    )
                },
                onUnlock: {
                    guard let installedModule = contextualInstalledModule else { return }
                    clearContextualModuleSelection()
                    beginUnlock(installedModule)
                },
                onDeleteIndex: {
                    clearContextualModuleSelection()
                    pendingRowActionConfirmation = ModuleBrowserRowActionConfirmation(
                        kind: .deleteIndex,
                        module: contextualModule
                    )
                }
            )
        } else {
            AndroidActivityTopAppBar(
                title: String(localized: "download", defaultValue: "Download Documents"),
                accessibilityIdentifier: "moduleBrowser",
                backgroundColor: surfacePalette.toolbarBackgroundColor,
                foregroundColor: surfacePalette.toolbarForegroundColor,
                onBack: { dismiss() }
            ) {
                if !downloadErrors.isEmpty {
                    AndroidActivityTopAppBarActionButton(
                        icon: .asset("ActivityErrorOutline"),
                        accessibilityLabel: String(
                            localized: "download_errors",
                            defaultValue: "Download errors"
                        ),
                        accessibilityIdentifier: "moduleBrowserDownloadErrorsButton",
                        foregroundColor: surfacePalette.toolbarForegroundColor
                    ) {
                        showOverflowMenu = false
                        showDownloadErrors = true
                    }
                }
                AndroidActivityTopAppBarActionButton(
                    icon: .asset("ToolbarOverflow"),
                    accessibilityLabel: String(localized: "system_items1", defaultValue: "More"),
                    accessibilityIdentifier: "moduleBrowserOverflowButton",
                    foregroundColor: surfacePalette.toolbarForegroundColor
                ) {
                    showOverflowMenu.toggle()
                }
                .androidPopupMenuAnchor(id: PopupAnchor.overflow)
            }
        }
    }

    /**
     Builds the Downloads overflow popup using Android's menu item set.

     Android promotes Download errors to a toolbar action when errors exist. The overflow itself
     contains Load Documents From Files and Custom repositories in source order, presented through
     the shared app-owned popup rather than SwiftUI's native `Menu`.

     - Returns: A dark, right-aligned overflow popup anchored below the app bar.
     - Side effects: Menu rows can show download errors, start the ZIP importer, or push repository
       management.
     - Failure modes: Install ZIP remains visible but disabled while a selected external document is
       being imported.
     */
    private var androidOverflowMenu: some View {
        AndroidPopupMenuSurface(
            colorScheme: colorScheme,
            accessibilityIdentifier: "moduleBrowserOverflowSurface",
            backgroundColor: surfacePalette.backgroundColor,
            primaryTextColor: surfacePalette.foregroundColor,
            secondaryTextColor: surfacePalette.secondaryForegroundColor,
            accentColor: AndroidDialogSurfacePalette.accent(for: colorScheme)
        ) {
            VStack(spacing: 0) {
                AndroidPopupMenuRow(
                    title: String(
                        localized: "install_zip",
                        defaultValue: "Load Documents From Files"
                    ),
                    accessibilityIdentifier: "moduleBrowserInstallZipButton"
                ) {
                    guard !isImportingExternalDocument else { return }
                    showOverflowMenu = false
                    showInstallZipImporter = true
                }
                .opacity(isImportingExternalDocument ? 0.52 : 1)

                AndroidPopupMenuRow(
                    title: String(
                        localized: "custom_repositories",
                        defaultValue: "Custom repositories"
                    ),
                    accessibilityIdentifier: "moduleBrowserRepositoriesButton"
                ) {
                    showOverflowMenu = false
                    showRepositoryManager = true
                }
            }
        }
    }

    /**
     Builds Android's inline Downloads filters.

     - Parameter visibleModuleCount: Number of rows visible after current filters.
     - Returns: Language, search, document-type, and count controls in Android's compact row.
     - Side effects: Filter menus mutate `selectedLanguage` and `selectedCategory`; search text
       mutates `searchText`.
     - Failure modes: Empty language catalogs show the all-language label and keep the menu usable.
     */
    private func androidFilterBar(visibleModuleCount: Int) -> AndroidDocumentSelectionFilterBar {
        let categoryOptions = [nil] + visibleCategoryFilters.map(Optional.some)
        return AndroidDocumentSelectionFilterBar(
            surfacePalette: surfacePalette,
            languageTitle: languageFilterTitle(for: selectedLanguage),
            languageOptions: availableLanguages.map {
                AndroidDocumentSelectionOption(id: $0, title: displayName(for: $0))
            },
            documentTypeTitle: categoryFilterTitle(for: selectedCategory),
            documentTypeOptions: categoryOptions.enumerated().map { index, category in
                AndroidDocumentSelectionOption(
                    id: String(index),
                    title: categoryFilterTitle(for: category)
                )
            },
            resultCountTitle: documentsCountTitle(visibleModuleCount),
            searchPlaceholder: String(
                localized: "free_text_search_documents",
                defaultValue: "Search"
            ),
            searchText: $searchText,
            accessibilityPrefix: "moduleBrowser",
            onOpenLanguageOptions: {
                clearContextualModuleSelection()
                selectedLanguage = ""
                captureDownloadListSortSnapshot()
            },
            onSelectLanguage: { language in
                clearContextualModuleSelection()
                selectedLanguage = language
                Self.rememberExplicitSelectedLanguage(language)
                captureDownloadListSortSnapshot()
            },
            onSearchFocused: {
                clearContextualModuleSelection()
                selectedLanguage = ""
                selectedCategory = nil
                persistSelectedCategory(nil)
                captureDownloadListSortSnapshot()
            },
            onSelectDocumentType: { optionID in
                guard let index = Int(optionID), categoryOptions.indices.contains(index) else {
                    return
                }
                clearContextualModuleSelection()
                selectedCategory = categoryOptions[index]
                persistSelectedCategory(categoryOptions[index])
                captureDownloadListSortSnapshot()
            }
        )
    }

    /**
     Builds the scrollable Android Downloads row list.

     - Parameters:
       - visibleModules: Rows visible after filter/search processing.
       - installedModulesByName: Installed modules keyed by initials for row status resolution.
     - Returns: Loading, empty, error, or row content matching Android's document list.
     - Side effects: Row buttons can start/cancel installs or open row details.
     - Failure modes: Empty or failed catalogs show retry affordances instead of a blank list.
     */
    @ViewBuilder
    private func androidDownloadsContent(
        visibleModules: [RemoteModuleInfo],
        installedModulesByName: [String: ModuleInfo]
    ) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }

                if isLoadingInitialState || isRefreshing {
                    androidLoadingRow
                } else if visibleModules.isEmpty && !availableModules.isEmpty {
                    androidMessageRow(String(localized: "no_modules_match_filters"))
                } else if !visibleModules.isEmpty {
                    ForEach(visibleModules) { module in
                        remoteModuleRow(
                            module,
                            installedModulesByName: installedModulesByName
                        )
                    }
                } else if availableModules.isEmpty && !isRefreshing && !isLoadingInitialState {
                    VStack(spacing: 10) {
                        Text(String(localized: "tap_refresh_to_load"))
                            .foregroundStyle(surfacePalette.secondaryForegroundColor)
                        Button {
                            refreshCatalog()
                        } label: {
                            Label(String(localized: "refresh_catalog"), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .tint(surfacePalette.foregroundColor)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                }

                if isImportingExternalDocument {
                    androidExternalImportProgressRow
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(surfacePalette.backgroundColor)
    }

    /**
     Loading row used while local state or repositories are refreshing.

     - Returns: Android-dark progress row with current source text when available.
     - Side effects: none.
     - Failure modes: Missing progress text falls back to Loading/Refreshing text.
     */
    private var androidLoadingRow: some View {
        VStack(spacing: 8) {
            ProgressView()
                .tint(surfacePalette.foregroundColor)
            Text(refreshProgress ?? (isLoadingInitialState
                ? String(localized: "loading", defaultValue: "Loading...")
                : String(localized: "refreshing_catalog")))
                .font(.caption)
                .foregroundStyle(surfacePalette.secondaryForegroundColor)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }

    /**
     Renders durable local-module install phase and determinate/indeterminate progress.

     - Returns: Full-width Android-dark progress row.
     - Side effects: none.
     - Failure modes: Missing progress before the detached task starts displays the queued phase.
     */
    private var androidExternalImportProgressRow: some View {
        let progress = externalDocumentImportProgress ?? ModuleInstallProgress(phase: .queued)
        return VStack(spacing: 8) {
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
                    .tint(surfacePalette.foregroundColor)
            } else {
                ProgressView()
                    .tint(surfacePalette.foregroundColor)
            }
            Text(Self.installPhaseText(progress.phase, progressPercent: progress.percent))
                .font(.caption)
                .foregroundStyle(surfacePalette.secondaryForegroundColor)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }

    /**
     Message row for empty Android Downloads states.

     - Parameter message: User-visible empty-state message.
     - Returns: Full-width dark-list message row.
     - Side effects: none.
     - Failure modes: none.
     */
    private func androidMessageRow(_ message: String) -> some View {
        Text(message)
            .font(.body)
            .foregroundStyle(surfacePalette.secondaryForegroundColor)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
    }

    /**
     Document categories shown in Android's type filter.

     - Returns: All seven rows from Android's static `documentTypes` array in source order.
     - Side effects: none.
     - Failure modes: none
     */
    private var visibleCategoryFilters: [ModuleCategory] {
        [
            .bible,
            .commentary,
            .dictionary,
            .generalBook,
            .map,
            .addon,
        ]
    }

    /**
     Resolves the Downloads language filter label.

     - Parameter language: Selected language code, or an empty string for Android's all-languages
       option.
     - Returns: User-visible filter title.
     - Side effects: none.
     - Failure modes: Unknown language codes fall back through `displayName(for:)`.
     */
    private func languageFilterTitle(for language: String) -> String {
        guard !language.isEmpty else {
            return String(localized: "chooce_language_hint", defaultValue: "Language")
        }
        return displayName(for: language)
    }

    /**
     Formats the Android Downloads visible-document count.

     - Parameter count: Number of rows visible after filters.
     - Returns: User-visible count text.
     - Side effects: Reads the application localization bundle through the shared formatter.
     - Failure modes: Missing translations use Android's exact English fallback.
     */
    private func documentsCountTitle(_ count: Int) -> String {
        AndroidDocumentSelectionFilterBar.localizedResultCount(count)
    }

    /**
     Resolves the Downloads document-type filter label.

     - Parameter category: Selected document category, or `nil` for Android's All types option.
     - Returns: User-visible category label.
     - Side effects: none.
     - Failure modes: Unsupported categories fall back to their raw SWORD value.
     */
    private func categoryFilterTitle(for category: ModuleCategory?) -> String {
        guard let category else {
            return String(localized: "doc_type_all", defaultValue: "All types")
        }
        switch category {
        case .bible:
            return String(localized: "doc_type_bible", defaultValue: "Bible")
        case .commentary:
            return String(localized: "doc_type_commentary", defaultValue: "Commentary")
        case .dictionary:
            return String(localized: "doc_type_dictionary", defaultValue: "Dictionary")
        case .generalBook:
            return String(localized: "doc_type_book", defaultValue: "Book")
        case .map:
            return String(localized: "doc_type_map", defaultValue: "Map")
        case .addon:
            return String(localized: "doc_type_addons", defaultValue: "Add-ons")
        default:
            return category.rawValue
        }
    }

    /**
     Reads Android's persisted document type filter index.

     - Returns: Stored index, or `0` when Downloads has never persisted a type filter.
     - Side effects: Reads `UserDefaults`.
     - Failure modes: Nonexistent values fall back to Android's All types index.
     */
    private static func persistedDocumentFilterIndex() -> Int {
        UserDefaults.standard.object(forKey: selectedDocumentFilterIndexKey) as? Int ?? 0
    }

    /**
     Persists the selected document type using Android's spinner index contract.

     - Parameter category: Selected document category, or `nil` for All types.
     - Side effects: Writes `UserDefaults`.
     - Failure modes: Unsupported categories persist as All types.
     */
    private func persistSelectedCategory(_ category: ModuleCategory?) {
        UserDefaults.standard.set(Self.androidFilterIndex(for: category), forKey: Self.selectedDocumentFilterIndexKey)
    }

    /**
     Remembers Android's sticky Downloads language after explicit user selection.

     - Parameter language: Selected language code, or empty when the user clears the filter.
     - Side effects: Updates process memory only for concrete language selections.
     - Failure modes: Empty language values are ignored so Android's default-language logic can run.
     */
    static func rememberExplicitSelectedLanguage(_ language: String) {
        guard !language.isEmpty else { return }
        lastSelectedLanguageCode = language
    }

    /**
     Clears Android's process-local sticky Downloads language for deterministic tests.

     - Returns: none.
     - Side effects: Clears `lastSelectedLanguageCode`.
     - Failure modes: none.
     */
    static func resetExplicitSelectedLanguageForTesting() {
        lastSelectedLanguageCode = nil
    }

    /**
     Returns Android's process-local sticky Downloads language for deterministic tests.

     - Returns: Last explicit language-menu selection, or `nil` when none has been selected.
     - Side effects: none.
     - Failure modes: none.
     */
    static func explicitSelectedLanguageForTesting() -> String? {
        lastSelectedLanguageCode
    }

    /**
     Applies Android's default language rule once catalog rows are available.

     Android chooses a sticky language when present, otherwise the device language if there are Bibles
     in that language, otherwise an installed Bible language, otherwise English. iOS applies the same
     rule after cached or refreshed catalog data is loaded because the language list depends on the
     current document rows.

     - Parameter force: Whether to re-run the rule after a document-type change.
     - Side effects: Mutates `selectedLanguage` when a matching default exists.
     - Failure modes: Empty catalogs leave the language unselected until rows are available.
     */
    private func applyAndroidDefaultLanguageIfNeeded(force: Bool = false) {
        if force {
            didApplyAndroidDefaultLanguage = false
        }
        guard !didApplyAndroidDefaultLanguage,
              selectedLanguage.isEmpty,
              searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        guard let defaultLanguage = Self.defaultLanguageCode(
            availableModules: availableModules,
            installedModules: installedModules,
            availableLanguages: availableLanguages,
            localeLanguageCode: Locale.current.language.languageCode?.identifier,
            stickyLanguageCode: Self.lastSelectedLanguageCode
        ) else {
            return
        }
        selectedLanguage = defaultLanguage
        didApplyAndroidDefaultLanguage = true
    }

    /**
     Resolves Android's default Downloads language from catalog and installed module state.

     - Parameters:
       - availableModules: Remote rows used to test whether the device language has Bible rows.
       - installedModules: Local modules used as Android's installed-language fallback.
       - availableLanguages: Current language menu values for the selected document filter.
       - localeLanguageCode: Device language code, such as `en`.
       - stickyLanguageCode: Previous user-selected Downloads language.
     - Returns: Language code to select, or `nil` when no language rows are available.
     - Side effects: none.
     - Failure modes: Invalid/empty language codes are ignored.
     */
    static func defaultLanguageCode(
        availableModules: [RemoteModuleInfo],
        installedModules: [ModuleInfo],
        availableLanguages: [String],
        localeLanguageCode: String?,
        stickyLanguageCode: String?
    ) -> String? {
        guard !availableLanguages.isEmpty else { return nil }
        if let stickyLanguageCode,
           availableLanguages.contains(stickyLanguageCode) {
            return stickyLanguageCode
        }

        let normalizedLocaleLanguage = localeLanguageCode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let normalizedLocaleLanguage,
           !normalizedLocaleLanguage.isEmpty,
           availableModules.contains(where: {
               $0.category == .bible && $0.language.lowercased() == normalizedLocaleLanguage
           }),
           let matchingLanguage = availableLanguages.first(where: { $0.lowercased() == normalizedLocaleLanguage }) {
            return matchingLanguage
        }

        if let installedBibleLanguage = installedModules.first(where: {
            $0.category == .bible && availableLanguages.contains($0.language)
        })?.language {
            return installedBibleLanguage
        }

        if let english = availableLanguages.first(where: { $0.lowercased() == "en" }) {
            return english
        }
        return availableLanguages.first
    }

    /**
     Handles Android's Install ZIP overflow picker result.

     - Parameter result: File importer result from iOS document picker.
     - Side effects: Imports the selected document through `ExternalDocumentImportService`, refreshes
       installed module state, and surfaces feedback through the Downloads alert/errors menu.
     - Failure modes: Picker cancellation is ignored; importer failures become user-visible feedback.
     */
    private func handleInstallZipSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let request = ExternalDocumentImportRequest(
                url: url,
                contentTypeIdentifier: try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier,
                suggestedFileName: url.lastPathComponent
            )
            preflightExternalDocumentImport(request)
        case .failure(let error):
            if Self.isFileImporterCancellation(error) {
                return
            }
            let message = error.localizedDescription
            externalDocumentImportMessage = message
            recordDownloadError(message)
        }
    }

    /**
     Performs read-only import preflight and prompts when local SWORD destinations conflict.

     - Parameter request: Selected external document and provider metadata.
     - Side effects: Reads archive metadata off the main actor and updates import/prompt/error state.
     - Failure modes: Validation failures surface through the existing install feedback alert and
       Downloads error history; no installer writes run after a failed preflight.
     */
    private func preflightExternalDocumentImport(_ request: ExternalDocumentImportRequest) {
        isImportingExternalDocument = true
        externalDocumentImportProgress = ModuleInstallProgress(phase: .queued)
        let service = ExternalDocumentImportService()
        Task { @MainActor in
            let preflight = await Task.detached(priority: .userInitiated) {
                service.preflightDocument(request)
            }.value
            switch preflight {
            case .ready:
                importExternalDocument(request, overwritePolicy: .reject)
            case .moduleOverwriteRequired(let inspection):
                isImportingExternalDocument = false
                externalDocumentImportProgress = nil
                pendingLocalModuleOverwrite = ModuleBrowserLocalOverwriteConfirmation(
                    request: request,
                    inspection: inspection
                )
            case .failed(let message):
                isImportingExternalDocument = false
                externalDocumentImportProgress = nil
                externalDocumentImportMessage = message
                recordDownloadError(message)
            }
        }
    }

    /**
     Installs one preflighted external document with an explicit SWORD overwrite policy.

     - Parameters:
       - request: Selected document request.
       - overwritePolicy: `.reject` for conflict-free/default imports or `.replaceExisting` after
         explicit user consent.
     - Side effects: Runs installer I/O off the main actor, streams SWORD phase progress onto UI
       state, records failures, and refreshes installed-module metadata.
     - Failure modes: Installer failures are represented by `ExternalDocumentImportResult.failed`.
     */
    private func importExternalDocument(
        _ request: ExternalDocumentImportRequest,
        overwritePolicy: LocalSwordZipOverwritePolicy
    ) {
        isImportingExternalDocument = true
        externalDocumentImportProgress = ModuleInstallProgress(phase: .queued)
        let service = ExternalDocumentImportService()
        Task { @MainActor in
            let importResult = await Task.detached(priority: .userInitiated) {
                service.importDocument(
                    request,
                    moduleOverwritePolicy: overwritePolicy,
                    progressState: { progress in
                        Task { @MainActor in
                            externalDocumentImportProgress = progress
                        }
                    }
                )
            }.value
            isImportingExternalDocument = false
            externalDocumentImportProgress = nil
            externalDocumentImportMessage = importResult.feedbackMessage
            if case .failed(let message) = importResult {
                recordDownloadError(message)
            }
            refreshInstalledList()
        }
    }

    /**
     Builds Android-style overwrite disclosure from exact conflicting local paths.

     - Parameter inspection: Validated local SWORD ZIP inspection.
     - Returns: Prompt text naming modules and every existing destination that will be replaced.
     - Side effects: none.
     - Failure modes: Empty module names fall back to a generic module label; conflict lists are
       non-empty whenever this prompt is presented.
     */
    static func localModuleOverwriteMessage(_ inspection: LocalSwordZipInspection) -> String {
        let modules = inspection.moduleNames.isEmpty
            ? String(localized: "install_zip_module", defaultValue: "Bible module")
            : inspection.moduleNames.joined(separator: ", ")
        return "\(modules)\n\n" + inspection.conflictingPaths.joined(separator: "\n")
    }

    /**
     Returns whether a file-importer error represents a user-cancelled picker.

     iOS reports picker cancellation through the `.failure` branch even though Android simply
     returns to the previous screen when Install ZIP is cancelled. Treating cancellation as a no-op
     keeps iOS plumbing aligned with Android's user-visible behavior.

     - Parameter error: Error delivered by SwiftUI's `fileImporter`.
     - Returns: `true` when the error is the standard Cocoa user-cancelled code.
     - Side effects: none.
     - Failure modes: none.
     */
    static func isFileImporterCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == CocoaError.userCancelled.rawValue
    }

    /**
     Adds one message to Android's Download errors overflow list.

     - Parameter message: Error text from a repository, metadata, or install failure.
     - Side effects: Mutates `downloadErrors` without duplicating identical messages.
     - Failure modes: Empty messages are ignored.
     */
    private func recordDownloadError(_ message: String) {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty,
              !downloadErrors.contains(trimmedMessage) else {
            return
        }
        downloadErrors.append(trimmedMessage)
    }

    /**
     Merges Android's catalog refresh errors into the Download errors overflow list.

     - Parameter errors: Repository or metadata errors produced by the refresh.
     - Side effects: Mutates `downloadErrors` without dropping install/import errors from earlier
       user actions.
     - Failure modes: Empty errors leave prior non-refresh errors intact.
    */
    private func replaceDownloadErrors(with errors: [String]) {
        downloadErrors = Self.mergedDownloadErrors(existing: downloadErrors, refreshErrors: errors)
    }

    /**
     Merges refresh failures with existing Download errors while preserving first-seen order.

     Android tracks repository/metadata failures separately from row install failures. Refreshing
     metadata must therefore not erase install/import errors that are still visible through the
     Downloads overflow menu.

     - Parameters:
       - existing: Current Download errors list.
       - refreshErrors: Repository or metadata errors produced by the refresh.
     - Returns: Trimmed, non-empty, de-duplicated errors in first-seen order.
     - Side effects: none.
     - Failure modes: none.
     */
    static func mergedDownloadErrors(existing: [String], refreshErrors: [String]) -> [String] {
        var merged: [String] = []
        for message in existing + refreshErrors {
            let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedMessage.isEmpty,
                  !merged.contains(trimmedMessage) else {
                continue
            }
            merged.append(trimmedMessage)
        }
        return merged
    }

    /**
     Resolves the inline failure shown after a repository refresh.

     Android keeps partial repository failures behind the Download Errors menu while continuing to
     show the usable catalog. Inline failure copy is reserved for a refresh that produced no module
     rows at all, which prevents successful Easy Install packages from appearing to have failed.

     - Parameters:
       - availableModuleCount: Number of usable catalog rows after refreshed and cached rows merge.
       - errors: Repository and metadata failures collected during the refresh.
     - Returns: Aggregate failure copy only when no usable module row exists; otherwise `nil`.
     - Side effects: none.
     - Failure modes: Empty errors return `nil` even when the catalog is empty.
     */
    static func catalogRefreshInlineError(
        availableModuleCount: Int,
        errors: [String]
    ) -> String? {
        guard availableModuleCount == 0, !errors.isEmpty else { return nil }
        return "Failed to load catalogs:\n" + errors.joined(separator: "\n")
    }

    /**
     Formats a localized module download failure for Android's Download errors surface.

     - Parameters:
       - moduleName: Module initials associated with the failure.
       - message: Platform error detail reported by the repository or installer.
     - Returns: Download failure text with a localized prefix and stable module context.
     - Side effects: none.
     - Failure modes: Empty module names or messages are preserved so the caller can still surface the
       underlying failure.
     */
    static func downloadFailureMessage(moduleName: String, message: String) -> String {
        ModuleInstallErrorPresentation.failureMessage(detail: "\(moduleName): \(message)")
    }

    /**
     Formats a localized module download failure for inline alert presentation.

     - Parameter message: Platform error detail reported by the repository or installer.
     - Returns: Download failure text with a localized prefix.
     - Side effects: none.
     - Failure modes: Empty messages are preserved so the caller can still surface a failure state.
     */
    static func downloadFailureMessage(_ message: String) -> String {
        ModuleInstallErrorPresentation.failureMessage(detail: message)
    }

    /**
     Resolves the localized empty-repository error used by refresh and Download errors.

     - Returns: User-visible message for an empty repository source list.
     - Side effects: none.
     - Failure modes: none
     */
    static func noRepositorySourcesConfiguredMessage() -> String {
        String(localized: "no_sources_configured", defaultValue: "No repository sources configured.")
    }

    /**
     Formats the localized fallback for an unavailable remote module.

     - Parameter moduleName: Module initials shown in the unavailable message.
     - Returns: User-visible unavailable-module message.
     - Side effects: none.
     - Failure modes: Empty module names are preserved so the caller can still show the failure.
     */
    static func moduleUnavailableForInstallationMessage(moduleName: String) -> String {
        String(localized: "module_unavailable_for_installation \(moduleName)")
    }

    /**
     Formats the localized fallback for a missing repository source.

     - Parameter moduleName: Module initials whose source could not be resolved.
     - Returns: User-visible missing-source message.
     - Side effects: none.
     - Failure modes: Empty module names are preserved so the caller can still show the failure.
     */
    static func moduleSourceNotFoundMessage(moduleName: String) -> String {
        String(localized: "module_source_not_found \(moduleName)")
    }

    /**
     Formats the localized uninstall failure text.

     - Parameter message: Platform error detail reported by the repository.
     - Returns: User-visible uninstall failure message.
     - Side effects: none.
     - Failure modes: Empty messages are preserved so the caller can still show the failure.
     */
    static func uninstallFailureMessage(_ message: String) -> String {
        String(localized: "uninstall_failed \(message)")
    }

    // MARK: - Row Views

    /**
     Clears type and language filters once search becomes active, matching Android Downloads.

     Android `DocumentSelectionBase` removes document-type and language filters when the user
     enters document search mode so the query can find any module initials. SwiftUI does not expose
     the same search-field focus event consistently across the supported app surface, so iOS applies
     the same state transition when the query first becomes non-empty.

     - Parameter query: Current free-text search value.

     Side effects:
     - mutates `selectedCategory` to All types for non-empty searches
     - clears `selectedLanguage` for non-empty searches

     Failure modes:
     - none; empty and whitespace-only values leave existing filters intact
     */
    private func alignFiltersWithAndroidSearchState(_ query: String) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        selectedCategory = nil
        selectedLanguage = ""
        persistSelectedCategory(nil)
    }

    /**
     Resolves the initial Downloads document-type filter from Android's startup rules.

     Android starts a fresh Downloads browser on filter index 0, `All types`; search and Easy Start
     entry points also use an all-type query so a module initials lookup can match any document
     family.

     - Parameters:
       - initialSearchText: Optional query supplied by the caller.
       - defaultDownloadMode: Startup default-download mode supplied by the caller.
       - storedFilterIndex: Persisted Android document filter index.
     - Returns: Selected category, or `nil` for Android's `All types` filter.
     - Side effects: none.
     - Failure modes: none.
     */
    static func initialSelectedCategory(
        initialSearchText: String,
        defaultDownloadMode: ModuleBrowserDefaultDownloadMode,
        storedFilterIndex: Int = 0
    ) -> ModuleCategory? {
        guard initialSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !defaultDownloadMode.shouldInstallDefaultDocuments else {
            return nil
        }
        return category(forAndroidFilterIndex: storedFilterIndex)
    }

    /**
     Maps Android's document type spinner index to the iOS module category.

     - Parameter index: Android `selected_document_filter_no` value.
     - Returns: Matching category, or `nil` for All/unknown values.
     - Side effects: none.
     - Failure modes: Unknown persisted indexes reset to All types.
     */
    static func category(forAndroidFilterIndex index: Int) -> ModuleCategory? {
        switch index {
        case 1:
            return .bible
        case 2:
            return .commentary
        case 3:
            return .dictionary
        case 4:
            return .generalBook
        case 5:
            return .map
        case 6:
            return .addon
        default:
            return nil
        }
    }

    /**
     Maps one iOS module category back to Android's document type spinner index.

     - Parameter category: Selected category, or `nil` for All types.
     - Returns: Android `selected_document_filter_no` value.
     - Side effects: none.
     - Failure modes: Unsupported categories map to All types.
     */
    static func androidFilterIndex(for category: ModuleCategory?) -> Int {
        switch category {
        case .bible:
            return 1
        case .commentary:
            return 2
        case .dictionary:
            return 3
        case .generalBook:
            return 4
        case .map:
            return 5
        case .addon:
            return 6
        case nil:
            return 0
        default:
            return 0
        }
    }

    /**
     Builds one row for a remotely available module with install-state affordances.

     - Parameters:
       - module: Remote module metadata to render.
       - installedModulesByName: Installed modules keyed by initials for O(1) row state lookup.
     - Returns: A row showing remote source metadata and an install affordance when applicable.
     */
    private func remoteModuleRow(
        _ module: RemoteModuleInfo,
        installedModulesByName: [String: ModuleInfo]
    ) -> some View {
        let status = Self.displayStatus(
            for: module,
            installedModulesByName: installedModulesByName,
            downloadActivities: downloadActivities
        )
        let installedModule = installedModulesByName[module.name]
        let rowActions = Self.rowActions(
            installedModule: installedModule,
            isBeingInstalled: status.isBeingInstalled,
            installedModules: installedModules
        )
        let isRecommended = recommendedDocuments?.contains(module) == true
        let badAction = badDocuments?.badDocumentAction(for: module) ?? .none
        let isContextuallySelected = contextualModuleIdentity == module.installIdentity
        let statusPresentation = ModuleBrowserStatusSlotPresentation(status: status)

        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                AndroidDocumentListLeadingColumn(
                    category: module.category,
                    languageTitle: displayName(for: module.language),
                    installSizeTitle: Self.installSizeText(for: module.installSizeBytes),
                    statusIconAssetName: statusPresentation.statusIconAssetName,
                    statusIconColor: statusPresentation.statusIconColor,
                    isRecommended: isRecommended,
                    isWarned: badAction == .warn,
                    encryptionState: Self.encryptionState(for: installedModule),
                    surfacePalette: surfacePalette
                )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(module.name)
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(surfacePalette.foregroundColor)
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        Text(module.sourceName)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(surfacePalette.secondaryForegroundColor)
                            .lineLimit(1)
                            .multilineTextAlignment(.trailing)
                    }

                    Text(module.description)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(surfacePalette.secondaryForegroundColor)
                        .lineLimit(module.isInstallable ? 2 : 3)
                    if isRecommended {
                        Text(String(localized: "recommended_document", defaultValue: "Recommended!"))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(surfacePalette.secondaryForegroundColor)
                    }

                    rowTrailingControls(
                        for: module,
                        installedModule: installedModule,
                        status: status,
                        rowActions: rowActions
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 2)

            Rectangle()
                .fill(surfacePalette.inactiveBorderColor)
                .frame(height: 1)
                .padding(.leading, 96)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            handleRemoteModuleRowTap(module, status: status)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(module.name)
        .accessibilityValue(Self.downloadStatusAccessibilityToken(status))
        .accessibilityAddTraits(Self.primaryRowTapStartsDownload(status) ? .isButton : [])
        .accessibilityIdentifier("moduleBrowserRow::\(module.installIdentity.rawValue)")
        .androidDocumentContextSelection(
            isSelected: isContextuallySelected,
            onLongPress: { beginContextualModuleSelection(module) }
        )
    }

    /**
     Computes Android's management actions for one Downloads row.

     - Parameters:
       - installedModule: Matching installed module, or `nil` for a remote-only row.
       - isBeingInstalled: Whether the remote row currently has an active install task.
       - installedModules: Complete Android-compatible installed inventory used to protect the last
         Bible from removal.
     - Returns: Ordered row actions, including Unlock for every installed encrypted module.
     - Side effects: None.
     - Failure modes: None; missing installed metadata produces only remote-row actions.
     */
    static func rowActions(
        installedModule: ModuleInfo?,
        isBeingInstalled: Bool,
        installedModules: [ModuleInfo]
    ) -> [ModuleDownloadRowAction] {
        ModuleDownloadRowActionPlanner.availableActions(
            installedModule: installedModule,
            isBeingInstalled: isBeingInstalled,
            installedModules: installedModules
        )
    }

    /**
     Presents the shared Android passphrase flow for an encrypted Downloads row.

     - Parameter module: Installed encrypted module selected from the row context menu.
     - Side effects: Clears stale input/error state and presents the module-scoped alert.
     - Failure modes: None; manager validation happens only after the user submits a key.
     */
    private func beginUnlock(_ module: ModuleInfo) {
        unlockCipherKey = ""
        unlockFailureMessage = nil
        pendingUnlockModule = module
    }

    /**
     Submits a Downloads passphrase through the same manager-backed contract as the reader picker.

     - Parameter module: Installed encrypted module associated with the visible prompt.
     - Side effects: Validates and persists the key through `SwordManager`, refreshes installed rows on
       success, or dismisses and re-presents the prompt with invalid-key feedback on rejection.
     - Failure modes: Missing managers, empty/rejected keys, and persistence failures remain retryable
       and do not update the installed snapshot.
     */
    private func attemptUnlock(_ module: ModuleInfo) {
        let cipherKey = unlockCipherKey
        if ModuleUnlockActionCoordinator.submit(
            module: module,
            cipherKey: cipherKey,
            unlockModule: { moduleName, submittedKey in
                swordManager?.unlockModule(
                    named: moduleName,
                    withCipherKey: submittedKey
                ) ?? false
            },
            onAccepted: {
                clearUnlockPrompt()
                refreshInstalledList()
            }
        ) {
            return
        }

        pendingUnlockModule = nil
        unlockCipherKey = ""
        let failureMessage = ModuleUnlockActionCoordinator.failureMessage
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ModuleUnlockActionCoordinator.retryPresentationDelay
        ) {
            unlockFailureMessage = failureMessage
            pendingUnlockModule = module
        }
    }

    /**
     Opens installed module metadata from Android's unlock-information action.

     - Parameter module: Locked module whose provider instructions should be shown.
     - Side effects: Dismisses the passphrase alert and presents the shared About dialog.
     - Failure modes: The action is exposed only when `UnlockInfo` is non-empty.
     */
    private func showUnlockInformation(for module: ModuleInfo) {
        clearUnlockPrompt()
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ModuleUnlockActionCoordinator.retryPresentationDelay
        ) {
            selectedModuleDetails = ModuleBrowserModuleDetails(installedModule: module)
        }
    }

    /**
     Clears transient Downloads passphrase state.

     - Side effects: Dismisses the alert and discards the entered key and retry message.
     - Failure modes: None.
     */
    private func clearUnlockPrompt() {
        pendingUnlockModule = nil
        unlockCipherKey = ""
        unlockFailureMessage = nil
    }

    /**
     Builds the trailing controls for a Downloads row from Android-compatible row actions.

     - Parameters:
       - module: Remote catalog row being rendered.
       - installedModule: Matching installed row, when present.
       - status: Current Android-equivalent install status.
       - rowActions: Precomputed secondary actions from `ModuleDownloadRowActionPlanner`.
     - Returns: SwiftUI controls for About plus the primary install/update/progress affordance.
     - Side effects: Produced controls may mutate view state when tapped, including opening the shared
       Android-style module details dialog.
     - Failure modes: Action failures are handled by `installModule(_:)`, `cancelInstall(_:)`, or
       the confirmation alert handlers.
     */
    @ViewBuilder
    private func rowTrailingControls(
        for module: RemoteModuleInfo,
        installedModule: ModuleInfo?,
        status: ModuleBrowserDownloadStatus,
        rowActions: [ModuleDownloadRowAction]
    ) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            rowPrimaryControl(for: module, status: status)

            Spacer(minLength: 8)

            if rowActions.contains(.about) {
                Button {
                    clearContextualModuleSelection()
                    selectedModuleDetails = ModuleBrowserModuleDetails(
                        module: module,
                        installedModule: installedModule
                    )
                } label: {
                    AndBibleIconView(name: "DocumentInfo", size: 24)
                        .foregroundStyle(AndroidResourcePalette.grey600)
                        .frame(width: 44, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "about"))
                .accessibilityIdentifier(
                    "moduleBrowserAboutButton::\(module.installIdentity.rawValue)"
                )
            }
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .trailing)
    }

    /**
     Builds the primary install/status control for one Downloads row.

     - Parameters:
       - module: Remote catalog row being rendered.
       - status: Current Android-equivalent install status.
     - Returns: Android's horizontal install progress/cancel row, unavailable text, or an empty slot.
     - Side effects: The active-install cancel button can cancel its repository-scoped task. Retry and
       update remain row-tap actions exactly as in Android's `DocumentDownloadItemAdapter`.
     - Failure modes: Install failures are caught and retained as row error state by
       `installModule(_:)`.
     */
    @ViewBuilder
    private func rowPrimaryControl(
        for module: RemoteModuleInfo,
        status: ModuleBrowserDownloadStatus
    ) -> some View {
        switch status {
        case .beingInstalled(let progress):
            HStack(spacing: 8) {
                let progressPercent = progress.percent
                if let progressPercent {
                    ProgressView(value: Double(progressPercent), total: 100)
                        .frame(maxWidth: .infinity)
                        .tint(surfacePalette.foregroundColor)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(maxWidth: .infinity)
                        .tint(surfacePalette.foregroundColor)
                }

                let isCancellable = progress.isCancellable
                Button {
                    cancelInstall(module.installIdentity)
                } label: {
                    AndBibleIconView(name: "DocumentCancel", size: 24)
                        .frame(width: 44, height: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AndroidResourcePalette.documentErrorRed)
                .disabled(!isCancellable)
                .opacity(isCancellable ? 1 : 0)
                .accessibilityHidden(!isCancellable)
                .accessibilityLabel(String(localized: "cancel"))
            }
        case .unavailable:
            Text(String(localized: "unavailable"))
                .font(.caption)
                .foregroundStyle(surfacePalette.disabledForegroundColor)
        case .installed, .errorDownloading, .updateAvailable, .installable:
            Color.clear
                .frame(height: 1)
                .accessibilityHidden(true)
        }
    }

    /**
     Builds compact phase-aware text for Android-equivalent install progress.

     - Parameters:
       - phase: Current durable installer phase.
       - progressPercent: Optional phase-local percent; absent for indeterminate transfers.
     - Returns: A concise phase label with percent when the phase is determinate.
     - Side effects: Reads localized strings from the application bundle.
     - Failure modes: Missing translations use the supplied English fallback values.
     */
    static func installPhaseText(_ phase: ModuleInstallPhase, progressPercent: Int?) -> String {
        let phaseText: String
        switch phase {
        case .queued:
            phaseText = String(localized: "module_install_phase_queued", defaultValue: "Please wait…")
        case .downloading:
            phaseText = String(localized: "module_install_phase_downloading", defaultValue: "Download")
        case .extracting:
            phaseText = String(localized: "extracting_zip_file", defaultValue: "Extracting Zip file now…")
        case .committing:
            phaseText = String(
                localized: "module_install_phase_committing",
                defaultValue: "Please wait. Loading modules from a file."
            )
        case .complete:
            phaseText = String(
                localized: "install_zip_successfull",
                defaultValue: "Module was installed successfully"
            )
        }
        guard let progressPercent else { return phaseText }
        return "\(phaseText) \(progressPercent)%"
    }

    /**
     Runs Android's primary row action for a visible Downloads document.

     Android rows dispatch to `DownloadControl.manageDownload`: installable, update, and failed rows
     show a confirmation before starting or retrying downloads; active rows are ignored because the
     explicit undo/cancel control owns cancellation. Installed and unavailable rows do not install
     again. iOS keeps the same behavior for row taps while preserving the explicit trailing icons.

     - Parameters:
       - module: Remote catalog row represented by the tapped row.
       - status: Current Android-equivalent install status.
     - Side effects: May show Android's download confirmation dialog.
     - Failure modes: `installModule(_:)` owns confirmed install failure behavior.
     */
    private func performPrimaryRowAction(
        for module: RemoteModuleInfo,
        status: ModuleBrowserDownloadStatus
    ) {
        switch status {
        case .installable, .updateAvailable, .errorDownloading:
            requestDownloadConfirmation(for: module, status: status)
        case .beingInstalled, .installed, .unavailable:
            break
        }
    }

    /**
     Dispatches a Downloads row tap through Android's contextual-selection and download contracts.

     Android enters contextual action mode after a long press. While that mode is active, a row tap
     changes or clears the selected document instead of starting a download. Outside contextual mode,
     the normal `DownloadControl.manageDownload` behavior remains authoritative.

     - Parameters:
       - module: Remote catalog row represented by the tap.
       - status: Current Android-equivalent install status for the row.
     - Side effects: Changes contextual selection or stages a download confirmation.
     - Failure modes: Confirmed install failures remain owned by `installModule(_:)`.
     */
    private func handleRemoteModuleRowTap(
        _ module: RemoteModuleInfo,
        status: ModuleBrowserDownloadStatus
    ) {
        guard contextualModuleIdentity == nil else {
            contextualModuleIdentity = contextualModuleIdentity == module.installIdentity
                ? nil
                : module.installIdentity
            return
        }
        performPrimaryRowAction(for: module, status: status)
    }

    /**
     Enters Android's app-owned contextual document action mode for one Downloads row.

     - Parameter module: Remote catalog row selected by a long press or accessibility action.
     - Side effects: Closes the ordinary overflow popup and replaces the Downloads app bar with the
       shared contextual action bar.
     - Failure modes: none.
     */
    private func beginContextualModuleSelection(_ module: RemoteModuleInfo) {
        showOverflowMenu = false
        contextualModuleIdentity = module.installIdentity
    }

    /**
     Leaves Android's contextual document action mode and closes its overflow popup.

     - Side effects: Clears the selected row and any contextual popup presentation.
     - Failure modes: none.
     */
    private func clearContextualModuleSelection() {
        contextualModuleIdentity = nil
        showOverflowMenu = false
    }

    /**
     Converts installed SWORD encryption metadata into the shared Android lock-icon state.

     - Parameter module: Installed module paired with the remote row, when available.
     - Returns: No lock for unencrypted or remote-only rows, a red closed lock for a locked module,
       or a green open lock for an unlocked encrypted module.
     - Side effects: none.
     - Failure modes: Missing installed metadata is represented as `.none`.
     */
    private static func encryptionState(
        for module: ModuleInfo?
    ) -> AndroidDocumentEncryptionState {
        guard let module, module.isEncrypted else { return .none }
        return module.isUnlocked ? .unlocked : .locked
    }

    /**
     Stages Android's per-document download confirmation for one row.

     Android opens either a simple `download_document_confirm_prefix` confirmation or, for installed
     documents with generic bookmarks, `documentUpgradeConfirmation` before `doDownload(...)` runs.
     Keeping this as a separate staging step preserves the confirmation/cancel contract for row taps,
     retry, and update affordances without changing startup/default-document installs.

     - Parameters:
       - module: Remote catalog row the user requested.
       - status: Current Android-equivalent install status for the row entry point.
     - Side effects: Presents the confirmation alert.
     - Failure modes: bookmark-count fetch failures fall back to the simple confirmation; confirmed
       installs are handled by `installModule(_:)`.
     */
    private func requestDownloadConfirmation(
        for module: RemoteModuleInfo,
        status: ModuleBrowserDownloadStatus
    ) {
        let kind: ModuleBrowserDownloadConfirmation.Kind
        if Self.shouldShowGenericBookmarkUpdateWarning(
            status: status,
            isInstalled: Self.isModuleInstalledFromSelectedRepository(
                module,
                installedModules: installedModules
            ),
            hasGenericBookmarks: hasGenericBookmarks(for: module)
        ) {
            kind = .genericBookmarkUpdateWarning
        } else {
            kind = .download
        }
        pendingDownloadConfirmation = ModuleBrowserDownloadConfirmation(module: module, kind: kind)
    }

    // MARK: - Helpers

    /**
     Resolves a language code into a localized display name when possible.

     - Parameter languageCode: ISO-style language code, optionally including script or region
       suffixes such as `en-GB` or `abq-Cyrl`.
     - Returns: A localized language name with suffix preservation when lookup succeeds, or the
       uppercased original code when no localization is available.
     */
    private func displayName(for languageCode: String) -> String {
        // Strip script/region suffixes for lookup (e.g., "abq-Cyrl" → "abq")
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
     De-duplicates remote modules by Android repository-scoped identity while preserving priority.

     Same-initials rows from different repositories remain independently visible and actionable.
     Duplicate cache/refresh rows from the same repository collapse to the first source-priority row.
     */
    static func deduplicatedModules(from modules: [RemoteModuleInfo]) -> [RemoteModuleInfo] {
        var seen: Set<RemoteModuleIdentity> = []
        var unique: [RemoteModuleInfo] = []
        for module in modules where seen.insert(module.installIdentity).inserted {
            unique.append(module)
        }
        return unique
    }

    /**
     Adds cached catalog rows for sources that failed during the current refresh.

     - Parameters:
       - refreshedModules: Rows successfully refreshed from currently reachable sources.
       - cachedModules: Rows restored from the on-disk catalog cache.
       - failedSourceNames: Source names whose current catalog refresh failed.
     - Returns: Refreshed rows followed by cached rows for failed sources that are not already
       represented by the same source/module id.

     Side effects:
     - none

     Failure modes:
     - empty cache or empty failure set returns the refreshed rows unchanged
     */
    static func modulesByAddingCachedCatalogsForFailedSources(
        refreshedModules: [RemoteModuleInfo],
        cachedModules: [RemoteModuleInfo],
        failedSourceNames: Set<String>
    ) -> [RemoteModuleInfo] {
        guard !failedSourceNames.isEmpty else { return refreshedModules }

        var seenModuleIds = Set(refreshedModules.map(\.id))
        var mergedModules = refreshedModules
        for module in cachedModules
            where failedSourceNames.contains(module.sourceName) &&
                seenModuleIds.insert(module.id).inserted {
            mergedModules.append(module)
        }
        return mergedModules
    }

    /**
     Tests whether startup default selection has any installable catalog data to consume.

     - Parameter modules: Full remote catalog rows available to startup default selection.
     - Returns: `true` when at least one row can be installed.

     Side effects:
     - none

     Failure modes:
     - empty or pseudo/unavailable-only catalogs return `false` so the startup flow remains
       retryable after a later refresh
     */
    static func startupDefaultCatalogHasInstallableRows(_ modules: [RemoteModuleInfo]) -> Bool {
        modules.contains(where: \.isInstallable)
    }

    /**
     Captures Android Downloads ordering inputs for a list/filter rebuild.

     Android's adapter receives row-state updates after a download starts, but the list order is
     only recomputed when the document filter list is rebuilt. Tests use this helper to preserve
     that distinction without constructing SwiftUI view state.

     - Parameters:
       - installedModules: Installed module state at the rebuild boundary.
       - downloadActivities: Active or failed row activities at the rebuild boundary.
     - Returns: Immutable sort inputs for `filteredDownloadModules`.

     Side effects:
     - none

     Failure modes:
     - none
     */
    static func downloadListSortSnapshot(
        installedModules: [ModuleInfo],
        downloadActivities: [RemoteModuleIdentity: ModuleBrowserDownloadActivity]
    ) -> ModuleBrowserDownloadSortSnapshot {
        ModuleBrowserDownloadSortSnapshot(
            installedModules: installedModules,
            downloadActivities: downloadActivities
        )
    }

    /**
     Filters and sorts remote modules using Android `DocumentSelectionBase.filterDocuments`
     semantics adapted to iOS data models.

     - Parameters:
       - modules: Complete remote/pseudo module catalog.
       - selectedCategory: Selected document type, or `nil` for all types.
       - selectedLanguage: Selected language code, or empty for all languages.
       - searchText: Free-text query applied to initials, description, language, and source.
       - installedModules: Current installed modules used for status and update sorting.
       - downloadActivities: Repository-scoped rows with active progress or retained failure state.
       - recommendedDocuments: Android recommended metadata used for language-specific ordering.
       - badDocuments: Android bad-document metadata used to hide or warn rows.
     - Returns: Visible modules ordered by Android status, installed/recommended/category, and
       initials.

     Side effects:
     - none

     Failure modes:
     - malformed metadata is ignored by `ModuleDownloadConfiguration`
     */
    static func filteredDownloadModules(
        _ modules: [RemoteModuleInfo],
        selectedCategory: ModuleCategory?,
        selectedLanguage: String,
        searchText: String,
        installedModules: [ModuleInfo],
        downloadActivities: [RemoteModuleIdentity: ModuleBrowserDownloadActivity],
        recommendedDocuments: ModuleDownloadConfiguration?,
        badDocuments: ModuleDownloadConfiguration?
    ) -> [RemoteModuleInfo] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = modules.filter { module in
            if !matchesDownloadCategory(module.category, selectedCategory: selectedCategory) {
                return false
            }
            if !matchesDownloadLanguage(module, selectedLanguage: selectedLanguage) {
                return false
            }
            if badDocuments?.badDocumentAction(for: module) == .hide {
                return false
            }
            guard !query.isEmpty else { return true }
            return module.name.localizedCaseInsensitiveContains(query) ||
                module.description.localizedCaseInsensitiveContains(query) ||
                module.language.localizedCaseInsensitiveContains(query) ||
                module.sourceName.localizedCaseInsensitiveContains(query)
        }
        return sortedDownloadModules(
            filtered,
            installedModules: installedModules,
            downloadActivities: downloadActivities,
            selectedLanguage: selectedLanguage,
            recommendedDocuments: recommendedDocuments
        )
    }

    /**
     Tests Android Downloads document-type visibility for a remote or installed module category.

     Android's "All types" filter intentionally excludes `BookCategory.AND_BIBLE`, exposing
     add-ons only through the Add-ons filter. iOS follows the same rule using the explicit
     `.addon` category instead of folding add-on rows into Bibles, books, or unknown rows.

     - Parameters:
       - category: Module category from SWORD/Android metadata.
       - selectedCategory: Selected Downloads type, or `nil` for Android's All filter.
     - Returns: `true` when the row belongs in the selected type filter.
     - Side effects: none.
     - Failure modes: none; unsupported future categories appear only in All.
     */
    private static func matchesDownloadCategory(
        _ category: ModuleCategory,
        selectedCategory: ModuleCategory?
    ) -> Bool {
        guard let selectedCategory else {
            return category != .addon
        }
        return category == selectedCategory
    }

    /**
     Tests Android Downloads language visibility for one remote module row.

     Android does not exclude `BookCategory.AND_BIBLE` rows when a concrete language is selected,
     because add-ons provide app assets rather than user-readable document text. iOS preserves that
     behavior so add-on rows stay visible under the Add-ons filter even if their catalog language is
     only a metadata placeholder.

     - Parameters:
       - module: Remote module row being filtered.
       - selectedLanguage: Selected language code, or empty for all languages.
     - Returns: `true` when the row belongs in the selected language filter.
     - Side effects: none.
     - Failure modes: none.
     */
    private static func matchesDownloadLanguage(
        _ module: RemoteModuleInfo,
        selectedLanguage: String
    ) -> Bool {
        selectedLanguage.isEmpty || module.language == selectedLanguage || module.category == .addon
    }

    /**
     Sorts remote download rows according to Android's document list priorities.

     - Parameters:
       - modules: Already-filtered remote rows.
       - installedModules: Installed modules used to detect installed/update state.
       - downloadActivities: Repository-scoped rows with active progress or retained failure state.
       - selectedLanguage: Current language filter; Android only prioritizes recommended rows when
         a concrete language is active.
       - recommendedDocuments: Android recommended metadata.
     - Returns: Modules sorted by install state, installed state, recommendation, category, and
       localized initials.

     Side effects:
     - none

     Failure modes:
     - none
     */
    static func sortedDownloadModules(
        _ modules: [RemoteModuleInfo],
        installedModules: [ModuleInfo],
        downloadActivities: [RemoteModuleIdentity: ModuleBrowserDownloadActivity],
        selectedLanguage: String,
        recommendedDocuments: ModuleDownloadConfiguration?
    ) -> [RemoteModuleInfo] {
        let installedModulesByName = installedModuleLookup(from: installedModules)

        return modules.sorted { lhs, rhs in
            let lhsStatus = displayStatus(
                for: lhs,
                installedModulesByName: installedModulesByName,
                downloadActivities: downloadActivities
            )
            let rhsStatus = displayStatus(
                for: rhs,
                installedModulesByName: installedModulesByName,
                downloadActivities: downloadActivities
            )
            let lhsStatusRank = statusSortRank(lhsStatus)
            let rhsStatusRank = statusSortRank(rhsStatus)
            if lhsStatusRank != rhsStatusRank {
                return lhsStatusRank < rhsStatusRank
            }

            let lhsInstalled = isInstalledStatus(lhsStatus)
            let rhsInstalled = isInstalledStatus(rhsStatus)
            if lhsInstalled != rhsInstalled {
                return lhsInstalled && !rhsInstalled
            }

            if !selectedLanguage.isEmpty {
                let lhsRecommended = recommendedDocuments?.contains(lhs) == true
                let rhsRecommended = recommendedDocuments?.contains(rhs) == true
                if lhsRecommended != rhsRecommended {
                    return lhsRecommended && !rhsRecommended
                }
            }

            let lhsCategoryRank = categorySortRank(lhs.category)
            let rhsCategoryRank = categorySortRank(rhs.category)
            if lhsCategoryRank != rhsCategoryRank {
                return lhsCategoryRank < rhsCategoryRank
            }

            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /**
     Resolves the Android-style download status for one remote row.

     - Parameters:
       - module: Remote module row.
       - installedModules: Installed module snapshot.
       - downloadActivities: Repository-scoped rows with active progress or retained failure state.
     - Returns: Status used for row affordances and sort order.

     Side effects:
     - none

     Failure modes:
     - invalid or absent same-repository version strings are treated as update-available, matching
       Android's `DownloadControl` exception path
     */
    static func displayStatus(
        for module: RemoteModuleInfo,
        installedModules: [ModuleInfo],
        downloadActivities: [RemoteModuleIdentity: ModuleBrowserDownloadActivity]
    ) -> ModuleBrowserDownloadStatus {
        displayStatus(
            for: module,
            installedModulesByName: installedModuleLookup(from: installedModules),
            downloadActivities: downloadActivities
        )
    }

    /**
     Resolves the Android-style download status using a precomputed installed-module lookup.

     - Parameters:
       - module: Remote module row.
       - installedModulesByName: Installed modules keyed by initials.
       - downloadActivities: Repository-scoped rows with active progress or retained failure state.
     - Returns: Status used for row affordances and sort order.

     Side effects:
     - none

     Failure modes:
     - invalid or absent same-repository version strings are treated as update-available, matching
       Android's `DownloadControl` exception path
     */
    private static func displayStatus(
        for module: RemoteModuleInfo,
        installedModulesByName: [String: ModuleInfo],
        downloadActivities: [RemoteModuleIdentity: ModuleBrowserDownloadActivity]
    ) -> ModuleBrowserDownloadStatus {
        if let activity = downloadActivities[module.installIdentity] {
            switch activity.phase {
            case .inProgress:
                return .beingInstalled(
                    progress: activity.installProgress ?? ModuleInstallProgress(phase: .queued)
                )
            case .failed:
                return .errorDownloading(message: activity.message ?? "")
            }
        }
        guard module.isInstallable else {
            return .unavailable
        }
        guard let installedModule = installedModulesByName[module.name] else {
            return .installable
        }
        let installedRepository = installedModule.aboutMetadata.repository
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !installedRepository.isEmpty, installedRepository != module.sourceName {
            return .installable
        }
        if isRemoteVersionNewer(remoteVersion: module.version, installedVersion: installedModule.version) {
            return .updateAvailable
        }
        return .installed
    }

    /**
     Tests whether one row status represents the installed module from that exact repository.

     - Parameter status: Repository-aware row status.
     - Returns: `true` for installed and update-available rows; other-repository duplicates remain
       installable and return `false`.
     - Side effects: none.
     - Failure modes: none.
     */
    private static func isInstalledStatus(_ status: ModuleBrowserDownloadStatus) -> Bool {
        switch status {
        case .installed, .updateAvailable:
            return true
        case .beingInstalled, .errorDownloading, .unavailable, .installable:
            return false
        }
    }

    /**
     Tests whether local storage contains the selected repository's module independently of row activity.

     A retained download error temporarily replaces the row's installed/update status, but Android
     still treats a failed update as an installed document for bookmark-warning purposes. Repository
     metadata keeps same-initials rows from another source out of that warning path.

     - Parameters:
       - module: Selected remote repository row.
       - installedModules: Current installed module inventory.
     - Returns: `true` when the installed initials belong to this source, or when a legacy install has
       no recorded source and therefore cannot be distinguished.
     - Side effects: none.
     - Failure modes: none.
     */
    static func isModuleInstalledFromSelectedRepository(
        _ module: RemoteModuleInfo,
        installedModules: [ModuleInfo]
    ) -> Bool {
        let repositoryStatus = displayStatus(
            for: module,
            installedModules: installedModules,
            downloadActivities: [:]
        )
        return isInstalledStatus(repositoryStatus)
    }

    /**
     Builds an initials-keyed installed-module lookup for row rendering and sorting.

     - Parameter installedModules: Installed module snapshots from the current SWORD manager.
     - Returns: Dictionary keyed by module initials, preserving the first module when duplicate
       initials appear.
     - Side effects: none.
     - Failure modes: none.
     */
    static func installedModuleLookup(from installedModules: [ModuleInfo]) -> [String: ModuleInfo] {
        Dictionary(installedModules.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /**
     Formats SWORD install-size metadata using Android's one-decimal megabyte presentation.

     - Parameter bytes: Install size in bytes from the remote catalog.
     - Returns: Formatted size text, or `nil` when size metadata is absent or invalid.

     Side effects:
     - none

     Failure modes:
     - zero/negative byte counts return `nil`
     */
    static func installSizeText(for bytes: Int64?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        return String(format: "%.1f MB", Double(bytes) / 1_000_000.0)
    }

    /**
     Compares remote and installed versions to detect Android-style update availability.

     - Parameters:
       - remoteVersion: Repository version string.
       - installedVersion: Local installed version string.
     - Returns: `true` when the remote version sorts after the installed version, or when either
       non-empty value cannot be parsed by Android's JSword version grammar.

     Side effects:
     - none

     Failure modes:
     - empty versions compare as JSword's read-time `1.0` default, so versionless modules and
       catalog caches persisted before that default never report a phantom update
     - malformed or overflowing versions return `true`, matching Android's deliberate
       upgrade-available fallback when `Version(...)` throws
     */
    static func isRemoteVersionNewer(remoteVersion: String, installedVersion: String) -> Bool {
        let remoteText = remoteVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let installedText = installedVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let remote = parseJSwordVersion(remoteText.isEmpty ? "1.0" : remoteText),
              let installed = parseJSwordVersion(installedText.isEmpty ? "1.0" : installedText) else {
            return true
        }
        return compareVersion(remote, installed) == .orderedDescending
    }

    /**
     Parses the version grammar used by JSword's `Version` constructor.

     JSword accepts one to four numeric components and initializes omitted trailing components to
     `-1`. Its published regular expression consumes one separator character between components;
     this parser preserves that behavior while limiting numeric values to Java's signed 32-bit range.

     - Parameter version: Unmodified repository or installed module metadata value.
     - Returns: Four comparison components, or `nil` when JSword would throw.
     - Side effects: None.
     - Failure modes: Empty values, surrounding whitespace, consecutive separators, more than four
       components, non-ASCII digits, and 32-bit overflow return `nil`.
     */
    private static func parseJSwordVersion(_ version: String) -> [Int]? {
        guard !version.isEmpty else { return nil }

        var parts: [Int] = []
        var digits = ""
        for scalar in version.unicodeScalars {
            if scalar.value >= 48, scalar.value <= 57 {
                digits.unicodeScalars.append(scalar)
                continue
            }

            guard ![10, 13, 0x85, 0x2028, 0x2029].contains(scalar.value),
                  !digits.isEmpty,
                  parts.count < 4,
                  let value = Int32(digits) else {
                return nil
            }
            parts.append(Int(value))
            digits = ""
        }

        guard !digits.isEmpty,
              parts.count < 4,
              let value = Int32(digits) else {
            return nil
        }
        parts.append(Int(value))
        parts.append(contentsOf: repeatElement(-1, count: 4 - parts.count))
        return parts
    }

    /**
     Compares parsed JSword version components in major/minor/micro/nano order.

     - Parameters:
       - lhs: First four-part JSword version.
       - rhs: Second four-part JSword version.
     - Returns: Foundation comparison result.

     Side effects:
     - none

     Failure modes:
     - none; `parseJSwordVersion` validates and normalizes both arrays before comparison
     */
    private static func compareVersion(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
        for (lhsPart, rhsPart) in zip(lhs, rhs) where lhsPart != rhsPart {
            return lhsPart < rhsPart ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }

    /**
     Returns whether a Downloads row tap should be exposed as an actionable control.

     Android row taps start by opening confirmation for install/update/retry states. Active installs
     cancel only from the explicit undo control, and installed/unavailable rows are passive.

     - Parameter status: Current Android-equivalent row status.
     - Returns: `true` only when tapping the row opens download confirmation.
     - Side effects: none.
     - Failure modes: none.
     */
    private static func primaryRowTapStartsDownload(_ status: ModuleBrowserDownloadStatus) -> Bool {
        switch status {
        case .installable, .updateAvailable, .errorDownloading:
            return true
        case .beingInstalled, .installed, .unavailable:
            return false
        }
    }

    /**
     Formats Android's per-row download confirmation text.

     - Parameter module: Remote catalog row selected by the user.
     - Returns: Localized prefix plus the best available document display name.
     - Side effects: none.
     - Failure modes: none.
     */
    fileprivate static func downloadConfirmationMessage(for module: RemoteModuleInfo) -> String {
        let prefix = String(localized: "download_document_confirm_prefix", defaultValue: "Download")
        let trimmedDescription = module.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmedDescription.isEmpty ? module.name : trimmedDescription
        return "\(prefix) \(displayName)"
    }

    /**
     Builds Android's generic-bookmark update warning body.

     Android concatenates `bookmark_warning2`, `bookmark_warning4`, and `bookmark_warning3` with
     blank lines. Keeping that assembly in one helper preserves the same warning order for update
     confirmations without coupling the alert renderer to individual string keys.

     - Returns: Localized warning text used when updating a document with generic bookmarks/notes.
     - Side effects: none.
     - Failure modes: missing translations fall back to the supplied English defaults.
     */
    fileprivate static func genericBookmarkUpdateWarningMessage() -> String {
        let warningMessage = String(
            localized: "bookmark_warning2",
            defaultValue: "If document structure has changed, updating this document could make the locations of these bookmarks/notes move inside the document or disappear completely."
        )
        let warningRecommendation = String(
            localized: "bookmark_warning4",
            defaultValue: "It is recommended that you backup the module before updating."
        )
        let warningQuestion = String(
            localized: "bookmark_warning3",
            defaultValue: "Do you still want to update module?"
        )
        return "\(warningMessage)\n\n\(warningRecommendation)\n\n\(warningQuestion)"
    }

    /**
     Checks Android's update-warning condition for generic bookmarks tied to a module.

     Android queries `GenericBookmarkWithNotes` by document initials before updating an installed
     document. iOS mirrors the same user-safety gate by fetching at most one `GenericBookmark` with
     the selected module initials; the warning is only needed when a matching row exists.

     - Parameter module: Remote catalog row that is about to be updated.
     - Returns: `true` when at least one generic bookmark targets `module.name`.
     - Side effects: performs a read-only SwiftData fetch.
     - Failure modes: fetch errors return `false` so the download path remains usable.
     */
    private func hasGenericBookmarks(for module: RemoteModuleInfo) -> Bool {
        Self.hasGenericBookmarks(for: module.name, in: modelContext)
    }

    /**
     Performs Android's `GenericBookmarkWithNotes.bookInitials` existence query against SwiftData.

     Android counts rows from the `GenericBookmarkWithNotes` view before warning on installed
     document updates. That view left-joins notes, so the correct iOS equivalent is the owning
     `GenericBookmark` row keyed by document initials, regardless of whether a note payload exists.

     - Parameters:
       - moduleName: Module initials for the document being updated.
       - modelContext: SwiftData context that owns bookmark rows.
     - Returns: `true` when at least one generic bookmark targets `moduleName`.
     - Side effects: performs a read-only SwiftData fetch.
     - Failure modes: fetch errors return `false` so the download path remains usable.
     */
    static func hasGenericBookmarks(for moduleName: String, in modelContext: ModelContext) -> Bool {
        var descriptor = FetchDescriptor<GenericBookmark>(
            predicate: #Predicate { bookmark in
                bookmark.bookInitials == moduleName
            }
        )
        descriptor.fetchLimit = 1
        return ((try? modelContext.fetch(descriptor)) ?? []).isEmpty == false
    }

    /**
     Selects Android's bookmark/notes warning branch for Downloads update confirmations.

     Android checks for installed documents with generic bookmarks before every non-active
     `manageDownload` action, not only before clean `UPGRADE_AVAILABLE` rows. That means a failed
     retry for an already-installed document must still warn before replacing module files.

     - Parameters:
       - status: Current Android-equivalent row status.
       - isInstalled: Whether the selected document is already installed locally.
       - hasGenericBookmarks: Whether generic bookmarks/notes target the selected module initials.
     - Returns: `true` when iOS should show Android's `documentUpgradeConfirmation` warning.
     - Side effects: none.
     - Failure modes: none.
     */
    static func shouldShowGenericBookmarkUpdateWarning(
        status: ModuleBrowserDownloadStatus,
        isInstalled: Bool,
        hasGenericBookmarks: Bool
    ) -> Bool {
        Self.canPromptForDownload(status) && isInstalled && hasGenericBookmarks
    }

    /**
     Confirms that a status is in Android's download-manageable set before warning selection.

     Android only enters `manageDownload` for non-active, non-pseudo rows. iOS calls the confirmation
     staging helper from installable, retry, and update entry points; this helper keeps the
     bookmark-warning predicate tied to that same actionable status set.

     - Parameter status: Current Android-equivalent row status.
     - Returns: `true` for statuses that can proceed to a download confirmation.
     - Side effects: none.
     - Failure modes: none.
     */
    private static func canPromptForDownload(_ status: ModuleBrowserDownloadStatus) -> Bool {
        switch status {
        case .installable, .updateAvailable, .errorDownloading:
            return true
        case .beingInstalled, .installed, .unavailable:
            return false
        }
    }

    /**
     Returns Android's primary status sort rank.

     - Parameter status: Resolved row status.
     - Returns: Lower values sort first, matching Android's being-installed/update/other ordering.
     */
    private static func statusSortRank(_ status: ModuleBrowserDownloadStatus) -> Int {
        switch status {
        case .beingInstalled:
            return 0
        case .updateAvailable:
            return 1
        case .installed:
            return 2
        case .errorDownloading, .installable, .unavailable:
            return 3
        }
    }

    /**
     Converts a Downloads row status into a compact token for UI-test state exports.

     - Parameter status: Resolved Android-parity download row status.
     - Returns: Stable ASCII token used by `moduleBrowserStateExport`.
     - Side effects: none.
     - Failure modes: none.
     */
    private static func downloadStatusAccessibilityToken(_ status: ModuleBrowserDownloadStatus) -> String {
        switch status {
        case .beingInstalled:
            return "beingInstalled"
        case .errorDownloading:
            return "errorDownloading"
        case .updateAvailable:
            return "updateAvailable"
        case .installed:
            return "installed"
        case .unavailable:
            return "unavailable"
        case .installable:
            return "installable"
        }
    }

    /**
     Returns Android's document-type sort rank.

     - Parameter category: SWORD module category.
     - Returns: Lower values sort first.
     */
    private static func categorySortRank(_ category: ModuleCategory) -> Int {
        switch category {
        case .bible:
            return 0
        case .commentary:
            return 1
        case .dictionary:
            return 2
        case .generalBook:
            return 4
        case .map:
            return 5
        case .addon:
            return 6
        default:
            return 7
        }
    }

    // MARK: - Data Management

    /**
     Initial state restored before the Downloads list can show cached or installed rows.

     This snapshot is produced away from the main actor so SWORD manager creation, installed-module
     scanning, and JSON catalog decoding do not block modal presentation. It contains only
     value-semantic module/source metadata plus the freshly created `SwordManager` needed by later
     install/uninstall operations.

     Inputs:
     - captured `ModuleRepository` whose cache is restored by the background load

     Outputs:
     - one immutable state bundle consumed by `loadInitialStateIfNeeded`

     Side effects:
     - none itself; the loader that creates it performs local file I/O and SWORD initialization

     Failure modes:
     - unavailable managers or missing cache files are represented as `nil`/empty values so the UI
       can still open and offer refresh
     */
    private struct InitialModuleBrowserState {
        let swordManager: SwordManager?
        let sources: [SourceConfig]
        let recommendedDocuments: ModuleDownloadConfiguration?
        let badDocuments: ModuleDownloadConfiguration?
        let defaultDocuments: ModuleDownloadConfiguration?
        let installedModules: [ModuleInfo]
        let cachedModules: [RemoteModuleInfo]
        let shouldRefreshCatalogs: Bool
    }

    /**
     Decides whether normal Downloads should refresh repository catalogs after showing cached rows.

     Android opens the Downloads activity from cached installer/book-list state and refreshes the
     repository list only when that list is stale, missing, or the user explicitly requests a
     refresh. This helper mirrors that behavior using iOS catalog cache timestamps.

     - Parameters:
       - sources: Configured repository sources that should have catalog cache entries.
       - repository: Repository facade that can report catalog cache age per source.
       - staleInterval: Maximum accepted catalog age. Defaults to Android's one-day refresh window.
     - Returns: `true` when at least one configured source is missing cache data or has stale cache
       data, otherwise `false`.

     Side effects:
     - reads catalog cache metadata from disk through `repository`

     Failure modes:
     - malformed, unreadable, or absent cache files are treated as stale so the next open can
       recover by refreshing
     */
    nonisolated static func shouldAutoRefreshCatalogs(
        sources: [SourceConfig],
        repository: ModuleRepository,
        staleInterval: TimeInterval = Self.downloadCatalogStaleInterval
    ) -> Bool {
        guard !sources.isEmpty else { return false }
        return sources.contains { source in
            guard let cacheAge = repository.catalogCacheAge(for: source.name) else {
                return true
            }
            return cacheAge > staleInterval
        }
    }

    /**
     Starts initial local state restoration after the Downloads sheet has been presented.

     Side effects:
     - sets `isLoadingInitialState` while local setup is in flight
     - creates a `SwordManager` and scans installed modules on a background task
     - loads configured repository sources and cached Android metadata/catalog rows from disk
     - updates SwiftUI state on the main actor after the snapshot is ready
     - starts Android default-document refresh/install flow after local state is available

     Failure modes:
     - missing caches produce empty module lists and keep the sheet interactive
     - cancellation leaves current state unchanged so dismissed sheets do not apply stale updates

     - Important: This method intentionally avoids synchronous SWORD or catalog work on the main
       actor. Downloads should present immediately, then populate rows, matching Android's
       behavior of opening the screen before repository work completes.
     */
    @MainActor
    private func loadInitialStateIfNeeded() async {
        guard !didStartInitialStateLoad else { return }
        didStartInitialStateLoad = true
        isLoadingInitialState = true

        let repository = repository
        let initialState = await Task.detached(priority: .userInitiated) {
            let manager = SwordManager()
            let sources = repository.loadSources()
            let cachedModules = repository.loadCachedCatalogs() + repository.loadCachedPseudoModules()
            return InitialModuleBrowserState(
                swordManager: manager,
                sources: sources,
                recommendedDocuments: repository.loadCachedRecommendedDocuments(),
                badDocuments: repository.loadCachedBadDocuments(),
                defaultDocuments: repository.loadCachedDefaultDocuments(),
                installedModules: manager?.installedModules() ?? [],
                cachedModules: cachedModules,
                shouldRefreshCatalogs: Self.shouldAutoRefreshCatalogs(
                    sources: sources,
                    repository: repository
                )
            )
        }.value

        guard !Task.isCancelled else { return }

        swordManager = initialState.swordManager
        sources = initialState.sources
        recommendedDocuments = initialState.recommendedDocuments
        badDocuments = initialState.badDocuments
        defaultDocuments = initialState.defaultDocuments
        installedModules = initialState.installedModules
        if availableModules.isEmpty && !initialState.cachedModules.isEmpty {
            availableModules = Self.deduplicatedModules(from: initialState.cachedModules)
        }
        applyAndroidDefaultLanguageIfNeeded()
        captureDownloadListSortSnapshot()
        isLoadingInitialState = false
        if defaultDownloadMode.shouldInstallDefaultDocuments {
            startDefaultDownloadFlowIfNeeded()
        } else if initialState.shouldRefreshCatalogs {
            refreshCatalog()
        }
    }

    /**
     Reloads repository sources after the repository manager changes `InstallMgr.conf`.

     Side effects:
     - replaces the local source list used by subsequent catalog refreshes

     Failure modes:
     - source-manager read failures surface as an empty source list, matching initial setup behavior
     */
    @MainActor
    private func reloadRepositorySources() {
        sources = repository.loadSources()
    }

    /**
     Reloads locally installed modules from a fresh `SwordManager`.

     Side effects:
     - rebuilds `swordManager` so SWORD rescans module files after installs, restores, or uninstalls
     - replaces the local `installedModules` array when a manager is available

     Failure modes:
     - returns without mutating state when a new `SwordManager` cannot be created and no previous
       manager is available
     */
    private func refreshInstalledList() {
        if let mgr = SwordManager() {
            swordManager = mgr
        }
        guard let mgr = swordManager else { return }
        installedModules = mgr.installedModules()
    }

    /**
     Starts Android's startup default-document flow for Easy Start launches.

     Normal Downloads entry points leave `defaultDownloadMode` disabled. When startup Easy Start
     enables it, the view refreshes catalogs and Android metadata first so selection uses the
     newest `default_documents_v2.json` when available, with cached metadata/catalog fallback inside
     `refreshCatalog()`.

     Side effects:
     - starts a catalog refresh if a default-download mode is active and no refresh is running
     - may eventually install modules through `installDefaultDocumentsIfNeeded`

     Failure modes:
     - if sources are missing or refresh fails without usable cache, `refreshCatalog()` surfaces
       the user-visible error and leaves the flow retryable
     */
    private func startDefaultDownloadFlowIfNeeded() {
        guard defaultDownloadMode.shouldInstallDefaultDocuments,
              !didRequestDefaultDocuments,
              !isRefreshing else {
            return
        }
        onDefaultDownloadActivityChanged(true)
        refreshCatalog()
    }

    /**
     Requests Android default modules after metadata and catalogs are available.

     - Parameters:
       - modules: Full remote catalog rows from the current refresh/cache.
       - defaultDocuments: Android default metadata from the current refresh/cache.

     Side effects:
     - marks the startup default flow as requested once metadata and installable catalog rows are
       available
     - mutates `downloadActivities`, `errorMessage`, `swordManager`, and `installedModules`
       through normal module installation
     - performs file/network I/O indirectly through `installModule(_:)`

     Failure modes:
     - missing default metadata leaves the flow retryable and reports a user-visible error
     - empty or unavailable-only catalogs leave the flow retryable for a later refresh
     - missing, installed, unavailable, malformed, or duplicate default entries are skipped
     - individual install failures are surfaced by `installModule(_:)`
     */
    private func installDefaultDocumentsIfNeeded(
        using modules: [RemoteModuleInfo],
        defaultDocuments: ModuleDownloadConfiguration?
    ) {
        guard defaultDownloadMode.shouldInstallDefaultDocuments,
              !didRequestDefaultDocuments,
              let language = defaultDownloadMode.languageCode else {
            return
        }
        guard let defaultDocuments else {
            errorMessage = "Could not load default document list."
            finishDefaultDownloadActivityIfNeeded()
            return
        }
        guard Self.startupDefaultCatalogHasInstallableRows(modules) else {
            if errorMessage == nil {
                errorMessage = "Could not load module catalog."
            }
            finishDefaultDownloadActivityIfNeeded()
            return
        }

        refreshInstalledList()
        let modulesToInstall = DefaultDocumentDownloadPlanner.selectedModules(
            from: defaultDocuments,
            availableModules: modules,
            installedModules: installedModules,
            language: language
        )
        didRequestDefaultDocuments = true

        let moduleIdentities = Set(modulesToInstall.map(\.installIdentity))
        guard !moduleIdentities.isEmpty else {
            finishDefaultDownloadActivityIfNeeded()
            return
        }

        let totalInstallBytes = Self.combinedInstallSizeBytes(for: modulesToInstall)
        if let requirement = repository.storageRequirement(estimatedAdditionalBytes: totalInstallBytes),
           !requirement.isSatisfied {
            let message = ModuleInstallErrorPresentation.detail(for: ModuleRepositoryError.insufficientStorage(
                requiredBytes: requirement.requiredBytes,
                availableBytes: requirement.availableBytes
            ))
            errorMessage = message
            recordDownloadError(message)
            finishDefaultDownloadActivityIfNeeded()
            return
        }

        defaultDownloadInstallingModules.formUnion(moduleIdentities)
        onDefaultDownloadActivityChanged(true)
        for module in modulesToInstall {
            installModule(module)
        }
    }

    /**
     Sums positive catalog install sizes for an Easy Start batch without overflowing.

     - Parameter modules: Remote rows selected by Android default-document metadata.
     - Returns: Total known install bytes, `nil` when no row reports a usable size, or `Int64.max`
       when the sum overflows so storage preflight fails closed.
     - Side effects: none.
     - Failure modes: Malformed and non-positive catalog sizes are ignored.
     */
    static func combinedInstallSizeBytes(for modules: [RemoteModuleInfo]) -> Int64? {
        var total: Int64 = 0
        var foundKnownSize = false
        for module in modules {
            guard let size = module.installSizeBytes, size > 0 else { continue }
            foundKnownSize = true
            let (newTotal, overflow) = total.addingReportingOverflow(size)
            if overflow { return Int64.max }
            total = newTotal
        }
        return foundKnownSize ? total : nil
    }

    /**
     Refreshes all configured remote catalogs and updates the filtered module list.

     Side effects:
     - marks the view as refreshing, clears stale error text, and updates progress copy while each
       source is fetched
     - refreshes Android pseudo, recommended, bad, and default metadata, falling back to caches
     - when repository refreshes fail, preserves cached catalogs for failed sources so startup
       defaults can still resolve modules from the most recent successful refresh
     - merges and de-duplicates the refreshed module set before storing it in `availableModules`
     - in startup default mode, requests selected Android default modules from the full catalog so
       source-scoped tokens can resolve alternate repository rows hidden by visible-row de-duplication
     - records every refresh failure in Download Errors and reserves `errorMessage` for an empty catalog

     Failure modes:
     - if no sources are configured, sets a user-visible error and exits without attempting a fetch
     - per-source refresh failures are accumulated without aborting usable catalog results
     */
    private func refreshCatalog() {
        isRefreshing = true
        errorMessage = nil
        refreshProgress = nil

        Task {
            let sourcesToRefresh = sources
            let shouldRequireDefaultDocuments = defaultDownloadMode.shouldInstallDefaultDocuments
            if sourcesToRefresh.isEmpty {
                await MainActor.run {
                    let message = Self.noRepositorySourcesConfiguredMessage()
                    errorMessage = message
                    recordDownloadError(message)
                    isRefreshing = false
                    finishDefaultDownloadActivityIfNeeded()
                }
                return
            }

            var allModules: [RemoteModuleInfo] = []
            var errors: [String] = []
            var failedSourceNames: Set<String> = []
            let total = sourcesToRefresh.count

            for (index, source) in sourcesToRefresh.enumerated() {
                await MainActor.run {
                    refreshProgress = "Refreshing \(source.name) (\(index + 1)/\(total))..."
                }

                do {
                    let modules = try await repository.refreshCatalog(for: source)
                    allModules.append(contentsOf: modules)
                } catch {
                    failedSourceNames.insert(source.name)
                    errors.append("\(source.name): \(error.localizedDescription)")
                }
            }

            if !failedSourceNames.isEmpty {
                let cachedCatalogs = repository.loadCachedCatalogs()
                allModules = Self.modulesByAddingCachedCatalogsForFailedSources(
                    refreshedModules: allModules,
                    cachedModules: cachedCatalogs,
                    failedSourceNames: failedSourceNames
                )
            }

            await MainActor.run {
                refreshProgress = "Refreshing unavailable modules..."
            }

            do {
                let pseudoModules = try await repository.refreshPseudoModules()
                allModules.append(contentsOf: pseudoModules)
            } catch {
                let cachedPseudoModules = repository.loadCachedPseudoModules()
                if cachedPseudoModules.isEmpty {
                    errors.append("AndBible metadata: \(error.localizedDescription)")
                } else {
                    allModules.append(contentsOf: cachedPseudoModules)
                }
            }

            do {
                let refreshedRecommendedDocuments = try await repository.refreshRecommendedDocuments()
                await MainActor.run {
                    recommendedDocuments = refreshedRecommendedDocuments
                }
            } catch {
                if let cachedRecommendedDocuments = repository.loadCachedRecommendedDocuments() {
                    await MainActor.run {
                        recommendedDocuments = cachedRecommendedDocuments
                    }
                } else {
                    errors.append("AndBible recommendations: \(error.localizedDescription)")
                }
            }

            do {
                let refreshedBadDocuments = try await repository.refreshBadDocuments()
                await MainActor.run {
                    badDocuments = refreshedBadDocuments
                }
            } catch {
                if let cachedBadDocuments = repository.loadCachedBadDocuments() {
                    await MainActor.run {
                        badDocuments = cachedBadDocuments
                    }
                } else {
                    errors.append("AndBible bad-document list: \(error.localizedDescription)")
                }
            }

            let resolvedDefaultDocuments: ModuleDownloadConfiguration?
            do {
                let refreshedDefaultDocuments = try await repository.refreshDefaultDocuments()
                resolvedDefaultDocuments = refreshedDefaultDocuments
                await MainActor.run {
                    defaultDocuments = refreshedDefaultDocuments
                }
            } catch {
                if let cachedDefaultDocuments = repository.loadCachedDefaultDocuments() {
                    resolvedDefaultDocuments = cachedDefaultDocuments
                    await MainActor.run {
                        defaultDocuments = cachedDefaultDocuments
                    }
                } else {
                    resolvedDefaultDocuments = nil
                    if shouldRequireDefaultDocuments {
                        errors.append("AndBible defaults: \(error.localizedDescription)")
                    }
                }
            }

            let uniqueModules = Self.deduplicatedModules(from: allModules)

            await MainActor.run {
                availableModules = uniqueModules
                replaceDownloadErrors(with: errors)
                applyAndroidDefaultLanguageIfNeeded()
                captureDownloadListSortSnapshot()
                isRefreshing = false
                refreshProgress = nil
                installDefaultDocumentsIfNeeded(
                    using: allModules,
                    defaultDocuments: resolvedDefaultDocuments
                )

                if let inlineError = Self.catalogRefreshInlineError(
                    availableModuleCount: uniqueModules.count,
                    errors: errors
                ) {
                    errorMessage = inlineError
                }
            }
        }
    }

    /**
     Installs one remote module from its configured repository source.

     - Parameter module: Remote module to install locally.

     Side effects:
     - records the module name in `downloadActivities` so the UI can show progress and cancel
     - performs repository installation work and, on success, rebuilds local SWORD state before
       refreshing the installed-module list
     - repository installation follows Android's package ZIP path for remote SWORD modules
     - stores installation failures in the row activity and surfaces the latest failure in
       `errorMessage`

     Failure modes:
     - if the matching source cannot be resolved, sets a user-visible error and returns
     - pre-commit cancellation clears active row state without reporting a failure, matching
       Android `INSTALL_CANCELLED`; commit/rollback failures remain visible even if cancellation
       was requested after the mutation boundary
     - repository installation errors are caught and reported without crashing the view
    */
    private func installModule(_ module: RemoteModuleInfo) {
        let identity = module.installIdentity
        guard module.isInstallable else {
            let message = module.unavailableReason
                ?? Self.moduleUnavailableForInstallationMessage(moduleName: module.name)
            errorMessage = message
            recordDownloadError(message)
            markDefaultDownloadModuleFinishedIfNeeded(identity)
            return
        }

        guard installTasks[identity] == nil else {
            return
        }

        guard let source = sources.first(where: { $0.name == module.sourceName }) else {
            let message = Self.moduleSourceNotFoundMessage(moduleName: module.name)
            errorMessage = message
            recordDownloadError(message)
            markDefaultDownloadModuleFinishedIfNeeded(identity)
            return
        }

        let installID = UUID()
        downloadActivities[identity] = .inProgress(ModuleInstallProgress(phase: .queued))
        installTaskIDs[identity] = installID
        errorMessage = nil

        if UITestRuntimeConfiguration.shouldHoldDownloadInstall(for: module.name) {
            installTasks[identity] = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                }
                guard installTaskIDs[identity] == installID else { return }
                installTasks[identity] = nil
                installTaskIDs[identity] = nil
                downloadActivities[identity] = nil
                markDefaultDownloadModuleFinishedIfNeeded(identity)
            }
            return
        }

        let task = Task {
            await Task.yield()
            do {
                try await repository.installModule(
                    named: module.name,
                    from: source,
                    progressState: { progress in
                    Task { @MainActor in
                        guard installTaskIDs[identity] == installID else { return }
                        downloadActivities[identity] = .inProgress(progress)
                    }
                })

                await MainActor.run {
                    guard installTaskIDs[identity] == installID else { return }
                    installTasks[identity] = nil
                    installTaskIDs[identity] = nil
                    downloadActivities[identity] = nil
                    swordManager = SwordManager()
                    refreshInstalledList()
                    markDefaultDownloadModuleFinishedIfNeeded(identity)
                }
            } catch {
                await MainActor.run {
                    guard installTaskIDs[identity] == installID else { return }
                    installTasks[identity] = nil
                    installTaskIDs[identity] = nil
                    if error is CancellationError
                        || (error as? URLError)?.code == .cancelled {
                        downloadActivities[identity] = nil
                    } else {
                        let detail = ModuleInstallErrorPresentation.detail(for: error)
                        let message = Self.downloadFailureMessage(detail)
                        downloadActivities[identity] = .failed(message)
                        errorMessage = message
                        recordDownloadError(Self.downloadFailureMessage(moduleName: module.name, message: detail))
                    }
                    markDefaultDownloadModuleFinishedIfNeeded(identity)
                }
            }
        }
        installTasks[identity] = task
    }

    /**
     Cancels an active module install from its Downloads row.

     - Parameter identity: Repository-scoped identity for the active install task.

     Side effects:
     - requests cancellation only while the current phase remains pre-commit
     - keeps task and row identity until the installer reports its actual terminal result

     - Returns: Active task that callers can await before touching module files, or `nil` when no
       install was active. A non-cancellable commit task is returned without cancelling it.
     Failure modes:
     - missing or already-finished tasks are ignored
     */
    @discardableResult
    private func cancelInstall(_ identity: RemoteModuleIdentity) -> Task<Void, Never>? {
        guard let activeTask = installTasks[identity] else { return nil }
        if downloadActivities[identity]?.installProgress?.isCancellable != false {
            activeTask.cancel()
        }
        return activeTask
    }

    /**
     Marks one startup default module done and finishes the default flow when none remain.

     - Parameter identity: Repository-scoped identity for the completed or skipped default install.
     Side effects:
     - removes the module from the active startup default install set
     - invokes `onDefaultDownloadActivityChanged(false)` once the startup default set is exhausted

     Failure modes:
     - ignored for normal Downloads sessions where default-download mode is disabled
     */
    private func markDefaultDownloadModuleFinishedIfNeeded(_ identity: RemoteModuleIdentity) {
        guard defaultDownloadMode.shouldInstallDefaultDocuments else {
            return
        }

        defaultDownloadInstallingModules.remove(identity)
        if defaultDownloadInstallingModules.isEmpty {
            finishDefaultDownloadActivityIfNeeded()
        }
    }

    /**
     Reports that startup default refresh/install activity is no longer active.

     Side effects:
     - clears active default install activity
     - invokes `onDefaultDownloadActivityChanged(false)` for the reader coordinator

     Failure modes:
     - ignored for normal Downloads sessions where default-download mode is disabled
     */
    private func finishDefaultDownloadActivityIfNeeded() {
        guard defaultDownloadMode.shouldInstallDefaultDocuments else {
            return
        }

        defaultDownloadInstallingModules.removeAll()
        onDefaultDownloadActivityChanged(false)
    }

    /**
     Uninstalls one locally installed module after cancelling any active install/update task.

     - Parameter name: Module name to remove from the local SWORD module store.

     Side effects:
     - cancels and awaits any active install task for the same module before deleting files
     - deletes the module's generated Search index before repository file removal, matching Android
     - invokes repository-backed uninstall file I/O off the main actor
     - rebuilds the local SWORD manager and installed-module cache after a successful uninstall
     - records uninstall failures in `errorMessage`

     Failure modes:
     - active install cancellation may delay uninstall until the installer finishes its rollback path
     - repository uninstall errors are caught and surfaced through `errorMessage`
     */
    private func uninstallModuleAfterCancellingInstall(_ name: String) {
        let cancelledInstallTasks = installTasks.keys
            .filter { $0.initials == name }
            .compactMap(cancelInstall)
        let repository = repository
        let searchIndexService = searchIndexService

        Task {
            for cancelledInstallTask in cancelledInstallTasks {
                await cancelledInstallTask.value
            }

            do {
                try await ModuleSearchIndexUninstaller.uninstall(
                    moduleName: name,
                    deleteSearchIndex: { moduleName in
                        await searchIndexService.deleteIndex(for: moduleName)
                    },
                    removeModule: { moduleName in
                        try await Task.detached(priority: .userInitiated) {
                            try repository.uninstallModule(named: moduleName)
                        }.value
                    }
                )

                await MainActor.run {
                    swordManager = SwordManager()
                    refreshInstalledList()
                }
            } catch {
                await MainActor.run {
                    let message = Self.uninstallFailureMessage(error.localizedDescription)
                    errorMessage = message
                    recordDownloadError(message)
                }
            }
        }
    }

    /**
     Deletes the local full-text search index for one installed module.

     Android exposes this as the `delete_index` contextual document action and confirms before
     dispatching to `SwordDocumentFacade.deleteDocumentIndex`. iOS uses its FTS5-backed
     `SearchIndexService`; deleting a missing index is intentionally harmless so the action can
     stay visible for every installed row like Android.

     - Parameter name: Module initials whose local search index should be removed.
     - Side effects: Mutates the shared search-index SQLite database through `SearchIndexService`.
     - Failure modes: `SearchIndexService.deleteIndex(for:)` treats missing indexes and SQLite
       failures as no-ops, matching Android's best-effort contextual action.
     */
    private func deleteModuleIndex(_ name: String) {
        Task {
            await searchIndexService.deleteIndex(for: name)
        }
    }
}
