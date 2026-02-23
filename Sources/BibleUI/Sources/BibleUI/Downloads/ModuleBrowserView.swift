// ModuleBrowserView.swift — Module download browser

import SwiftUI
import BibleCore
import SwordKit

/// Browse and download Bible modules from remote repositories.
public struct ModuleBrowserView: View {
    @State private var selectedCategory: ModuleCategory = .bible
    @State private var selectedLanguage: String = ""
    @State private var searchText = ""
    @State private var isRefreshing = false
    @State private var availableModules: [RemoteModuleInfo] = []
    @State private var installedModules: [ModuleInfo] = []
    @State private var swordManager: SwordManager?
    @State private var repository = ModuleRepository()
    @State private var sources: [SourceConfig] = []
    @State private var installingModules: Set<String> = []
    @State private var errorMessage: String?
    @State private var refreshProgress: String?

    public init() {}

    // MARK: - Computed Properties

    /// All unique languages from available + installed modules, sorted by display name.
    /// English is placed first, then alphabetical by resolved name, then unresolved codes last.
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

    public var body: some View {
        List {
            // Category picker
            Section {
                Picker("Category", selection: $selectedCategory) {
                    Text("Bibles").tag(ModuleCategory.bible)
                    Text("Commentaries").tag(ModuleCategory.commentary)
                    Text("Dictionaries").tag(ModuleCategory.dictionary)
                    Text("Books").tag(ModuleCategory.generalBook)
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
                        Text("All Languages (\(availableLanguages.count))")
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
                            Text("Refreshing catalog...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            } else if filteredAvailableModules.isEmpty && !availableModules.isEmpty {
                Section {
                    Text("No modules match your filters")
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
                        Text("Tap Refresh to load available modules")
                            .foregroundStyle(.secondary)
                        Button("Refresh Catalog") {
                            refreshCatalog()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical)
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search modules")
        .navigationTitle("Downloads")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 12) {
                    NavigationLink {
                        RepositoryManagerView()
                    } label: {
                        Image(systemName: "server.rack")
                    }
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

    /// Convert a language code to a display name (e.g., "en" → "English").
    /// Handles ISO 639-1 ("en"), 639-3 ("aai"), and script variants ("abq-Cyrl").
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

    private func refreshInstalledList() {
        guard let mgr = swordManager else { return }
        installedModules = mgr.installedModules()
    }

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
