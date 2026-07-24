// RepositoryManagerView.swift — Android custom-repository activities

import SwiftUI
import SwordKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/**
 Hosts Android's Custom repositories list and editor as app-owned activity surfaces.

 Android's `CustomRepositories` activity lists only user-installed repositories; built-in sources
 belong to Downloads and are not editable here. Its empty-state card owns Add and Information,
 while a populated row opens `CustomRepositoryEditor`. The editor owns live URL validation,
 Paste/validity feedback, and Save/Delete/Help action-bar commands. This projection deliberately
 avoids native `List`, `Form`, swipe actions, navigation toolbars, and feature-local color guesses.

 Data dependencies:
 - `RepositorySourceManager` loads, validates, persists, replaces, and deletes repository sources.
 - `ReaderThemeSurfacePalette` supplies the owning reader/workspace colors.
 - the platform pasteboard supplies Android's explicit Paste command.

 Side effects:
 - appearing reloads persisted source configuration;
 - editor validation performs cancellable HTTPS reads after the Android debounce;
 - Save/Delete mutate repository configuration and notify Downloads;
 - Help can hand the documented wiki URL to the platform browser.

 Failure modes:
 - invalid/unreachable URLs remain unchecked and cannot be saved;
 - persistence failures stay in the editor and render an app-owned error dialog;
 - stale edit/delete targets report the manager error without dismissing the activity.
 */
public struct RepositoryManagerView: View {
    /// Pops the full app-owned activity destination.
    @Environment(\.dismiss) private var dismiss

    /// Opens the Android custom-repository wiki after the app-owned Help dialog.
    @Environment(\.openURL) private var openURL

    /// Repository validation and persistence owner.
    private let sourceManager: RepositorySourceManager

    /// Reader/workspace palette inherited from Document Downloader.
    private let surfacePalette: ReaderThemeSurfacePalette

    /// Complete persisted source inventory; presentation filters it to custom sources.
    @State private var sources: [SourceConfig] = []

    /// Active Android editor activity state, or `nil` while the list activity is visible.
    @State private var editorState: RepositorySourceEditorState?

    /// Registration produced by live validation for the current editor URL.
    @State private var validatedRegistration: RepositorySourceRegistration?

    /// Trimmed URL that produced `validatedRegistration`.
    @State private var validatedRepositoryURL: String?

    /// Whether the current URL is undergoing Android-style manifest/catalog validation.
    @State private var isValidatingSource = false

    /// Whether a validated registration is being committed to local configuration.
    @State private var isSavingSource = false

    /// Whether the context-sensitive Android Help dialog is visible.
    @State private var showHelp = false

    /// Whether Back is waiting for confirmation to discard changed editor input.
    @State private var showDiscardConfirmation = false

    /// Existing repository awaiting Android's Yes/No delete confirmation.
    @State private var deletionCandidate: RepositorySourceDeletionCandidate?

    /// Validation-independent source-management error shown in the app-owned dialog layer.
    @State private var sourceErrorMessage: String?

    /**
     Creates the public repository route with the application-default palette.

     - Parameter sourceManager: Repository service used by list and editor activities.
     - Side effects: none; sources load on appearance.
     - Failure modes: none.
     */
    public init(sourceManager: RepositorySourceManager = RepositorySourceManager()) {
        self.sourceManager = sourceManager
        surfacePalette = .standard
    }

    /**
     Creates the reader-owned repository route used by Document Downloader.

     - Parameters:
       - sourceManager: Repository service used by list and editor activities.
       - surfacePalette: Active reader/workspace palette inherited from Downloads.
     - Side effects: none; sources load on appearance.
     - Failure modes: none.
     */
    init(
        sourceManager: RepositorySourceManager = RepositorySourceManager(),
        surfacePalette: ReaderThemeSurfacePalette
    ) {
        self.sourceManager = sourceManager
        self.surfacePalette = surfacePalette
    }

    /**
     Renders exactly one full activity plus its shared dialog layer.

     - Returns: Custom-repository list or editor content using owner-themed Android components.
     - Side effects: `onAppear` reloads persisted sources; editor URL changes start validation.
     - Failure modes: Source errors are retained in `repositoryDialogOverlay`.
     */
    public var body: some View {
        ZStack {
            if editorState == nil {
                repositoryListActivity
            } else {
                repositoryEditorActivity
            }

            repositoryDialogOverlay
        }
        .onAppear(perform: loadSources)
    }

    /// Android's documented custom-repositories wiki.
    private static let customRepositoriesWikiURL = URL(
        string: "https://github.com/AndBible/and-bible/wiki/Custom-repositories"
    )!

    /// Persisted sources Android exposes in this activity; packaged defaults remain in Downloads.
    private var customSources: [SourceConfig] {
        sources.filter { !sourceManager.isDefaultSource($0) }
    }

    /// Editable URL binding that invalidates any result derived from the previous value.
    private var editorURLBinding: Binding<String> {
        Binding(
            get: { editorState?.repositoryURL ?? "" },
            set: { newValue in
                editorState?.repositoryURL = newValue
                validatedRegistration = nil
                validatedRepositoryURL = nil
            }
        )
    }

    /// Whether Android's Save command must stay disabled for the current editor state.
    private var editorSaveDisabled: Bool {
        guard let editorState else { return true }
        let trimmedURL = editorState.repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return isSavingSource
            || isValidatingSource
            || trimmedURL.isEmpty
            || validatedRepositoryURL != trimmedURL
            || validatedRegistration == nil
    }

    /// Whether Back must ask to discard URL changes before returning to the list activity.
    private var editorHasUnsavedChanges: Bool {
        guard let editorState else { return false }
        return editorState.repositoryURL != editorState.initialRepositoryURL
    }

    /// Stable screen identity retained for existing editor automation.
    private var editorScreenAccessibilityIdentifier: String {
        editorState?.originalName == nil
            ? "repositoryManagerAddSourceScreen"
            : "repositoryManagerSourceEditorScreen"
    }

    /**
     Builds Android's Custom repositories list activity.

     - Returns: Shared action bar plus either the exact empty card or custom repository rows.
     - Side effects: Add/Help/Back and row taps mutate presentation state.
     - Failure modes: An unreadable inventory is represented by the manager's empty result.
     */
    private var repositoryListActivity: some View {
        ZStack(alignment: .topLeading) {
            AndroidActivityScreen(
                title: String(localized: "custom_repositories", defaultValue: "Custom repositories"),
                accessibilityIdentifier: "repositoryManagerTopAppBar",
                palette: surfacePalette,
                onBack: { dismiss() }
            ) {
                AndroidActivityTopAppBarActionButton(
                    icon: .asset("ActivityAddCircle"),
                    accessibilityLabel: String(localized: "new_item", defaultValue: "New item"),
                    accessibilityIdentifier: "repositoryManagerAddButton",
                    foregroundColor: surfacePalette.toolbarForegroundColor,
                    action: beginAddingSource
                )

                AndroidActivityTopAppBarActionButton(
                    icon: .asset("DrawerHelp"),
                    accessibilityLabel: String(localized: "help", defaultValue: "Help"),
                    accessibilityIdentifier: "repositoryManagerHelpButton",
                    foregroundColor: surfacePalette.toolbarForegroundColor,
                    action: { showHelp = true }
                )
            } content: {
                if customSources.isEmpty {
                    repositoryEmptyCard
                } else {
                    repositoryRows
                }
            }

            AndroidActivityAccessibilityMarker(
                label: String(localized: "custom_repositories", defaultValue: "Custom repositories"),
                accessibilityIdentifier: "repositoryManagerScreen",
                surfaceColor: surfacePalette.backgroundColor
            )
        }
    }

    /**
     Builds Android's elevated empty-list guidance card.

     - Returns: Empty message followed by shared Add and Information raised buttons.
     - Side effects: Buttons open the editor or Help dialog.
     - Failure modes: none.
     */
    private var repositoryEmptyCard: some View {
        VStack {
            Spacer(minLength: 24)

            VStack(spacing: 15) {
                Text(String(
                    localized: "custom_repositories_empty_list_message",
                    defaultValue: "No custom repositories are defined"
                ))
                .font(.system(size: 16))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

                AndroidRaisedTextButton(
                    title: String(
                        localized: "custom_repositories_create_button_label",
                        defaultValue: "Add Custom Repository"
                    ),
                    icon: .asset("ActivityAddCircle"),
                    foregroundColor: surfacePalette.foregroundColor,
                    backgroundColor: surfacePalette.controlFillColor,
                    accessibilityIdentifier: "repositoryManagerEmptyAddCustomButton",
                    action: beginAddingSource
                )

                AndroidRaisedTextButton(
                    title: String(
                        localized: "custom_repositories_info_button_label",
                        defaultValue: "Information"
                    ),
                    icon: .asset("DocumentInfo"),
                    foregroundColor: surfacePalette.foregroundColor,
                    backgroundColor: surfacePalette.controlFillColor,
                    accessibilityIdentifier: "repositoryManagerEmptyInformationButton",
                    action: { showHelp = true }
                )
            }
            .padding(15)
            .background(surfacePalette.backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
            .shadow(color: Color.black.opacity(0.34), radius: 20, y: 8)
            .padding(25)

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /**
     Builds the Android `ListView` projection containing custom repositories only.

     - Returns: Lazily rendered title/description rows with Android separators.
     - Side effects: Row taps open the editor activity.
     - Failure modes: none.
     */
    private var repositoryRows: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(customSources, id: \.repositoryManagerListID) { source in
                    sourceRow(source)
                }
            }
        }
        .scrollIndicators(.visible)
    }

    /**
     Builds one Android `custom_repository_item` row.

     - Parameter source: Custom source whose name and description are shown.
     - Returns: A plain full-width title/description row with no invented icon or swipe command.
     - Side effects: A tap opens the dedicated editor activity.
     - Failure modes: Missing manifest descriptions fall back to the editable HTTPS URL.
     */
    private func sourceRow(_ source: SourceConfig) -> some View {
        Button {
            beginEditingSource(source)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .font(.system(size: 16))
                    .foregroundStyle(surfacePalette.foregroundColor)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(source.repositoryManagerDescription)
                    .font(.system(size: 14))
                    .foregroundStyle(surfacePalette.secondaryForegroundColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(surfacePalette.inactiveBorderColor)
                .frame(height: 1)
        }
        .accessibilityIdentifier("repositoryManagerSourceRow_\(source.name)")
    }

    /**
     Builds Android's dedicated Custom repository editor activity.

     - Returns: Shared action bar plus URL/Paste/validity/info/progress content.
     - Side effects: URL changes start cancellable validation; toolbar commands save, delete, help,
       or request Back/discard behavior.
     - Failure modes: Invalid URLs stay unchecked and keep Save disabled.
     */
    private var repositoryEditorActivity: some View {
        ZStack(alignment: .topLeading) {
            AndroidActivitySurface(palette: surfacePalette) {
                repositoryEditorTopAppBar
            } content: {
                repositoryEditorContent
            }

            AndroidActivityAccessibilityMarker(
                label: String(localized: "custom_repositories", defaultValue: "Custom repositories"),
                accessibilityIdentifier: editorScreenAccessibilityIdentifier,
                surfaceColor: surfacePalette.backgroundColor
            )
        }
        .task(id: editorState?.repositoryURL) {
            await validateCurrentEditorURL()
        }
    }

    /**
     Builds editor Save/Delete/Help actions in Android menu order.

     - Returns: Owner-themed shared activity app bar.
     - Side effects: Commands commit, confirm deletion, open Help, or return to the list.
     - Failure modes: Save is disabled until live validation owns the current URL.
     */
    private var repositoryEditorTopAppBar: some View {
        AndroidActivityTopAppBar(
            title: String(localized: "custom_repositories", defaultValue: "Custom repositories"),
            accessibilityIdentifier: "repositoryManagerEditorTopAppBar",
            backgroundColor: surfacePalette.toolbarBackgroundColor,
            foregroundColor: surfacePalette.toolbarForegroundColor,
            onBack: requestCloseEditor
        ) {
            AndroidActivityTopAppBarActionButton(
                icon: .asset("ActivitySave"),
                accessibilityLabel: String(localized: "okay", defaultValue: "OK"),
                accessibilityIdentifier: "repositoryManagerSourceEditorSaveButton",
                foregroundColor: editorSaveDisabled
                    ? surfacePalette.toolbarDisabledForegroundColor
                    : surfacePalette.toolbarForegroundColor,
                action: saveEditorSource
            )
            .disabled(editorSaveDisabled)

            if editorState?.originalName != nil {
                AndroidActivityTopAppBarActionButton(
                    icon: .asset("ActivityDelete"),
                    accessibilityLabel: String(localized: "delete", defaultValue: "Delete"),
                    accessibilityIdentifier: "repositoryManagerSourceEditorDeleteButton",
                    foregroundColor: surfacePalette.toolbarForegroundColor,
                    action: requestDeleteEditedSource
                )
            }

            AndroidActivityTopAppBarActionButton(
                icon: .asset("DrawerHelp"),
                accessibilityLabel: String(localized: "help", defaultValue: "Help"),
                accessibilityIdentifier: "repositoryManagerSourceEditorHelpButton",
                foregroundColor: surfacePalette.toolbarForegroundColor,
                action: { showHelp = true }
            )
        }
    }

    /**
     Builds the owner-themed editor body from Android's `custom_repository_editor.xml`.

     - Returns: Repository URL, exact Paste drawable, validity check, resolved metadata, and
       validation progress.
     - Side effects: Editing and Paste mutate `editorState.repositoryURL`.
     - Failure modes: Empty or invalid URLs intentionally produce no metadata/checkmark.
     */
    private var repositoryEditorContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                AndroidActivityTextInput(
                    placeholder: String(
                        localized: "repository_specification",
                        defaultValue: "Repository specification"
                    ),
                    text: editorURLBinding,
                    foregroundColor: surfacePalette.foregroundColor,
                    backgroundColor: surfacePalette.controlFillColor,
                    borderColor: surfacePalette.inactiveBorderColor,
                    accessibilityIdentifier: "repositoryManagerRepositoryURLField"
                )
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .autocorrectionDisabled()

                Button(action: pasteRepositoryURL) {
                    AndBibleIconView(name: "ActivityPaste", size: 24)
                        .frame(width: 48, height: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(surfacePalette.foregroundColor)
                .accessibilityLabel(String(localized: "paste", defaultValue: "Paste"))
                .accessibilityIdentifier("repositoryManagerPasteButton")

                Group {
                    if validatedRegistration != nil {
                        AndBibleIconView(name: "ActivitySave", size: 24)
                            .foregroundStyle(AndroidResourcePalette.documentInstalledGreen)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 48, height: 48)
                .accessibilityHidden(validatedRegistration == nil)
                .accessibilityLabel(String(localized: "success", defaultValue: "Success"))
                .accessibilityIdentifier("repositoryManagerValidCheck")
            }

            if let validatedRegistration {
                Text("\(validatedRegistration.source.name)\n\n\(validatedRegistration.description)")
                    .font(.system(size: 16))
                    .foregroundStyle(surfacePalette.foregroundColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .accessibilityIdentifier("repositoryManagerResolvedInformation")
            }

            if isValidatingSource || isSavingSource {
                ProgressView()
                    .tint(surfacePalette.foregroundColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .accessibilityLabel(String(
                        localized: "validating_repository",
                        defaultValue: "Validating repository"
                    ))
                    .accessibilityIdentifier("repositoryManagerValidationProgress")
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /**
     Builds every transient repository prompt through the shared Android dialog owner.

     - Returns: At most one discard/delete/help/error dialog in deterministic priority order.
     - Side effects: Dialog actions clear state, mutate sources, open the wiki, or close the editor.
     - Failure modes: Failed delete operations retain the editor and continue to the error dialog.
     */
    @ViewBuilder
    private var repositoryDialogOverlay: some View {
        if showDiscardConfirmation {
            AndroidDecisionDialog(
                title: "",
                message: String(
                    localized: "discard_changes_confirmation",
                    defaultValue: "Discard changes?"
                ),
                actions: [
                    .init(
                        id: "yes",
                        title: String(localized: "yes", defaultValue: "Yes"),
                        style: .normal
                    ) {
                        showDiscardConfirmation = false
                        closeEditor()
                    },
                    .init(
                        id: "no",
                        title: String(localized: "no", defaultValue: "No"),
                        style: .normal
                    ) {
                        showDiscardConfirmation = false
                    },
                ]
            )
        } else if let candidate = deletionCandidate {
            AndroidDecisionDialog(
                title: "",
                message: String(
                    format: String(
                        localized: "delete_custom_repository",
                        defaultValue: "Do you want to remove custom repository %@?"
                    ),
                    candidate.source.name
                ),
                actions: [
                    .init(
                        id: "yes",
                        title: String(localized: "yes", defaultValue: "Yes"),
                        style: .destructive
                    ) {
                        deletionCandidate = nil
                        if deleteSource(candidate.source) {
                            closeEditor()
                        }
                    },
                    .init(
                        id: "no",
                        title: String(localized: "no", defaultValue: "No"),
                        style: .normal
                    ) {
                        deletionCandidate = nil
                    },
                ]
            )
        } else if showHelp {
            AndroidDecisionDialog(
                title: String(localized: "custom_repositories", defaultValue: "Custom repositories"),
                message: repositoryHelpMessage,
                actions: [
                    .init(
                        id: "wiki",
                        title: String(localized: "wiki_page", defaultValue: "Wiki page"),
                        style: .normal
                    ) {
                        showHelp = false
                        openURL(Self.customRepositoriesWikiURL)
                    },
                    .init(
                        id: "okay",
                        title: String(localized: "okay", defaultValue: "OK"),
                        style: .normal
                    ) {
                        showHelp = false
                    },
                ]
            )
        } else if let sourceErrorMessage {
            AndroidDecisionDialog(
                title: String(localized: "error_occurred", defaultValue: "Error occurred"),
                message: sourceErrorMessage,
                actions: [
                    .init(
                        id: "okay",
                        title: String(localized: "okay", defaultValue: "OK"),
                        style: .normal
                    ) {
                        self.sourceErrorMessage = nil
                    },
                ]
            )
        }
    }

    /// Android Help copy, including editor-only URL instructions when the editor owns the dialog.
    private var repositoryHelpMessage: String {
        var paragraphs = [String(
            localized: "custom_repositories_help0",
            defaultValue: "You can install documents from external custom repositories by installing custom repositories."
        )]
        if editorState != nil {
            paragraphs.append(String(
                localized: "custom_repositories_help1",
                defaultValue: "To add a new custom repository, type or copy & paste custom repository URL here."
            ))
        }
        paragraphs.append(String(
            format: String(
                localized: "custom_repositories_help2",
                defaultValue: "You can read more information about custom repositories in %@."
            ),
            String(localized: "wiki_page", defaultValue: "Wiki page")
        ))
        return paragraphs.joined(separator: "\n\n")
    }

    /** Reloads persisted sources without altering the active editor. */
    private func loadSources() {
        sources = sourceManager.loadSources()
    }

    /** Opens a blank Android editor activity and clears validation/error state. */
    private func beginAddingSource() {
        clearEditorValidation()
        sourceErrorMessage = nil
        editorState = RepositorySourceEditorState(
            originalName: nil,
            initialRepositoryURL: "",
            repositoryURL: "",
            packageDirectory: ""
        )
    }

    /**
     Opens Android's editor activity for one custom source.

     - Parameter source: Persisted custom source to replace after validation.
     - Side effects: Clears transient feedback and starts live validation through the editor task.
     - Failure modes: none; stale targets are detected when Save/Delete commits.
     */
    private func beginEditingSource(_ source: SourceConfig) {
        clearEditorValidation()
        sourceErrorMessage = nil
        let editableURL = source.editableURLString
        editorState = RepositorySourceEditorState(
            originalName: source.name,
            initialRepositoryURL: editableURL,
            repositoryURL: editableURL,
            packageDirectory: source.packageDirectory ?? ""
        )
    }

    /** Requests editor Back, preserving Android's discard confirmation for changed input. */
    private func requestCloseEditor() {
        if editorHasUnsavedChanges {
            showDiscardConfirmation = true
        } else {
            closeEditor()
        }
    }

    /** Closes the editor activity and clears every editor-owned transient state. */
    private func closeEditor() {
        editorState = nil
        showDiscardConfirmation = false
        deletionCandidate = nil
        clearEditorValidation()
    }

    /** Clears results and activity flags derived from an editor URL. */
    private func clearEditorValidation() {
        validatedRegistration = nil
        validatedRepositoryURL = nil
        isValidatingSource = false
        isSavingSource = false
    }

    /**
     Debounces and validates the current editor URL without persisting it.

     - Side effects: Performs HTTPS reads and replaces validation/check/info state only when the
       result still belongs to the current URL.
     - Failure modes: Cancellation or validation errors quietly leave Save disabled, matching
       Android's editor.
     */
    @MainActor
    private func validateCurrentEditorURL() async {
        validatedRegistration = nil
        validatedRepositoryURL = nil
        isValidatingSource = false

        guard let rawURL = editorState?.repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURL.isEmpty else { return }

        do {
            try await Task.sleep(nanoseconds: 200_000_000)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }

        isValidatingSource = true
        defer {
            if editorState?.repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines) == rawURL {
                isValidatingSource = false
            }
        }

        do {
            let registration = try await sourceManager.resolveCustomSource(from: rawURL)
            guard !Task.isCancelled,
                  editorState?.repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines) == rawURL else {
                return
            }
            validatedRegistration = registration
            validatedRepositoryURL = rawURL
        } catch {
            guard !Task.isCancelled else { return }
            validatedRegistration = nil
            validatedRepositoryURL = nil
        }
    }

    /**
     Commits the exact registration produced by live validation.

     - Side effects: Persists add/replace configuration, reloads rows, and returns to the list on
       success; presents an app-owned error dialog on failure.
     - Failure modes: Missing/stale validation is ignored because Save is disabled for that state.
     */
    private func saveEditorSource() {
        guard !editorSaveDisabled,
              let editorState,
              let validatedRegistration else { return }

        isSavingSource = true
        do {
            try sourceManager.persistResolvedCustomSource(
                validatedRegistration,
                replacing: editorState.originalName,
                packageDirectory: editorState.packageDirectory
            )
            loadSources()
            closeEditor()
        } catch {
            isSavingSource = false
            sourceErrorMessage = error.localizedDescription
        }
    }

    /** Selects the currently edited custom source for Android's delete confirmation. */
    private func requestDeleteEditedSource() {
        guard let originalName = editorState?.originalName,
              let source = customSources.first(where: { $0.name == originalName }) else {
            sourceErrorMessage = RepositorySourceManagementError
                .sourceNotFound(editorState?.originalName ?? "")
                .localizedDescription
            return
        }
        deletionCandidate = RepositorySourceDeletionCandidate(source: source)
    }

    /**
     Deletes one custom source and reloads the list.

     - Parameter source: Confirmed source to remove.
     - Returns: `true` only when persistence and reload succeed.
     - Side effects: Rewrites repository configuration or records an app-owned error message.
     - Failure modes: Manager errors return `false` and preserve the editor.
     */
    @discardableResult
    private func deleteSource(_ source: SourceConfig) -> Bool {
        do {
            try sourceManager.deleteCustomSource(named: source.name)
            loadSources()
            return true
        } catch {
            sourceErrorMessage = error.localizedDescription
            return false
        }
    }

    /** Pastes the current platform text payload into Android's repository URL field. */
    private func pasteRepositoryURL() {
        #if canImport(UIKit)
        guard let text = UIPasteboard.general.string else { return }
        editorURLBinding.wrappedValue = text
        #elseif canImport(AppKit)
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        editorURLBinding.wrappedValue = text
        #endif
    }
}

/** Value state retained while Android's dedicated custom-repository editor is active. */
private struct RepositorySourceEditorState {
    /// Existing custom source name, or `nil` for a new repository.
    let originalName: String?

    /// URL captured when the editor opened for Back/discard comparison.
    let initialRepositoryURL: String

    /// Current user-entered manifest or direct catalog URL.
    var repositoryURL: String

    /// Existing SWORD package directory preserved while Android keeps that field hidden.
    let packageDirectory: String
}

/** Existing custom source selected for Android's Yes/No delete confirmation. */
private struct RepositorySourceDeletionCandidate {
    /// Custom source that will be deleted after confirmation.
    let source: SourceConfig
}

private extension SourceConfig {
    /// Stable identity for custom rows that can share names across repository families.
    var repositoryManagerListID: String {
        "\(repositoryType)|\(type)|\(name)|\(host)|\(catalogPath)"
    }

    /// Android row description with a durable HTTPS fallback for migrated source-only records.
    var repositoryManagerDescription: String {
        let trimmedDescription = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedDescription?.isEmpty == false ? trimmedDescription! : editableURLString
    }

    /**
     HTTPS URL prefilled when replacing a custom source.

     Persisted non-HTTPS manifest metadata is ignored so legacy rows fall back to the synthesized
     HTTPS catalog URL accepted by Android-style validation.
     */
    var editableURLString: String {
        if let manifestURL, manifestURL.scheme?.lowercased() == "https" {
            return manifestURL.absoluteString
        }
        return "https://\(host)\(catalogPath)"
    }
}
