import BibleCore
import SwiftUI
import SwiftData
import SwordKit
import UniformTypeIdentifiers

/**
 Retains one local SWORD archive while the picker requests overwrite consent.

 The repository repeats validation during install; this value exists only to preserve provider
 metadata and show the exact preflight conflicts before authorizing replacement.
 */
private struct DocumentPickerLocalOverwriteConfirmation: Identifiable {
    /// Selected external document request retained across alert presentation.
    let request: ExternalDocumentImportRequest

    /// Validated archive summary and conflicting destination paths.
    let inspection: LocalSwordZipInspection

    /// Stable alert identity derived from the selected file URL.
    var id: String { request.url.standardizedFileURL.path }
}

/**
 Presents document rows for the currently focused pane and routes selections through the same
 document outcomes as Android's `ChooseDocument` activity.

 Android's chooser is not only a list of installed SWORD text modules. It also exposes the visible
 `FakeBookFactory` pseudo-documents, hides add-ons from "All types", exposes add-ons through their
 own filter, and offers document management actions from the row context menu. This view keeps that
 parity contract in pure filtering helpers so tests can protect the Android behavior independently
 from SwiftUI rendering details.
 */
struct BibleReaderModulePicker: View {
    /// Shared popup anchor names for the activity toolbar.
    private enum PopupAnchor {
        static let overflow = "modulePickerOverflowAnchor"
    }

    /// Single installed document selected by Android's contextual action mode.
    private enum ContextualDocument: Equatable {
        /// Stable chooser-row identity for one installed SWORD/SQLite/add-on book.
        case module(String)

        /// Installed EPUB stable library identifier.
        case epub(String)
    }

    let controller: BibleReaderController
    let category: DocumentCategory
    let surfacePalette: ReaderThemeSurfacePalette
    let onDismiss: () -> Void
    let onOpenDownloads: () -> Void
    let onOpenDictionaryBrowser: () -> Void
    let onOpenGeneralBookBrowser: () -> Void
    let onOpenMapBrowser: () -> Void
    let onOpenStudyPadSelector: () -> Void
    let onDeleteEpub: (String) -> Void

    /// Search-index service used by Android's Delete Index row action.
    @Environment(SearchIndexService.self) private var searchIndexService

    /// SwiftData context used to replay current My Documents ownership before EPUB import.
    @Environment(\.modelContext) private var modelContext

    /// Active scheme used only for the shared popup elevation/accent projection.
    @Environment(\.colorScheme) private var colorScheme

    /// Selected Android document-type filter.
    @State private var selectedFilter: DocumentTypeFilter

    /// Selected ISO language code, or an empty string for Android's all-language default.
    @State private var selectedLanguage = ""

    /// Free-text filter applied to module initials, descriptions, category labels, and language.
    @State private var searchText = ""

    /// Installed module or EPUB selected by Android's single-choice contextual action mode.
    @State private var contextualDocument: ContextualDocument?

    /// Details dialog payload for Android's About row action.
    @State private var selectedModuleDetails: ModuleBrowserModuleDetails?

    /// Confirmation payload for destructive Android document actions.
    @State private var pendingRowActionConfirmation: ModuleBrowserRowActionConfirmation?

    /// Exact admitted add-on owner awaiting Android's destructive delete confirmation.
    @State private var pendingAddonUninstall: SwordAdmittedAddonModule?

    /// Success-only EPUB deletion state shared with the reader reconciliation boundary.
    @State private var epubDeletionState = EpubLibraryDeletionState()

    /// EPUB awaiting Android's Delete search index confirmation.
    @State private var pendingEpubIndexDeletion: EpubInfo?

    /// Last row-action failure surfaced to the user.
    @State private var rowActionErrorMessage: String?

    /// Whether the Android-style app-bar overflow menu is visible.
    @State private var showOverflowMenu = false

    /// Installed modules captured for Android's selected-by-default backup sheet.
    @State private var moduleBackupCandidates: [ModuleInfo] = []

    /// Whether Android's module-backup selection sheet is visible.
    @State private var showModuleBackupSelection = false

    /// Whether selected module files are currently being archived.
    @State private var isExportingModuleBackup = false

    /// Generated Android module backup passed to SwiftUI's document exporter.
    @State private var moduleBackupDocument = BackupExportDocument()

    /// Temporary file backing the current streamed Android module backup export.
    @State private var moduleBackupTemporaryFileURL: URL?

    /// Android-compatible default filename for the generated module backup.
    @State private var moduleBackupFileName = AndroidModuleBackupService.moduleBackupFileName

    /// Whether the destination picker for a generated module backup is visible.
    @State private var showModuleBackupExporter = false

    /// Whether Android's Load Documents From Files picker is visible.
    @State private var showInstallZipImporter = false

    /// Whether a selected ZIP, EPUB, font, or module backup is being installed.
    @State private var isImportingExternalDocument = false

    /// Durable phase snapshot for an ordinary local SWORD ZIP install.
    @State private var externalDocumentImportProgress: ModuleInstallProgress?

    /// Local SWORD archive waiting for explicit overwrite consent.
    @State private var pendingLocalModuleOverwrite: DocumentPickerLocalOverwriteConfirmation?

    /// User-visible completion or failure feedback for import/export routes.
    @State private var externalDocumentImportMessage: String?

    /// Locked module whose cipher-key prompt is visible.
    @State private var pendingUnlockModule: ModuleInfo?

    /// Cipher key entered for the pending locked module.
    @State private var unlockCipherKey = ""

    /// Failed unlock feedback shown when Android's passphrase prompt is retried.
    @State private var unlockFailureMessage: String?

    /// Generic module retained for retry after exact-key validation fails.
    @State private var pendingGenericSwitchRetry: ModuleInfo?

    /// SWORD key-validation failure shown without dismissing the document picker.
    @State private var genericSwitchFailureMessage: String?

    /// Repository service used by Android's Delete document row action.
    private let repository = ModuleRepository()

    /**
     Creates a pane-scoped document picker with Android-compatible initial type selection.

     - Parameters:
       - controller: Ready reader controller whose installed modules and document actions back the picker.
       - category: Category requested by the caller. This becomes the initial document-type filter,
         matching Android's `type` intent extra for Bible/commentary launches.
       - startsWithAllTypes: Whether the picker should start on Android's "All types" filter. Use
         this for the drawer-level Choose Document action, which Android opens without a `type`
         extra.
       - surfacePalette: Colors inherited from the launching reader workspace/window.
       - onDismiss: Callback that closes the activity destination without changing reader state.
       - onOpenDownloads: Callback that opens Downloads after the chooser dismisses.
       - onOpenDictionaryBrowser: Follow-up browser route used after selecting a dictionary module.
       - onOpenGeneralBookBrowser: Follow-up browser route used after selecting a general book.
       - onOpenMapBrowser: Follow-up browser route used after selecting a map module.
       - onOpenStudyPadSelector: Follow-up route for Android's visible Journal/StudyPad pseudo-document.
       - onDeleteEpub: Reader-owner callback emitted only after durable EPUB deletion succeeds.

     - Side effects: Initializes SwiftUI state only; controller mutations happen later from row
       selection.

     - Failure modes: The caller must wait for a ready pane controller before constructing the
       picker; a missing controller is a pane-readiness state, not an empty installed-document state.
     */
    init(
        controller: BibleReaderController,
        category: DocumentCategory,
        startsWithAllTypes: Bool = false,
        surfacePalette: ReaderThemeSurfacePalette = .standard,
        onDismiss: @escaping () -> Void,
        onOpenDownloads: @escaping () -> Void,
        onOpenDictionaryBrowser: @escaping () -> Void,
        onOpenGeneralBookBrowser: @escaping () -> Void,
        onOpenMapBrowser: @escaping () -> Void,
        onOpenStudyPadSelector: @escaping () -> Void = {},
        onDeleteEpub: @escaping (String) -> Void = { _ in }
    ) {
        self.controller = controller
        self.category = category
        self.surfacePalette = surfacePalette
        self.onDismiss = onDismiss
        self.onOpenDownloads = onOpenDownloads
        self.onOpenDictionaryBrowser = onOpenDictionaryBrowser
        self.onOpenGeneralBookBrowser = onOpenGeneralBookBrowser
        self.onOpenMapBrowser = onOpenMapBrowser
        self.onOpenStudyPadSelector = onOpenStudyPadSelector
        self.onDeleteEpub = onDeleteEpub
        _selectedFilter = State(initialValue: startsWithAllTypes ? .all : Self.initialDocumentTypeFilter(for: category))
    }

    /**
     All installed modules Android's document-type spinner can expose.

     - Returns: Installed Bible, commentary, dictionary, general book, map, and every comparator-
       distinct add-on supplied by the shared Android compatibility/BookSet projection.
     */
    private var allSelectableModules: [ModuleInfo] {
        selectableDocumentModules.map(\.info) + selectableAddons.map(\.moduleInfo)
    }

    /**
     Returns non-add-on installed documents gathered once per Android document category.

     - Side effects: Reads current controller inventory without changing reader state.
     - Failure modes: Categories with no installed owner contribute no rows.
     */
    private var selectableDocumentModules: [BibleReaderInstalledBookPresentation] {
        controller.installedBookPresentationsForDocumentPicker().filter {
            Self.documentCategory(for: $0.info.category) != nil
        }
    }

    /**
     Returns shared payload-admitted add-ons with JSword abbreviation and identity metadata intact.

     - Side effects: May populate the current manager's immutable add-on projection cache.
     - Failure modes: Missing manager state and rejected add-ons produce no rows.
     */
    private var selectableAddons: [SwordAdmittedAddonModule] {
        Self.selectableAddonModules(from: controller.swordManager)
    }

    /**
     Returns the shared Android-admitted add-on inventory for picker presentation.

     - Parameter swordManager: Current installed-module manager, or nil before module startup.
     - Returns: Admitted add-on metadata in pinned JSword TreeSet order, or an empty list without a
       manager.
     - Side effects: May populate the manager's installed add-on projection cache.
     - Failure modes: Invalid, unsupported, or future add-ons are omitted fail closed by SwordKit.
     */
    static func selectableAddonModules(
        from swordManager: SwordManager?
    ) -> [SwordAdmittedAddonModule] {
        swordManager?.admittedAddonModules() ?? []
    }

    /**
     Returns only EPUBs that own their Android book identity in the current combined registry.

     The on-disk EPUB library can contain a stale or concurrently imported package whose initials
     are rejected by an earlier native, SQLite, EPUB, or My Documents registration. Android never
     exposes that package through `ChooseDocument`, because the corresponding `Book` was not added
     to `Books.installed()`. Resolving each candidate through the controller keeps the picker on the
     same exact-initials, exact-full-name, and case-insensitive TreeSet contract as every reader
     entry point.

     - Returns: Admitted EPUB metadata in stable library enumeration order.
     - Side effects: Enumerates installed EPUB metadata, opens immutable EPUB generations, and asks
       the controller to replay installed/local registration metadata; no EPUB fragment or My
       Documents page is read and reader state is not mutated.
     - Failure modes: Missing generations, metadata failures, installed owners, and a different
       local owner all omit the candidate so it cannot be advertised or selected.
     */
    private var selectableEpubs: [EpubInfo] {
        Self.admittedEpubs(
            from: EpubReader.installedEpubs(),
            resolvedOwnerIdentifier: { epub in
                guard let reader = EpubReader(identifier: epub.identifier),
                      let owner = controller.localGeneralBookDocument(
                          named: epub.initials,
                          preferredEpub: reader
                      ),
                      case .epub(let admittedReader) = owner else {
                    return nil
                }
                return admittedReader.identifier
            }
        )
    }

    /// Android chooser rows before filters are applied, including only globally admitted EPUBs.
    private var allRows: [DocumentChooserRow] {
        Self.allRows(
            installedBooks: selectableDocumentModules,
            admittedAddons: selectableAddons,
            epubs: selectableEpubs
        )
    }

    /// Rows after applying Android-compatible admission, type, language, and free-text filters.
    private var filteredDocumentRows: [DocumentChooserRow] {
        Self.filteredRows(
            installedBooks: selectableDocumentModules,
            admittedAddons: selectableAddons,
            epubs: selectableEpubs,
            selectedFilter: selectedFilter,
            selectedLanguage: selectedLanguage,
            searchText: searchText
        )
    }

    /// Exact installed row currently driving Android's contextual document menu.
    private var contextualRow: DocumentChooserRow? {
        guard case .module(let rowID) = contextualDocument else { return nil }
        return allRows.first(where: { $0.id == rowID })
    }

    /// Installed metadata currently driving Android's contextual document menu.
    private var contextualModule: ModuleInfo? {
        contextualRow?.moduleInfo
    }

    /// Installed EPUB currently driving Android's contextual document menu.
    private var contextualEpub: EpubInfo? {
        guard case .epub(let identifier) = contextualDocument else { return nil }
        return selectableEpubs.first { $0.identifier == identifier }
    }

    /// Android-ordered contextual actions for the currently selected installed row.
    private var contextualModuleActions: [ModuleDownloadRowAction] {
        guard let contextualModule else { return [] }
        return Self.rowActions(for: contextualModule, installedModules: allSelectableModules)
    }

    /// Android's common About/Delete/Delete Index actions for a deletable EPUB general book.
    private var contextualEpubActions: [ModuleDownloadRowAction] {
        [.about, .uninstall, .deleteIndex]
    }

    /// Whether any installed document currently owns the single-choice contextual action bar.
    private var hasContextualDocumentSelection: Bool {
        contextualDocument != nil
    }

    /// Language choices built from the complete chooser dataset, sorted alphabetically.
    private var availableLanguages: [String] {
        Self.availableLanguages(from: allRows)
    }

    /// Whether the active document type has no rows before language/search filtering.
    private var shouldShowFilterEmptyState: Bool {
        Self.shouldShowFilterEmptyState(allRows, selectedFilter: selectedFilter)
    }

    /**
     Builds the Android-style document chooser surface with type/language filters, search, rows,
     row actions, and a persistent Downloads handoff.
     */
    var body: some View {
        rowActionPresentedScreen
            .overlay(alignment: .bottom) {
                installProgressOverlay
            }
    }

    /**
     Attaches document details, backup export, and local import presentation to the chooser.

     - Returns: Chooser content with non-alert document-management presenters.
     - Side effects: Presented controls can export backups or start an external document import.
     - Failure modes: Export and import failures are retained for the later feedback-alert stage.
     */
    private var documentManagementPresentedScreen: some View {
        androidDocumentChooserScreen
        .moduleBrowserModuleDetailsDialog(details: selectedModuleDetails) {
            selectedModuleDetails = nil
        }
        .overlay {
            if showModuleBackupSelection {
                AndroidModuleBackupExportDialog(
                    isExporting: isExportingModuleBackup,
                    onCancel: dismissModuleBackupSelection
                ) {
                    AndroidModuleBackupExportSheet(
                        modules: moduleBackupCandidates,
                        isExporting: isExportingModuleBackup,
                        onCancel: dismissModuleBackupSelection,
                        onExport: exportModuleBackup(moduleNames:)
                    )
                }
            }
        }
        .fileExporter(
            isPresented: $showModuleBackupExporter,
            document: moduleBackupDocument,
            contentType: .zip,
            defaultFilename: moduleBackupFileName,
            onCompletion: handleModuleBackupExport
        )
        .fileImporter(
            isPresented: $showInstallZipImporter,
            allowedContentTypes: ExternalDocumentImportService.supportedContentTypes,
            allowsMultipleSelection: false,
            onCompletion: handleInstallZipSelection
        )
    }

    /**
     Attaches local-module overwrite consent and import/export completion feedback.

     - Returns: Document-management content with external-file alerts.
     - Side effects: Consent can start a replacement install; dismissals clear retained feedback.
     - Failure modes: Import failures remain visible until the user dismisses the feedback alert.
     */
    private var importFeedbackPresentedScreen: some View {
        documentManagementPresentedScreen
        .overlay {
            if let confirmation = pendingLocalModuleOverwrite {
                ModulePickerDecisionDialog(
                    title: String(localized: "android_module_backup_overwrite_title", defaultValue: "Overwrite existing module files?"),
                    message: Self.localModuleOverwriteMessage(confirmation.inspection),
                    actions: [
                        .init(id: "cancel", title: String(localized: "cancel"), role: nil) { pendingLocalModuleOverwrite = nil },
                        .init(id: "overwrite", title: String(localized: "overwrite", defaultValue: "Overwrite"), role: .destructive) {
                            pendingLocalModuleOverwrite = nil
                            importExternalDocument(confirmation.request, overwritePolicy: .replaceExisting(confirmation.inspection.overwriteAuthorization))
                        }
                    ]
                )
            } else if let message = externalDocumentImportMessage {
                ModulePickerDecisionDialog(
                    title: String(localized: "install_zip", defaultValue: "Load Documents From Files"),
                    message: message,
                    actions: [.init(id: "okay", title: String(localized: "okay", defaultValue: "OK"), role: nil) { externalDocumentImportMessage = nil }]
                )
            }
        }
    }

    /**
     Attaches encrypted-module unlock and generic-key retry presentation.

     - Returns: Import-feedback content with module-access alerts.
     - Side effects: Actions can update a cipher key, retry a switch, or clear retained module state.
     - Failure modes: Rejected keys and read failures keep retryable state in the chooser.
     */
    private var moduleAccessPresentedScreen: some View {
        importFeedbackPresentedScreen
        .overlay {
            if let module = pendingUnlockModule {
                ModulePickerUnlockDialog(title: Self.unlockPromptTitle(for: module), message: unlockFailureMessage ?? String(localized: "enter_module_passphrase", defaultValue: "Enter the module passphrase."), cipherKey: $unlockCipherKey, showUnlockInfo: !module.aboutMetadata.unlockInfo.isEmpty, onUnlock: { attemptUnlock(module) }, onShowUnlockInfo: { showUnlockInformation(for: module) }, onCancel: clearUnlockPrompt)
            } else if let module = pendingGenericSwitchRetry {
                ModulePickerDecisionDialog(title: String(localized: "error_occurred"), message: genericSwitchFailureMessage ?? String(localized: "error_occurred"), actions: [
                    .init(id: "retry", title: String(localized: "retry"), role: nil) { pendingGenericSwitchRetry = nil; genericSwitchFailureMessage = nil; selectUnlockedModule(module) },
                    .init(id: "cancel", title: String(localized: "cancel"), role: nil) { pendingGenericSwitchRetry = nil; genericSwitchFailureMessage = nil }
                ])
            }
        }
    }

    /**
     Attaches destructive row confirmation and row-action failure feedback last.

     - Returns: Fully presented chooser content before the transient install-progress overlay.
     - Side effects: Confirmed actions can uninstall modules or delete search indexes.
     - Failure modes: Action failures remain visible until the user dismisses the error alert.
     */
    private var rowActionPresentedScreen: some View {
        moduleAccessPresentedScreen
        .overlay {
            if epubDeletionState.isAwaitingConfirmation,
               let candidate = epubDeletionState.pending.first {
                let format = String(localized: "delete_doc", defaultValue: "Delete %@?")
                ModulePickerDecisionDialog(
                    title: "",
                    message: String(format: format, candidate.title),
                    actions: [
                        .init(
                            id: "yes",
                            title: String(localized: "yes", defaultValue: "Yes"),
                            role: .destructive,
                            perform: deletePendingEpubs
                        ),
                        .init(
                            id: "no",
                            title: String(localized: "no", defaultValue: "No"),
                            role: nil
                        ) {
                            epubDeletionState.cancel()
                        },
                    ]
                )
            } else if let epub = pendingEpubIndexDeletion {
                let format = String(
                    localized: "delete_search_index_doc",
                    defaultValue: "Delete index of %@?"
                )
                ModulePickerDecisionDialog(
                    title: "",
                    message: String(format: format, epub.initials),
                    actions: [
                        .init(
                            id: "okay",
                            title: String(localized: "okay", defaultValue: "OK"),
                            role: .destructive
                        ) {
                            pendingEpubIndexDeletion = nil
                            deleteEpubSearchIndex(epub)
                        },
                        .init(
                            id: "cancel",
                            title: String(localized: "cancel", defaultValue: "Cancel"),
                            role: nil
                        ) {
                            pendingEpubIndexDeletion = nil
                        },
                    ]
                )
            } else if let addon = pendingAddonUninstall {
                let confirmation = confirmation(.uninstall, for: addon.moduleInfo)
                ModulePickerDecisionDialog(
                    title: confirmation.title,
                    message: confirmation.message,
                    actions: [
                        .init(
                            id: "confirm",
                            title: confirmation.confirmButtonTitle,
                            role: .destructive
                        ) {
                            pendingAddonUninstall = nil
                            uninstallInstalledAddon(addon)
                        },
                        .init(
                            id: "cancel",
                            title: confirmation.cancelButtonTitle,
                            role: nil
                        ) {
                            pendingAddonUninstall = nil
                        },
                    ]
                )
            } else if let confirmation = pendingRowActionConfirmation {
                ModulePickerDecisionDialog(title: confirmation.title, message: confirmation.message, actions: [
                    .init(id: "confirm", title: confirmation.confirmButtonTitle, role: .destructive) {
                        switch confirmation.kind {
                        case .uninstall: uninstallInstalledModule(confirmation.moduleName)
                        case .deleteIndex: deleteModuleIndex(confirmation.moduleName)
                        }
                        pendingRowActionConfirmation = nil
                    },
                    .init(id: "cancel", title: confirmation.cancelButtonTitle, role: nil) { pendingRowActionConfirmation = nil }
                ])
            } else if let message = rowActionErrorMessage {
                ModulePickerDecisionDialog(title: String(localized: "document_action_failed", defaultValue: "Document action failed"), message: message, actions: [
                    .init(id: "okay", title: String(localized: "okay", defaultValue: "OK"), role: nil) { rowActionErrorMessage = nil }
                ])
            }
        }
    }

    /**
     Builds the transient progress bar shown while an external document is installed.

     - Returns: Determinate or indeterminate progress content, or no content when no import is active.
     - Side effects: none.
     - Failure modes: Missing byte progress uses an indeterminate indicator.
     */
    @ViewBuilder
    private var installProgressOverlay: some View {
        if isImportingExternalDocument {
            HStack(spacing: 12) {
                if let fraction = externalDocumentImportProgress?.fraction {
                    ProgressView(value: fraction)
                        .frame(maxWidth: 140)
                } else {
                    ProgressView()
                }
                Text(String(localized: "installing", defaultValue: "Installing"))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(surfacePalette.foregroundColor)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(surfacePalette.backgroundColor)
            .overlay(alignment: .top) {
                Divider().background(surfacePalette.inactiveBorderColor)
            }
            .accessibilityIdentifier("modulePickerInstallProgress")
        }
    }

    /**
     Builds Android's full-screen `ChooseDocument` surface.

     Android uses `DocumentSelectionBase`: top app bar, inline language/search/type controls with a
     result count, and custom document rows. This view intentionally avoids SwiftUI `List`,
     `.searchable`, and navigation toolbar chrome so the chooser visually matches Android instead of
     inheriting iOS sheet styling.

     - Returns: Full-screen document chooser content with Android-owned controls.
     - Side effects: Toolbar and row actions can dismiss, open Downloads, switch reader documents, or
       show the shared module details surface.
     - Failure modes: Empty document sets render explicit Android-style rows instead of a blank list.
     */
    private var androidDocumentChooserScreen: some View {
        let visibleRows = filteredDocumentRows

        return AndroidDocumentSelectionActivityScreen(surfacePalette: surfacePalette) {
            androidTopAppBar
        } filterBar: {
            androidFilterBar(visibleDocumentCount: visibleRows.count)
        } rows: {
            androidDocumentRowsContent(visibleRows)
        }
        .overlay(alignment: .topLeading) {
            AndroidActivityAccessibilityMarker(
                label: String(localized: "document", defaultValue: "Document"),
                accessibilityIdentifier: "modulePickerScreen",
                surfaceColor: surfacePalette.backgroundColor
            )
        }
        .androidAnchoredPopupMenu(
            anchorID: PopupAnchor.overflow,
            isPresented: $showOverflowMenu,
            menuWidth: 290,
            estimatedMenuHeight: 144,
            accessibilityIdentifier: "modulePickerOverflowMenu"
        ) {
            androidChooserOverflowMenu
        }
        .onChange(of: searchText) { oldValue, newValue in
            clearContextualModuleSelection()
            if oldValue.isEmpty && !newValue.isEmpty {
                selectedFilter = .all
                selectedLanguage = ""
            }
        }
    }

    /**
     Builds Android's `Document` app bar with back navigation and overflow access.

     - Returns: A 56-point top bar matching Android `ChooseDocument` title chrome.
     - Side effects: Back dismisses the chooser; overflow toggles the Android-style menu.
     - Failure modes: none.
     */
    @ViewBuilder
    private var androidTopAppBar: some View {
        if let contextualModule {
            let contextualDeletion = contextualRow.flatMap(Self.deletionSelection)
            AndroidDocumentContextActionBar(
                actions: contextualModuleActions,
                surfacePalette: surfacePalette,
                accessibilityPrefix: "modulePicker",
                onClose: clearContextualModuleSelection,
                onAbout: {
                    clearContextualModuleSelection()
                    selectedModuleDetails = moduleDetails(for: contextualModule)
                },
                onDelete: {
                    clearContextualModuleSelection()
                    switch contextualDeletion {
                    case .addon(let addon):
                        pendingAddonUninstall = addon
                    case .module(let module):
                        pendingRowActionConfirmation = confirmation(
                            .uninstall,
                            for: module
                        )
                    case nil:
                        break
                    }
                },
                onUnlock: {
                    clearContextualModuleSelection()
                    beginUnlock(contextualModule)
                },
                onDeleteIndex: {
                    clearContextualModuleSelection()
                    pendingRowActionConfirmation = confirmation(.deleteIndex, for: contextualModule)
                }
            )
        } else if let contextualEpub {
            AndroidDocumentContextActionBar(
                actions: contextualEpubActions,
                surfacePalette: surfacePalette,
                accessibilityPrefix: "modulePicker",
                onClose: clearContextualModuleSelection,
                onAbout: {
                    clearContextualModuleSelection()
                    selectedModuleDetails = ModuleBrowserModuleDetails(epub: contextualEpub)
                },
                onDelete: {
                    clearContextualModuleSelection()
                    epubDeletionState.request([
                        EpubLibraryDeletionCandidate(
                            identifier: contextualEpub.identifier,
                            title: contextualEpub.initials
                        )
                    ])
                },
                onUnlock: {},
                onDeleteIndex: {
                    clearContextualModuleSelection()
                    pendingEpubIndexDeletion = contextualEpub
                }
            )
        } else {
            AndroidActivityTopAppBar(
                title: String(localized: "document", defaultValue: "Document"),
                accessibilityIdentifier: "modulePicker",
                backgroundColor: surfacePalette.toolbarBackgroundColor,
                foregroundColor: surfacePalette.toolbarForegroundColor,
                onBack: onDismiss
            ) {
                AndroidActivityTopAppBarActionButton(
                    icon: .asset("ToolbarOverflow"),
                    accessibilityLabel: String(localized: "system_items1", defaultValue: "More"),
                    accessibilityIdentifier: "modulePickerOverflowButton",
                    foregroundColor: surfacePalette.toolbarForegroundColor
                ) {
                    showOverflowMenu.toggle()
                }
                .androidPopupMenuAnchor(id: PopupAnchor.overflow)
            }
        }
    }

    /**
     Builds Android's chooser overflow menu.

     Android exposes Downloads, module backup, and local-file installation from this app bar. Each
     route remains inside the chooser except the explicit Downloads handoff.
     */
    private var androidChooserOverflowMenu: some View {
        AndroidPopupMenuSurface(
            colorScheme: colorScheme,
            accessibilityIdentifier: "modulePickerOverflowSurface",
            backgroundColor: surfacePalette.backgroundColor,
            primaryTextColor: surfacePalette.foregroundColor,
            secondaryTextColor: surfacePalette.secondaryForegroundColor,
            accentColor: AndroidDialogSurfacePalette.accent(for: colorScheme)
        ) {
            VStack(spacing: 0) {
                AndroidPopupMenuRow(
                    title: String(
                        localized: "backup_modules2",
                        defaultValue: "Backup Documents to…"
                    ),
                    accessibilityIdentifier: "modulePickerBackupDocumentsButton"
                ) {
                    guard !isExportingModuleBackup else { return }
                    showOverflowMenu = false
                    presentModuleBackupSelection()
                }
                AndroidPopupMenuRow(
                    title: String(localized: "download", defaultValue: "Download Documents"),
                    accessibilityIdentifier: "modulePickerDownloadsButton"
                ) {
                    showOverflowMenu = false
                    openDownloadsAfterDismiss()
                }
                AndroidPopupMenuRow(
                    title: String(
                        localized: "install_zip",
                        defaultValue: "Load Documents From Files"
                    ),
                    accessibilityIdentifier: "modulePickerInstallZipButton"
                ) {
                    guard !isImportingExternalDocument else { return }
                    showOverflowMenu = false
                    showInstallZipImporter = true
                }
            }
        }
    }

    /**
     Builds Android's inline language, search, type, and result-count filters.

     - Parameter visibleDocumentCount: Number of rows after current filters.
     - Returns: The compact filter strip from Android `document_selection.xml`.
     - Side effects: Menus and the text field mutate the active picker filters.
     - Failure modes: Large Dynamic Type splits controls into two rows to avoid overlap.
     */
    private func androidFilterBar(visibleDocumentCount: Int) -> AndroidDocumentSelectionFilterBar {
        AndroidDocumentSelectionFilterBar(
            surfacePalette: surfacePalette,
            languageTitle: languageFilterTitle(for: selectedLanguage),
            languageOptions: availableLanguages.map {
                AndroidDocumentSelectionOption(id: $0, title: Self.displayName(for: $0))
            },
            documentTypeTitle: Self.documentTypeFilterTitle(for: selectedFilter),
            documentTypeOptions: Self.documentTypeFilterOrder.enumerated().map { index, filter in
                AndroidDocumentSelectionOption(
                    id: String(index),
                    title: Self.documentTypeFilterTitle(for: filter)
                )
            },
            resultCountTitle: AndroidDocumentSelectionFilterBar.localizedResultCount(
                visibleDocumentCount
            ),
            searchPlaceholder: String(
                localized: "free_text_search_documents",
                defaultValue: "Search"
            ),
            searchText: $searchText,
            accessibilityPrefix: "modulePicker",
            onOpenLanguageOptions: {
                clearContextualModuleSelection()
                selectedLanguage = ""
            },
            onSelectLanguage: {
                clearContextualModuleSelection()
                selectedLanguage = $0
            },
            onSearchFocused: {
                clearContextualModuleSelection()
                selectedLanguage = ""
                selectedFilter = .all
            },
            onSelectDocumentType: { optionID in
                guard let index = Int(optionID),
                      Self.documentTypeFilterOrder.indices.contains(index) else { return }
                clearContextualModuleSelection()
                selectedFilter = Self.documentTypeFilterOrder[index]
            }
        )
    }

    /**
     Builds the scrollable Android document rows.

     - Parameter visibleRows: Rows that survived the active filters.
     - Returns: Empty, no-match, or document row content.
     - Side effects: Row actions can mutate reader state or document management state.
     - Failure modes: Empty states include a Downloads handoff when the active document type has no
       installed rows.
     */
    @ViewBuilder
    private func androidDocumentRowsContent(_ visibleRows: [DocumentChooserRow]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if shouldShowFilterEmptyState {
                    VStack(spacing: 12) {
                        androidMessageRow(emptyMessage)
                        Button(String(localized: "download_modules")) {
                            openDownloadsAfterDismiss()
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else if visibleRows.isEmpty {
                    androidMessageRow(String(localized: "no_modules_match_filters"))
                } else {
                    ForEach(visibleRows) { row in
                        androidDocumentRow(row)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(surfacePalette.backgroundColor)
    }

    /**
     Builds one centered message row for Android chooser empty states.

     - Parameter message: User-visible text.
     - Returns: Full-width text row.
     - Side effects: none.
     - Failure modes: none.
     */
    private func androidMessageRow(_ message: String) -> some View {
        Text(message)
            .font(.body)
            .foregroundStyle(surfacePalette.secondaryForegroundColor)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 16)
            .padding(.vertical, 24)
    }

    /**
     Builds one selectable Android document row.

     - Parameter row: Installed module or visible Android pseudo-document.
     - Returns: A row matching Android `document_list_item` structure.
     - Side effects: Selection performs the row's document action.
     - Failure modes: Add-ons keep Android's non-selecting behavior through `select(_:)`.
     */
    @ViewBuilder
    private func androidDocumentRow(_ row: DocumentChooserRow) -> some View {
        switch row {
        case .module(let module):
            moduleRow(
                module.info,
                rowID: row.id,
                primaryTitle: row.primaryTitle,
                accessibilityIdentifier: row.moduleAccessibilityIdentifier
            )
        case .addon(let addon):
            moduleRow(
                addon.moduleInfo,
                rowID: row.id,
                primaryTitle: row.primaryTitle,
                accessibilityIdentifier: row.moduleAccessibilityIdentifier
            )
        case .epub(let epub):
            epubRow(epub)
        case .pseudoDocument(let document):
            pseudoDocumentRow(document)
        }
    }

    /**
     Builds one imported EPUB row as an Android `GENERAL_BOOK` document.

     - Parameter epub: Installed adapter metadata.
     - Returns: Tappable chooser row using stable EPUB initials as document identity.
     - Side effects: Selecting the row activates its general-book adapter and opens its TOC.
     - Failure modes: An EPUB that disappears between list construction and selection leaves the
       current document unchanged because `switchEpub(identifier:)` fails closed.
     */
    private func epubRow(_ epub: EpubInfo) -> some View {
        androidRowContainer(
            accessibilityIdentifier: "modulePickerRow::\(epub.initials)",
            isSelected: contextualDocument == .epub(epub.identifier),
            onLongPress: { beginContextualEpubSelection(epub) },
            leading: {
                AndroidDocumentListLeadingColumn(
                    category: .generalBook,
                    languageTitle: Self.displayName(for: epub.language),
                    installSizeTitle: nil,
                    statusIconAssetName: nil,
                    statusIconColor: .clear,
                    isRecommended: false,
                    isWarned: false,
                    encryptionState: .none,
                    surfacePalette: surfacePalette
                )
            },
            center: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(epub.initials)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(surfacePalette.foregroundColor)
                        .lineLimit(1)
                    Text(epub.title)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(surfacePalette.secondaryForegroundColor)
                        .lineLimit(2)
                }
            },
            trailing: {
                Spacer().frame(width: 48)
            },
            selection: {
                handleEpubRowTap(epub)
            }
        )
    }

    /**
     Builds one installed module row with Android list-item columns and row actions.

     - Parameters:
       - module: Installed module metadata from the active controller.
       - rowID: Comparator-distinct chooser identity retained through contextual selection.
       - primaryTitle: Android `Book.abbreviation` text rendered above the book name.
       - accessibilityIdentifier: Exact row identifier exposed to UI automation.
     - Returns: Tappable row that switches or opens the selected document.
     - Side effects: User gestures may open About, start contextual selection, or invoke reader
       switching through the existing picker callbacks.
     - Failure modes: Locked and stale modules remain visible; selection preflights fail closed in
       the controller without dismissing the picker.
     */
    private func moduleRow(
        _ module: ModuleInfo,
        rowID: String,
        primaryTitle: String,
        accessibilityIdentifier: String
    ) -> some View {
        let actions = Self.rowActions(for: module, installedModules: allSelectableModules)
        return androidRowContainer(
            accessibilityIdentifier: accessibilityIdentifier,
            isSelected: isContextualModuleSelected(rowID),
            onLongPress: { beginContextualModuleSelection(rowID: rowID) },
            leading: {
                AndroidDocumentListLeadingColumn(
                    category: module.category,
                    languageTitle: Self.displayName(for: module.language),
                    installSizeTitle: nil,
                    statusIconAssetName: nil,
                    statusIconColor: .clear,
                    isRecommended: false,
                    isWarned: false,
                    encryptionState: Self.encryptionState(for: module),
                    surfacePalette: surfacePalette
                )
            },
            center: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(primaryTitle)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(surfacePalette.foregroundColor)
                        .lineLimit(1)
                    Text(module.description)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(surfacePalette.secondaryForegroundColor)
                        .lineLimit(2)
                }
            },
            trailing: {
                VStack(alignment: .trailing, spacing: 10) {
                    if actions.contains(.about) {
                        aboutButton(for: module)
                    }
                }
                .frame(width: 48, alignment: .trailing)
            },
            selection: {
                handleModuleRowTap(module, rowID: rowID)
            }
        )
    }

    /**
     Builds one visible Android pseudo-document row.

     - Parameter document: Pseudo-document identity from Android `FakeBookFactory`.
     - Returns: Tappable row that opens the equivalent iOS document route.
     */
    private func pseudoDocumentRow(_ document: AndroidPseudoDocument) -> some View {
        androidRowContainer(
            accessibilityIdentifier: "modulePickerPseudoRow::\(document.rawValue)",
            leading: {
                AndroidDocumentListLeadingColumn(
                    category: Self.moduleCategory(for: document),
                    languageTitle: Self.displayName(for: document.language),
                    installSizeTitle: nil,
                    statusIconAssetName: nil,
                    statusIconColor: .clear,
                    isRecommended: false,
                    isWarned: false,
                    encryptionState: .none,
                    surfacePalette: surfacePalette
                )
            },
            center: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(document.androidInitials)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(surfacePalette.foregroundColor)
                        .lineLimit(1)
                    Text(document.description)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(surfacePalette.secondaryForegroundColor)
                        .lineLimit(2)
                }
            },
            trailing: {
                Spacer()
                    .frame(width: 48)
            },
            selection: {
                guard !hasContextualDocumentSelection else {
                    clearContextualModuleSelection()
                    return
                }
                select(document)
            }
        )
    }

    /**
     Builds the shared Android `document_list_item` row frame.

     - Parameters:
       - accessibilityIdentifier: Stable identifier for the concrete row.
       - isSelected: Whether Android's contextual action mode currently owns the row.
       - onLongPress: Optional callback that enters contextual mode for a manageable row.
       - leading: Left icon/language column.
       - center: Main abbreviation and description column.
       - trailing: Right action/status column.
       - selection: Primary row action matching Android list-item selection.
     - Returns: A full-width button row with Android spacing and divider placement.
     - Side effects: Executes `selection` after a tap and `onLongPress` after the Android hold delay.
     - Failure modes: Rows without a long-press callback remain ordinary selectable rows.
     */
    private func androidRowContainer<Leading: View, Center: View, Trailing: View>(
        accessibilityIdentifier: String,
        isSelected: Bool = false,
        onLongPress: (() -> Void)? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder center: () -> Center,
        @ViewBuilder trailing: () -> Trailing,
        selection: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Button(action: selection) {
                    HStack(alignment: .top, spacing: 12) {
                        leading()
                        center()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear
                            .frame(width: 48, height: 44)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(accessibilityIdentifier)
                .accessibilityValue(isSelected ? "selected" : "")

                trailing()
                    .padding(.top, 12)
                    .padding(.trailing, 14)
            }

            Rectangle()
                .fill(surfacePalette.inactiveBorderColor)
                .frame(height: 1)
                .padding(.leading, 96)
        }
        .androidDocumentContextSelection(
            isSelected: isSelected,
            onLongPress: onLongPress
        )
    }

    /**
     Builds Android's row-level About action button.

     - Parameter module: Installed module whose details should be shown.
     - Returns: Template info icon matching Android's `aboutButton` column.
     - Side effects: Sets `selectedModuleDetails`, presenting the shared details dialog.
     - Failure modes: Details payload falls back to installed-module metadata when repository source
       metadata is unavailable.
     */
    private func aboutButton(for module: ModuleInfo) -> some View {
        Button {
            clearContextualModuleSelection()
            selectedModuleDetails = moduleDetails(for: module)
        } label: {
            AndBibleIconView(name: "DocumentInfo", size: 24)
                .foregroundStyle(AndroidResourcePalette.grey600)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "about"))
        .accessibilityIdentifier("modulePickerAboutButton::\(module.name)")
    }

    /**
     Projects installed-module encryption into Android's shared document-row marker.

     - Parameter module: Installed module rendered by Choose Document.
     - Returns: No marker for ordinary modules, a red closed lock for locked encrypted modules, or a
       green open lock for unlocked encrypted modules.
     - Side effects: none.
     - Failure modes: none; `ModuleInfo` exposes both required flags.
     */
    private static func encryptionState(for module: ModuleInfo) -> AndroidDocumentEncryptionState {
        guard module.isEncrypted else { return .none }
        return module.isUnlocked ? .unlocked : .locked
    }

    /**
     Maps one Android pseudo-document category onto the shared document-list category glyph.

     - Parameter document: Pseudo-document from Android's `FakeBookFactory` projection.
     - Returns: Matching SWORD module category, with unsupported pseudo categories using General Book.
     - Side effects: none.
     - Failure modes: none; the default branch is an explicit generic-book fallback.
     */
    private static func moduleCategory(for document: AndroidPseudoDocument) -> ModuleCategory {
        switch document.category {
        case .commentary:
            return .commentary
        case .dictionary:
            return .dictionary
        case .map:
            return .map
        case .generalBook:
            return .generalBook
        default:
            return .generalBook
        }
    }

    /**
     Enters Android's single-choice contextual mode for an installed chooser row.

     - Parameter rowID: Comparator-distinct chooser identity for the long-pressed row.
     - Side effects: Closes the ordinary overflow popup and replaces the app bar with contextual
       document actions.
     - Failure modes: A stale or comparator-colliding row ID absent from the current `allRows`
       snapshot is ignored before contextual state changes.
     */
    private func beginContextualModuleSelection(rowID: String) {
        guard allRows.contains(where: { $0.id == rowID && $0.moduleInfo != nil }) else { return }
        showOverflowMenu = false
        contextualDocument = .module(rowID)
    }

    /**
     Enters Android's single-choice contextual mode for an imported EPUB document row.

     - Parameter epub: Long-pressed installed EPUB general book.
     - Side effects: Closes the ordinary overflow popup and selects the EPUB for shared document
       About, Delete, and Delete Index actions.
     - Failure modes: A concurrently removed, replaced, or globally rejected EPUB is ignored before
       contextual state changes; a later removal makes `contextualEpub` resolve to nil safely.
     */
    private func beginContextualEpubSelection(_ epub: EpubInfo) {
        guard selectableEpubs.contains(epub) else { return }
        showOverflowMenu = false
        contextualDocument = .epub(epub.identifier)
    }

    /**
     Applies Android row-tap behavior in normal or contextual mode.

     - Parameters:
       - module: Tapped installed module.
       - rowID: Comparator-distinct chooser identity for the rendered row.
     - Side effects: Selects the document normally when no contextual action mode exists; otherwise
       changes the single selected contextual row or closes contextual mode when the same row is tapped.
     - Failure modes: Ordinary document selection retains the existing unlock and key-validation paths.
     */
    private func handleModuleRowTap(_ module: ModuleInfo, rowID: String) {
        guard hasContextualDocumentSelection else {
            select(module)
            return
        }
        let selection = ContextualDocument.module(rowID)
        contextualDocument = isContextualModuleSelected(rowID) ? nil : selection
    }

    /**
     Tests contextual module selection with the row's comparator-distinct encoded identity.

     - Parameter rowID: Stable ASCII chooser identity represented by the rendered/tapped row.
     - Returns: True only when the same comparator-distinct row owns contextual selection.
     - Side effects: None.
     - Failure modes: None; row IDs encode Java-exact fields before reaching this comparison.
     */
    private func isContextualModuleSelected(_ rowID: String) -> Bool {
        guard case .module(let selectedRowID) = contextualDocument else { return false }
        return selectedRowID == rowID
    }

    /**
     Applies Android row-tap behavior to an imported EPUB in normal or contextual mode.

     - Parameter epub: Tapped installed EPUB row.
     - Side effects: Activates and opens the EPUB TOC in normal mode; otherwise changes or clears
       the single contextual selection without opening a document.
     - Failure modes: A stale row whose package disappeared, changed generation metadata, or lost
       global ownership is rejected before controller mutation; `switchEpub(identifier:)` also
       fails closed if the package disappears after this fresh admission check.
     */
    private func handleEpubRowTap(_ epub: EpubInfo) {
        guard selectableEpubs.contains(epub) else {
            if contextualDocument == .epub(epub.identifier) {
                clearContextualModuleSelection()
            }
            return
        }
        if hasContextualDocumentSelection {
            let selection = ContextualDocument.epub(epub.identifier)
            contextualDocument = contextualDocument == selection ? nil : selection
            return
        }
        controller.switchEpub(identifier: epub.identifier)
        dismissAndPresentAuxiliaryBrowser(onOpenGeneralBookBrowser)
    }

    /**
     Exits Android contextual mode without closing Choose Document.

     Side effects: Clears only the selected contextual module and ordinary overflow state.

     Failure modes: none; repeated calls are idempotent.
     */
    private func clearContextualModuleSelection() {
        contextualDocument = nil
        showOverflowMenu = false
    }

    /**
     Resolves Android's language filter label for the chooser.

     - Parameter language: Selected ISO language code, or empty when no language is selected.
     - Returns: Android's placeholder label for no selection, otherwise the localized language name.
     - Side effects: none.
     - Failure modes: Unknown language codes fall back through `displayName(for:)`.
     */
    private func languageFilterTitle(for language: String) -> String {
        guard !language.isEmpty else {
            return String(localized: "chooce_language_hint", defaultValue: "Language")
        }
        return Self.displayName(for: language)
    }

    /// Message shown when the requested filter has no selectable rows.
    private var emptyMessage: String {
        switch selectedFilter {
        case .category(.commentary):
            return String(localized: "picker_no_commentary_modules")
        case .category(.dictionary):
            return String(localized: "picker_no_dictionary_modules")
        case .category(.generalBook):
            return String(localized: "picker_no_general_book_modules")
        case .category(.map):
            return String(localized: "picker_no_map_modules")
        case .addons:
            return String(localized: "picker_no_addon_modules", defaultValue: "No add-ons installed")
        default:
            return String(localized: "picker_no_bible_modules")
        }
    }

    /**
     Selects a module and applies the category-specific reader transition.

     - Parameter module: Installed module selected from the chooser.
     - Side effects:
       - routes every Bible row through the controller's fresh access preflight before switching or
         opening the existing cipher-key prompt
       - mutates the reader controller's active module/category for other normal reader modules
       - dismisses the chooser for selectable reader documents
       - opens the auxiliary browser for dictionary, general book, or map selections
     - Failure modes:
       - locked encrypted modules open the cipher-key prompt without changing reader state
       - stale locked Bible rows that became readable avoid a duplicate prompt and switch normally
       - add-on rows are intentionally non-selecting, matching Android's AND_BIBLE guard in
         `ChooseDocument.handleDocumentSelection`
     */
    private func select(_ module: ModuleInfo) {
        if module.category == .bible {
            selectUnlockedModule(module)
            return
        }
        if Self.requiresUnlock(module) {
            beginUnlock(module)
            return
        }
        selectUnlockedModule(module)
    }

    /**
     Applies a category-specific reader transition after chooser-row validation succeeds.

     - Parameter module: Installed module selected from the inclusive full chooser.
     - Side effects: Switches the pane document after the controller's authoritative access
       preflight; exact generic keys dismiss without another chooser, invalid/missing keys replace
       the picker with the matching key browser, and key validation or enumeration failures keep the
       picker visible with Retry/Cancel actions.
     - Failure modes: A Bible or commentary that became locked after row construction reuses the
       existing passphrase prompt without dismissing or mutating the pane. Other unavailable,
       add-on, and unsupported rows remain in the picker. Repeated generic SWORD failures retain the
       selected module for retry.
     */
    private func selectUnlockedModule(_ module: ModuleInfo) {
        guard let selectedDocumentCategory = Self.documentCategory(for: module.category) else {
            return
        }

        switch selectedDocumentCategory {
        case .commentary:
            Self.handleCommentarySelection(
                module,
                controller: controller,
                onDismiss: onDismiss,
                onBeginAuthoritativeUnlock: {
                    beginUnlock($0, authoritativeAccessState: true)
                }
            )
        case .dictionary:
            handleGenericModuleSwitch(
                controller.switchDictionaryDocument(to: module.name),
                module: module,
                onOpenBrowser: onOpenDictionaryBrowser
            )
        case .generalBook:
            handleGenericModuleSwitch(
                controller.switchGeneralBookDocument(to: module.name),
                module: module,
                onOpenBrowser: onOpenGeneralBookBrowser
            )
        case .map:
            handleGenericModuleSwitch(
                controller.switchMapDocument(to: module.name),
                module: module,
                onOpenBrowser: onOpenMapBrowser
            )
        default:
            switch controller.switchBibleDocument(to: module.name) {
            case .switched:
                onDismiss()
            case .requiresUnlock:
                beginUnlock(module, authoritativeAccessState: true)
            case .unavailable:
                break
            }
        }
    }

    /**
     Routes one commentary row through the controller's typed authorization outcome.

     The chooser row is only a snapshot and can become stale before selection. A failed switch
     therefore re-resolves the canonical installed row and manager access instead of trusting
     `ModuleInfo`: only a freshly locked commentary enters the existing authoritative cipher-key
     flow, while missing, unsupported, replaced, and category-incompatible targets keep the picker
     visible.

     - Parameters:
       - module: Commentary row selected from the inclusive installed inventory.
       - controller: Pane controller that owns the atomic commentary document switch and manager.
       - onDismiss: Callback that closes the picker only after a completed switch.
       - onBeginAuthoritativeUnlock: Callback that presents the existing unlock flow after fresh
         manager classification reports `.locked`.
     - Side effects: A successful controller switch mutates and persists the pane before dismissal;
       a locked failure invokes the unlock callback. Other failures produce no picker or pane mutation.
     - Failure modes: A missing manager, non-commentary canonical row, and every non-locked failure
       retain the picker. Fresh classification is deliberately performed only after `.failed`, so
       successful switches do not race redundant inventory reads.
     */
    static func handleCommentarySelection(
        _ module: ModuleInfo,
        controller: BibleReaderController,
        onDismiss: () -> Void,
        onBeginAuthoritativeUnlock: (ModuleInfo) -> Void
    ) {
        switch controller.switchCommentaryDocument(to: module.name) {
        case .switched:
            onDismiss()
        case .failed:
            guard let manager = controller.swordManager,
                  manager.installedModules().first(where: {
                      SwordJavaStringIdentity.equalsIgnoreCase($0.name, module.name)
                  })?.category == .commentary,
                  manager.moduleAccessState(named: module.name) == .locked else {
                return
            }
            onBeginAuthoritativeUnlock(module)
        }
    }

    /**
     Routes one generic document switch according to Android's retain-or-choose contract.

     - Parameters:
       - outcome: Controller result after exact-key validation.
       - module: Selected module retained only when a failed lookup needs retry.
       - onOpenBrowser: Category-specific key chooser presentation callback.
     - Side effects: Dismisses the picker immediately when content can render, replaces it with the
       key browser only for an invalid/missing key, or keeps it open with a retry alert on read failure.
     - Failure modes: Repeated SWORD validation/enumeration failures keep the same retryable alert and
       never mutate the pane. A later transient browser failure uses the browser's retry state.
     */
    private func handleGenericModuleSwitch(
        _ outcome: BibleReaderGenericModuleSwitchOutcome,
        module: ModuleInfo,
        onOpenBrowser: @escaping () -> Void
    ) {
        switch outcome {
        case .switchedPreservingKey:
            onDismiss()
        case .switchedRequiringKeySelection:
            dismissAndPresentAuxiliaryBrowser(onOpenBrowser)
        case .failed(let message):
            genericSwitchFailureMessage = message
            pendingGenericSwitchRetry = module
        }
    }

    /**
     Starts Android's passphrase prompt for an encrypted locked module.

     - Parameters:
       - module: Locked chooser row selected directly or through its context action.
       - authoritativeAccessState: Whether the shared controller preflight freshly classified the
         module locked, even if the chooser's older metadata snapshot says otherwise.
     - Side effects: Clears stale key/error state and presents the module-scoped unlock alert.
     - Failure modes: Without an authoritative locked result, already-unlocked and unencrypted
       modules bypass the prompt and select normally. The authoritative path prevents a stale-row
       recursion between selection and preflight.
     */
    private func beginUnlock(
        _ module: ModuleInfo,
        authoritativeAccessState: Bool = false
    ) {
        guard authoritativeAccessState || Self.requiresUnlock(module) else {
            selectUnlockedModule(module)
            return
        }
        unlockCipherKey = ""
        unlockFailureMessage = nil
        pendingUnlockModule = module
    }

    /**
     Applies the entered cipher key through `SwordManager` and verifies refreshed metadata.

     - Parameter module: Locked module associated with the visible prompt.
     - Side Effects: Updates SWORD cipher configuration, refreshes controller module caches, selects
       the document on success, or reopens the passphrase prompt with retry feedback on failure.
     - Failure Modes: Missing managers, empty/rejected keys, and modules that remain locked all use
       the same retry path without dismissing the chooser.
     */
    private func attemptUnlock(_ module: ModuleInfo) {
        let cipherKey = unlockCipherKey
        if ModuleUnlockActionCoordinator.submit(
            module: module,
            cipherKey: cipherKey,
            unlockModule: { moduleName, submittedKey in
                controller.swordManager?.unlockModule(
                    named: moduleName,
                    withCipherKey: submittedKey
                ) ?? false
            },
            onAccepted: {
                clearUnlockPrompt()
                controller.refreshInstalledModules()
                selectUnlockedModule(module)
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
     Opens the existing module details dialog at Android's unlock-information action.

     - Parameter module: Locked module whose provider instructions should be shown.
     - Side Effects: Dismisses the passphrase prompt and presents module About metadata.
     - Failure Modes: Modules without unlock information do not expose this action.
     */
    private func showUnlockInformation(for module: ModuleInfo) {
        clearUnlockPrompt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            selectedModuleDetails = moduleDetails(for: module)
        }
    }

    /**
     Clears all transient cipher-key prompt state.

     - Side Effects: Dismisses the unlock alert and removes the entered key/failure message.
     - Failure Modes: None.
     */
    private func clearUnlockPrompt() {
        pendingUnlockModule = nil
        unlockCipherKey = ""
        unlockFailureMessage = nil
    }

    /**
     Selects one Android visible pseudo-document.

     - Parameter document: Pseudo-document row selected by the user.
     Side effects:
     - dismisses the chooser
     - opens My Notes, Compare, or the StudyPad selector through existing reader routes

	     Failure modes:
	     - pseudo-document loading keeps the controller's client-ready replay contract; selecting My
	       Notes before the WebView client is ready records the visible route intent and replays the
	       document load when the client finishes bootstrapping.
	     */
    private func select(_ document: AndroidPseudoDocument) {
        switch document {
        case .myNotes:
            dismissAndPerform {
                controller.loadMyNotesDocument()
            }
        case .studyPads:
            dismissAndPresentAuxiliaryBrowser(onOpenStudyPadSelector)
        case .compare:
            dismissAndPerform {
                controller.loadCompareDocument()
            }
        }
    }

    /**
     Replaces the chooser destination with Downloads on the existing reader stack.

     Side effects: invokes `onOpenDownloads`; the coordinator preserves the captured pane and owns
     the destination replacement.
     */
    private func openDownloadsAfterDismiss() {
        onOpenDownloads()
    }

    /**
     Replaces the picker with a category-specific browser on the same reader stack.

     - Parameter presentation: Browser presentation callback supplied by the reader coordinator.
     Side effects:
     - invokes the coordinator-owned destination replacement
     */
    private func dismissAndPresentAuxiliaryBrowser(_ presentation: @escaping () -> Void) {
        presentation()
    }

    /**
     Performs a reader document action and then closes the chooser destination.

     - Parameter action: Synchronous controller action matching Android's activity result handling.
     Side effects:
     - invokes `action`
     - invokes `onDismiss`
     */
    private func dismissAndPerform(_ action: @escaping () -> Void) {
        action()
        onDismiss()
    }

    /**
     Builds the shared About dialog payload for an installed module.

     - Parameter module: Installed module selected from the chooser.
     - Returns: Installed-only details payload compatible with Android's reader-picker About dialog.
     */
    private func moduleDetails(for module: ModuleInfo) -> ModuleBrowserModuleDetails {
        ModuleBrowserModuleDetails(installedModule: module)
    }

    /**
     Builds a destructive action confirmation payload for an installed module.

     - Parameters:
       - kind: Destructive operation to confirm.
       - module: Installed module selected from the chooser.
     - Returns: Confirmation payload shared with Downloads row actions.
     */
    private func confirmation(
        _ kind: ModuleBrowserRowActionConfirmation.Kind,
        for module: ModuleInfo
    ) -> ModuleBrowserRowActionConfirmation {
        ModuleBrowserRowActionConfirmation(
            kind: kind,
            installedModule: module
        )
    }

    /**
     Uninstalls one installed module using the same repository service as Downloads.

     - Parameter name: Module initials to remove from local storage.
     Side effects:
     - deletes the module's generated Search index before repository file removal, matching Android
     - deletes module files off the main actor
     - `ModuleRepository` posts the module-store notification used by reader controllers to refresh
     - records failures for a user-visible alert
     */
    private func uninstallInstalledModule(_ name: String) {
        let repository = repository
        let searchIndexService = searchIndexService

        Task {
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
            } catch {
                await MainActor.run {
                    rowActionErrorMessage = error.localizedDescription
                }
            }
        }
    }

    /**
     Uninstalls the exact config or generated CSV owner selected from Android's Add-ons filter.

     - Parameter addon: Admitted add-on row retaining its opaque installed deletion identity.
     - Side effects: Deletes the shared initials-based Search index first, then transactionally
       removes only the selected config/payload or standalone prompt CSV off the main actor.
     - Failure modes: Stale owner, path/ownership, filesystem, and rollback failures are retained
       as the row-action error; no same-initials fallback is attempted.
     */
    private func uninstallInstalledAddon(_ addon: SwordAdmittedAddonModule) {
        let repository = repository
        let searchIndexService = searchIndexService

        Task {
            do {
                try await ModuleSearchIndexUninstaller.uninstall(
                    moduleName: addon.moduleInfo.name,
                    deleteSearchIndex: { moduleName in
                        await searchIndexService.deleteIndex(for: moduleName)
                    },
                    removeModule: { _ in
                        try await Task.detached(priority: .userInitiated) {
                            try repository.uninstallAddon(addon.removalTarget)
                        }.value
                    }
                )
            } catch {
                await MainActor.run {
                    rowActionErrorMessage = error.localizedDescription
                }
            }
        }
    }

    /**
     Commits the EPUB deletion confirmed from Android's shared document action mode.

     - Side effects: Removes the published EPUB, notifies the reader owner only after durable
       deletion succeeds, and clears the confirmation request before storage work begins.
     - Failure modes: Stops at the first storage error and leaves that failure visible in the
       shared document-action dialog; successfully deleted EPUBs are never reported as present.
     */
    private func deletePendingEpubs() {
        rowActionErrorMessage = epubDeletionState.commit(
            delete: { try EpubReader.delete(identifier: $0) },
            onDeleted: onDeleteEpub
        )?.localizedDescription
    }

    /**
     Deletes an imported EPUB's FTS index through immutable generation publication.

     Android keeps the document installed and usable after Delete Index. The iOS adapter therefore
     publishes an index-free generation off the main actor and adopts it only when this pane still
     owns the same EPUB identity.

     - Parameter epub: Stable installed EPUB selected by contextual action mode.
     - Side effects: Publishes a replacement generation and re-renders the active EPUB when the
       initiating pane still owns it.
     - Failure modes: Publication errors surface in the shared action dialog. A stale pane or a
       document switch does not overwrite the newer reader state.
     */
    private func deleteEpubSearchIndex(_ epub: EpubInfo) {
        let identifier = epub.identifier
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                do {
                    return Result<EpubReader, Error>.success(
                        try EpubReader.deleteSearchIndex(identifier: identifier)
                    )
                } catch {
                    return Result<EpubReader, Error>.failure(error)
                }
            }.value

            switch outcome {
            case .success(let replacementReader):
                guard controller.activeEpubReader?.identifier == identifier else { return }
                guard controller.adoptRebuiltEpubReader(replacementReader) else {
                    rowActionErrorMessage = String(
                        localized: "error_occurred",
                        defaultValue: "An error has occurred"
                    )
                    return
                }
            case .failure(let error):
                rowActionErrorMessage = error.localizedDescription
            }
        }
    }

    /**
     Deletes one installed module's local search index.

     - Parameter name: Module initials whose search index should be deleted.
     Side effects:
     - delegates to `SearchIndexService`, whose missing-index behavior is intentionally harmless
     */
    private func deleteModuleIndex(_ name: String) {
        Task {
            await searchIndexService.deleteIndex(for: name)
        }
    }

    /**
     Presents Android's installed-document backup selection in language-first order.

     - Side Effects: Reads current manager inventory, stores a stable candidate snapshot, and opens
       the selected-by-default module sheet.
     - Failure Modes: Missing or empty inventory surfaces a user-visible no-modules error.
     */
    private func presentModuleBackupSelection() {
        guard let modules = controller.swordManager?.installedModules(), !modules.isEmpty else {
            rowActionErrorMessage = String(
                localized: "android_module_backup_no_modules",
                defaultValue: "No installed documents can be backed up."
            )
            return
        }
        moduleBackupCandidates = Self.sortedBackupModules(modules)
        showModuleBackupSelection = true
    }

    /**
     Dismisses module-backup selection without writing an archive.

     - Side Effects: Clears the candidate snapshot and active export state.
     - Failure Modes: None.
     */
    private func dismissModuleBackupSelection() {
        showModuleBackupSelection = false
        moduleBackupCandidates = []
        isExportingModuleBackup = false
    }

    /**
     Generates Android's `.abmd.zip` archive for selected installed documents.

     - Parameter moduleNames: Module initials selected in display order.
     - Side Effects: Reads module files off the main actor, dismisses selection, and presents the
       document exporter with Android's filename.
     - Failure Modes: Empty selections and archive errors leave the chooser open and surface an
       actionable error.
     */
    private func exportModuleBackup(moduleNames: [String]) {
        guard !moduleNames.isEmpty else {
            rowActionErrorMessage = String(
                localized: "android_module_backup_no_modules",
                defaultValue: "No installed documents can be backed up."
            )
            return
        }
        isExportingModuleBackup = true
        let selectedModuleNames = Set(moduleNames)

        Task { @MainActor in
            await Task.yield()
            do {
                let export = try await Task.detached(priority: .userInitiated) {
                    try AndroidModuleBackupService().exportArchiveFile(moduleNames: selectedModuleNames)
                }.value
                isExportingModuleBackup = false
                showModuleBackupSelection = false
                moduleBackupCandidates = []
                if let moduleBackupTemporaryFileURL {
                    try? FileManager.default.removeItem(at: moduleBackupTemporaryFileURL)
                }
                moduleBackupTemporaryFileURL = export.fileURL
                moduleBackupDocument = BackupExportDocument(fileURL: export.fileURL)
                moduleBackupFileName = export.fileName
                await Task.yield()
                showModuleBackupExporter = true
            } catch {
                isExportingModuleBackup = false
                showModuleBackupSelection = false
                moduleBackupCandidates = []
                rowActionErrorMessage = error.localizedDescription
            }
        }
    }

    /**
     Handles completion of Android module-backup destination selection.

     - Parameter result: Exported destination URL or exporter error.
     - Side Effects: Surfaces success/failure feedback and resets the generated document payload.
     - Failure Modes: User cancellation is treated as a no-op.
     */
    private func handleModuleBackupExport(_ result: Result<URL, Error>) {
        defer {
            if let moduleBackupTemporaryFileURL {
                try? FileManager.default.removeItem(at: moduleBackupTemporaryFileURL)
            }
            moduleBackupTemporaryFileURL = nil
            moduleBackupDocument = BackupExportDocument()
            moduleBackupFileName = AndroidModuleBackupService.moduleBackupFileName
        }
        switch result {
        case .success:
            externalDocumentImportMessage = String(
                localized: "android_module_backup_export_success",
                defaultValue: "Module backup exported successfully."
            )
        case .failure(let error):
            guard !Self.isFileImporterCancellation(error) else { return }
            rowActionErrorMessage = error.localizedDescription
        }
    }

    /**
     Handles Android's Load Documents From Files picker result.

     - Parameter result: File importer URLs or provider error.
     - Side Effects: Builds a metadata-preserving request and starts read-only import preflight.
     - Failure Modes: Cancellation is ignored; provider errors become chooser feedback.
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
            guard !Self.isFileImporterCancellation(error) else { return }
            externalDocumentImportMessage = error.localizedDescription
        }
    }

    /**
     Inspects a selected archive before any local SWORD destination is overwritten.

     - Parameter request: Selected document URL and provider metadata.
     - Side Effects: Captures installed/local registration metadata, runs archive inspection off the
       main actor, then starts import, presents exact overwrite conflicts, or reports validation.
     - Failure Modes: My Documents metadata failure reserves every EPUB identity; failed archive
       preflight never runs installer writes.
     */
    private func preflightExternalDocumentImport(_ request: ExternalDocumentImportRequest) {
        isImportingExternalDocument = true
        externalDocumentImportProgress = ModuleInstallProgress(phase: .queued)
        let service = ExternalDocumentImportService.androidRegistryAware(
            modelContext: modelContext,
            swordManager: controller.swordManager
        )
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
                pendingLocalModuleOverwrite = DocumentPickerLocalOverwriteConfirmation(
                    request: request,
                    inspection: inspection
                )
            case .failed(let message):
                isImportingExternalDocument = false
                externalDocumentImportProgress = nil
                externalDocumentImportMessage = ExternalDocumentImportResult.failed(
                    message: message
                ).feedbackMessage
            }
        }
    }

    /**
     Installs one preflighted external document with explicit overwrite authorization.

     - Parameters:
       - request: Selected ZIP, EPUB, font, or Android module-backup request.
       - overwritePolicy: Conflict policy, with replacement used only after explicit consent.
     - Side Effects: Captures Android's installed/local registry, runs installer I/O off the main
       actor, publishes progress, refreshes controller module inventory, and surfaces structured
       feedback without dismissing the chooser.
     - Failure Modes: EPUB identity collisions and installer failures are returned as user-visible
       feedback and preserve retry; My Documents metadata failure rejects EPUB admission closed.
     */
    private func importExternalDocument(
        _ request: ExternalDocumentImportRequest,
        overwritePolicy: LocalSwordZipOverwritePolicy
    ) {
        isImportingExternalDocument = true
        externalDocumentImportProgress = ModuleInstallProgress(phase: .queued)
        let service = ExternalDocumentImportService.androidRegistryAware(
            modelContext: modelContext,
            swordManager: controller.swordManager
        )
        Task { @MainActor in
            await Task.yield()
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
            controller.refreshInstalledModules()
        }
    }

    /**
     Builds Android-style overwrite disclosure from exact conflicting local paths.

     - Parameter inspection: Validated local SWORD ZIP inspection.
     - Returns: Prompt text naming modules and every destination that replacement will modify.
     - Side Effects: None.
     - Failure Modes: Empty module names use a generic module label.
     */
    static func localModuleOverwriteMessage(_ inspection: LocalSwordZipInspection) -> String {
        let modules = inspection.moduleNames.isEmpty
            ? String(localized: "install_zip_module", defaultValue: "Bible module")
            : inspection.moduleNames.joined(separator: ", ")
        return "\(modules)\n\n" + inspection.conflictingPaths.joined(separator: "\n")
    }

    /**
     Detects the Cocoa error emitted when the user cancels a file importer/exporter.

     - Parameter error: SwiftUI document-picker error.
     - Returns: `true` for the standard user-cancelled code.
     - Side Effects: None.
     - Failure Modes: None.
     */
    static func isFileImporterCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain
            && nsError.code == CocoaError.userCancelled.rawValue
    }

    /**
     Sorts backup candidates using Android's language, description, and initials order.

     - Parameter modules: Installed non-pseudo module inventory.
     - Returns: Stable module order used by the backup selection sheet.
     - Side Effects: None.
     - Failure Modes: None.
     */
    static func sortedBackupModules(_ modules: [ModuleInfo]) -> [ModuleInfo] {
        modules.sorted { lhs, rhs in
            let languageOrder = lhs.language.localizedCaseInsensitiveCompare(rhs.language)
            if languageOrder != .orderedSame {
                return languageOrder == .orderedAscending
            }
            let descriptionOrder = lhs.description.localizedCaseInsensitiveCompare(rhs.description)
            if descriptionOrder != .orderedSame {
                return descriptionOrder == .orderedAscending
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /**
     Projects the EPUB library through Android's current global-book ownership result.

     Candidate admission and identity lookup belong to `BibleReaderInstalledModuleResolver`; this
     helper deliberately performs no second approximation of those rules. It only retains a
     candidate when the resolver-selected local EPUB has the same immutable library identifier,
     preventing a rejected candidate from borrowing an earlier owner's chooser row.

     - Parameters:
       - epubs: Complete installed EPUB metadata in stable library order.
       - resolvedOwnerIdentifier: Combined-registry lookup returning the selected local EPUB
         identifier, or `nil` when an installed book, My Document, missing generation, or metadata
         failure owns/blocks the candidate token.
     - Returns: Only candidates whose own identifier is the resolver-selected owner, preserving
       input order.
     - Side effects: None directly; the supplied resolver closure may perform metadata reads.
     - Failure modes: A nil or different owner identifier rejects the candidate without fallback.
     */
    static func admittedEpubs(
        from epubs: [EpubInfo],
        resolvedOwnerIdentifier: (EpubInfo) -> String?
    ) -> [EpubInfo] {
        epubs.filter { epub in
            resolvedOwnerIdentifier(epub) == epub.identifier
        }
    }

    /**
     Builds a SwiftUI row ID that cannot canonically fold Java-distinct module identities.

     - Parameters:
       - namespace: Stable backend namespace such as `module` or `epub`.
       - value: Exact JSword initials value.
     - Returns: A readable ASCII ID for ASCII values, or a lowercase UTF-16 hexadecimal
       ID for non-ASCII values so composed/decomposed spellings remain distinct to SwiftUI.
     - Side effects: None.
     - Failure modes: None; every Swift string has a valid UTF-16 view.
     */
    private static func javaExactRowID(namespace: String, value: String) -> String {
        guard value.utf16.contains(where: { $0 > 0x7f }) else {
            return "\(namespace):\(value)"
        }
        let encoded = value.utf16.map { String($0, radix: 16) }.joined(separator: "-")
        return "\(namespace):utf16:\(encoded)"
    }

    /**
     Encodes one comparator-distinct installed add-on identity for SwiftUI and contextual state.

     - Parameter addon: Shared admitted add-on retaining TreeSet abbreviation/identity fields.
     - Returns: ASCII ID containing length-delimited hexadecimal UTF-16 abbreviation, initials, and
       full-name fields; books retained by JSword cannot collide through Swift normalization.
     - Side effects: None.
     - Failure modes: None; every source field exposes valid UTF-16 code units.
     */
    private static func addonRowID(_ addon: SwordAdmittedAddonModule) -> String {
        let fields = [
            addon.abbreviation,
            addon.moduleInfo.name,
            addon.moduleInfo.description,
        ].map { value -> String in
            let units = Array(value.utf16)
            let encoded = units.map { String($0, radix: 16) }.joined(separator: "-")
            return "\(units.count):\(encoded)"
        }
        return "addon:\(fields.joined(separator: ":"))"
    }

    /**
     Builds Android chooser rows from globally admitted books retaining exact abbreviations.

     - Parameters:
       - installedBooks: Native/SQLite books after global ownership and BookSet projection.
       - admittedAddons: Shared payload-admitted add-ons retaining abbreviation/BookSet identity.
       - epubs: Installed EPUB general-book adapters.
     - Returns: Installed module/EPUB rows plus My Notes, StudyPads, and Compare pseudo-document rows.
     - Side effects: None.
     - Failure modes: None; caller-owned immutable metadata is projected without content reads.
     */
    static func allRows(
        installedBooks: [BibleReaderInstalledBookPresentation],
        admittedAddons: [SwordAdmittedAddonModule] = [],
        epubs: [EpubInfo] = []
    ) -> [DocumentChooserRow] {
        installedBooks.map(DocumentChooserRow.module) +
            admittedAddons.map(DocumentChooserRow.addon) +
            epubs.map(DocumentChooserRow.epub) +
            visibleAndroidPseudoDocuments.map(DocumentChooserRow.pseudoDocument)
    }

    /**
     Filters and sorts globally admitted chooser books using Android presentation metadata.

     - Parameters:
       - installedBooks: Installed books retaining exact JSword abbreviations.
       - admittedAddons: Shared payload-admitted add-ons retaining abbreviation/BookSet identity.
       - epubs: Installed EPUB general-book adapters.
       - selectedFilter: Android document-type filter.
       - selectedLanguage: ISO language filter, or empty for all languages.
       - searchText: Free-text search over initials, abbreviation, name, category, and language.
     - Returns: Filtered rows stably sorted by Android status/category and language-locale-lowercased
       abbreviation.
     - Side effects: None.
     - Failure modes: None; empty or unmatched inventories return an empty array.
     */
    static func filteredRows(
        installedBooks: [BibleReaderInstalledBookPresentation],
        admittedAddons: [SwordAdmittedAddonModule] = [],
        epubs: [EpubInfo] = [],
        selectedFilter: DocumentTypeFilter,
        selectedLanguage: String,
        searchText: String
    ) -> [DocumentChooserRow] {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchingRows = allRows(
            installedBooks: installedBooks,
            admittedAddons: admittedAddons,
            epubs: epubs
        ).filter { row in
            rowMatchesFilter(row, selectedFilter: selectedFilter) &&
            rowMatchesLanguage(row, selectedLanguage: selectedLanguage) &&
            rowMatchesSearch(row, searchText: trimmedSearch)
        }
        return matchingRows.enumerated().sorted { lhs, rhs in
            let comparison = rowSortComparison(lhs.element, rhs.element)
            return comparison == 0 ? lhs.offset < rhs.offset : comparison < 0
        }.map(\.element)
    }

    /**
     Builds the alphabetized language list shown in the chooser language filter.

     - Parameter rows: Complete chooser row set.
     - Returns: Unique ISO language codes sorted by localized display name.
     */
    static func availableLanguages(from rows: [DocumentChooserRow]) -> [String] {
        Array(Set(rows.map(\.language))).sorted {
            displayName(for: $0).localizedCaseInsensitiveCompare(displayName(for: $1)) == .orderedAscending
        }
    }

    /**
     Tests whether the selected Android document type has no rows before language/search filtering.

     - Parameters:
       - rows: Complete chooser row set.
       - selectedFilter: Android document-type filter.
     - Returns: `true` only when a concrete type has no matching chooser rows.
     */
    static func shouldShowFilterEmptyState(
        _ rows: [DocumentChooserRow],
        selectedFilter: DocumentTypeFilter
    ) -> Bool {
        guard selectedFilter != .all else { return false }
        return !rows.contains { rowMatchesFilter($0, selectedFilter: selectedFilter) }
    }

    /**
     Maps SWORD module categories into reader document categories that Android exposes.

     - Parameter moduleCategory: Category reported by SWORD metadata.
     - Returns: Matching reader document category, or `nil` for add-on and unsupported types.
     */
    static func documentCategory(for moduleCategory: ModuleCategory) -> DocumentCategory? {
        switch moduleCategory {
        case .bible:
            return .bible
        case .commentary:
            return .commentary
        case .dictionary:
            return .dictionary
        case .generalBook:
            return .generalBook
        case .map:
            return .map
        default:
            return nil
        }
    }

    /**
     Determines the initial Android document-type filter for the requested chooser category.

     - Parameter category: Category requested by the reader action.
     - Returns: The category when Android has a matching document-type row; otherwise all types.
     */
    static func initialCategoryFilter(for category: DocumentCategory) -> DocumentCategory? {
        documentCategoryFilterOrder.contains(category) ? category : nil
    }

    /**
     Determines the initial Android document-type filter for the requested chooser category.

     - Parameter category: Category requested by the reader action.
     - Returns: Matching document-type filter or `.all` when Android has no matching row.
     */
    static func initialDocumentTypeFilter(for category: DocumentCategory) -> DocumentTypeFilter {
        initialCategoryFilter(for: category).map(DocumentTypeFilter.category) ?? .all
    }

    /**
     Determines whether selecting an installed module must first request a cipher key.

     - Parameter module: Installed module metadata.
     - Returns: `true` only for encrypted modules not currently reported as unlocked.
     - Side Effects: None.
     - Failure Modes: None.
     */
    static func requiresUnlock(_ module: ModuleInfo) -> Bool {
        module.isEncrypted && !module.isUnlocked
    }

    /**
     Builds Android's module-scoped passphrase prompt title.

     - Parameter module: Locked module being unlocked.
     - Returns: Localized title containing the module initials.
     - Side Effects: None.
     - Failure Modes: Missing localization uses the supplied English format string.
     */
    static func unlockPromptTitle(for module: ModuleInfo) -> String {
        ModuleUnlockActionCoordinator.promptTitle(for: module)
    }

    /**
     Computes Android contextual document actions for an installed chooser row.

     - Parameters:
       - module: Installed module metadata.
       - installedModules: Complete Android-compatible installed inventory used to protect the last
         Bible from removal.
     - Returns: Ordered Android row actions, including unlock for encrypted installed modules.
     */
    static func rowActions(
        for module: ModuleInfo,
        installedModules: [ModuleInfo]
    ) -> [ModuleDownloadRowAction] {
        ModuleDownloadRowActionPlanner.availableActions(
            installedModule: module,
            isBeingInstalled: false,
            installedModules: installedModules
        )
    }

    /**
     Produces the localized display name for a language code.

     - Parameter languageCode: ISO language code from module metadata.
     - Returns: Localized language name, or the uppercased code when no name is available.
     */
    static func displayName(for languageCode: String) -> String {
        Locale.current.localizedString(forLanguageCode: languageCode) ?? languageCode.uppercased()
    }

    /// Android document-type filter order.
    static let documentTypeFilterOrder: [DocumentTypeFilter] = [
        .all,
        .category(.bible),
        .category(.commentary),
        .category(.dictionary),
        .category(.generalBook),
        .category(.map),
        .addons
    ]

    /// Android normal document category filter order, excluding All types and Add-ons.
    private static let documentCategoryFilterOrder: [DocumentCategory] = [
        .bible,
        .commentary,
        .dictionary,
        .generalBook,
        .map
    ]

    /// Android visible `FakeBookFactory.pseudoDocuments`, excluding hidden Memorize and non-chooser Multi.
    private static let visibleAndroidPseudoDocuments: [AndroidPseudoDocument] = [
        .myNotes,
        .studyPads,
        .compare
    ]

    /**
     Returns the localized title for one document-type filter row.

     - Parameter filter: Android document-type filter.
     - Returns: Localized picker label matching Android's document-type list.
     */
    private static func documentTypeFilterTitle(for filter: DocumentTypeFilter) -> String {
        switch filter {
        case .all:
            return String(localized: "doc_type_all", defaultValue: "All types")
        case .category(let category):
            return categoryFilterTitle(for: category)
        case .addons:
            return String(localized: "doc_type_addons", defaultValue: "Add-ons")
        }
    }

    /**
     Returns the localized title for one normal document category row.

     - Parameter category: Reader category.
     - Returns: Localized picker label matching Android's document-type list.
     */
    private static func categoryFilterTitle(for category: DocumentCategory) -> String {
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
        default:
            return String(localized: "doc_type_all", defaultValue: "All types")
        }
    }

    /**
     Returns the localized title for one installed module category.

     - Parameter moduleCategory: SWORD module category.
     - Returns: Localized picker label matching Android's document-type list.
     */
    private static func moduleCategoryTitle(for moduleCategory: ModuleCategory) -> String {
        if moduleCategory == .addon {
            return documentTypeFilterTitle(for: .addons)
        }
        return categoryFilterTitle(for: documentCategory(for: moduleCategory) ?? .bible)
    }

    /**
     Tests whether one row matches the active document-type filter.

     - Parameters:
       - row: Installed module or pseudo-document row.
       - selectedFilter: Android document-type filter.
     - Returns: `true` when the row belongs in the filter.
     */
    private static func rowMatchesFilter(
        _ row: DocumentChooserRow,
        selectedFilter: DocumentTypeFilter
    ) -> Bool {
        switch selectedFilter {
        case .all:
            return row.documentCategory != nil && !row.isAndroidAddon
        case .category(let category):
            return row.documentCategory == category
        case .addons:
            return row.isAndroidAddon
        }
    }

    /**
     Tests whether one row matches the active language filter.

     - Parameters:
       - row: Installed module or pseudo-document row.
       - selectedLanguage: ISO language filter, or empty for all languages.
     - Returns: `true` when the row should survive language filtering.
     */
    private static func rowMatchesLanguage(
        _ row: DocumentChooserRow,
        selectedLanguage: String
    ) -> Bool {
        selectedLanguage.isEmpty || row.language == selectedLanguage || row.isAndroidAddon
    }

    /**
     Tests whether one row matches the free-text chooser search.

     - Parameters:
       - row: Installed module or pseudo-document row.
       - searchText: Trimmed search text.
     - Returns: `true` when initials, description, language, or category text contains the query.
     */
    private static func rowMatchesSearch(_ row: DocumentChooserRow, searchText: String) -> Bool {
        guard !searchText.isEmpty else { return true }

        return row.searchableText.contains { value in
            value.localizedCaseInsensitiveContains(searchText)
        }
    }

    /**
     Compares chooser rows using Android's document status, category, and abbreviation order.

     - Parameters:
       - lhs: Left row.
       - rhs: Right row.
     - Returns: Negative, zero, or positive in Android chooser order; zero retains stable input order.
     */
    private static func rowSortComparison(
        _ lhs: DocumentChooserRow,
        _ rhs: DocumentChooserRow
    ) -> Int {
        let lhsInstalledRank = lhs.isRealInstalledDocument ? 0 : 1
        let rhsInstalledRank = rhs.isRealInstalledDocument ? 0 : 1
        if lhsInstalledRank != rhsInstalledRank {
            return lhsInstalledRank - rhsInstalledRank
        }

        let lhsRank = categoryRank(for: lhs)
        let rhsRank = categoryRank(for: rhs)
        if lhsRank != rhsRank {
            return lhsRank - rhsRank
        }

        let lhsKey = lhs.sortAbbreviation.lowercased(with: Locale(identifier: lhs.language))
        let rhsKey = rhs.sortAbbreviation.lowercased(with: Locale(identifier: rhs.language))
        return javaStringCompare(lhsKey, rhsKey)
    }

    /**
     Compares strings by Java `String.compareTo` unsigned UTF-16 ordering.

     - Parameters:
       - lhs: Left Android chooser sort key.
       - rhs: Right Android chooser sort key.
     - Returns: First UTF-16 unit difference, then length difference when one is a prefix.
     - Side effects: None.
     - Failure modes: None; every Swift string exposes valid UTF-16 code units.
     */
    private static func javaStringCompare(_ lhs: String, _ rhs: String) -> Int {
        let left = lhs.utf16
        let right = rhs.utf16
        for (leftUnit, rightUnit) in zip(left, right) where leftUnit != rightUnit {
            return Int(leftUnit) - Int(rightUnit)
        }
        return left.count - right.count
    }

    /**
     Resolves Android document-type sort rank for one row.

     - Parameter row: Installed module or pseudo-document row.
     - Returns: Lower rank for earlier Android chooser display order.
     */
    private static func categoryRank(for row: DocumentChooserRow) -> Int {
        if row.isAndroidAddon {
            return 6
        }

        switch row.documentCategory {
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

    /**
     Android document-type filter values from `DocumentSelectionBase.DOCUMENT_TYPE_SPINNER_FILTERS`.

     `all` excludes add-ons, while `addons` maps Android's AND_BIBLE category. Normal category
     filters match the reader document categories iOS can display.
     */
    enum DocumentTypeFilter: Hashable {
        /// Android "All types" filter.
        case all

        /// Android normal document category filter.
        case category(DocumentCategory)

        /// Android Add-ons filter for AND_BIBLE documents.
        case addons
    }

    /**
     One row in the Android document chooser.

     Rows retain installed SWORD documents, comparator-distinct add-ons, imported EPUBs, and the
     visible `FakeBookFactory` pseudo-documents that Android includes in `ChooseDocument`.
     */
    enum DocumentChooserRow: Identifiable, Equatable {
        /// Installed local module row.
        case module(BibleReaderInstalledBookPresentation)

        /// Payload-admitted And Bible add-on retaining JSword abbreviation and full identity.
        case addon(SwordAdmittedAddonModule)

        /// Imported EPUB exposed through Android's general-book contract.
        case epub(EpubInfo)

        /// Android visible pseudo-document row.
        case pseudoDocument(AndroidPseudoDocument)

        /// Stable row identity.
        var id: String {
            switch self {
            case .module(let module):
                return BibleReaderModulePicker.javaExactRowID(
                    namespace: "module",
                    value: module.info.name
                )
            case .addon(let addon):
                return BibleReaderModulePicker.addonRowID(addon)
            case .epub(let epub):
                return BibleReaderModulePicker.javaExactRowID(
                    namespace: "epub",
                    value: epub.initials
                )
            case .pseudoDocument(let document):
                return "pseudo:\(document.rawValue)"
            }
        }

        /// Reader document category for filtering and sorting.
        var documentCategory: DocumentCategory? {
            switch self {
            case .module(let module):
                return BibleReaderModulePicker.documentCategory(for: module.info.category)
            case .addon:
                return nil
            case .epub:
                return .generalBook
            case .pseudoDocument(let document):
                return document.category
            }
        }

        /// Language code used by Android's language spinner.
        var language: String {
            switch self {
            case .module(let module):
                return module.info.language
            case .addon(let addon):
                return addon.moduleInfo.language
            case .epub(let epub):
                return epub.language
            case .pseudoDocument(let document):
                return document.language
            }
        }

        /// Whether the row is an Android AND_BIBLE add-on.
        var isAndroidAddon: Bool {
            if case .addon = self { return true }
            guard case .module(let module) = self else { return false }
            return module.info.category == .addon
        }

        /// Whether Android would rank the row as a real installed SWORD document before fake rows.
        var isRealInstalledDocument: Bool {
            if case .epub = self { return true }
            if case .addon = self { return true }
            guard case .module(let module) = self else { return false }
            return BibleReaderModulePicker.documentCategory(for: module.info.category) != nil
                || module.info.category == .addon
        }

        /// Sort key matching Android's abbreviation-based row ordering.
        var sortAbbreviation: String {
            switch self {
            case .module(let module):
                return module.abbreviation
            case .addon(let addon):
                return addon.abbreviation
            case .epub(let epub):
                return epub.initials
            case .pseudoDocument(let document):
                return document.title
            }
        }

        /**
         Returns the Android `Book.abbreviation` text rendered as the chooser row's primary label.

         - Returns: The retained JSword abbreviation for installed books/add-ons, or the matching
           adapter/pseudo-document abbreviation.
         - Side effects: None.
         - Failure modes: None; every row case owns a nonoptional display identity.
         */
        var primaryTitle: String {
            switch self {
            case .module(let module):
                return module.abbreviation
            case .addon(let addon):
                return addon.abbreviation
            case .epub(let epub):
                return epub.initials
            case .pseudoDocument(let document):
                return document.androidInitials
            }
        }

        /**
         Returns the stable accessibility identifier for an installed module or add-on row.

         - Returns: The established initials-based identifier for ordinary modules, or the exact
           comparator-distinct add-on row ID when duplicate initials survive Android BookSet replay.
         - Side effects: None.
         - Failure modes: None; non-module rows return their stable row identity defensively.
         */
        var moduleAccessibilityIdentifier: String {
            switch self {
            case .module(let module):
                return "modulePickerRow::\(module.info.name)"
            case .addon:
                return "modulePickerRow::\(id)"
            case .epub, .pseudoDocument:
                return id
            }
        }

        /// Values included in the chooser's free-text search.
        var searchableText: [String] {
            switch self {
            case .module(let module):
                return [
                    module.info.name,
                    module.abbreviation,
                    module.info.description,
                    module.info.language,
                    BibleReaderModulePicker.displayName(for: module.info.language),
                    BibleReaderModulePicker.moduleCategoryTitle(for: module.info.category)
                ]
            case .addon(let addon):
                let module = addon.moduleInfo
                return [
                    module.name,
                    addon.abbreviation,
                    module.description,
                    module.language,
                    BibleReaderModulePicker.displayName(for: module.language),
                    BibleReaderModulePicker.moduleCategoryTitle(for: module.category)
                ]
            case .epub(let epub):
                return [
                    epub.initials,
                    epub.title,
                    epub.author,
                    epub.language,
                    BibleReaderModulePicker.displayName(for: epub.language),
                    BibleReaderModulePicker.categoryFilterTitle(for: .generalBook)
                ]
            case .pseudoDocument(let document):
                return [
                    document.androidInitials,
                    document.title,
                    document.description,
                    document.language,
                    BibleReaderModulePicker.displayName(for: document.language),
                    BibleReaderModulePicker.categoryFilterTitle(for: document.category)
                ]
            }
        }

        /// Installed module metadata used by rendering and contextual actions, when applicable.
        var moduleInfo: ModuleInfo? {
            switch self {
            case .module(let module):
                return module.info
            case .addon(let addon):
                return addon.moduleInfo
            case .epub, .pseudoDocument:
                return nil
            }
        }

        /**
         Compares rows by stable identity.

         - Parameters:
           - lhs: Left row.
           - rhs: Right row.
         - Returns: `true` when both rows represent the same exact module, add-on, EPUB, or
           pseudo-document identity.
         */
        static func == (lhs: DocumentChooserRow, rhs: DocumentChooserRow) -> Bool {
            lhs.id == rhs.id
        }
    }

    /** Exact installed owner retained before the contextual selection state is cleared. */
    enum InstalledDocumentDeletionSelection {
        /// Ordinary installed module routed through the established module uninstall boundary.
        case module(ModuleInfo)

        /// Comparator-distinct add-on routed through its opaque installed-owner token.
        case addon(SwordAdmittedAddonModule)
    }

    /**
     Captures the destructive owner represented by one installed chooser row.

     - Parameter row: Current chooser row before contextual selection state is cleared.
     - Returns: Ordinary module metadata or the exact admitted add-on owner; EPUB and pseudo rows
       return nil because their deletion flows are owned by separate boundaries.
     - Side effects: None; the returned value is immutable and survives subsequent UI-state reset.
     - Failure modes: None; unsupported row families return nil rather than approximating identity.
     */
    static func deletionSelection(
        for row: DocumentChooserRow
    ) -> InstalledDocumentDeletionSelection? {
        switch row {
        case .module(let module):
            return .module(module.info)
        case .addon(let addon):
            return .addon(addon)
        case .epub, .pseudoDocument:
            return nil
        }
    }

    /**
     Android visible pseudo-documents from `FakeBookFactory.pseudoDocuments`.

     Memorize is intentionally absent because Android marks it `HideFromSelector=1`. Multi is also
     absent because Android does not include it in the `pseudoDocuments` list used by
     `ChooseDocument`.
     */
    enum AndroidPseudoDocument: String, CaseIterable, Identifiable {
        /// Android My Note pseudo-document.
        case myNotes

        /// Android Journal/StudyPad pseudo-document.
        case studyPads

        /// Android Compare pseudo-document.
        case compare

        /// Stable row identity.
        var id: String { rawValue }

        /// Android module initials from `FakeBookFactory`.
        var androidInitials: String {
            switch self {
            case .myNotes:
                return "My Note"
            case .studyPads:
                return "Journal"
            case .compare:
                return "Compare"
            }
        }

        /// Reader category assigned by Android fake module metadata.
        var category: DocumentCategory {
            switch self {
            case .myNotes, .compare:
                return .commentary
            case .studyPads:
                return .generalBook
            }
        }

        /// Language code used by Android's language filtering for special fake documents.
        var language: String { "en" }

        /// User-facing row title.
        var title: String {
            switch self {
            case .myNotes:
                return String(localized: "my_notes", defaultValue: "My Notes")
            case .studyPads:
                return String(localized: "study_pad", defaultValue: "StudyPad")
            case .compare:
                return String(localized: "compare", defaultValue: "Compare")
            }
        }

        /// User-facing row subtitle.
        var description: String {
            switch self {
            case .myNotes:
                return String(
                    localized: "my_notes_description",
                    defaultValue: "Personal notes for the current passage"
                )
            case .studyPads:
                return String(
                    localized: "study_pad_description",
                    defaultValue: "StudyPad labels and saved study content"
                )
            case .compare:
                return String(
                    localized: "compare_description",
                    defaultValue: "Compare installed Bible translations"
                )
            }
        }

        /// Symbol used for the pseudo-document row leading affordance.
        var iconName: String {
            switch self {
            case .myNotes:
                return "note.text"
            case .studyPads:
                return "rectangle.stack"
            case .compare:
                return "text.columns"
            }
        }
    }
}
