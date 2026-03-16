// ModuleBrowserView.swift — Module download browser

import SwiftUI
import BibleCore
import SwordKit

/**
 Browses installed and remote SWORD modules, then coordinates install and uninstall actions.

 The view combines locally installed module metadata from `SwordManager` with cached or refreshed
 remote catalogs from `ModuleRepository`, and lets the user filter both sets by category,
 language, and free-text search.

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
   `SwordManager`, and refreshes the installed-module list shown in the UI
 */
public struct ModuleBrowserView: View {
    /// Selected remote/local module category segment.
    @State private var selectedCategory: ModuleCategory = .bible

    /// Selected language filter, or an empty string when all languages should be shown.
    @State private var selectedLanguage: String = ""

    /// Free-text query applied to both installed and available module lists.
    @State private var searchText = ""

    /// Whether a remote catalog refresh is currently in progress.
    @State private var isRefreshing = false

    /// De-duplicated remote modules loaded from configured sources or the local cache.
    @State private var availableModules: [RemoteModuleInfo] = []

    /// Installed module metadata resolved from the current local SWORD manager.
    @State private var installedModules: [ModuleInfo] = []

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
     Creates the module browser with empty local state.

     - Note: The view resolves installed modules and repository data lazily in `onAppear`.
     */
    public init() {}

    // MARK: - Computed Properties

    /**
     All unique languages from available and installed modules, sorted by display name.

     English is placed first, then alphabetical by resolved name, then unresolved codes last.
     */
    private var availableLanguages: [String] {
        var langs = Set<String>()
        for m in availableModules where m.category == selectedCategory {
            langs.insert(m.language)
        }
        for m in installedModules where m.category == selectedCategory {
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

    /// Installed modules filtered by category, language, and search text.
    private var filteredInstalledModules: [ModuleInfo] {
        var modules = installedModules.filter { $0.category == selectedCategory }
        if !selectedLanguage.isEmpty {
            modules = modules.filter { $0.language == selectedLanguage }
        }
        if !searchText.isEmpty {
            modules = modules.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.description.localizedCaseInsensitiveContains(searchText) ||
                $0.language.localizedCaseInsensitiveContains(searchText)
            }
        }
        return modules.sorted { $0.name < $1.name }
    }

    /// Available (remote) modules filtered by category, language, and search text.
    private var filteredAvailableModules: [RemoteModuleInfo] {
        var modules = availableModules.filter { $0.category == selectedCategory }
        if !selectedLanguage.isEmpty {
            modules = modules.filter { $0.language == selectedLanguage }
        }
        if !searchText.isEmpty {
            modules = modules.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.description.localizedCaseInsensitiveContains(searchText) ||
                $0.language.localizedCaseInsensitiveContains(searchText)
            }
        }
        return modules.sorted { $0.name < $1.name }
    }

    // MARK: - Body

    /**
     Builds the filtered installed-module list, remote catalog list, and repository-management
     toolbar actions.
     */
    public var body: some View {
        List {
            // Category picker
            Section {
                Picker("Category", selection: $selectedCategory) {
                    Text(String(localized: "bibles")).tag(ModuleCategory.bible)
                    Text(String(localized: "commentaries")).tag(ModuleCategory.commentary)
                    Text(String(localized: "dictionaries")).tag(ModuleCategory.dictionary)
                    Text(String(localized: "category_books")).tag(ModuleCategory.generalBook)
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

            // Installed modules (filtered)
            if !filteredInstalledModules.isEmpty {
                Section("Installed (\(filteredInstalledModules.count))") {
                    ForEach(filteredInstalledModules) { module in
                        installedModuleRow(module)
                    }
                }
            }

            // Available modules
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
                Section("Available (\(filteredAvailableModules.count))") {
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
     Builds one row for a locally installed module with removal controls.

     - Parameter module: Installed module metadata to render.
     - Returns: A row showing install state, summary metadata, and a remove action.
     */
    private func installedModuleRow(_ module: ModuleInfo) -> some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(module.name)
                    .font(.body)
                Text(module.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(displayName(for: module.language))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if !module.version.isEmpty {
                        Text("v\(module.version)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
            Button("Remove", role: .destructive) {
                uninstallModule(module.name)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    /**
     Builds one row for a remotely available module with install-state affordances.

     - Parameter module: Remote module metadata to render.
     - Returns: A row showing remote source metadata and an install affordance when applicable.
     */
    private func remoteModuleRow(_ module: RemoteModuleInfo) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(module.name)
                    .font(.headline)
                Text(module.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Text(displayName(for: module.language))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(module.sourceName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if installedModuleNames.contains(module.name) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if installingModules.contains(module.name) {
                ProgressView()
            } else {
                Button("Install") {
                    installModule(module)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
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

    // MARK: - Data Management

    /**
     Initializes the local SWORD manager, repository sources, and cached catalog state.

     Side effects:
     - creates a `SwordManager` instance the first time the view appears
     - loads configured remote sources from repository storage
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
        refreshInstalledList()

        // Load cached catalog from disk if available modules are empty
        if availableModules.isEmpty {
            let cached = repository.loadCachedCatalogs()
            if !cached.isEmpty {
                // De-duplicate
                var seen: Set<String> = []
                var unique: [RemoteModuleInfo] = []
                for m in cached {
                    if seen.insert(m.name).inserted {
                        unique.append(m)
                    }
                }
                availableModules = unique
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

            // De-duplicate modules (same name from different sources — keep first)
            var seen: Set<String> = []
            var uniqueModules: [RemoteModuleInfo] = []
            for module in allModules {
                if seen.insert(module.name).inserted {
                    uniqueModules.append(module)
                }
            }

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
