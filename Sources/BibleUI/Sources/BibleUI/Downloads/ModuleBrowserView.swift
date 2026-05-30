// ModuleBrowserView.swift — Module download browser

import Foundation
import SwiftUI
import BibleCore
import SwordKit

/**
 Tracks one active or failed Downloads row operation using Android's document-status shape.

 Android exposes `BEING_INSTALLED` with a percent and `ERROR_DOWNLOADING` as row states rather
 than a global spinner. iOS keeps the same contract locally: in-progress rows sort first and show
 determinate progress plus cancel, while failed rows remain in the list with a retry action.

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
    /// Android's repository list staleness window before Downloads refreshes catalogs on open.
    static let downloadCatalogStaleInterval: TimeInterval = 24 * 60 * 60

    /// Startup/default-document behavior requested by the caller.
    private let defaultDownloadMode: ModuleBrowserDefaultDownloadMode

    /// Reports whether startup default refresh/install work is still active.
    private let onDefaultDownloadActivityChanged: (Bool) -> Void

    /// Selected remote/local module category segment, or `nil` for Android's "All types" filter.
    @State private var selectedCategory: ModuleCategory? = .bible

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

    /// Running install tasks keyed by module initials so row cancel buttons can stop work.
    @State private var installTasks: [String: Task<Void, Never>] = [:]

    /// Monotonic task identifiers that prevent stale cancelled tasks from clearing newer retries.
    @State private var installTaskIDs: [String: UUID] = [:]

    /// User-visible error text for refresh, install, or uninstall failures.
    @State private var errorMessage: String?

    /// Progress text describing which remote source is being refreshed.
    @State private var refreshProgress: String?

    /// Guards Android startup defaults so they are requested at most once per Downloads session.
    @State private var didRequestDefaultDocuments = false

    /// Startup default module names whose asynchronous installs have not finished yet.
    @State private var defaultDownloadInstallingModules: Set<String> = []

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
        _selectedCategory = State(
            initialValue: normalizedSearchText.isEmpty && !defaultDownloadMode.shouldInstallDefaultDocuments
                ? .bible
                : nil
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
        for m in availableModules where matchesSelectedCategory(m.category) {
            langs.insert(m.language)
        }
        for m in installedModules where matchesSelectedCategory(m.category) {
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

    /// Installed module names for quick lookup.
    private var installedModuleNames: Set<String> {
        Set(installedModules.map(\.name))
    }

    /// Available (remote) modules filtered by category, language, and search text.
    private var filteredAvailableModules: [RemoteModuleInfo] {
        Self.filteredDownloadModules(
            availableModules,
            selectedCategory: selectedCategory,
            selectedLanguage: selectedLanguage,
            searchText: searchText,
            installedModules: installedModules,
            downloadActivities: downloadActivities,
            recommendedDocuments: recommendedDocuments,
            badDocuments: badDocuments
        )
    }

    // MARK: - Body

    /**
     Builds the filtered Android-style download list and repository-management toolbar actions.
     */
    public var body: some View {
        List {
            // Category picker
            Section {
                Picker("Category", selection: $selectedCategory) {
                    Text(String(localized: "doc_type_all", defaultValue: "All types"))
                        .tag(Optional<ModuleCategory>.none)
                    Text(String(localized: "bibles")).tag(Optional(ModuleCategory.bible))
                    Text(String(localized: "commentaries")).tag(Optional(ModuleCategory.commentary))
                    Text(String(localized: "dictionaries")).tag(Optional(ModuleCategory.dictionary))
                    Text(String(localized: "category_books")).tag(Optional(ModuleCategory.generalBook))
                    Text(String(localized: "maps", defaultValue: "Maps")).tag(Optional(ModuleCategory.map))
                }
                .pickerStyle(.segmented)
                .onChange(of: selectedCategory) {
                    // Reset language filter when category changes
                    selectedLanguage = ""
                }
            }

            // Language filter
            if !availableLanguages.isEmpty {
                Section {
                    Picker("Language", selection: $selectedLanguage) {
                        Text(String(localized: "all_languages_count \(availableLanguages.count)"))
                            .tag("")
                        ForEach(availableLanguages, id: \.self) { lang in
                            Text(displayName(for: lang))
                                .tag(lang)
                        }
                    }
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            if isLoadingInitialState || isRefreshing {
                Section {
                    VStack(spacing: 8) {
                        ProgressView()
                        if let refreshProgress {
                            Text(refreshProgress)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if isLoadingInitialState {
                            Text(String(localized: "loading", defaultValue: "Loading..."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(String(localized: "refreshing_catalog"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            } else if filteredAvailableModules.isEmpty && !availableModules.isEmpty {
                Section {
                    Text(String(localized: "no_modules_match_filters"))
                        .foregroundStyle(.secondary)
                }
            } else if !filteredAvailableModules.isEmpty {
                Section(String(localized: "document_filter_results \(filteredAvailableModules.count)")) {
                    ForEach(filteredAvailableModules) { module in
                        remoteModuleRow(module)
                    }
                }
            } else if availableModules.isEmpty && !isRefreshing && !isLoadingInitialState {
                Section {
                    VStack(spacing: 8) {
                        Text(String(localized: "tap_refresh_to_load"))
                            .foregroundStyle(.secondary)
                        Button(String(localized: "refresh_catalog")) {
                            refreshCatalog()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical)
                }
            }
        }
        .accessibilityIdentifier("moduleBrowserScreen")
        .searchable(text: $searchText, prompt: String(localized: "search_modules"))
        .onChange(of: searchText) {
            alignFiltersWithAndroidSearchState(searchText)
        }
        .navigationTitle(String(localized: "downloads"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 12) {
                    NavigationLink {
                        RepositoryManagerView()
                    } label: {
                        Image(systemName: "server.rack")
                    }
                    .accessibilityIdentifier("moduleBrowserRepositoriesButton")
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        refreshCatalog()
                    }
                    .disabled(isRefreshing || isLoadingInitialState)
                }
            }
        }
        .task {
            await loadInitialStateIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: RepositorySourceManager.sourcesDidChangeNotification)) { _ in
            Task { @MainActor in
                reloadRepositorySources()
            }
        }
    }

    // MARK: - Row Views

    /**
     Tests whether a module category is visible under the current Android-parity type filter.

     - Parameter category: Module category from installed or remote catalog metadata.
     - Returns: `true` when the selected filter is "All types" or matches the supplied category.

     The helper is deterministic and performs no side effects. It exists so installed, available,
     and language filters all interpret the optional category state identically.

     Failure modes:
     - none; unknown future categories only match an identical selected enum value
     */
    private func matchesSelectedCategory(_ category: ModuleCategory) -> Bool {
        selectedCategory.map { $0 == category } ?? true
    }

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
    }

    /**
     Builds one row for a remotely available module with install-state affordances.

     - Parameter module: Remote module metadata to render.
     - Returns: A row showing remote source metadata and an install affordance when applicable.
     */
    private func remoteModuleRow(_ module: RemoteModuleInfo) -> some View {
        let status = Self.displayStatus(
            for: module,
            installedModules: installedModules,
            downloadActivities: downloadActivities
        )
        let isRecommended = recommendedDocuments?.contains(module) == true
        let badAction = badDocuments?.badDocumentAction(for: module) ?? .none

        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(module.name)
                    .font(.headline)
                Text(module.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(module.isInstallable ? 2 : 3)
                HStack(spacing: 4) {
                    Text(displayName(for: module.language))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(module.sourceName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if let installSize = Self.installSizeText(for: module.installSizeBytes) {
                        Text(installSize)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 6) {
                    if isRecommended {
                        Label(String(localized: "recommended_document"), systemImage: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    if badAction == .warn {
                        Label(String(localized: "bad_document_warning"), systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
                if case let .errorDownloading(message) = status {
                    Text(message.isEmpty ? String(localized: "error_download_failed") : message)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer()

            switch status {
            case .installed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .beingInstalled(let progressPercent):
                VStack(alignment: .trailing, spacing: 6) {
                    Text("\(progressPercent)%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ProgressView(value: Double(progressPercent), total: 100)
                        .frame(width: 76)
                    Button {
                        cancelInstall(module.name)
                    } label: {
                        Label(String(localized: "cancel"), systemImage: "arrow.uturn.backward.circle")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(String(localized: "cancel"))
                }
            case .errorDownloading:
                VStack(alignment: .trailing, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Button(String(localized: "retry", defaultValue: "Retry")) {
                        installModule(module)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            case .updateAvailable:
                Button(String(localized: "update")) {
                    installModule(module)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            case .unavailable:
                Label(String(localized: "unavailable"), systemImage: "lock.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .installable:
                Button(String(localized: "install_module", defaultValue: "Install")) {
                    installModule(module)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if installedModuleNames.contains(module.name) {
                Button(role: .destructive) {
                    uninstallModule(module.name)
                } label: {
                    Label(String(localized: "uninstall"), systemImage: "trash")
                }
            }
        }
        .contextMenu {
            if installedModuleNames.contains(module.name) {
                Button(role: .destructive) {
                    uninstallModule(module.name)
                } label: {
                    Label(String(localized: "uninstall"), systemImage: "trash")
                }
            }
        }
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
            if let selectedCategory, module.category != selectedCategory {
                return false
            }
            if !selectedLanguage.isEmpty, module.language != selectedLanguage {
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
        modules.sorted { lhs, rhs in
            let lhsStatus = displayStatus(
                for: lhs,
                installedModules: installedModules,
                downloadActivities: downloadActivities
            )
            let rhsStatus = displayStatus(
                for: rhs,
                installedModules: installedModules,
                downloadActivities: downloadActivities
            )
            let lhsStatusRank = statusSortRank(lhsStatus)
            let rhsStatusRank = statusSortRank(rhsStatus)
            if lhsStatusRank != rhsStatusRank {
                return lhsStatusRank < rhsStatusRank
            }

            let lhsInstalled = installedModules.contains { $0.name == lhs.name }
            let rhsInstalled = installedModules.contains { $0.name == rhs.name }
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
        guard let installedModule = installedModules.first(where: { $0.name == module.name }) else {
            return .installable
        }
        if isRemoteVersionNewer(remoteVersion: module.version, installedVersion: installedModule.version) {
            return .updateAvailable
        }
        return .installed
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
     Reloads locally installed modules from the active `SwordManager`.

     Side effects:
     - replaces the local `installedModules` array when a manager is available

     Failure modes:
     - returns without mutating state when `swordManager` has not been initialized yet
     */
    private func refreshInstalledList() {
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

        defaultDownloadInstallingModules.formUnion(moduleNames)
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
                    errorMessage = "No remote sources configured."
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
            errorMessage = module.unavailableReason ?? "\(module.name) is not available for installation."
            markDefaultDownloadModuleFinishedIfNeeded(module.name)
            return
        }

        guard installTasks[module.name] == nil else {
            return
        }

        guard let source = sources.first(where: { $0.name == module.sourceName }) ?? repository.source(for: module.name) else {
            errorMessage = "Source not found for \(module.name)"
            markDefaultDownloadModuleFinishedIfNeeded(module.name)
            return
        }

        let installID = UUID()
        downloadActivities[module.name] = .inProgress(0)
        installTaskIDs[module.name] = installID
        errorMessage = nil

        let task = Task {
            await Task.yield()
            do {
                try await repository.installModule(named: module.name, from: source) { progress in
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
                    markDefaultDownloadModuleFinishedIfNeeded(module.name)
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
                        errorMessage = "Install failed: \(message)"
                    }
                    markDefaultDownloadModuleFinishedIfNeeded(module.name)
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

     Failure modes:
     - missing or already-finished tasks are ignored
     */
    private func cancelInstall(_ moduleName: String) {
        installTasks[moduleName]?.cancel()
        installTasks[moduleName] = nil
        installTaskIDs[moduleName] = nil
        downloadActivities[moduleName] = nil
        markDefaultDownloadModuleFinishedIfNeeded(moduleName)
    }

    /**
     Marks one startup default module done and finishes the default flow when none remain.

     - Parameter moduleName: Module initials for the completed or skipped default install.

     Side effects:
     - removes `moduleName` from `defaultDownloadInstallingModules`
     - invokes `onDefaultDownloadActivityChanged(false)` once the startup default set is exhausted

     Failure modes:
     - ignored for normal Downloads sessions where default-download mode is disabled
     */
    private func markDefaultDownloadModuleFinishedIfNeeded(_ moduleName: String) {
        guard defaultDownloadMode.shouldInstallDefaultDocuments else {
            return
        }

        defaultDownloadInstallingModules.remove(moduleName)
        if defaultDownloadInstallingModules.isEmpty {
            finishDefaultDownloadActivityIfNeeded()
        }
    }

    /**
     Reports that startup default refresh/install activity is no longer active.

     Side effects:
     - clears `defaultDownloadInstallingModules`
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
     Uninstalls one locally installed module and refreshes the installed-module list.

     - Parameter name: Module name to remove from the local SWORD module store.

     Side effects:
     - invokes repository-backed uninstall file I/O
     - rebuilds the local SWORD manager and installed-module cache after a successful uninstall
     - records uninstall failures in `errorMessage`

     Failure modes:
     - repository uninstall errors are caught and surfaced through `errorMessage`
     */
    private func uninstallModule(_ name: String) {
        do {
            try repository.uninstallModule(named: name)
            swordManager = SwordManager()
            refreshInstalledList()
        } catch {
            errorMessage = "Uninstall failed: \(error.localizedDescription)"
        }
    }
}
