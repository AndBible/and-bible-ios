// RepositoryManagerView.swift — Repository source management

import SwiftUI
import SwiftData
import BibleCore
import SwordKit

/**
 Manages remote SWORD repository sources used by the downloads browser.

 The view reads repository definitions from `InstallMgr.conf`, lets the user enable or disable
 individual sources for catalog refresh, supports adding custom HTTP sources, and can reset the
 source list back to the default packaged configuration.

 Data dependencies:
 - `ModuleRepository` is used indirectly to read the current source configuration from disk
 - `UserDefaults` stores the set of user-disabled repository names
 - `InstallManager` resolves and mutates the underlying `InstallMgr.conf` file used by SWORD

 Side effects:
 - `onAppear` loads both repository configuration and disabled-source preferences
 - add, delete, toggle, and reset actions mutate on-disk repository configuration or
   `UserDefaults`, then reload local state from those persisted sources
 - resetting sources deletes the current config file and recreates the default source set
 */
public struct RepositoryManagerView: View {
    /// SwiftData context inherited from the parent environment.
    @Environment(\.modelContext) private var modelContext

    /// All configured repository sources loaded from `InstallMgr.conf`.
    @State private var sources: [SourceConfig] = []

    /// Repository names the user has disabled in local preferences.
    @State private var disabledSources: Set<String> = []

    /// Whether the add-source sheet is currently presented.
    @State private var showAddSource = false

    /// Whether the destructive reset confirmation alert is currently presented.
    @State private var showResetConfirm = false

    /// Pending custom source display name entered in the add-source form.
    @State private var newSourceName = ""

    /// Pending custom source host entered in the add-source form.
    @State private var newSourceHost = ""

    /// Pending custom source catalog path entered in the add-source form.
    @State private var newSourcePath = ""

    /**
     Creates the repository manager with empty local state.

     - Note: Repository configuration is loaded lazily in `onAppear`.
     */
    public init() {}

    /**
     Builds the repository list, add-source sheet, and reset-to-defaults controls.
     */
    public var body: some View {
        List {
            if sources.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Text(String(localized: "no_sources_configured"))
                            .foregroundStyle(.secondary)
                        Button(String(localized: "reset_to_defaults")) {
                            resetToDefaults()
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical)
                }
            } else {
                Section {
                    ForEach(sources) { source in
                        sourceRow(source)
                    }
                } header: {
                    Text(String(localized: "remote_sources"))
                } footer: {
                    Text(String(localized: "sources_count_\(sources.count)_\(enabledCount)"))
                }

                Section {
                    Button(String(localized: "reset_to_defaults"), role: .destructive) {
                        showResetConfirm = true
                    }
                }
            }
        }
        .navigationTitle(String(localized: "repositories"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("repositoryManagerScreen")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "add"), systemImage: "plus") {
                    showAddSource = true
                }
                .accessibilityIdentifier("repositoryManagerAddButton")
            }
        }
        .sheet(isPresented: $showAddSource) {
            NavigationStack {
                addSourceView
            }
            .presentationDetents([.medium])
        }
        .alert(String(localized: "reset_sources_title"), isPresented: $showResetConfirm) {
            Button(String(localized: "reset"), role: .destructive) {
                resetToDefaults()
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "reset_sources_message"))
        }
        .onAppear {
            loadSources()
            loadDisabledSources()
        }
    }

    /// Number of non-FTP sources currently enabled for refresh.
    private var enabledCount: Int {
        sources.filter { !disabledSources.contains($0.name) && $0.type != "FTP" }.count
    }

    /// Whether the pending custom host indicates an unsupported FTP source.
    private var isFTPHost: Bool {
        let host = newSourceHost.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return host.hasPrefix("ftp://") || host.hasPrefix("ftp.")
    }

    // MARK: - Source Row

    /**
     Builds one repository row with enable/disable and destructive-delete affordances.

     - Parameter source: Source definition to render.
     - Returns: A row showing source metadata, support state, and local management actions.
     */
    private func sourceRow(_ source: SourceConfig) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: disabledSources.contains(source.name) ? "circle" : "checkmark.circle.fill")
                    .foregroundStyle(disabledSources.contains(source.name) ? Color.secondary : Color.green)

                VStack(alignment: .leading) {
                    Text(source.name)
                        .font(.body)
                        .foregroundStyle(disabledSources.contains(source.name) ? .secondary : .primary)
                    Text("\(source.host)\(source.catalogPath)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if source.type == "FTP" {
                    Text(String(localized: "ftp_unsupported"))
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red.opacity(0.1))
                        .clipShape(Capsule())
                } else {
                    Text(source.type)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(Capsule())
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard source.type != "FTP" else { return }
            toggleSource(source)
        }
        .swipeActions(edge: .trailing) {
            Button(String(localized: "delete"), role: .destructive) {
                deleteSource(source)
            }
        }
    }

    // MARK: - Add Source View

    /**
     Builds the modal form used to create one custom HTTP source.
     */
    private var addSourceView: some View {
        Form {
            Section(String(localized: "source_details")) {
                TextField(String(localized: "source_name_placeholder"), text: $newSourceName)
                    .textContentType(.organizationName)
                    #if os(iOS)
                    .autocapitalization(.words)
                    #endif
                TextField(String(localized: "source_host_placeholder"), text: $newSourceHost)
                    .textContentType(.URL)
                    #if os(iOS)
                    .autocapitalization(.none)
                    .keyboardType(.URL)
                    #endif
                TextField(String(localized: "source_path_placeholder"), text: $newSourcePath)
                    #if os(iOS)
                    .autocapitalization(.none)
                    #endif
            }

            if isFTPHost {
                Section {
                    SwiftUI.Label(String(localized: "ftp_not_supported_hint"), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Text(String(localized: "source_catalog_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(String(localized: "add_source"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("repositoryManagerAddSourceScreen")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "cancel")) {
                    clearAddForm()
                    showAddSource = false
                }
                .accessibilityIdentifier("repositoryManagerAddSourceCancelButton")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "add")) {
                    addSource()
                    showAddSource = false
                }
                .disabled(newSourceName.isEmpty || newSourceHost.isEmpty || newSourcePath.isEmpty || isFTPHost)
            }
        }
    }

    // MARK: - Actions

    /**
     Reloads repository definitions from the install-manager configuration file.

     Side effects:
     - replaces the local `sources` array with the current on-disk configuration
     */
    private func loadSources() {
        let repo = ModuleRepository()
        sources = repo.loadSources()
    }

    /**
     Loads the locally disabled repository names from `UserDefaults`.

     Side effects:
     - replaces the local `disabledSources` set when persisted values exist
     */
    private func loadDisabledSources() {
        let key = "disabledRepositorySources"
        if let saved = UserDefaults.standard.array(forKey: key) as? [String] {
            disabledSources = Set(saved)
        }
    }

    /**
     Persists the current disabled-source set to `UserDefaults`.

     Side effects:
     - writes the `disabledSources` set under the `disabledRepositorySources` preference key
     */
    private func saveDisabledSources() {
        let key = "disabledRepositorySources"
        UserDefaults.standard.set(Array(disabledSources), forKey: key)
    }

    /**
     Toggles one source between enabled and disabled states.

     - Parameter source: Source whose enabled state should be inverted.

     Side effects:
     - mutates the local `disabledSources` set
     - persists the updated disabled-source set to `UserDefaults`
     */
    private func toggleSource(_ source: SourceConfig) {
        if disabledSources.contains(source.name) {
            disabledSources.remove(source.name)
        } else {
            disabledSources.insert(source.name)
        }
        saveDisabledSources()
    }

    /**
     Deletes one custom or default source entry from `InstallMgr.conf`.

     - Parameter source: Source definition to remove from the persisted configuration.

     Side effects:
     - rewrites `InstallMgr.conf` without the selected source entry
     - removes the source from the disabled-source set and reloads local source state

     Failure modes:
     - returns without mutating persisted state if the config file cannot be read
     - file-write failures are ignored and will leave the current on-disk configuration unchanged
     */
    private func deleteSource(_ source: SourceConfig) {
        // Remove from config file
        let basePath = InstallManager.defaultBasePath()
        let configPath = (basePath as NSString).appendingPathComponent("InstallMgr.conf")

        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return }

        let lines = content.components(separatedBy: .newlines)
        let filteredLines = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Keep all lines except the one matching this source
            if trimmed.hasPrefix("HTTPSource=") || trimmed.hasPrefix("FTPSource=") {
                let parts = String(trimmed.drop(while: { $0 != "=" }).dropFirst())
                    .components(separatedBy: "|")
                return parts.first != source.name
            }
            return true
        }

        let newContent = filteredLines.joined(separator: "\n")
        try? newContent.write(toFile: configPath, atomically: true, encoding: .utf8)

        disabledSources.remove(source.name)
        saveDisabledSources()
        loadSources()
    }

    /**
     Appends one custom HTTP source to `InstallMgr.conf`.

     Side effects:
     - creates a default config skeleton when the file does not yet exist
     - appends the new source definition to the on-disk config, clears the add-source form, and
       reloads the source list

     Failure modes:
     - file-write failures are ignored, in which case the source list will reload without the new
       source being present
     */
    private func addSource() {
        let basePath = InstallManager.defaultBasePath()
        let configPath = (basePath as NSString).appendingPathComponent("InstallMgr.conf")

        // Read existing content
        var content = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? """
        [General]
        PassiveFTP=true

        [Sources]
        """

        // Append new source
        let path = newSourcePath.hasPrefix("/") ? newSourcePath : "/\(newSourcePath)"
        content += "\nHTTPSource=\(newSourceName)|\(newSourceHost)|\(path)"

        try? content.write(toFile: configPath, atomically: true, encoding: .utf8)

        clearAddForm()
        loadSources()
    }

    /**
     Restores the repository configuration file to the default packaged source set.

     Side effects:
     - deletes the current `InstallMgr.conf` file
     - clears disabled-source preferences and recreates the default source configuration
     - reloads the in-memory source list from the recreated config

     Failure modes:
     - deleting the existing config uses `try?`; if removal fails, the subsequent recreation step
       still runs and may overwrite or preserve the prior file depending on install-manager behavior
     */
    private func resetToDefaults() {
        // Delete the config file so ensureDefaultConfig recreates it
        let basePath = InstallManager.defaultBasePath()
        let configPath = (basePath as NSString).appendingPathComponent("InstallMgr.conf")
        try? FileManager.default.removeItem(atPath: configPath)

        // Clear disabled sources
        disabledSources = []
        saveDisabledSources()

        // Recreate defaults
        InstallManager.ensureDefaultConfigPublic(at: basePath)
        loadSources()
    }

    /**
     Clears the transient add-source form fields.

     Side effects:
     - resets the local add-source text fields back to empty strings
     */
    private func clearAddForm() {
        newSourceName = ""
        newSourceHost = ""
        newSourcePath = ""
    }
}
