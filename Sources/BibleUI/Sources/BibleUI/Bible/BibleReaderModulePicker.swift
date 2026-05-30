import BibleCore
import SwiftUI
import SwordKit

/**
 Presents document modules for the currently focused pane and routes selections through the same
 category switching outcomes as Android's `ChooseDocument` activity.

 The reader coordinator owns whether the sheet is visible. This view owns Android-parity chooser
 state that can be represented with the current iOS module model: document type filtering,
 all-language default filtering, free-text module search, active-module marking, and the direct
 Downloads handoff. Android pseudo-documents, encrypted-module unlock prompts, and long-press
 about/delete actions are documented as separate gaps because this picker currently receives only
 installed `ModuleInfo` values and has no module mutation or cipher-key coordinator.
 */
struct BibleReaderModulePicker: View {
    let controller: BibleReaderController
    let category: DocumentCategory
    let onDismiss: () -> Void
    let onOpenDownloads: () -> Void
    let onOpenDictionaryBrowser: () -> Void
    let onOpenGeneralBookBrowser: () -> Void
    let onOpenMapBrowser: () -> Void

    /// Selected Android document-type filter; `nil` represents the Android "All types" row.
    @State private var selectedCategory: DocumentCategory?

    /// Selected ISO language code, or an empty string for Android's all-language default.
    @State private var selectedLanguage = ""

    /// Free-text filter applied to module initials, descriptions, category labels, and language.
    @State private var searchText = ""

    /**
     Creates a pane-scoped module picker with Android-compatible initial type selection.

     - Parameters:
       - controller: Ready reader controller whose installed modules and switch actions back the picker.
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

     Side effects:
     - initializes SwiftUI state only; controller mutations happen later from row selection.

     Failure modes:
     - The caller must wait for a ready pane controller before constructing the picker; a missing
       controller is a pane-readiness state, not an empty installed-module state.
     */
    init(
        controller: BibleReaderController,
        category: DocumentCategory,
        startsWithAllTypes: Bool = false,
        onDismiss: @escaping () -> Void,
        onOpenDownloads: @escaping () -> Void,
        onOpenDictionaryBrowser: @escaping () -> Void,
        onOpenGeneralBookBrowser: @escaping () -> Void,
        onOpenMapBrowser: @escaping () -> Void
    ) {
        self.controller = controller
        self.category = category
        self.onDismiss = onDismiss
        self.onOpenDownloads = onOpenDownloads
        self.onOpenDictionaryBrowser = onOpenDictionaryBrowser
        self.onOpenGeneralBookBrowser = onOpenGeneralBookBrowser
        self.onOpenMapBrowser = onOpenMapBrowser
        _selectedCategory = State(initialValue: startsWithAllTypes ? nil : Self.initialCategoryFilter(for: category))
    }

    /**
     All installed modules that Android's `ChooseDocument` category spinner can expose.

     - Returns: Installed Bible, commentary, dictionary, general book, and map modules from the
       active reader controller, de-duplicated by module initials.
     */
    private var allSelectableModules: [ModuleInfo] {
        let categoryOrder = Self.categoryFilterOrder.compactMap { $0 }
        var seen = Set<String>()
        return categoryOrder.flatMap { controller.installedModules(for: $0) }
            .filter { seen.insert($0.name).inserted }
    }

    /// Modules after applying Android-compatible type, language, and free-text filters.
    private var filteredModules: [ModuleInfo] {
        Self.filteredModules(
            allSelectableModules,
            selectedCategory: selectedCategory,
            selectedLanguage: selectedLanguage,
            searchText: searchText
        )
    }

    /// Language choices built from the complete installed chooser dataset, sorted alphabetically.
    private var availableLanguages: [String] {
        Self.availableLanguages(from: allSelectableModules)
    }

    /// Whether the active document type has no installed modules before language/search filtering.
    private var shouldShowCategoryEmptyState: Bool {
        Self.shouldShowCategoryEmptyState(
            allSelectableModules,
            selectedCategory: selectedCategory
        )
    }

    /**
     Builds the Android-style document chooser surface with type/language filters, search, rows,
     and a persistent Downloads handoff.
     */
    var body: some View {
        NavigationStack {
            List {
                filterControls

                if allSelectableModules.isEmpty || shouldShowCategoryEmptyState {
                    emptyState
                } else if filteredModules.isEmpty {
                    noMatchesState
                } else {
                    moduleRows
                }
            }
            .accessibilityIdentifier("modulePickerScreen")
            .navigationTitle(navigationTitle)
            .searchable(text: $searchText, prompt: String(localized: "search_modules"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "done"), action: onDismiss)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(String(localized: "download_modules"), systemImage: "arrow.down.circle") {
                        openDownloadsAfterDismiss()
                    }
                    .accessibilityIdentifier("modulePickerDownloadsButton")
                }
            }
            .onChange(of: searchText) { oldValue, newValue in
                if oldValue.isEmpty && !newValue.isEmpty {
                    selectedCategory = nil
                    selectedLanguage = ""
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /**
     Builds the document-type and language controls that correspond to Android's spinners.

     The document-type picker starts on the requested category, while the language picker starts at
     the all-language default used by Android `ChooseDocument`.
     */
    private var filterControls: some View {
        Section {
            Picker(String(localized: "document_type", defaultValue: "Document type"), selection: $selectedCategory) {
                ForEach(Self.categoryFilterOrder, id: \.self) { category in
                    Text(Self.categoryFilterTitle(for: category)).tag(category)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("modulePickerCategoryFilter")

            if !availableLanguages.isEmpty {
                Picker(String(localized: "settings_language"), selection: $selectedLanguage) {
                    Text(String(localized: "all_languages_count \(availableLanguages.count)"))
                        .tag("")
                    ForEach(availableLanguages, id: \.self) { language in
                        Text(Self.displayName(for: language))
                            .tag(language)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("modulePickerLanguageFilter")
            }
        }
    }

    /// Empty state shown when no installed modules exist for the chooser at all.
    private var emptyState: some View {
        VStack(spacing: 12) {
            Text(emptyMessage)
                .foregroundStyle(.secondary)
            Button(String(localized: "download_modules")) {
                openDownloadsAfterDismiss()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical)
    }

    /// Empty state shown when installed modules exist but the active filters hide all rows.
    private var noMatchesState: some View {
        Text(String(localized: "no_modules_match_filters"))
            .foregroundStyle(.secondary)
    }

    /// Rows for the currently filtered module set.
    private var moduleRows: some View {
        Section(String(localized: "document_filter_results \(filteredModules.count)")) {
            ForEach(filteredModules, id: \.name) { module in
                moduleRow(module)
            }
        }
    }

    /**
     Builds one selectable module row with active-state and lock-state affordances.

     - Parameter module: Installed module metadata from the active reader controller.
     - Returns: A row that switches to the module's own category when selected.
     */
    private func moduleRow(_ module: ModuleInfo) -> some View {
        Button {
            select(module)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(module.name)
                            .font(.headline)
                        if module.isEncrypted && !module.isUnlocked {
                            Image(systemName: "lock.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(String(localized: "locked", defaultValue: "Locked"))
                        }
                    }
                    Text(module.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(Self.displayName(for: module.language))
                        Text(Self.categoryFilterTitle(for: Self.documentCategory(for: module.category)))
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
                Spacer()
                if isActive(module) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .fontWeight(.semibold)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("modulePickerRow::\(module.name)")
    }

    /// Message shown when the requested category has no installed modules.
    private var emptyMessage: String {
        switch selectedCategory ?? category {
        case .commentary:
            return String(localized: "picker_no_commentary_modules")
        case .dictionary:
            return String(localized: "picker_no_dictionary_modules")
        case .generalBook:
            return String(localized: "picker_no_general_book_modules")
        case .map:
            return String(localized: "picker_no_map_modules")
        default:
            return String(localized: "picker_no_bible_modules")
        }
    }

    /// Android chooser title.
    private var navigationTitle: String {
        String(localized: "choose_document", defaultValue: "Choose Document")
    }

    /**
     Selects a module and applies the category-specific reader transition.

     - Parameter module: Installed module selected from the chooser.
     Side effects:
     - mutates the reader controller's active module/category
     - dismisses the chooser
     - opens the auxiliary browser for dictionary, general book, or map selections

     Failure modes:
     - unsupported module categories dismiss without mutation because Android-only pseudo-doc rows
       are not represented by `ModuleInfo`
     */
    private func select(_ module: ModuleInfo) {
        guard let selectedDocumentCategory = Self.documentCategory(for: module.category) else {
            onDismiss()
            return
        }

        switch selectedDocumentCategory {
        case .commentary:
            controller.switchCommentaryModule(to: module.name)
            if controller.currentCategory != .commentary {
                controller.switchCategory(to: .commentary)
            }
            onDismiss()
        case .dictionary:
            controller.switchDictionaryModule(to: module.name)
            controller.switchCategory(to: .dictionary)
            dismissAndPresentAuxiliaryBrowser(onOpenDictionaryBrowser)
        case .generalBook:
            controller.switchGeneralBookModule(to: module.name)
            controller.switchCategory(to: .generalBook)
            dismissAndPresentAuxiliaryBrowser(onOpenGeneralBookBrowser)
        case .map:
            controller.switchMapModule(to: module.name)
            controller.switchCategory(to: .map)
            dismissAndPresentAuxiliaryBrowser(onOpenMapBrowser)
        default:
            controller.switchModule(to: module.name)
            if controller.currentCategory != .bible {
                controller.switchCategory(to: .bible)
            }
            onDismiss()
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
     Tests whether a module is the currently active module for its own category.

     - Parameter module: Installed module metadata to compare against the reader controller.
     - Returns: `true` when the module name matches the active module for its category.
     */
    private func isActive(_ module: ModuleInfo) -> Bool {
        guard let documentCategory = Self.documentCategory(for: module.category) else { return false }
        return module.name == controller.activeModuleName(for: documentCategory)
    }

    /**
     Dismisses the picker before opening a category-specific browser.

     - Parameter presentation: Browser presentation callback supplied by the reader coordinator.
     Side effects:
     - invokes `onDismiss`
     - schedules the browser presentation after the sheet transition delay
     */
    private func dismissAndPresentAuxiliaryBrowser(_ presentation: @escaping () -> Void) {
        onDismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            presentation()
        }
    }

    /**
     Filters and sorts installed modules using Android `DocumentSelectionBase` semantics that are
     representable with iOS `ModuleInfo`.

     - Parameters:
       - modules: Complete installed-module set.
       - selectedCategory: Optional document-type filter, with `nil` meaning all types.
       - selectedLanguage: ISO language filter, or empty for all languages.
       - searchText: Free-text search over initials, description, category, and language.
     - Returns: Filtered modules sorted by Android category order and localized initials.
     */
    static func filteredModules(
        _ modules: [ModuleInfo],
        selectedCategory: DocumentCategory?,
        selectedLanguage: String,
        searchText: String
    ) -> [ModuleInfo] {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return modules.filter { module in
            let documentCategory = documentCategory(for: module.category)
            let matchesCategory = selectedCategory.map { $0 == documentCategory } ?? true
            let matchesLanguage = selectedLanguage.isEmpty || module.language == selectedLanguage
            let matchesSearch = trimmedSearch.isEmpty || moduleMatchesSearch(module, searchText: trimmedSearch)
            return matchesCategory && matchesLanguage && matchesSearch && documentCategory != nil
        }
        .sorted(by: sortModules)
    }

    /**
     Builds the alphabetized language list shown in the chooser language filter.

     - Parameter modules: Complete installed-module set.
     - Returns: Unique ISO language codes sorted by localized display name.
     */
    static func availableLanguages(from modules: [ModuleInfo]) -> [String] {
        Array(Set(modules.map(\.language))).sorted {
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
        guard let selectedCategory else { return false }
        return !modules.contains { documentCategory(for: $0.category) == selectedCategory }
    }

    /**
     Maps SWORD module categories into reader document categories that Android exposes.

     - Parameter moduleCategory: Category reported by SWORD metadata.
     - Returns: Matching reader document category, or `nil` for unsupported pseudo/add-on types.
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
        categoryFilterOrder.contains { $0 == category } ? category : nil
    }

    /**
     Produces the localized display name for a language code.

     - Parameter languageCode: ISO language code from module metadata.
     - Returns: Localized language name, or the uppercased code when no name is available.
     */
    static func displayName(for languageCode: String) -> String {
        Locale.current.localizedString(forLanguageCode: languageCode) ?? languageCode.uppercased()
    }

    /// Android document-type filter order, with `nil` representing "All types".
    private static let categoryFilterOrder: [DocumentCategory?] = [
        nil,
        .bible,
        .commentary,
        .dictionary,
        .generalBook,
        .map
    ]

    /**
     Returns the localized title for one document-type filter row.

     - Parameter category: Optional reader category, where `nil` means all types.
     - Returns: Localized picker label matching Android's document-type list.
     */
    private static func categoryFilterTitle(for category: DocumentCategory?) -> String {
        switch category {
        case nil:
            return String(localized: "doc_type_all", defaultValue: "All types")
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
     Tests whether one module matches the free-text chooser search.

     - Parameters:
       - module: Installed module metadata.
       - searchText: Trimmed, non-empty search text.
     - Returns: `true` when initials, description, language, or category text contains the query.
     */
    private static func moduleMatchesSearch(_ module: ModuleInfo, searchText: String) -> Bool {
        module.name.localizedCaseInsensitiveContains(searchText) ||
        module.description.localizedCaseInsensitiveContains(searchText) ||
        module.language.localizedCaseInsensitiveContains(searchText) ||
        displayName(for: module.language).localizedCaseInsensitiveContains(searchText) ||
        categoryFilterTitle(for: documentCategory(for: module.category)).localizedCaseInsensitiveContains(searchText)
    }

    /**
     Sorts chooser rows using Android's category order before localized initials.

     - Parameters:
       - lhs: Left module.
       - rhs: Right module.
     - Returns: `true` when `lhs` should precede `rhs`.
     */
    private static func sortModules(_ lhs: ModuleInfo, _ rhs: ModuleInfo) -> Bool {
        let lhsRank = categoryRank(for: documentCategory(for: lhs.category))
        let rhsRank = categoryRank(for: documentCategory(for: rhs.category))
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    /**
     Resolves Android document-type sort rank for one category.

     - Parameter category: Optional reader document category.
     - Returns: Lower rank for earlier Android chooser display order.
     */
    private static func categoryRank(for category: DocumentCategory?) -> Int {
        categoryFilterOrder.firstIndex(where: { $0 == category }) ?? Int.max
    }
}
