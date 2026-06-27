import BibleCore
import SwiftUI
import SwordKit

/**
 Light document-selection palette matching Android's `ChooseDocument` activity surface.

 The chooser shares Android's `DocumentSelectionBase` layout with Downloads, but Android renders
 this route with a light content surface and a dark gray app bar. These constants keep the custom
 SwiftUI layout independent from reader theme colors so changing Bible text colors does not
 accidentally recolor the document-management screen.
 */
private enum DocumentChooserPalette {
    /// Activity background behind filters and rows.
    static let background = Color.white

    /// Android action bar chrome for the Document activity.
    static let appBar = Color(red: 0.27, green: 0.27, blue: 0.27)

    /// Overflow menu surface anchored to the app bar.
    static let menuSurface = Color.white

    /// Thin row separators and filter dividers.
    static let divider = Color.black.opacity(0.12)

    /// Primary row and filter text.
    static let primaryText = Color(red: 0.13, green: 0.13, blue: 0.13)

    /// Secondary row metadata and labels.
    static let secondaryText = Color(red: 0.47, green: 0.47, blue: 0.47)

    /// Template icon tint used by Android-style document rows.
    static let icon = Color(red: 0.49, green: 0.49, blue: 0.49)
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
    let controller: BibleReaderController
    let category: DocumentCategory
    let onDismiss: () -> Void
    let onOpenDownloads: () -> Void
    let onOpenDictionaryBrowser: () -> Void
    let onOpenGeneralBookBrowser: () -> Void
    let onOpenMapBrowser: () -> Void
    let onOpenStudyPadSelector: () -> Void

    /// Search-index service used by Android's Delete Index row action.
    @Environment(SearchIndexService.self) private var searchIndexService

    /// Dynamic Type category used to split Android's compact filter row when large text needs space.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Selected Android document-type filter.
    @State private var selectedFilter: DocumentTypeFilter

    /// Selected ISO language code, or an empty string for Android's all-language default.
    @State private var selectedLanguage = ""

    /// Free-text filter applied to module initials, descriptions, category labels, and language.
    @State private var searchText = ""

    /// Details sheet payload for Android's About row action.
    @State private var selectedModuleDetails: ModuleBrowserModuleDetails?

    /// Confirmation payload for destructive Android document actions.
    @State private var pendingRowActionConfirmation: ModuleBrowserRowActionConfirmation?

    /// Last row-action failure surfaced to the user.
    @State private var rowActionErrorMessage: String?

    /// Whether the Android-style app-bar overflow menu is visible.
    @State private var showOverflowMenu = false

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
       - onDismiss: Callback that closes the sheet without changing reader state.
       - onOpenDownloads: Callback that opens Downloads after the chooser dismisses.
       - onOpenDictionaryBrowser: Follow-up browser route used after selecting a dictionary module.
       - onOpenGeneralBookBrowser: Follow-up browser route used after selecting a general book.
       - onOpenMapBrowser: Follow-up browser route used after selecting a map module.
       - onOpenStudyPadSelector: Follow-up route for Android's visible Journal/StudyPad pseudo-document.

     Side effects:
     - initializes SwiftUI state only; controller mutations happen later from row selection.

     Failure modes:
     - The caller must wait for a ready pane controller before constructing the picker; a missing
       controller is a pane-readiness state, not an empty installed-document state.
     */
    init(
        controller: BibleReaderController,
        category: DocumentCategory,
        startsWithAllTypes: Bool = false,
        onDismiss: @escaping () -> Void,
        onOpenDownloads: @escaping () -> Void,
        onOpenDictionaryBrowser: @escaping () -> Void,
        onOpenGeneralBookBrowser: @escaping () -> Void,
        onOpenMapBrowser: @escaping () -> Void,
        onOpenStudyPadSelector: @escaping () -> Void = {}
    ) {
        self.controller = controller
        self.category = category
        self.onDismiss = onDismiss
        self.onOpenDownloads = onOpenDownloads
        self.onOpenDictionaryBrowser = onOpenDictionaryBrowser
        self.onOpenGeneralBookBrowser = onOpenGeneralBookBrowser
        self.onOpenMapBrowser = onOpenMapBrowser
        self.onOpenStudyPadSelector = onOpenStudyPadSelector
        _selectedFilter = State(initialValue: startsWithAllTypes ? .all : Self.initialDocumentTypeFilter(for: category))
    }

    /**
     All installed modules Android's document-type spinner can expose.

     - Returns: Installed Bible, commentary, dictionary, general book, map, and add-on modules,
       de-duplicated by module initials.
     */
    private var allSelectableModules: [ModuleInfo] {
        var seen = Set<String>()
        let documentModules = Self.documentCategoryFilterOrder
            .flatMap { controller.installedModules(for: $0) }
        let addonModules = controller.swordManager?.installedModules(category: .addon) ?? []

        return (documentModules + addonModules).filter { seen.insert($0.name).inserted }
    }

    /// Android chooser rows before filters are applied.
    private var allRows: [DocumentChooserRow] {
        Self.allRows(from: allSelectableModules)
    }

    /// Rows after applying Android-compatible type, language, and free-text filters.
    private var filteredDocumentRows: [DocumentChooserRow] {
        Self.filteredRows(
            allSelectableModules,
            selectedFilter: selectedFilter,
            selectedLanguage: selectedLanguage,
            searchText: searchText
        )
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
        androidDocumentChooserScreen
        .sheet(item: $selectedModuleDetails) { details in
            NavigationStack {
                ModuleBrowserModuleDetailsView(details: details)
            }
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
                    uninstallInstalledModule(confirmation.moduleName)
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
        .alert(
            String(localized: "document_action_failed", defaultValue: "Document action failed"),
            isPresented: Binding(
                get: { rowActionErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        rowActionErrorMessage = nil
                    }
                }
            )
        ) {
            Button(String(localized: "okay", defaultValue: "OK"), role: .cancel) {
                rowActionErrorMessage = nil
            }
        } message: {
            Text(rowActionErrorMessage ?? "")
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

        return ZStack(alignment: .topTrailing) {
            documentChooserScreenMarker
            VStack(spacing: 0) {
                androidTopAppBar
                androidFilterBar(visibleDocumentCount: visibleRows.count)
                androidDocumentRowsContent(visibleRows)
            }
            if showOverflowMenu {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                    .onTapGesture {
                        showOverflowMenu = false
                    }
                androidChooserOverflowMenu
                    .padding(.top, 56)
                    .padding(.trailing, 8)
                    .zIndex(1)
            }
        }
        .background(DocumentChooserPalette.background.ignoresSafeArea())
        .onChange(of: searchText) { oldValue, newValue in
            if oldValue.isEmpty && !newValue.isEmpty {
                selectedFilter = .all
                selectedLanguage = ""
            }
        }
        .navigationBarBackButtonHidden(true)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    /**
     Builds a stable screen marker without making every child inherit the same identifier.

     SwiftUI accessibility identifiers can propagate from container views. Android parity tests need
     a route-level marker and concrete row/filter identifiers, so this tiny non-interactive element
     carries `modulePickerScreen` while the visible layout remains accessible by its own labels.
     */
    private var documentChooserScreenMarker: some View {
        Rectangle()
            .fill(DocumentChooserPalette.background.opacity(0.001))
            .frame(width: 1, height: 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "document", defaultValue: "Document"))
            .accessibilityIdentifier("modulePickerScreen")
            .allowsHitTesting(false)
    }

    /**
     Builds Android's `Document` app bar with back navigation and overflow access.

     - Returns: A 56-point top bar matching Android `ChooseDocument` title chrome.
     - Side effects: Back dismisses the chooser; overflow toggles the Android-style menu.
     - Failure modes: none.
     */
    private var androidTopAppBar: some View {
        HStack(spacing: 16) {
            Button(action: onDismiss) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 24, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.white)
            .accessibilityLabel(String(localized: "back_to_previous", defaultValue: "Back"))
            .accessibilityIdentifier("modulePickerBackButton")

            Text(String(localized: "document", defaultValue: "Document"))
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.white)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button {
                showOverflowMenu.toggle()
            } label: {
                Image(systemName: "ellipsis.vertical")
                    .font(.system(size: 24, weight: .bold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.white)
            .accessibilityLabel(String(localized: "more", defaultValue: "More"))
            .accessibilityIdentifier("modulePickerOverflowButton")
        }
        .padding(.horizontal, 8)
        .frame(height: 56)
        .background(DocumentChooserPalette.appBar)
    }

    /**
     Builds Android's chooser overflow menu.

     Android exposes document-management actions from this app bar. iOS currently has a real
     Downloads handoff from the chooser, so it is surfaced here instead of as a native toolbar item.
     */
    private var androidChooserOverflowMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            androidOverflowMenuButton(
                title: String(localized: "download_modules"),
                accessibilityIdentifier: "modulePickerDownloadsButton"
            ) {
                showOverflowMenu = false
                openDownloadsAfterDismiss()
            }
        }
        .frame(width: 260, alignment: .leading)
        .background(DocumentChooserPalette.menuSurface)
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        .shadow(color: Color.black.opacity(0.25), radius: 8, x: 0, y: 4)
    }

    /**
     Builds one row in the Android-style overflow menu.

     - Parameters:
       - title: User-visible row title.
       - accessibilityIdentifier: Stable UI-test identifier.
       - action: Command executed when the row is tapped.
     - Returns: A full-width menu row.
     - Side effects: Executes `action`.
     - Failure modes: none.
     */
    private func androidOverflowMenuButton(
        title: String,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(DocumentChooserPalette.primaryText)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    /**
     Builds Android's inline language, search, type, and result-count filters.

     - Parameter visibleDocumentCount: Number of rows after current filters.
     - Returns: The compact filter strip from Android `document_selection.xml`.
     - Side effects: Menus and the text field mutate the active picker filters.
     - Failure modes: Large Dynamic Type splits controls into two rows to avoid overlap.
     */
    private func androidFilterBar(visibleDocumentCount: Int) -> some View {
        VStack(spacing: 4) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .bottom, spacing: 14) {
                            androidLanguageFilterMenu()
                                .frame(maxWidth: .infinity, alignment: .leading)
                            androidDocumentTypeFilterMenu(visibleDocumentCount: visibleDocumentCount)
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
                        androidDocumentTypeFilterMenu(visibleDocumentCount: visibleDocumentCount)
                            .frame(minWidth: 112, maxWidth: .infinity, alignment: .trailing)
                            .layoutPriority(1)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 10)

            Rectangle()
                .fill(DocumentChooserPalette.divider)
                .frame(height: 1)
        }
        .background(DocumentChooserPalette.background)
    }

    /**
     Builds Android's language autocomplete affordance as a compact menu.

     - Returns: Underlined language label with all installed chooser languages.
     - Side effects: Selecting a row mutates `selectedLanguage`.
     - Failure modes: Empty language lists still expose the all-language placeholder.
     */
    private func androidLanguageFilterMenu() -> some View {
        Menu {
            Button(String(localized: "settings_language")) {
                selectedLanguage = ""
            }
            if !availableLanguages.isEmpty {
                Divider()
            }
            ForEach(availableLanguages, id: \.self) { language in
                Button(Self.displayName(for: language)) {
                    selectedLanguage = language
                }
            }
        } label: {
            androidFilterLabel(languageFilterTitle(for: selectedLanguage))
        }
        .accessibilityIdentifier("modulePickerLanguageFilter")
    }

    /**
     Builds Android's inline free-text document search field.

     - Returns: Plain underlined search input.
     - Side effects: Typing mutates `searchText` and the root screen aligns filters with Android's
       search-focus behavior.
     - Failure modes: none.
     */
    private func androidSearchFilterField() -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(String(localized: "search", defaultValue: "Search"), text: $searchText)
                .textFieldStyle(.plain)
                .foregroundStyle(DocumentChooserPalette.primaryText)
                .tint(DocumentChooserPalette.primaryText)
                .submitLabel(.search)
            Rectangle()
                .fill(DocumentChooserPalette.secondaryText)
                .frame(height: 1)
        }
        .accessibilityIdentifier("modulePickerSearchField")
    }

    /**
     Builds Android's document-type spinner and visible document count.

     - Parameter visibleDocumentCount: Number of rows after current filters.
     - Returns: Count text stacked above the document-type menu.
     - Side effects: Selecting a type mutates `selectedFilter`.
     - Failure modes: Unsupported filters are not generated because the order is static.
     */
    private func androidDocumentTypeFilterMenu(visibleDocumentCount: Int) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(String(localized: "documents_count \(visibleDocumentCount)"))
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(DocumentChooserPalette.secondaryText)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .multilineTextAlignment(.trailing)
            Menu {
                ForEach(Self.documentTypeFilterOrder, id: \.self) { filter in
                    Button(Self.documentTypeFilterTitle(for: filter)) {
                        selectedFilter = filter
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(Self.documentTypeFilterTitle(for: selectedFilter))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .multilineTextAlignment(.trailing)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(DocumentChooserPalette.primaryText)
            }
        }
        .accessibilityIdentifier("modulePickerCategoryFilter")
    }

    /**
     Builds one underlined Android filter label.

     - Parameter title: User-visible label text.
     - Returns: Compact label with Android-style underline.
     - Side effects: none.
     - Failure modes: Accessibility text sizes allow two lines to avoid truncating long languages.
     */
    private func androidFilterLabel(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(DocumentChooserPalette.primaryText)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            Rectangle()
                .fill(DocumentChooserPalette.secondaryText)
                .frame(height: 1)
        }
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
        .background(DocumentChooserPalette.background)
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
            .foregroundStyle(DocumentChooserPalette.secondaryText)
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
            moduleRow(module)
        case .pseudoDocument(let document):
            pseudoDocumentRow(document)
        }
    }

    /**
     Builds one installed module row with Android list-item columns and row actions.

     - Parameter module: Installed module metadata from the active controller.
     - Returns: Tappable row that switches or opens the selected document.
     */
    private func moduleRow(_ module: ModuleInfo) -> some View {
        let actions = Self.rowActions(for: module)
        return androidRowContainer(
            accessibilityIdentifier: "modulePickerRow::\(module.name)",
            leading: {
                VStack(spacing: 5) {
                    categoryIcon(for: module.category)
                    if module.isEncrypted && !module.isUnlocked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(DocumentChooserPalette.icon)
                            .accessibilityLabel(String(localized: "locked", defaultValue: "Locked"))
                    }
                    Text(Self.displayName(for: module.language))
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(DocumentChooserPalette.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .frame(width: 70)
            },
            center: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(module.name)
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(DocumentChooserPalette.primaryText)
                        .lineLimit(1)
                    Text(module.description)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(DocumentChooserPalette.secondaryText)
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
                select(module)
            }
        )
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if actions.contains(.uninstall) {
                Button(role: .destructive) {
                    pendingRowActionConfirmation = confirmation(.uninstall, for: module)
                } label: {
                    Label(String(localized: "uninstall"), systemImage: "trash")
                }
            }
        }
        .contextMenu {
            if actions.contains(.about) {
                Button {
                    selectedModuleDetails = moduleDetails(for: module)
                } label: {
                    Label(String(localized: "about"), systemImage: "info.circle")
                }
            }
            if actions.contains(.uninstall) {
                Button(role: .destructive) {
                    pendingRowActionConfirmation = confirmation(.uninstall, for: module)
                } label: {
                    Label(String(localized: "uninstall"), systemImage: "trash")
                }
            }
            if actions.contains(.deleteIndex) {
                Button(role: .destructive) {
                    pendingRowActionConfirmation = confirmation(.deleteIndex, for: module)
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
     Builds one visible Android pseudo-document row.

     - Parameter document: Pseudo-document identity from Android `FakeBookFactory`.
     - Returns: Tappable row that opens the equivalent iOS document route.
     */
    private func pseudoDocumentRow(_ document: AndroidPseudoDocument) -> some View {
        androidRowContainer(
            accessibilityIdentifier: "modulePickerPseudoRow::\(document.rawValue)",
            leading: {
                VStack(spacing: 5) {
                    pseudoDocumentIcon(for: document)
                    Text(Self.displayName(for: document.language))
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(DocumentChooserPalette.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .frame(width: 70)
            },
            center: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(document.androidInitials)
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(DocumentChooserPalette.primaryText)
                        .lineLimit(1)
                    Text(document.description)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(DocumentChooserPalette.secondaryText)
                        .lineLimit(2)
                }
            },
            trailing: {
                Spacer()
                    .frame(width: 48)
            },
            selection: {
                select(document)
            }
        )
    }

    /**
     Builds the shared Android `document_list_item` row frame.

     - Parameters:
       - accessibilityIdentifier: Stable identifier for the concrete row.
       - leading: Left icon/language column.
       - center: Main abbreviation and description column.
       - trailing: Right action/status column.
       - selection: Primary row action matching Android list-item selection.
     - Returns: A full-width button row with Android spacing and divider placement.
     - Side effects: Executes `selection` when the row body is tapped.
     - Failure modes: Row-level context and swipe actions are supplied by the caller.
     */
    private func androidRowContainer<Leading: View, Center: View, Trailing: View>(
        accessibilityIdentifier: String,
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
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(accessibilityIdentifier)

                trailing()
                    .padding(.top, 12)
                    .padding(.trailing, 14)
            }

            Rectangle()
                .fill(DocumentChooserPalette.divider)
                .frame(height: 1)
                .padding(.leading, 96)
        }
    }

    /**
     Builds Android's row-level About action button.

     - Parameter module: Installed module whose details should be shown.
     - Returns: Template info icon matching Android's `aboutButton` column.
     - Side effects: Sets `selectedModuleDetails`, presenting the shared details sheet.
     - Failure modes: Details payload falls back to installed-module metadata when repository source
       metadata is unavailable.
     */
    private func aboutButton(for module: ModuleInfo) -> some View {
        Button {
            selectedModuleDetails = moduleDetails(for: module)
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(DocumentChooserPalette.icon)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "about"))
        .accessibilityIdentifier("modulePickerAboutButton::\(module.name)")
    }

    /**
     Renders the Android-sourced document category icon for a chooser row.

     - Parameter category: Installed module category.
     - Returns: Template icon matching the closest bundled Android document glyph.
     - Side effects: Loads local image assets when rendered.
     - Failure modes: Unknown categories use the generic document icon.
     */
    @ViewBuilder
    private func categoryIcon(for category: ModuleCategory) -> some View {
        switch category {
        case .bible:
            AndBibleIconView(name: "ToolbarBible", size: 28)
                .foregroundStyle(DocumentChooserPalette.icon)
        case .commentary:
            AndBibleIconView(name: "ToolbarCommentary", size: 28)
                .foregroundStyle(DocumentChooserPalette.icon)
        case .dictionary:
            AndBibleIconView(name: "SettingsIconDictionary", size: 28)
                .foregroundStyle(DocumentChooserPalette.icon)
        case .generalBook:
            AndBibleIconView(name: "DrawerDocuments", size: 28)
                .foregroundStyle(DocumentChooserPalette.icon)
        case .map:
            Image(systemName: "map")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(DocumentChooserPalette.icon)
        case .addon:
            AndBibleIconView(name: "DrawerDownloads", size: 28)
                .foregroundStyle(DocumentChooserPalette.icon)
        default:
            AndBibleIconView(name: "DrawerDocuments", size: 28)
                .foregroundStyle(DocumentChooserPalette.icon)
        }
    }

    /**
     Renders the category icon for one Android pseudo-document.

     - Parameter document: Pseudo-document identity.
     - Returns: Icon based on the same document category mapping Android rows use.
     - Side effects: Loads local image assets when rendered.
     - Failure modes: Unsupported pseudo categories use the generic document icon.
     */
    @ViewBuilder
    private func pseudoDocumentIcon(for document: AndroidPseudoDocument) -> some View {
        switch document.category {
        case .commentary:
            categoryIcon(for: .commentary)
        case .generalBook:
            categoryIcon(for: .generalBook)
        case .dictionary:
            categoryIcon(for: .dictionary)
        case .map:
            categoryIcon(for: .map)
        default:
            categoryIcon(for: .generalBook)
        }
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
            return String(localized: "settings_language")
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
     Side effects:
     - mutates the reader controller's active module/category for normal reader modules
     - dismisses the chooser for selectable reader documents
     - opens the auxiliary browser for dictionary, general book, or map selections

     Failure modes:
     - add-on rows are intentionally non-selecting, matching Android's AND_BIBLE guard in
       `ChooseDocument.handleDocumentSelection`.
     */
    private func select(_ module: ModuleInfo) {
        guard let selectedDocumentCategory = Self.documentCategory(for: module.category) else {
            return
        }

        switch selectedDocumentCategory {
        case .commentary:
            controller.switchCommentaryDocument(to: module.name)
            onDismiss()
        case .dictionary:
            controller.switchDictionaryDocument(to: module.name)
            dismissAndPresentAuxiliaryBrowser(onOpenDictionaryBrowser)
        case .generalBook:
            controller.switchGeneralBookDocument(to: module.name)
            dismissAndPresentAuxiliaryBrowser(onOpenGeneralBookBrowser)
        case .map:
            controller.switchMapDocument(to: module.name)
            dismissAndPresentAuxiliaryBrowser(onOpenMapBrowser)
        default:
            controller.switchBibleDocument(to: module.name)
            onDismiss()
        }
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
     Dismisses the picker and opens Downloads after SwiftUI has finished the sheet transition.

     Side effects:
     - invokes `onDismiss`
     - invokes `onOpenDownloads` on the main queue after a short delay
     */
    private func openDownloadsAfterDismiss() {
        onDismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            onOpenDownloads()
        }
    }

    /**
     Dismisses the picker before opening a category-specific browser.

     - Parameter presentation: Browser presentation callback supplied by the reader coordinator.
     Side effects:
     - invokes `onDismiss`
     - schedules the browser presentation after the sheet transition delay
     */
    private func dismissAndPresentAuxiliaryBrowser(_ presentation: @escaping () -> Void) {
        dismissAndPerform(presentation)
    }

    /**
     Dismisses the picker before performing a reader action.

     - Parameter action: Work to run after the sheet transition delay.
     Side effects:
     - invokes `onDismiss`
     - schedules `action` on the main queue
     */
    private func dismissAndPerform(_ action: @escaping () -> Void) {
        onDismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            action()
        }
    }

    /**
     Builds the shared About sheet payload for an installed module.

     - Parameter module: Installed module selected from the chooser.
     - Returns: Details payload compatible with the Downloads About sheet.
     */
    private func moduleDetails(for module: ModuleInfo) -> ModuleBrowserModuleDetails {
        ModuleBrowserModuleDetails(
            module: Self.remoteModuleInfo(for: module),
            installedModule: module
        )
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
            module: Self.remoteModuleInfo(for: module)
        )
    }

    /**
     Uninstalls one installed module using the same repository service as Downloads.

     - Parameter name: Module initials to remove from local storage.
     Side effects:
     - deletes module files off the main actor
     - `ModuleRepository` posts the module-store notification used by reader controllers to refresh
     - records failures for a user-visible alert
     */
    private func uninstallInstalledModule(_ name: String) {
        let repository = repository

        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try repository.uninstallModule(named: name)
                }.value
            } catch {
                await MainActor.run {
                    rowActionErrorMessage = error.localizedDescription
                }
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
     Builds all Android chooser rows from installed modules and visible pseudo-documents.

     - Parameter modules: Installed module snapshots.
     - Returns: Installed module rows plus My Notes, StudyPads, and Compare pseudo-document rows.
     */
    static func allRows(from modules: [ModuleInfo]) -> [DocumentChooserRow] {
        modules.map(DocumentChooserRow.module) +
            visibleAndroidPseudoDocuments.map(DocumentChooserRow.pseudoDocument)
    }

    /**
     Filters and sorts chooser rows using Android `DocumentSelectionBase` semantics.

     - Parameters:
       - modules: Complete installed-module set.
       - selectedFilter: Android document-type filter.
       - selectedLanguage: ISO language filter, or empty for all languages.
       - searchText: Free-text search over initials, description, category, and language.
     - Returns: Filtered rows sorted by Android category/status order and localized initials.
     */
    static func filteredRows(
        _ modules: [ModuleInfo],
        selectedFilter: DocumentTypeFilter,
        selectedLanguage: String,
        searchText: String
    ) -> [DocumentChooserRow] {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return allRows(from: modules).filter { row in
            rowMatchesFilter(row, selectedFilter: selectedFilter) &&
            rowMatchesLanguage(row, selectedLanguage: selectedLanguage) &&
            rowMatchesSearch(row, searchText: trimmedSearch)
        }
        .sorted(by: sortRows)
    }

    /**
     Filters and sorts installed modules using the legacy module-only projection.

     - Parameters:
       - modules: Complete installed-module set.
       - selectedCategory: Optional document-type filter, with `nil` meaning all types.
       - selectedLanguage: ISO language filter, or empty for all languages.
       - searchText: Free-text search over initials, description, category, and language.
     - Returns: Filtered normal reader modules sorted by Android category order and initials.
     */
    static func filteredModules(
        _ modules: [ModuleInfo],
        selectedCategory: DocumentCategory?,
        selectedLanguage: String,
        searchText: String
    ) -> [ModuleInfo] {
        let selectedFilter = selectedCategory.map(DocumentTypeFilter.category) ?? .all
        return filteredRows(
            modules,
            selectedFilter: selectedFilter,
            selectedLanguage: selectedLanguage,
            searchText: searchText
        )
        .compactMap { row in
            guard case .module(let module) = row,
                  documentCategory(for: module.category) != nil else {
                return nil
            }
            return module
        }
    }

    /**
     Builds the alphabetized language list shown in the chooser language filter.

     - Parameter modules: Complete installed-module set.
     - Returns: Unique ISO language codes sorted by localized display name.
     */
    static func availableLanguages(from modules: [ModuleInfo]) -> [String] {
        availableLanguages(from: allRows(from: modules))
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
     Tests whether the selected Android document type has no installed modules at all.

     - Parameters:
       - modules: Complete installed-module set.
       - selectedCategory: Optional document-type filter, with `nil` meaning all types.
     - Returns: `true` only when a concrete type is selected and that type has no modules before
       language or free-text filters run.
     */
    static func shouldShowCategoryEmptyState(
        _ modules: [ModuleInfo],
        selectedCategory: DocumentCategory?
    ) -> Bool {
        let selectedFilter = selectedCategory.map(DocumentTypeFilter.category) ?? .all
        return shouldShowFilterEmptyState(allRows(from: modules), selectedFilter: selectedFilter)
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
     Computes Android contextual document actions for an installed chooser row.

     - Parameter module: Installed module metadata.
     - Returns: Ordered Android row actions. Unlock remains hidden until iOS has a real cipher-key
       coordinator, matching the Downloads planner contract.
     */
    static func rowActions(for module: ModuleInfo) -> [ModuleDownloadRowAction] {
        ModuleDownloadRowActionPlanner.availableActions(
            installedModule: module,
            isBeingInstalled: false,
            supportsUnlock: false
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
            return String(localized: "bibles")
        case .commentary:
            return String(localized: "commentaries")
        case .dictionary:
            return String(localized: "dictionaries")
        case .generalBook:
            return String(localized: "category_books")
        case .map:
            return String(localized: "map")
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
     Sorts chooser rows using Android's document status, pseudo-document, category, and initials order.

     - Parameters:
       - lhs: Left row.
       - rhs: Right row.
     - Returns: `true` when `lhs` should precede `rhs`.
     */
    private static func sortRows(_ lhs: DocumentChooserRow, _ rhs: DocumentChooserRow) -> Bool {
        let lhsInstalledRank = lhs.isRealInstalledDocument ? 0 : 1
        let rhsInstalledRank = rhs.isRealInstalledDocument ? 0 : 1
        if lhsInstalledRank != rhsInstalledRank {
            return lhsInstalledRank < rhsInstalledRank
        }

        let lhsRank = categoryRank(for: lhs)
        let rhsRank = categoryRank(for: rhs)
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }

        return lhs.sortTitle.localizedCaseInsensitiveCompare(rhs.sortTitle) == .orderedAscending
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
     Builds a Downloads-compatible remote metadata payload from an installed module snapshot.

     - Parameter module: Installed module metadata.
     - Returns: Minimal remote row used by the shared About and confirmation presentation helpers.
     */
    private static func remoteModuleInfo(for module: ModuleInfo) -> RemoteModuleInfo {
        RemoteModuleInfo(
            name: module.name,
            description: module.description,
            category: module.category,
            language: module.language,
            sourceName: String(localized: "installed", defaultValue: "Installed"),
            version: module.version
        )
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

     Rows are either installed SWORD modules or the visible `FakeBookFactory` pseudo-documents that
     Android includes in `ChooseDocument`.
     */
    enum DocumentChooserRow: Identifiable, Equatable {
        /// Installed local module row.
        case module(ModuleInfo)

        /// Android visible pseudo-document row.
        case pseudoDocument(AndroidPseudoDocument)

        /// Stable row identity.
        var id: String {
            switch self {
            case .module(let module):
                return "module:\(module.name)"
            case .pseudoDocument(let document):
                return "pseudo:\(document.rawValue)"
            }
        }

        /// Reader document category for filtering and sorting.
        var documentCategory: DocumentCategory? {
            switch self {
            case .module(let module):
                return BibleReaderModulePicker.documentCategory(for: module.category)
            case .pseudoDocument(let document):
                return document.category
            }
        }

        /// Language code used by Android's language spinner.
        var language: String {
            switch self {
            case .module(let module):
                return module.language
            case .pseudoDocument(let document):
                return document.language
            }
        }

        /// Whether the row is an Android AND_BIBLE add-on.
        var isAndroidAddon: Bool {
            guard case .module(let module) = self else { return false }
            return module.category == .addon
        }

        /// Whether Android would rank the row as a real installed SWORD document before fake rows.
        var isRealInstalledDocument: Bool {
            guard case .module(let module) = self else { return false }
            return BibleReaderModulePicker.documentCategory(for: module.category) != nil || module.category == .addon
        }

        /// Sort key matching Android's abbreviation-based row ordering.
        var sortTitle: String {
            switch self {
            case .module(let module):
                return module.name
            case .pseudoDocument(let document):
                return document.title
            }
        }

        /// Values included in the chooser's free-text search.
        var searchableText: [String] {
            switch self {
            case .module(let module):
                return [
                    module.name,
                    module.description,
                    module.language,
                    BibleReaderModulePicker.displayName(for: module.language),
                    BibleReaderModulePicker.moduleCategoryTitle(for: module.category)
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

        /**
         Compares rows by stable identity.

         - Parameters:
           - lhs: Left row.
           - rhs: Right row.
         - Returns: `true` when both rows represent the same module or pseudo-document.
         */
        static func == (lhs: DocumentChooserRow, rhs: DocumentChooserRow) -> Bool {
            lhs.id == rhs.id
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
