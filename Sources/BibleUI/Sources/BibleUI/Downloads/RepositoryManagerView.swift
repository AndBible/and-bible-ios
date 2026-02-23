// RepositoryManagerView.swift — Repository source management

import SwiftUI
import SwiftData
import BibleCore
import SwordKit

/// Manage module repository sources (add, remove, enable/disable).
public struct RepositoryManagerView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var sources: [SourceConfig] = []
    @State private var disabledSources: Set<String> = []
    @State private var showAddSource = false
    @State private var showResetConfirm = false
    @State private var newSourceName = ""
    @State private var newSourceHost = ""
    @State private var newSourcePath = ""

    public init() {}

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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "add"), systemImage: "plus") {
                    showAddSource = true
                }
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

    private var enabledCount: Int {
        sources.filter { !disabledSources.contains($0.name) }.count
    }

    // MARK: - Source Row

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

                Text(source.type)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(Capsule())
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            toggleSource(source)
        }
        .swipeActions(edge: .trailing) {
            Button(String(localized: "delete"), role: .destructive) {
                deleteSource(source)
            }
        }
    }

    // MARK: - Add Source View

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
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "cancel")) {
                    clearAddForm()
                    showAddSource = false
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "add")) {
                    addSource()
                    showAddSource = false
                }
                .disabled(newSourceName.isEmpty || newSourceHost.isEmpty || newSourcePath.isEmpty)
            }
        }
    }

    // MARK: - Actions

    private func loadSources() {
        let repo = ModuleRepository()
        sources = repo.loadSources()
    }

    private func loadDisabledSources() {
        let key = "disabledRepositorySources"
        if let saved = UserDefaults.standard.array(forKey: key) as? [String] {
            disabledSources = Set(saved)
        }
    }

    private func saveDisabledSources() {
        let key = "disabledRepositorySources"
        UserDefaults.standard.set(Array(disabledSources), forKey: key)
    }

    private func toggleSource(_ source: SourceConfig) {
        if disabledSources.contains(source.name) {
            disabledSources.remove(source.name)
        } else {
            disabledSources.insert(source.name)
        }
        saveDisabledSources()
    }

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

    private func clearAddForm() {
        newSourceName = ""
        newSourceHost = ""
        newSourcePath = ""
    }
}
