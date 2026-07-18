// ModuleBrowserView.swift — Module download browser

import Foundation
import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import BibleCore
import SwordKit

/**
 Tracks one active or failed Downloads row operation using Android's document-status shape.

 Android exposes `BEING_INSTALLED` with a percent and `ERROR_DOWNLOADING` as row states rather
 than a global spinner. iOS keeps the same contract locally: in-progress rows show determinate
 progress plus cancel, while failed rows remain in the list with a retry action.

 Side effects:
 - none; values are immutable snapshots of row state

 Failure modes:
 - none; progress values are clamped to `0.0...1.0` so malformed callbacks cannot produce invalid
   progress UI
 */
struct ModuleBrowserDownloadActivity: Equatable {
    /**
     Operation phase for a download row.

     Cases mirror Android's install-status branch points: progress for `BEING_INSTALLED`, and
     retained failure details for `ERROR_DOWNLOADING`.
     */
    enum Phase: Equatable {
        /// Module files are still downloading or being installed.
        case inProgress

        /// The latest install attempt failed and can be retried from the row.
        case failed
    }

    /// Current Android-equivalent row phase.
    let phase: Phase

    /// Clamped normalized completion ratio used by the row progress bar.
    let progressFraction: Double

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
        ModuleBrowserDownloadActivity(
            phase: .inProgress,
            progressFraction: min(max(progressFraction, 0), 1),
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
            progressFraction: 0,
            message: message
        )
    }

    /**
     Integer percent displayed beside the row progress indicator.

     - Returns: A clamped `0...100` percent derived from `progressFraction`.
     - Side effects: none.
     - Failure modes: none.
     */
    var progressPercent: Int {
        Int((min(max(progressFraction, 0), 1) * 100).rounded(.towardZero))
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
    let downloadActivities: [String: ModuleBrowserDownloadActivity]
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
 Android download-row status used by `ModuleBrowserView`.

 The enum mirrors Android `DocumentStatus.DocumentInstallStatus` closely enough for sorting and
 row controls: in-progress rows sort first with determinate progress, failed rows keep a retry
 affordance, updates sort before already-installed rows, installed rows show completed state,
 unavailable pseudo rows stay visible but disabled, and installable rows expose the normal install
 action.
 */
enum ModuleBrowserDownloadStatus: Equatable {
    /// The module is currently being installed with Android-style percent progress.
    case beingInstalled(progressPercent: Int)

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
     SWORD package-install policy for one requested module.

     Normal Downloads follows Android package-first behavior while retaining iOS raw fallback for
     legacy/raw-compatible sources. Startup defaults require Android package ZIPs for modules
     selected by the Easy Start default-document planner until that module succeeds or is cancelled,
     so a failed default install keeps strict retry behavior while unrelated manual installs in the
     same Downloads session keep the normal fallback behavior.

     - Parameters:
       - moduleName: Module initials about to be installed.
       - strictDefaultModules: Easy Start default modules whose current session retries must remain
         package-only.
     - Returns: Strict package policy only for active Easy Start default modules; otherwise the
       normal package-then-raw policy.
     - Side effects: none.
     - Failure modes: none.
     */
    func modulePackageInstallPolicy(
        for moduleName: String,
        strictDefaultModules: Set<String>
    ) -> ModulePackageInstallPolicy {
        guard self == .englishStartup,
              strictDefaultModules.contains(moduleName) else {
            return .preferPackageThenRaw
        }
        return .requirePackage
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
 Fixed Android Downloads surface colors.

 Android renders the document download browser with a dark app-bar/list surface independent of the
 reader's day/night theme. iOS keeps those colors local to Downloads so app theming still controls
 the reader while this route matches Android's document-management UI.

 Side effects:
 - none; values are static color constants

 Failure modes:
 - none
 */
private enum ModuleBrowserPalette {
    /// Full-screen Downloads background.
    static let background = Color(red: 0.18, green: 0.18, blue: 0.18)

    /// Android top app bar background.
    static let appBar = Color.black

    /// Android overflow menu popup surface.
    static let menuSurface = Color(red: 0.20, green: 0.20, blue: 0.20)

    /// Row divider and filter underline color.
    static let divider = Color.white.opacity(0.16)

    /// Primary row/app-bar text color.
    static let primaryText = Color.white

    /// Secondary row/filter text color.
    static let secondaryText = Color.white.opacity(0.72)

    /// Muted metadata text color.
    static let tertiaryText = Color.white.opacity(0.52)

    /// Android install/update affordance color.
    static let install = Color.orange

    /// Android installed affordance color.
    static let installed = Color(red: 0.15, green: 0.85, blue: 0.28)
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
    /// Android's repository list staleness window before Downloads refreshes catalogs on open.
    static let downloadCatalogStaleInterval: TimeInterval = 24 * 60 * 60

    /// Persisted Android-style document type filter index.
    private static let selectedDocumentFilterIndexKey = "downloads.selectedDocumentFilterIndex"

    /// Android-style sticky Downloads language for the current app process.
    private static var lastSelectedLanguageCode: String?

    /// Dismisses the Android-style Downloads destination back to the reader stack.
    @Environment(\.dismiss) private var dismiss

    /// Shared full-text search index service used for Android's Delete Index row action.
    @Environment(SearchIndexService.self) private var searchIndexService

    /// Startup/default-document behavior requested by the caller.
    private let defaultDownloadMode: ModuleBrowserDefaultDownloadMode

    /// Reports whether startup default refresh/install work is still active.
    private let onDefaultDownloadActivityChanged: (Bool) -> Void

    /// Selected remote/local module category segment, or `nil` for Android's "All types" filter.
    @State private var selectedCategory: ModuleCategory?

    /// Selected language filter, or an empty string when all languages should be shown.
    @State private var selectedLanguage: String = ""

    /// Free-text query applied to the Android-style download list.
    @State private var searchText = ""

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
    @State private var downloadActivities: [String: ModuleBrowserDownloadActivity] = [:]

    /// Whether Downloads has captured Android's current filter/sort inputs for visible row order.
    @State private var didCaptureDownloadSortSnapshot = false

    /// Installed/activity state used for Android-style row ordering until the next filter rebuild.
    @State private var downloadSortSnapshot = ModuleBrowserDownloadSortSnapshot(
        installedModules: [],
        downloadActivities: [:]
    )

    /// Running install tasks keyed by module initials so row cancel buttons can stop work.
    @State private var installTasks: [String: Task<Void, Never>] = [:]

    /// Monotonic task identifiers that prevent stale cancelled tasks from clearing newer retries.
    @State private var installTaskIDs: [String: UUID] = [:]

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

    /// Whether the custom repository manager is pushed from the Downloads overflow menu.
    @State private var showRepositoryManager = false

    /// Whether Android's Install ZIP file picker is visible.
    @State private var showInstallZipImporter = false

    /// Whether a selected ZIP/EPUB/font import is currently installing.
    @State private var isImportingExternalDocument = false

    /// Feedback from Android's Install ZIP equivalent.
    @State private var externalDocumentImportMessage: String?

    /// Current Dynamic Type size used to keep Android's compact filter row readable.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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

    /// Startup default install lifecycle whose failures must keep strict package-only retry policy.
    @State private var defaultDownloadStrictPackageState = ModuleBrowserDefaultDownloadStrictPackageState()

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
     - initializes local SwiftUI state only; repository and installed-module data are still loaded
       lazily in `onAppear`
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
        self.defaultDownloadMode = defaultDownloadMode
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

    /**
     Whether the Android Add-ons filter should be visible in the Downloads type picker.

     Android exposes add-ons as a separate document type backed by rows in the repository/document
     list. iOS mirrors that by showing Add-ons only after the loaded catalog contains `And Bible`
     rows, while keeping it visible if it is already selected so users can move back to another
     filter after a catalog refresh.
     */
    private var shouldShowAddonsFilter: Bool {
        selectedCategory == .addon || availableModules.contains { $0.category == .addon }
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
    private var androidDownloadsScreen: some View {
        let visibleModules = filteredAvailableModules
        let installedModulesByName = Self.installedModuleLookup(from: installedModules)

        return ZStack(alignment: .topTrailing) {
            moduleBrowserScreenMarker
            moduleBrowserStateExport(
                visibleModules: visibleModules,
                installedModulesByName: installedModulesByName
            )
            VStack(spacing: 0) {
                androidTopAppBar
                androidFilterBar(visibleModuleCount: visibleModules.count)
                androidDownloadsContent(
                    visibleModules: visibleModules,
                    installedModulesByName: installedModulesByName
                )
            }
            if showOverflowMenu {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                    .onTapGesture {
                        showOverflowMenu = false
                    }
                androidOverflowMenu
                    .padding(.top, 56)
                    .padding(.trailing, 8)
                    .zIndex(1)
            }
        }
        .background(ModuleBrowserPalette.background.ignoresSafeArea())
        .onChange(of: searchText) {
            alignFiltersWithAndroidSearchState(searchText)
            captureDownloadListSortSnapshot()
        }
        .navigationBarBackButtonHidden(true)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .navigationDestination(isPresented: $showRepositoryManager) {
            RepositoryManagerView()
            #if os(iOS)
            .toolbar(.visible, for: .navigationBar)
            #endif
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
        .alert(
            String(localized: "download_errors", defaultValue: "Download errors"),
            isPresented: $showDownloadErrors
        ) {
            Button(String(localized: "okay", defaultValue: "OK"), role: .cancel) {}
        } message: {
            Text(downloadErrors.joined(separator: "\n"))
        }
        .alert(
            String(localized: "install_zip", defaultValue: "Load Documents From Files"),
            isPresented: Binding(
                get: { externalDocumentImportMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        externalDocumentImportMessage = nil
                    }
                }
            )
        ) {
            Button(String(localized: "okay", defaultValue: "OK"), role: .cancel) {}
        } message: {
            Text(externalDocumentImportMessage ?? "")
        }
        .alert(
            pendingDownloadConfirmation?.title ?? "",
            isPresented: Binding(
                get: { pendingDownloadConfirmation != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingDownloadConfirmation = nil
                    }
                }
            ),
            presenting: pendingDownloadConfirmation
        ) { confirmation in
            Button(confirmation.confirmButtonTitle) {
                pendingDownloadConfirmation = nil
                installModule(confirmation.module)
            }
            Button(String(localized: "cancel"), role: .cancel) {
                pendingDownloadConfirmation = nil
            }
        } message: { confirmation in
            Text(confirmation.message)
        }
        .alert(
            pendingRowActionConfirmation?.title ?? "",
            isPresented: Binding(
                get: { pendingRowActionConfirmation != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingRowActionConfirmation = nil
                    }
                }
            ),
            presenting: pendingRowActionConfirmation
        ) { confirmation in
            switch confirmation.kind {
            case .uninstall:
                Button(String(localized: "uninstall"), role: .destructive) {
                    uninstallModuleAfterCancellingInstall(confirmation.moduleName)
                    pendingRowActionConfirmation = nil
                }
            case .deleteIndex:
                Button(String(localized: "delete_module_index", defaultValue: "Delete Index"), role: .destructive) {
                    deleteModuleIndex(confirmation.moduleName)
                    pendingRowActionConfirmation = nil
                }
            }
            Button(String(localized: "cancel"), role: .cancel) {
                pendingRowActionConfirmation = nil
            }
        } message: { confirmation in
            Text(confirmation.message)
        }
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
     Builds a stable screen-level accessibility marker without overriding child identifiers.

     SwiftUI propagates container accessibility identifiers to descendants in this layout. Keeping
     the screen identifier on a tiny explicit marker lets UI tests detect the route while preserving
     concrete identifiers on the app bar, filters, and rows.

     - Returns: A one-pixel accessibility marker for the Downloads route.
     - Side effects: none.
     - Failure modes: none.
     */
    private var moduleBrowserScreenMarker: some View {
        Rectangle()
            .fill(ModuleBrowserPalette.background.opacity(0.001))
            .frame(width: 1, height: 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "download_documents", defaultValue: "Download Documents"))
            .accessibilityIdentifier("moduleBrowserScreen")
            .allowsHitTesting(false)
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
    private var androidTopAppBar: some View {
        HStack(spacing: 16) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 24, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(ModuleBrowserPalette.primaryText)
            .accessibilityLabel(String(localized: "back_to_previous", defaultValue: "Back"))
            .accessibilityIdentifier("moduleBrowserBackButton")

            Text(String(localized: "download_documents", defaultValue: "Download Documents"))
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(ModuleBrowserPalette.primaryText)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button {
                showOverflowMenu.toggle()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 24, weight: .bold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(ModuleBrowserPalette.primaryText)
            .accessibilityLabel(String(localized: "more", defaultValue: "More"))
            .accessibilityIdentifier("moduleBrowserOverflowButton")
        }
        .padding(.horizontal, 8)
        .frame(height: 56)
        .background(ModuleBrowserPalette.appBar)
    }

    /**
     Builds the Downloads overflow popup using Android's menu item set.

     Android defines Download errors, Load Documents From Files, and Custom repositories for this activity. iOS
     presents the same actions from an explicit top-right popup instead of SwiftUI's native `Menu`
     because the route needs Android-style placement and stable accessibility behavior.

     - Returns: A dark, right-aligned overflow popup anchored below the app bar.
     - Side effects: Menu rows can show download errors, start the ZIP importer, or push repository
       management.
     - Failure modes: Install ZIP remains visible but disabled while a selected external document is
       being imported.
     */
    private var androidOverflowMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !downloadErrors.isEmpty {
                androidOverflowMenuButton(
                    title: String(localized: "download_errors", defaultValue: "Download errors"),
                    accessibilityIdentifier: "moduleBrowserDownloadErrorsButton"
                ) {
                    showOverflowMenu = false
                    showDownloadErrors = true
                }
                Divider()
                    .background(ModuleBrowserPalette.divider)
            }

            androidOverflowMenuButton(
                title: String(localized: "install_zip", defaultValue: "Load Documents From Files"),
                accessibilityIdentifier: "moduleBrowserInstallZipButton",
                disabled: isImportingExternalDocument
            ) {
                showOverflowMenu = false
                showInstallZipImporter = true
            }

            androidOverflowMenuButton(
                title: String(localized: "custom_repositories", defaultValue: "Custom repositories"),
                accessibilityIdentifier: "moduleBrowserRepositoriesButton"
            ) {
                showOverflowMenu = false
                showRepositoryManager = true
            }
        }
        .frame(width: 260, alignment: .leading)
        .background(ModuleBrowserPalette.menuSurface)
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        .shadow(color: Color.black.opacity(0.35), radius: 8, x: 0, y: 4)
    }

    /**
     Builds one Android overflow-menu row.

     - Parameters:
       - title: Localized row title.
       - accessibilityIdentifier: Stable identifier used by UI tests for the concrete action.
       - disabled: Whether the row should reject taps while remaining visible.
       - action: Action to execute when the row is enabled and tapped.
     - Returns: A full-width text row matching Android's compact overflow menu.
     - Side effects: Executes `action` when tapped.
     - Failure modes: Disabled rows do not execute their action.
     */
    private func androidOverflowMenuButton(
        title: String,
        accessibilityIdentifier: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            guard !disabled else { return }
            action()
        } label: {
            Text(title)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(disabled ? ModuleBrowserPalette.tertiaryText : ModuleBrowserPalette.primaryText)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    /**
     Builds Android's inline Downloads filters.

     - Parameter visibleModuleCount: Number of rows visible after current filters.
     - Returns: Language, search, document-type, and count controls in Android's compact row.
     - Side effects: Filter menus mutate `selectedLanguage` and `selectedCategory`; search text
       mutates `searchText`.
     - Failure modes: Empty language catalogs show the all-language label and keep the menu usable.
     */
    private func androidFilterBar(visibleModuleCount: Int) -> some View {
        VStack(spacing: 4) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .bottom, spacing: 14) {
                            androidLanguageFilterMenu()
                                .frame(maxWidth: .infinity, alignment: .leading)
                            androidDocumentTypeFilterMenu(visibleModuleCount: visibleModuleCount)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        androidSearchFilterField()
                    }
                } else {
                    HStack(alignment: .bottom, spacing: 14) {
                        androidLanguageFilterMenu()
                            .frame(minWidth: 96, maxWidth: .infinity, alignment: .leading)
                            .layoutPriority(1)
                        androidSearchFilterField()
                            .frame(minWidth: 96)
                            .layoutPriority(2)
                        androidDocumentTypeFilterMenu(visibleModuleCount: visibleModuleCount)
                            .frame(minWidth: 112, maxWidth: .infinity, alignment: .trailing)
                            .layoutPriority(1)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 10)

            Rectangle()
                .fill(ModuleBrowserPalette.divider)
                .frame(height: 1)
        }
        .background(ModuleBrowserPalette.background)
    }

    /**
     Builds Android's language filter menu for the Downloads filter row.

     - Returns: Menu containing all available languages plus Android's all-language option.
     - Side effects: Mutates `selectedLanguage` when a menu item is selected.
     - Failure modes: Empty catalogs show only the all-language option.
     */
    private func androidLanguageFilterMenu() -> some View {
        Menu {
            Button(languageFilterTitle(for: "")) {
                selectedLanguage = ""
                captureDownloadListSortSnapshot()
            }
            if !availableLanguages.isEmpty {
                Divider()
            }
            ForEach(availableLanguages, id: \.self) { language in
                Button(displayName(for: language)) {
                    selectedLanguage = language
                    Self.rememberExplicitSelectedLanguage(language)
                    captureDownloadListSortSnapshot()
                }
            }
        } label: {
            androidFilterLabel(languageFilterTitle(for: selectedLanguage))
        }
    }

    /**
     Builds Android's inline search filter for the Downloads filter row.

     - Returns: Plain underlined search field matching Android's compact Downloads toolbar.
     - Side effects: Mutates `searchText` as the user types.
     - Failure modes: none.
     */
    private func androidSearchFilterField() -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(String(localized: "search", defaultValue: "Search"), text: $searchText)
                .textFieldStyle(.plain)
                .foregroundStyle(ModuleBrowserPalette.primaryText)
                .tint(ModuleBrowserPalette.primaryText)
                .submitLabel(.search)
            Rectangle()
                .fill(ModuleBrowserPalette.secondaryText)
                .frame(height: 1)
        }
        .accessibilityIdentifier("moduleBrowserSearchField")
    }

    /**
     Builds Android's document-type filter and visible document count.

     - Parameter visibleModuleCount: Number of rows visible after current filters.
     - Returns: Count text stacked above the Android document-type filter menu.
     - Side effects: Mutates and persists `selectedCategory`; resets language selection using Android's
       category-switch behavior.
     - Failure modes: Empty category catalogs still expose Android's all-type option.
     */
    private func androidDocumentTypeFilterMenu(visibleModuleCount: Int) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(documentsCountTitle(visibleModuleCount))
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(ModuleBrowserPalette.secondaryText)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .multilineTextAlignment(.trailing)
            Menu {
                Button(categoryFilterTitle(for: nil)) {
                    selectedCategory = nil
                    selectedLanguage = ""
                    persistSelectedCategory(nil)
                    applyAndroidDefaultLanguageIfNeeded(force: true)
                    captureDownloadListSortSnapshot()
                }
                Divider()
                ForEach(visibleCategoryFilters, id: \.self) { category in
                    Button(categoryFilterTitle(for: category)) {
                        selectedCategory = category
                        selectedLanguage = ""
                        persistSelectedCategory(category)
                        applyAndroidDefaultLanguageIfNeeded(force: true)
                        captureDownloadListSortSnapshot()
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(categoryFilterTitle(for: selectedCategory))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .multilineTextAlignment(.trailing)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(ModuleBrowserPalette.primaryText)
            }
        }
    }

    /**
     Builds one underlined Android filter menu label.

     - Parameter title: User-visible filter title.
     - Returns: Compact label with underline.
     - Side effects: none.
     - Failure modes: Long titles use two lines at accessibility Dynamic Type sizes and otherwise
       compress like Android's toolbar filters.
     */
    private func androidFilterLabel(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(ModuleBrowserPalette.primaryText)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            Rectangle()
                .fill(ModuleBrowserPalette.secondaryText)
                .frame(height: 1)
        }
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
                            .foregroundStyle(ModuleBrowserPalette.secondaryText)
                        Button {
                            refreshCatalog()
                        } label: {
                            Label(String(localized: "refresh_catalog"), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .tint(ModuleBrowserPalette.primaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                }

                if isImportingExternalDocument {
                    androidLoadingRow
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ModuleBrowserPalette.background)
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
                .tint(ModuleBrowserPalette.primaryText)
            Text(refreshProgress ?? (isLoadingInitialState
                ? String(localized: "loading", defaultValue: "Loading...")
                : String(localized: "refreshing_catalog")))
                .font(.caption)
                .foregroundStyle(ModuleBrowserPalette.secondaryText)
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
            .foregroundStyle(ModuleBrowserPalette.secondaryText)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
    }

    /**
     Document categories shown in Android's type filter.

     - Returns: Category rows in Android filter order, omitting Add-ons until catalog data proves
       that Android add-on rows are present.
     - Side effects: none.
     - Failure modes: none
     */
    private var visibleCategoryFilters: [ModuleCategory] {
        var categories: [ModuleCategory] = [
            .bible,
            .commentary,
            .dictionary,
            .generalBook,
            .map,
        ]
        if shouldShowAddonsFilter {
            categories.append(.addon)
        }
        return categories
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
            return String(localized: "all_languages_count \(availableLanguages.count)")
        }
        return displayName(for: language)
    }

    /**
     Formats the Android Downloads visible-document count.

     - Parameter count: Number of rows visible after filters.
     - Returns: User-visible count text.
     - Side effects: none.
    - Failure modes: none
     */
    private func documentsCountTitle(_ count: Int) -> String {
        String(localized: "documents_count \(count)")
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
            isImportingExternalDocument = true
            Task { @MainActor in
                let request = ExternalDocumentImportRequest(
                    url: url,
                    contentTypeIdentifier: try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier,
                    suggestedFileName: url.lastPathComponent
                )
                let importResult = await Task.detached(priority: .userInitiated) {
                    ExternalDocumentImportService().importDocument(request)
                }.value
                isImportingExternalDocument = false
                externalDocumentImportMessage = importResult.feedbackMessage
                if case .failed(let message) = importResult {
                    recordDownloadError(message)
                }
                refreshInstalledList()
            }
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
        "\(String(localized: "error_download_failed", defaultValue: "Download failed")): \(moduleName): \(message)"
    }

    /**
     Formats a localized module download failure for inline alert presentation.

     - Parameter message: Platform error detail reported by the repository or installer.
     - Returns: Download failure text with a localized prefix.
     - Side effects: none.
     - Failure modes: Empty messages are preserved so the caller can still surface a failure state.
     */
    static func downloadFailureMessage(_ message: String) -> String {
        "\(String(localized: "error_download_failed", defaultValue: "Download failed")): \(message)"
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
        let rowActions = ModuleDownloadRowActionPlanner.availableActions(
            installedModule: installedModule,
            isBeingInstalled: status.isBeingInstalled
        )
        let isRecommended = recommendedDocuments?.contains(module) == true
        let badAction = badDocuments?.badDocumentAction(for: module) ?? .none

        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 5) {
                    categoryIcon(for: module.category)
                        .foregroundStyle(ModuleBrowserPalette.secondaryText)
                    if isRecommended {
                        Image(systemName: "star.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.yellow)
                    }
                    if badAction == .warn {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.red)
                    }
                    Text(displayName(for: module.language))
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(ModuleBrowserPalette.secondaryText)
                        .lineLimit(1)
                    if let installSize = Self.installSizeText(for: module.installSizeBytes) {
                        Text(installSize)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(ModuleBrowserPalette.secondaryText)
                            .lineLimit(1)
                    }
                }
                .frame(width: 70)

                VStack(alignment: .leading, spacing: 4) {
                    Text(module.name)
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(ModuleBrowserPalette.primaryText)
                        .lineLimit(1)
                    Text(module.description)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(ModuleBrowserPalette.secondaryText)
                        .lineLimit(module.isInstallable ? 2 : 3)
                    if isRecommended {
                        Text(String(localized: "recommended_document", defaultValue: "Recommended!"))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(ModuleBrowserPalette.secondaryText)
                    }
                    if case let .errorDownloading(message) = status {
                        Text(message.isEmpty ? String(localized: "error_download_failed") : message)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 10) {
                    Text(module.sourceName)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(ModuleBrowserPalette.secondaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)

                    rowTrailingControls(
                        for: module,
                        installedModule: installedModule,
                        status: status,
                        rowActions: rowActions
                    )
                }
                .frame(width: 112, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Rectangle()
                .fill(ModuleBrowserPalette.divider)
                .frame(height: 1)
                .padding(.leading, 96)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            performPrimaryRowAction(for: module, status: status)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(module.name)
        .accessibilityValue(Self.downloadStatusAccessibilityToken(status))
        .accessibilityAddTraits(Self.primaryRowTapStartsDownload(status) ? .isButton : [])
        .accessibilityIdentifier("moduleBrowserRow::\(module.name)")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if rowActions.contains(.uninstall) {
                Button(role: .destructive) {
                    pendingRowActionConfirmation = ModuleBrowserRowActionConfirmation(
                        kind: .uninstall,
                        module: module
                    )
                } label: {
                    Label(String(localized: "uninstall"), systemImage: "trash")
                }
            }
        }
        .contextMenu {
            if rowActions.contains(.about) {
                Button {
                    selectedModuleDetails = ModuleBrowserModuleDetails(
                        module: module,
                        installedModule: installedModule
                    )
                } label: {
                    Label(String(localized: "about"), systemImage: "info.circle")
                }
            }
            if rowActions.contains(.uninstall) {
                Button(role: .destructive) {
                    pendingRowActionConfirmation = ModuleBrowserRowActionConfirmation(
                        kind: .uninstall,
                        module: module
                    )
                } label: {
                    Label(String(localized: "uninstall"), systemImage: "trash")
                }
            }
            if rowActions.contains(.deleteIndex) {
                Button(role: .destructive) {
                    pendingRowActionConfirmation = ModuleBrowserRowActionConfirmation(
                        kind: .deleteIndex,
                        module: module
                    )
                } label: {
                    Label(
                        String(localized: "delete_module_index", defaultValue: "Delete Index"),
                        systemImage: "magnifyingglass"
                    )
                }
            }
        }
    }

    /**
     Renders the Android-sourced category icon for a Downloads row.

     - Parameter category: Remote module category.
     - Returns: Template icon matching the closest Android document category glyph available in the
       packaged icon catalog.
     - Side effects: Loads local asset images when rendered.
     - Failure modes: Unsupported categories use the generic documents icon.
     */
    @ViewBuilder
    private func categoryIcon(for category: ModuleCategory) -> some View {
        switch category {
        case .bible:
            AndBibleIconView(name: "ToolbarBible", size: 28)
        case .commentary:
            AndBibleIconView(name: "ToolbarCommentary", size: 28)
        case .dictionary:
            AndBibleIconView(name: "SettingsIconDictionary", size: 28)
        case .generalBook:
            AndBibleIconView(name: "DrawerDocuments", size: 28)
        case .map:
            Image(systemName: "map")
                .font(.system(size: 26, weight: .regular))
        case .addon:
            AndBibleIconView(name: "DrawerDownloads", size: 28)
        default:
            AndBibleIconView(name: "DrawerDocuments", size: 28)
        }
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
        HStack(spacing: 8) {
            if rowActions.contains(.about) {
                Button {
                    selectedModuleDetails = ModuleBrowserModuleDetails(
                        module: module,
                        installedModule: installedModule
                    )
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 22, weight: .regular))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .accessibilityLabel(String(localized: "about"))
            }

            rowPrimaryControl(for: module, status: status)
        }
    }

    /**
     Builds the primary install/status control for one Downloads row.

     - Parameters:
       - module: Remote catalog row being rendered.
       - status: Current Android-equivalent install status.
     - Returns: SwiftUI control matching Android's status branch for the row.
     - Side effects: Buttons may retry, update, or cancel module installs. Installable rows use
       `performPrimaryRowAction(for:status:)` from the row tap while this slot stays empty to match
       Android `NOT_INSTALLED`.
     - Failure modes: Install failures are caught and retained as row error state by
       `installModule(_:)`.
     */
    @ViewBuilder
    private func rowPrimaryControl(
        for module: RemoteModuleInfo,
        status: ModuleBrowserDownloadStatus
    ) -> some View {
        let presentation = ModuleBrowserStatusSlotPresentation(status: status)

        switch presentation.kind {
        case .installed:
            Image(systemName: presentation.statusIconSystemName ?? "checkmark.circle.fill")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(ModuleBrowserPalette.installed)
        case .progress(let progressPercent):
            VStack(alignment: .trailing, spacing: 6) {
                Text("\(progressPercent)%")
                    .font(.caption)
                    .foregroundStyle(ModuleBrowserPalette.secondaryText)
                ProgressView(value: Double(progressPercent), total: 100)
                    .frame(width: 76)
                    .tint(ModuleBrowserPalette.primaryText)
                Button {
                    cancelInstall(module.name)
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 22, weight: .regular))
                }
                .buttonStyle(.plain)
                .foregroundStyle(ModuleBrowserPalette.secondaryText)
                .accessibilityLabel(String(localized: "cancel"))
            }
        case .retryError:
            VStack(alignment: .trailing, spacing: 6) {
                Image(systemName: presentation.statusIconSystemName ?? "exclamationmark.triangle.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.red)
                Button {
                    requestDownloadConfirmation(for: module, status: status)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 22, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(ModuleBrowserPalette.install)
                .accessibilityLabel(String(localized: "retry", defaultValue: "Retry"))
            }
        case .update:
            Button {
                requestDownloadConfirmation(for: module, status: status)
            } label: {
                Image(systemName: presentation.statusIconSystemName ?? "arrow.up.circle.fill")
                    .font(.system(size: 24, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(ModuleBrowserPalette.install)
            .accessibilityLabel(String(localized: "update"))
        case .unavailable:
            Label(String(localized: "unavailable"), systemImage: "lock.slash")
                .font(.caption)
                .foregroundStyle(ModuleBrowserPalette.tertiaryText)
        case .emptyInstallableSlot:
            Color.clear
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
        }
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
            isInstalled: installedModules.contains(where: { $0.name == module.name }),
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
     De-duplicates remote modules by abbreviation while preserving source priority.

     Real SWORD catalog entries are passed before pseudo/unavailable metadata so an installable
     module keeps precedence over an unavailable placeholder with the same name.
     */
    private func deduplicatedModules(from modules: [RemoteModuleInfo]) -> [RemoteModuleInfo] {
        var seen: Set<String> = []
        var unique: [RemoteModuleInfo] = []
        for module in modules where seen.insert(module.name).inserted {
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
        downloadActivities: [String: ModuleBrowserDownloadActivity]
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
       - downloadActivities: Module initials with active progress or retained failure state.
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
        downloadActivities: [String: ModuleBrowserDownloadActivity],
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
       - downloadActivities: Module initials with active progress or retained failure state.
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
        downloadActivities: [String: ModuleBrowserDownloadActivity],
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

            let lhsInstalled = installedModulesByName[lhs.name] != nil
            let rhsInstalled = installedModulesByName[rhs.name] != nil
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
       - downloadActivities: Module initials with active progress or retained failure state.
     - Returns: Status used for row affordances and sort order.

     Side effects:
     - none

     Failure modes:
     - invalid or absent version strings fall back to non-update installed state
     */
    static func displayStatus(
        for module: RemoteModuleInfo,
        installedModules: [ModuleInfo],
        downloadActivities: [String: ModuleBrowserDownloadActivity]
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
       - downloadActivities: Module initials with active progress or retained failure state.
     - Returns: Status used for row affordances and sort order.

     Side effects:
     - none

     Failure modes:
     - invalid or absent version strings fall back to non-update installed state
     */
    private static func displayStatus(
        for module: RemoteModuleInfo,
        installedModulesByName: [String: ModuleInfo],
        downloadActivities: [String: ModuleBrowserDownloadActivity]
    ) -> ModuleBrowserDownloadStatus {
        if let activity = downloadActivities[module.name] {
            switch activity.phase {
            case .inProgress:
                return .beingInstalled(progressPercent: activity.progressPercent)
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
        if isRemoteVersionNewer(remoteVersion: module.version, installedVersion: installedModule.version) {
            return .updateAvailable
        }
        return .installed
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
     - Returns: `true` when the remote version sorts after the installed version.

     Side effects:
     - none

     Failure modes:
     - missing versions return `false` to avoid offering a destructive reinstall as an update
     */
    static func isRemoteVersionNewer(remoteVersion: String, installedVersion: String) -> Bool {
        let remote = remoteVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let installed = installedVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remote.isEmpty, !installed.isEmpty else { return false }
        return compareVersion(remote, installed) == .orderedDescending
    }

    /**
     Compares dotted version strings using numeric segments where possible.

     - Parameters:
       - lhs: First version string.
       - rhs: Second version string.
     - Returns: Foundation comparison result.

     Side effects:
     - none

     Failure modes:
     - non-numeric segments fall back to localized case-insensitive comparison
     */
    private static func compareVersion(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsParts = lhs.split(whereSeparator: { ".-_+".contains($0) }).map(String.init)
        let rhsParts = rhs.split(whereSeparator: { ".-_+".contains($0) }).map(String.init)
        let count = max(lhsParts.count, rhsParts.count)

        for index in 0..<count {
            let lhsPart = index < lhsParts.count ? lhsParts[index] : "0"
            let rhsPart = index < rhsParts.count ? rhsParts[index] : "0"
            if let lhsNumber = Int(lhsPart), let rhsNumber = Int(rhsPart) {
                if lhsNumber != rhsNumber {
                    return lhsNumber < rhsNumber ? .orderedAscending : .orderedDescending
                }
            } else {
                let comparison = lhsPart.localizedCaseInsensitiveCompare(rhsPart)
                if comparison != .orderedSame {
                    return comparison
                }
            }
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
    static func shouldAutoRefreshCatalogs(
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
            availableModules = deduplicatedModules(from: initialState.cachedModules)
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

        let moduleNames = Set(modulesToInstall.map(\.name))
        guard !moduleNames.isEmpty else {
            finishDefaultDownloadActivityIfNeeded()
            return
        }

        defaultDownloadStrictPackageState.startInstalling(moduleNames)
        onDefaultDownloadActivityChanged(true)
        for module in modulesToInstall {
            installModule(module)
        }
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
     - records aggregate or partial-source failures in `errorMessage`

     Failure modes:
     - if no sources are configured, sets a user-visible error and exits without attempting a fetch
     - per-source refresh failures are accumulated and surfaced after the refresh completes rather
       than aborting the entire operation
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

            let uniqueModules = deduplicatedModules(from: allModules)

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

                if uniqueModules.isEmpty && !errors.isEmpty {
                    errorMessage = "Failed to load catalogs:\n" + errors.joined(separator: "\n")
                } else if !errors.isEmpty {
                    errorMessage = "Some sources failed: " +
                        errors.map { $0.components(separatedBy: ":").first ?? "" }
                              .joined(separator: ", ")
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
     - active startup default-document modules require Android package ZIPs instead of raw SWORD
       file probes; manual installs in the same session keep normal raw fallback
     - stores installation failures in the row activity and surfaces the latest failure in
       `errorMessage`

     Failure modes:
     - if the matching source cannot be resolved, sets a user-visible error and returns
     - task cancellation clears active row state without reporting a failure, matching Android
       `INSTALL_CANCELLED`
     - repository installation errors are caught and reported without crashing the view
    */
    private func installModule(_ module: RemoteModuleInfo) {
        guard module.isInstallable else {
            let message = module.unavailableReason
                ?? Self.moduleUnavailableForInstallationMessage(moduleName: module.name)
            errorMessage = message
            recordDownloadError(message)
            markDefaultDownloadModuleFinishedIfNeeded(
                module.name,
                strictPolicyResolution: .retainForRetry
            )
            return
        }

        guard installTasks[module.name] == nil else {
            return
        }

        guard let source = sources.first(where: { $0.name == module.sourceName }) ?? repository.source(for: module.name) else {
            let message = Self.moduleSourceNotFoundMessage(moduleName: module.name)
            errorMessage = message
            recordDownloadError(message)
            markDefaultDownloadModuleFinishedIfNeeded(
                module.name,
                strictPolicyResolution: .retainForRetry
            )
            return
        }

        let installID = UUID()
        downloadActivities[module.name] = .inProgress(0)
        installTaskIDs[module.name] = installID
        errorMessage = nil

        if UITestRuntimeConfiguration.shouldHoldDownloadInstall(for: module.name) {
            installTasks[module.name] = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                }
            }
            return
        }

        let packageInstallPolicy = defaultDownloadStrictPackageState.packageInstallPolicy(
            mode: defaultDownloadMode,
            moduleName: module.name
        )

        let task = Task {
            await Task.yield()
            do {
                try await repository.installModule(
                    named: module.name,
                    from: source,
                    packageInstallPolicy: packageInstallPolicy
                ) { progress in
                    Task { @MainActor in
                        guard installTaskIDs[module.name] == installID else { return }
                        downloadActivities[module.name] = .inProgress(progress)
                    }
                }

                await MainActor.run {
                    guard installTaskIDs[module.name] == installID else { return }
                    installTasks[module.name] = nil
                    installTaskIDs[module.name] = nil
                    downloadActivities[module.name] = nil
                    swordManager = SwordManager()
                    refreshInstalledList()
                    markDefaultDownloadModuleFinishedIfNeeded(
                        module.name,
                        strictPolicyResolution: .clear
                    )
                }
            } catch {
                await MainActor.run {
                    guard installTaskIDs[module.name] == installID else { return }
                    installTasks[module.name] = nil
                    installTaskIDs[module.name] = nil
                    if error is CancellationError || Task.isCancelled {
                        downloadActivities[module.name] = nil
                    } else {
                        let message = error.localizedDescription
                        downloadActivities[module.name] = .failed(message)
                        errorMessage = Self.downloadFailureMessage(message)
                        recordDownloadError(Self.downloadFailureMessage(moduleName: module.name, message: message))
                    }
                    markDefaultDownloadModuleFinishedIfNeeded(
                        module.name,
                        strictPolicyResolution: (
                            error is CancellationError || Task.isCancelled
                        ) ? .clear : .retainForRetry
                    )
                }
            }
        }
        installTasks[module.name] = task
    }

    /**
     Cancels an active module install from its Downloads row.

     - Parameter moduleName: Module initials for the active install task.

     Side effects:
     - cancels the stored install task when present
     - clears the row activity immediately so the row returns to its normal installed/not-installed
       state, matching Android `INSTALL_CANCELLED`
     - marks startup default activity complete when the cancelled module belonged to that flow

     - Returns: Cancelled task that callers can await before touching module files, or `nil` when
       no install was active.
     Failure modes:
     - missing or already-finished tasks are ignored
     */
    @discardableResult
    private func cancelInstall(_ moduleName: String) -> Task<Void, Never>? {
        let cancelledTask = installTasks[moduleName]
        cancelledTask?.cancel()
        installTasks[moduleName] = nil
        installTaskIDs[moduleName] = nil
        downloadActivities[moduleName] = nil
        markDefaultDownloadModuleFinishedIfNeeded(moduleName, strictPolicyResolution: .clear)
        return cancelledTask
    }

    /**
     Marks one startup default module done and finishes the default flow when none remain.

     - Parameter moduleName: Module initials for the completed or skipped default install.
     - Parameter strictPolicyResolution: Whether this terminal state keeps strict package policy for
       later retries.

     Side effects:
     - records the terminal state in `defaultDownloadStrictPackageState`
     - invokes `onDefaultDownloadActivityChanged(false)` once the startup default set is exhausted

     Failure modes:
     - ignored for normal Downloads sessions where default-download mode is disabled
     */
    private func markDefaultDownloadModuleFinishedIfNeeded(
        _ moduleName: String,
        strictPolicyResolution: ModuleBrowserDefaultDownloadStrictPackageResolution
    ) {
        guard defaultDownloadMode.shouldInstallDefaultDocuments else {
            return
        }

        if defaultDownloadStrictPackageState.finish(
            moduleName,
            strictPolicyResolution: strictPolicyResolution
        ) {
            finishDefaultDownloadActivityIfNeeded()
        }
    }

    /**
     Reports that startup default refresh/install activity is no longer active.

     Side effects:
     - clears active default install activity while preserving failed-module strict retry state
     - invokes `onDefaultDownloadActivityChanged(false)` for the reader coordinator

     Failure modes:
     - ignored for normal Downloads sessions where default-download mode is disabled
     */
    private func finishDefaultDownloadActivityIfNeeded() {
        guard defaultDownloadMode.shouldInstallDefaultDocuments else {
            return
        }

        defaultDownloadStrictPackageState.finishActivity()
        onDefaultDownloadActivityChanged(false)
    }

    /**
     Uninstalls one locally installed module after cancelling any active install/update task.

     - Parameter name: Module name to remove from the local SWORD module store.

     Side effects:
     - cancels and awaits any active install task for the same module before deleting files
     - invokes repository-backed uninstall file I/O off the main actor
     - rebuilds the local SWORD manager and installed-module cache after a successful uninstall
     - records uninstall failures in `errorMessage`

     Failure modes:
     - active install cancellation may delay uninstall until the installer finishes its rollback path
     - repository uninstall errors are caught and surfaced through `errorMessage`
     */
    private func uninstallModuleAfterCancellingInstall(_ name: String) {
        let cancelledInstallTask = cancelInstall(name)
        let repository = repository

        Task {
            if let cancelledInstallTask {
                await cancelledInstallTask.value
            }

            do {
                try await Task.detached(priority: .userInitiated) {
                    try repository.uninstallModule(named: name)
                }.value

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
