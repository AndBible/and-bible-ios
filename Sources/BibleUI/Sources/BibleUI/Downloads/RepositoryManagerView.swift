// RepositoryManagerView.swift — Repository source management

import SwiftUI
import SwordKit

/**
 Manages Downloads repository sources with Android custom-repository parity.

 The screen separates built-in Android repositories from user-added custom repositories. Built-in
 normal, beta, and legacy FTP rows are read-only, while custom rows can be added, replaced, or
 deleted through the same HTTPS manifest/direct-catalog validation flow Android uses.

 Data dependencies:
 - `RepositorySourceManager` reads and mutates `InstallMgr.conf`
 - `InstallManager` classifies packaged Android default repositories through the manager
 - `openURL` opens the shared Android custom repositories help wiki

 Side effects:
 - `onAppear` loads the persisted source list
 - add, replace, delete, and reset actions rewrite `InstallMgr.conf` through `RepositorySourceManager`
 - help opens an external browser when the user chooses the wiki action
 */
public struct RepositoryManagerView: View {
    /// Opens the Android custom repository help URL when the help alert action is selected.
    @Environment(\.openURL) private var openURL

    /// Source-management service used for validation and config persistence.
    private let sourceManager: RepositorySourceManager

    /// All configured repository sources loaded from `InstallMgr.conf`.
    @State private var sources: [SourceConfig] = []

    /// Currently presented custom-source editor state, or `nil` when no editor sheet is open.
    @State private var editorState: RepositorySourceEditorState?

    /// Validation or persistence error shown inside the editor sheet.
    @State private var editorErrorMessage: String?

    /// Whether an add or replace request is currently validating remote HTTPS resources.
    @State private var isSavingSource = false

    /// Whether the destructive reset confirmation alert is currently presented.
    @State private var showResetConfirm = false

    /// Custom repository selected for destructive deletion confirmation.
    @State private var deletionCandidate: RepositorySourceDeletionCandidate?

    /// Whether the Android custom repositories help alert is currently presented.
    @State private var showHelp = false

    /// Last source-management error raised outside the editor sheet.
    @State private var sourceErrorMessage: String?

    /**
     Creates the repository manager with an injectable source-management service.

     - Parameter sourceManager: Service that owns source validation and `InstallMgr.conf` writes.

     Side effects:
     - none; repository configuration is loaded lazily in `onAppear`
     */
    public init(sourceManager: RepositorySourceManager = RepositorySourceManager()) {
        self.sourceManager = sourceManager
    }

    /**
     Builds the repository list, custom-source editor sheet, help, and reset controls.
     */
    public var body: some View {
        List {
            if sources.isEmpty {
                emptySourceSection
            } else {
                defaultRepositoriesSection
                customRepositoriesSection
                resetSection
            }
        }
        .navigationTitle(String(localized: "repositories", defaultValue: "Repositories"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("repositoryManagerScreen")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    beginAddingSource()
                } label: {
                    SwiftUI.Label(String(localized: "add", defaultValue: "Add"), systemImage: "plus")
                }
                .accessibilityIdentifier("repositoryManagerAddButton")
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    showHelp = true
                } label: {
                    SwiftUI.Label(String(localized: "help", defaultValue: "Help"), systemImage: "questionmark.circle")
                }
                .accessibilityIdentifier("repositoryManagerHelpButton")
            }
        }
        .sheet(item: $editorState) { _ in
            NavigationStack {
                sourceEditorView
            }
            .presentationDetents([.medium])
        }
        .alert(String(localized: "reset_sources_title", defaultValue: "Reset repositories"), isPresented: $showResetConfirm) {
            Button(String(localized: "reset", defaultValue: "Reset"), role: .destructive) {
                resetToDefaults()
            }
            Button(String(localized: "cancel", defaultValue: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(
                localized: "reset_sources_message",
                defaultValue: "Remove custom repositories and restore the built-in Android source list?"
            ))
        }
        .alert(item: $deletionCandidate) { candidate in
            Alert(
                title: Text(String(
                    localized: "delete_custom_repository_title",
                    defaultValue: "Delete repository"
                )),
                message: Text(String(
                    format: String(
                        localized: "delete_custom_repository_message_format",
                        defaultValue: "Delete %@?"
                    ),
                    candidate.source.name
                )),
                primaryButton: .destructive(Text(String(localized: "delete", defaultValue: "Delete"))) {
                    deleteSource(candidate.source)
                },
                secondaryButton: .cancel(Text(String(localized: "cancel", defaultValue: "Cancel")))
            )
        }
        .alert(String(localized: "custom_repositories", defaultValue: "Custom repositories"), isPresented: $showHelp) {
            Button(String(localized: "open_wiki", defaultValue: "Open Wiki")) {
                openURL(Self.customRepositoriesWikiURL)
            }
            Button(String(localized: "okay", defaultValue: "OK"), role: .cancel) {}
        } message: {
            Text(String(
                localized: "custom_repositories_help_summary",
                defaultValue: "Custom repositories use Android-compatible HTTPS manifests or direct SWORD catalog URLs."
            ))
        }
        .alert(
            String(localized: "repository_source_error", defaultValue: "Repository source error"),
            isPresented: sourceErrorPresented
        ) {
            Button(String(localized: "okay", defaultValue: "OK"), role: .cancel) {}
        } message: {
            Text(sourceErrorMessage ?? "")
        }
        .onAppear {
            loadSources()
        }
    }

    private static let customRepositoriesWikiURL = URL(
        string: "https://github.com/AndBible/and-bible/wiki/Custom-repositories"
    )!

    /// Sources that match Android's built-in normal, beta, or legacy FTP repositories.
    private var defaultSources: [SourceConfig] {
        sources.filter(sourceManager.isDefaultSource)
    }

    /// Sources that were added by the user and can be managed from this screen.
    private var customSources: [SourceConfig] {
        sources.filter { !sourceManager.isDefaultSource($0) }
    }

    /// Binding used by the source-error alert because SwiftUI alerts require a Boolean presenter.
    private var sourceErrorPresented: Binding<Bool> {
        Binding(
            get: { sourceErrorMessage != nil },
            set: { presented in
                if !presented {
                    sourceErrorMessage = nil
                }
            }
        )
    }

    /// Binding for the URL text field inside the optional editor state.
    private var editorURLBinding: Binding<String> {
        Binding(
            get: { editorState?.repositoryURL ?? "" },
            set: { newValue in
                if var current = editorState {
                    current.repositoryURL = newValue
                    editorState = current
                    editorErrorMessage = nil
                }
            }
        )
    }

    /// Whether the current editor URL is empty or a validation request is already in flight.
    private var editorSaveDisabled: Bool {
        editorState?.repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false || isSavingSource
    }

    // MARK: - Sections

    /**
     Builds the repair section shown when no source rows are available.
     */
    private var emptySourceSection: some View {
        Section {
            VStack(spacing: 12) {
                Text(String(localized: "no_sources_configured", defaultValue: "No repositories configured"))
                    .foregroundStyle(.secondary)
                Button(String(localized: "reset_to_defaults", defaultValue: "Reset to defaults")) {
                    resetToDefaults()
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical)
        }
    }

    /**
     Builds the read-only built-in repository section.
     */
    private var defaultRepositoriesSection: some View {
        Section {
            ForEach(defaultSources, id: \.repositoryManagerListID) { source in
                sourceRow(source, isCustom: false)
            }
        } header: {
            Text(String(localized: "default_repositories", defaultValue: "Default repositories"))
        }
    }

    /**
     Builds the custom repository section with edit and delete affordances.
     */
    private var customRepositoriesSection: some View {
        Section {
            if customSources.isEmpty {
                Button {
                    beginAddingSource()
                } label: {
                    SwiftUI.Label(
                        String(localized: "add_custom_repository", defaultValue: "Add custom repository"),
                        systemImage: "plus.circle"
                    )
                }
                .accessibilityIdentifier("repositoryManagerEmptyAddCustomButton")
            } else {
                ForEach(customSources, id: \.repositoryManagerListID) { source in
                    sourceRow(source, isCustom: true)
                }
            }
        } header: {
            Text(String(localized: "custom_repositories", defaultValue: "Custom repositories"))
        }
    }

    /**
     Builds the iOS repair action for restoring packaged defaults.
     */
    private var resetSection: some View {
        Section {
            Button(String(localized: "reset_to_defaults", defaultValue: "Reset to defaults"), role: .destructive) {
                showResetConfirm = true
            }
        }
    }

    // MARK: - Row Views

    /**
     Builds one repository row with Android-parity source metadata and custom-only actions.

     - Parameters:
       - source: Source definition to render.
       - isCustom: Whether edit/delete actions are available for the row.
     - Returns: A row showing repository name, URL, protocol support state, and management affordances.
     */
    private func sourceRow(_ source: SourceConfig, isCustom: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isCustom ? "globe" : "checkmark.seal.fill")
                .foregroundStyle(isCustom ? Color.accentColor : Color.green)

            VStack(alignment: .leading, spacing: 3) {
                Text(source.name)
                    .font(.body)
                Text(source.displayAddress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            sourceProtocolBadge(source)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isCustom {
                beginEditingSource(source)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if isCustom {
                Button(String(localized: "delete", defaultValue: "Delete"), role: .destructive) {
                    deletionCandidate = RepositorySourceDeletionCandidate(source: source)
                }
            }
        }
    }

    /**
     Builds the protocol/support badge for a repository row.

     - Parameter source: Source whose protocol should be shown.
     - Returns: A compact badge indicating HTTPS support or unsupported FTP state.
     */
    private func sourceProtocolBadge(_ source: SourceConfig) -> some View {
        Group {
            if source.type == "FTP" {
                Text(String(localized: "ftp_unsupported", defaultValue: "FTP unsupported"))
                    .foregroundStyle(.red)
                    .background(Color.red.opacity(0.1))
            } else {
                Text(String(localized: "https", defaultValue: "HTTPS"))
                    .foregroundStyle(.secondary)
                    .background(Color.secondary.opacity(0.1))
            }
        }
        .font(.caption2)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .clipShape(Capsule())
    }

    // MARK: - Source Editor

    /**
     Builds the add/replace sheet for custom repositories.
     */
    private var sourceEditorView: some View {
        Form {
            Section(String(localized: "repository_url", defaultValue: "Repository URL")) {
                TextField(
                    String(localized: "repository_url_placeholder", defaultValue: "https://example.org/repository"),
                    text: editorURLBinding
                )
                .textContentType(.URL)
                #if os(iOS)
                .autocapitalization(.none)
                .keyboardType(.URL)
                #endif
                .disabled(isSavingSource)
                .accessibilityIdentifier("repositoryManagerRepositoryURLField")
            }

            if isSavingSource {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(String(localized: "validating_repository", defaultValue: "Validating repository"))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let editorErrorMessage {
                Section {
                    SwiftUI.Label(editorErrorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle(editorState?.title ?? String(localized: "custom_repository", defaultValue: "Custom repository"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("repositoryManagerSourceEditorScreen")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "cancel", defaultValue: "Cancel")) {
                    closeEditor()
                }
                .disabled(isSavingSource)
                .accessibilityIdentifier("repositoryManagerSourceEditorCancelButton")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(editorState?.saveTitle ?? String(localized: "save", defaultValue: "Save")) {
                    saveEditorSource()
                }
                .disabled(editorSaveDisabled)
                .accessibilityIdentifier("repositoryManagerSourceEditorSaveButton")
            }
        }
    }

    // MARK: - Actions

    /**
     Reloads repository definitions from the source manager.

     Side effects:
     - replaces the local `sources` array with the current on-disk configuration
     */
    private func loadSources() {
        sources = sourceManager.loadSources()
    }

    /**
     Opens the editor for adding a new custom source.

     Side effects:
     - resets transient editor error state
     - presents the editor sheet
     */
    private func beginAddingSource() {
        editorErrorMessage = nil
        editorState = RepositorySourceEditorState(originalName: nil, repositoryURL: "")
    }

    /**
     Opens the editor for replacing an existing custom source.

     - Parameter source: Custom source whose persisted row should be replaced after validation.

     Side effects:
     - resets transient editor error state
     - presents the editor sheet with the source's current HTTPS catalog URL
     */
    private func beginEditingSource(_ source: SourceConfig) {
        editorErrorMessage = nil
        editorState = RepositorySourceEditorState(
            originalName: source.name,
            repositoryURL: source.editableURLString
        )
    }

    /**
     Dismisses the editor sheet and clears in-flight editor state.

     Side effects:
     - clears local editor state and validation errors
     */
    private func closeEditor() {
        editorState = nil
        editorErrorMessage = nil
        isSavingSource = false
    }

    /**
     Validates and persists the currently edited custom repository source.

     Side effects:
     - starts an asynchronous HTTPS validation request
     - writes `InstallMgr.conf` through `RepositorySourceManager` on success
     - reloads the local source list and dismisses the editor on success
     - keeps the editor open with an error message on failure
     */
    private func saveEditorSource() {
        guard let editorState else { return }
        isSavingSource = true
        editorErrorMessage = nil

        Task {
            do {
                if let originalName = editorState.originalName {
                    try await sourceManager.replaceCustomSource(
                        named: originalName,
                        with: editorState.repositoryURL
                    )
                } else {
                    try await sourceManager.addCustomSource(from: editorState.repositoryURL)
                }

                await MainActor.run {
                    loadSources()
                    closeEditor()
                }
            } catch {
                await MainActor.run {
                    isSavingSource = false
                    editorErrorMessage = error.localizedDescription
                }
            }
        }
    }

    /**
     Deletes one custom source from persisted configuration.

     - Parameter source: Custom source definition to remove.

     Side effects:
     - rewrites `InstallMgr.conf` through `RepositorySourceManager`
     - reloads local source state after successful deletion
     - stores a presentable error if deletion fails
     */
    private func deleteSource(_ source: SourceConfig) {
        do {
            try sourceManager.deleteCustomSource(named: source.name)
            loadSources()
        } catch {
            sourceErrorMessage = error.localizedDescription
        }
    }

    /**
     Restores the repository configuration file to the packaged Android source set.

     Side effects:
     - rewrites `InstallMgr.conf` through `RepositorySourceManager`
     - reloads local source state after successful reset
     - stores a presentable error if reset fails
     */
    private func resetToDefaults() {
        do {
            try sourceManager.resetToDefaults()
            loadSources()
        } catch {
            sourceErrorMessage = error.localizedDescription
        }
    }
}

private struct RepositorySourceEditorState: Identifiable {
    /// Stable sheet identity for SwiftUI modal presentation.
    let id = UUID()

    /// Name of the custom source being replaced, or `nil` when adding a new source.
    let originalName: String?

    /// User-entered HTTPS manifest or direct SWORD catalog URL.
    var repositoryURL: String

    /// Navigation title matching the current add or replace mode.
    var title: String {
        if originalName == nil {
            return String(localized: "add_custom_repository", defaultValue: "Add custom repository")
        }
        return String(localized: "edit_custom_repository", defaultValue: "Edit custom repository")
    }

    /// Confirmation button title matching the current add or replace mode.
    var saveTitle: String {
        if originalName == nil {
            return String(localized: "add", defaultValue: "Add")
        }
        return String(localized: "save", defaultValue: "Save")
    }
}

/// Identifiable wrapper for presenting destructive custom-source delete confirmation.
private struct RepositorySourceDeletionCandidate: Identifiable {
    /// Stable identity for the current delete prompt.
    let id = UUID()

    /// Custom source selected for deletion.
    let source: SourceConfig
}

private extension SourceConfig {
    /// Stable identity for lists where Android default HTTP and FTP rows can share a source name.
    var repositoryManagerListID: String {
        "\(type)|\(name)|\(host)|\(catalogPath)"
    }

    /// User-visible address for repository rows.
    var displayAddress: String {
        "\(scheme)://\(host)\(catalogPath)"
    }

    /// HTTPS URL prefilled when replacing custom sources.
    var editableURLString: String {
        "https://\(host)\(catalogPath)"
    }

    private var scheme: String {
        type == "FTP" ? "ftp" : "https"
    }
}
