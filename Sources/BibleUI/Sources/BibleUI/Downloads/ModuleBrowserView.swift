// ModuleBrowserView.swift — Module download browser

import SwiftUI
import BibleCore
import SwordKit

/**
 Android download-row status used by `ModuleBrowserView`.

 The enum mirrors Android `DocumentStatus.DocumentInstallStatus` closely enough for sorting and
 row controls: in-progress rows sort first, updates sort before already-installed rows, installed
 rows show completed state, unavailable pseudo rows stay visible but disabled, and installable rows
 expose the normal install action.
 */
enum ModuleBrowserDownloadStatus: Equatable {
    /// The module is currently being installed.
    case beingInstalled

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
 - installing or uninstalling a module mutates the local module store on disk, rebuilds the
   `SwordManager`, and refreshes the installed state shown in the download rows
 */
public struct ModuleBrowserView: View {
    /// Selected remote/local module category segment, or `nil` for Android's "All types" filter.
    @State private var selectedCategory: ModuleCategory? = .bible

    /// Selected language filter, or an empty string when all languages should be shown.
    @State private var selectedLanguage: String = ""

    /// Free-text query applied to the Android-style download list.
    @State private var searchText = ""

    /// Whether a remote catalog refresh is currently in progress.
    @State private var isRefreshing = false

    /// De-duplicated remote modules loaded from configured sources or the local cache.
    @State private var availableModules: [RemoteModuleInfo] = []

    /// Installed module metadata resolved from the current local SWORD manager.
    @State private var installedModules: [ModuleInfo] = []

    /// Android recommended-document metadata used for badges and language-specific ordering.
    @State private var recommendedDocuments: ModuleDownloadConfiguration?

    /// Android bad-document metadata used to hide or warn about known problematic modules.
    @State private var badDocuments: ModuleDownloadConfiguration?

    /// Lazily created SWORD manager used to query locally installed modules.
    @State private var swordManager: SwordManager?

    /// Repository facade used for source loading, catalog refresh, and install actions.
    @State private var repository = ModuleRepository()

    /// Configured remote source definitions loaded from repository configuration.
    @State private var sources: [SourceConfig] = []

    /// Module names currently being installed so duplicate install actions can be suppressed.
    @State private var installingModules: Set<String> = []

    /// User-visible error text for refresh, install, or uninstall failures.
    @State private var errorMessage: String?

    /// Progress text describing which remote source is being refreshed.
    @State private var refreshProgress: String?

    /**
     Creates the module browser with optional Android-compatible search state.

     - Parameter initialSearchText: Optional module initials that should pre-populate search.
       Empty or whitespace-only values are normalized to an empty query. A non-empty value starts
       on Android's "All types" category so Bibles, commentaries, dictionaries, and books can all
       satisfy a module-initials link.

     Side effects:
     - initializes local SwiftUI state only; repository and installed-module data are still loaded
       lazily in `onAppear`

     Failure modes:
     - invalid or unknown initials simply behave as a free-text all-types search with no matching
       rows until catalog data contains that module
     */
    public init(initialSearchText: String = "") {
        let normalizedSearchText = initialSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        _selectedCategory = State(initialValue: normalizedSearchText.isEmpty ? .bible : nil)
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
            installingModules: installingModules,
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

            if isRefreshing {
                Section {
                    VStack(spacing: 8) {
                        ProgressView()
                        if let refreshProgress {
                            Text(refreshProgress)
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
            } else if availableModules.isEmpty && !isRefreshing {
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
                    .disabled(isRefreshing)
                }
            }
        }
        .onAppear {
            setupManagers()
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
            installingModules: installingModules
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
            }

            Spacer()

            switch status {
            case .installed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .beingInstalled:
                ProgressView()
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
                Button(String(localized: "install")) {
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
     Filters and sorts remote modules using Android `DocumentSelectionBase.filterDocuments`
     semantics adapted to iOS data models.

     - Parameters:
       - modules: Complete remote/pseudo module catalog.
       - selectedCategory: Selected document type, or `nil` for all types.
       - selectedLanguage: Selected language code, or empty for all languages.
       - searchText: Free-text query applied to initials, description, language, and source.
       - installedModules: Current installed modules used for status and update sorting.
       - installingModules: Module initials currently being installed.
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
        installingModules: Set<String>,
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
            installingModules: installingModules,
            selectedLanguage: selectedLanguage,
            recommendedDocuments: recommendedDocuments
        )
    }

    /**
     Sorts remote download rows according to Android's document list priorities.

     - Parameters:
       - modules: Already-filtered remote rows.
       - installedModules: Installed modules used to detect installed/update state.
       - installingModules: Module initials currently being installed.
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
        installingModules: Set<String>,
        selectedLanguage: String,
        recommendedDocuments: ModuleDownloadConfiguration?
    ) -> [RemoteModuleInfo] {
        modules.sorted { lhs, rhs in
            let lhsStatus = displayStatus(for: lhs, installedModules: installedModules, installingModules: installingModules)
            let rhsStatus = displayStatus(for: rhs, installedModules: installedModules, installingModules: installingModules)
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
       - installingModules: Module initials currently being installed.
     - Returns: Status used for row affordances and sort order.

     Side effects:
     - none

     Failure modes:
     - invalid or absent version strings fall back to non-update installed state
     */
    static func displayStatus(
        for module: RemoteModuleInfo,
        installedModules: [ModuleInfo],
        installingModules: Set<String>
    ) -> ModuleBrowserDownloadStatus {
        if installingModules.contains(module.name) {
            return .beingInstalled
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
        case .installable, .unavailable:
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
     Initializes the local SWORD manager, repository sources, and cached catalog state.

     Side effects:
     - creates a `SwordManager` instance the first time the view appears
     - loads configured remote sources from repository storage
     - restores cached Android recommended/bad metadata for row badges and filtering
     - refreshes the installed-module list from the local module directory
     - restores cached remote catalogs when no in-memory catalog has been loaded yet
     */
    private func setupManagers() {
        if swordManager == nil {
            swordManager = SwordManager()
        }
        if sources.isEmpty {
            sources = repository.loadSources()
        }
        if recommendedDocuments == nil {
            recommendedDocuments = repository.loadCachedRecommendedDocuments()
        }
        if badDocuments == nil {
            badDocuments = repository.loadCachedBadDocuments()
        }
        refreshInstalledList()

        // Load cached catalog from disk if available modules are empty
        if availableModules.isEmpty {
            let cached = repository.loadCachedCatalogs() + repository.loadCachedPseudoModules()
            if !cached.isEmpty {
                availableModules = deduplicatedModules(from: cached)
            }
        }
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
     Refreshes all configured remote catalogs and updates the filtered module list.

     Side effects:
     - marks the view as refreshing, clears stale error text, and updates progress copy while each
       source is fetched
     - refreshes Android pseudo, recommended, bad, and default metadata, falling back to caches
     - merges and de-duplicates the refreshed module set before storing it in `availableModules`
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
            if sourcesToRefresh.isEmpty {
                await MainActor.run {
                    errorMessage = "No remote sources configured."
                    isRefreshing = false
                }
                return
            }

            var allModules: [RemoteModuleInfo] = []
            var errors: [String] = []
            let total = sourcesToRefresh.count

            for (index, source) in sourcesToRefresh.enumerated() {
                await MainActor.run {
                    refreshProgress = "Refreshing \(source.name) (\(index + 1)/\(total))..."
                }

                do {
                    let modules = try await repository.refreshCatalog(for: source)
                    allModules.append(contentsOf: modules)
                } catch {
                    errors.append("\(source.name): \(error.localizedDescription)")
                }
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

            do {
                _ = try await repository.refreshDefaultDocuments()
            } catch {
                // Defaults are cached opportunistically until #133 consumes them.
                _ = repository.loadCachedDefaultDocuments()
            }

            let uniqueModules = deduplicatedModules(from: allModules)

            await MainActor.run {
                availableModules = uniqueModules
                isRefreshing = false
                refreshProgress = nil

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
     - records the module name in `installingModules` so the UI can show progress
     - performs repository installation work and, on success, rebuilds local SWORD state before
       refreshing the installed-module list
     - surfaces installation failures in `errorMessage`

     Failure modes:
     - if the matching source cannot be resolved, sets a user-visible error and returns
     - repository installation errors are caught and reported without crashing the view
     */
    private func installModule(_ module: RemoteModuleInfo) {
        guard module.isInstallable else {
            errorMessage = module.unavailableReason ?? "\(module.name) is not available for installation."
            return
        }

        guard let source = repository.source(for: module.name) ?? sources.first(where: { $0.name == module.sourceName }) else {
            errorMessage = "Source not found for \(module.name)"
            return
        }

        installingModules.insert(module.name)
        errorMessage = nil

        Task {
            do {
                try await repository.installModule(named: module.name, from: source)

                await MainActor.run {
                    installingModules.remove(module.name)
                    swordManager = SwordManager()
                    refreshInstalledList()
                }
            } catch {
                await MainActor.run {
                    installingModules.remove(module.name)
                    errorMessage = "Install failed: \(error.localizedDescription)"
                }
            }
        }
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
