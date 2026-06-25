// SearchView.swift — Full-text search with FTS5 index support
//
// Matches Android's search UX: checks for search index, prompts creation if
// missing, shows progress during indexing, then enables fast FTS5 searching.

import SwiftUI
import BibleCore
import SwordKit

/// One-shot UI-test launch query consumed by Search regardless of which presenter opens it.
enum UITestSearchQuerySeed {
    private static var didConsume = false

    static func consume() -> String? {
        guard !didConsume,
              let query = resolveLaunchQuery()?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else {
            return nil
        }
        didConsume = true
        return query
    }

    private static func resolveLaunchQuery() -> String? {
        if let environmentQuery = ProcessInfo.processInfo.environment["UITEST_SEARCH_QUERY"] {
            return environmentQuery
        }

        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "-UITEST_SEARCH_QUERY") else {
            return nil
        }

        let valueIndex = arguments.index(after: flagIndex)
        guard valueIndex < arguments.endIndex else {
            return nil
        }

        return arguments[valueIndex]
    }
}

/**
 Full-text search interface with index management, scope filters, and multi-translation support.

 State machine:
 - `checkingIndex`: inspect whether the active module already has an FTS index
 - `needsIndex`: prompt the user to create the index
 - `creatingIndex`: show live progress from `SearchIndexService`
 - `ready`: render search options and results

 Data dependencies:
 - `swordModule` provides the primary search target and fallback direct-SWORD search path
 - `swordManager` resolves additional modules for multi-translation or Strong's searches
 - `searchIndexService` provides FTS index presence checks, index creation, and indexed search
 - `installedBibleModules`, `currentBook`, and `currentOsisBookId` define search scopes and
   translation-selection behavior

 Side effects:
 - `onAppear` seeds initial module selection, applies `initialQuery`, and triggers the index check
 - `startIndexCreation()` launches asynchronous index creation through `SearchIndexService`
 - `performSearch()` launches detached search work and marshals results back onto the main actor
 - `navigateTo(_:)` notifies the caller and dismisses Search with the active presentation mechanism
 */
public struct SearchView: View {
    /// Callback invoked when the user selects a search hit and wants to navigate to it.
    let onNavigate: ((String, Int, Int) -> Void)?

    /// Primary Sword module whose search index and results drive the screen.
    var swordModule: SwordModule?

    /// Sword manager used to resolve additional modules for translation or Strong's searches.
    var swordManager: SwordManager?

    /// Optional FTS index service used for index existence checks, creation, and indexed search.
    var searchIndexService: SearchIndexService?

    /// Installed Bible modules available for multi-translation search selection.
    var installedBibleModules: [ModuleInfo]

    /// Current user-visible book name used for the "current book" scope label and fallback navigation.
    var currentBook: String

    /// Current OSIS book identifier used to build SWORD scope expressions.
    var currentOsisBookId: String

    /// Current state of the search/index lifecycle.
    @State private var viewState: ViewState = .checkingIndex

    /// User-entered search text, also seeded from `initialQuery` when present.
    @State private var query = ""

    /// Whether a background search task is currently running.
    @State private var isSearching = false

    /// Flattened result list displayed in the main results section.
    @State private var results: [SearchHit] = []

    /// Aggregate per-module counts used when searching across multiple translations.
    @State private var multiResults: MultiResultGroup?

    /// Word-match mode controlling FTS query decoration and fallback search semantics.
    @State private var wordMode: SearchWordMode = .allWords

    /// Selected search scope (whole Bible, testament, or current book).
    @State private var scopeOption: ScopeChoice = .wholeBible

    /// Presents the translation picker for multi-module search selection.
    @State private var showTranslationPicker = false

    /// Installed module names selected for indexed multi-translation search.
    @State private var selectedModules: Set<String> = []

    /// Draft module names edited inside the Android-style translation picker before OK commits.
    @State private var pendingTranslationSelection: Set<String> = []

    /// Whether the options panel is expanded above the results list.
    @State private var showOptions = true

    /// Whether the system search field currently owns focus.
    @FocusState private var isSearchFieldFocused: Bool

    /// Current system color scheme used for Android-dialog surface colors.
    @Environment(\.colorScheme) private var colorScheme

    /// Navigation-title summary of the most recent search results.
    @State private var resultSummary: String = ""

    /// Dismiss action for popping Search after result navigation.
    @Environment(\.dismiss) private var dismiss

    /**
     High-level search/index lifecycle states that drive the visible UI.
     */
    enum ViewState {
        /// Verifies whether the active module already has a searchable index.
        case checkingIndex

        /// Prompts the user to build an index for the named module.
        case needsIndex(moduleName: String, moduleDescription: String)

        /// Shows progress while `SearchIndexService` is building one or more indexes.
        case creatingIndex

        /// Shows search controls and current results.
        case ready
    }

    /// Search scope choices exposed in the options panel.
    enum ScopeChoice: Hashable {
        /// Search across the entire Bible.
        case wholeBible

        /// Search only the Old Testament range.
        case oldTestament

        /// Search only the New Testament range.
        case newTestament

        /// Search only the currently focused book.
        case currentBook
    }

    /**
     One passage-level search result shown in the list.
     */
    struct SearchHit: Identifiable {
        /// Stable UI identity for list diffing.
        let id = UUID()

        /// User-visible book name parsed from the search result key.
        let book: String

        /// One-based chapter number parsed from the search result key.
        let chapter: Int

        /// One-based verse number parsed from the search result key.
        let verse: Int

        /// Snippet or preview text shown in the result row.
        let text: String

        /// Module name when the result came from a multi-translation search.
        let moduleName: String?

        /// Formatted human-readable reference string shown in the list row.
        var reference: String { "\(book) \(chapter):\(verse)" }
    }

    /**
     Aggregate counts for multi-translation result presentation.
     */
    struct MultiResultGroup {
        /// Per-module result totals used for the horizontal summary pill list.
        let perModule: [(name: String, count: Int)]

        /// Total hits across all selected modules.
        let totalCount: Int
    }

    /// Optional initial query to auto-populate and execute (e.g. from "Find all occurrences").
    private var initialQuery: String

    /**
     Creates the search view for one primary module and optional index service.

     - Parameters:
       - swordModule: Primary module to search and to use for index checks.
       - swordManager: Manager used to resolve additional modules for multi-search or Strong's.
       - searchIndexService: Optional index service providing FTS-backed search and indexing.
       - installedBibleModules: Installed Bible modules available to the translation picker.
       - currentBook: Current user-visible book name for the current-book search scope.
       - currentOsisBookId: Current OSIS book identifier for SWORD scope construction.
       - initialQuery: Optional query to prefill and auto-run on appear.
       - onNavigate: Callback invoked when the user selects a search hit.
     - Note: Initialization has no side effects. Index checks and optional auto-search begin in
       `onAppear`.
     */
    public init(
        swordModule: SwordModule? = nil,
        swordManager: SwordManager? = nil,
        searchIndexService: SearchIndexService? = nil,
        installedBibleModules: [ModuleInfo] = [],
        currentBook: String = "Genesis",
        currentOsisBookId: String = "Gen",
        initialQuery: String = "",
        onNavigate: ((String, Int, Int) -> Void)? = nil
    ) {
        self.swordModule = swordModule
        self.swordManager = swordManager
        self.searchIndexService = searchIndexService
        self.installedBibleModules = installedBibleModules
        self.currentBook = currentBook
        self.currentOsisBookId = currentOsisBookId
        self.initialQuery = initialQuery
        self.onNavigate = onNavigate
    }

    /**
     Builds the search UI for the current `viewState`.

     The body switches between index-check progress, index-creation prompt/progress, and the full
     search interface while also wiring the toolbar and translation-picker overlay.
     */
    public var body: some View {
        Group {
            switch viewState {
            case .checkingIndex:
                ProgressView(String(localized: "search_checking_index"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .needsIndex(let moduleName, let moduleDescription):
                indexPromptView(moduleName: moduleName, moduleDescription: moduleDescription)

            case .creatingIndex:
                indexProgressView

            case .ready:
                searchContent
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("searchScreen")
        .accessibilityValue(searchAccessibilityValue)
        .overlay(alignment: .topLeading) {
            // Export Search state through a tiny dedicated element so UI tests do not have to
            // snapshot the full Search container while result lists are changing.
            searchStateExport
        }
        .overlay {
            if showTranslationPicker {
                translationPickerOverlay
            }
        }
        .navigationTitle(navigationTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if case .ready = viewState {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        withAnimation { showOptions.toggle() }
                    } label: {
                        Image(systemName: showOptions ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityIdentifier("searchOptionsToggleButton")
                    .accessibilityValue(showOptions ? "visible" : "hidden")
                }
            }
        }
        .onAppear {
            if selectedModules.isEmpty, let mod = swordModule {
                selectedModules = [mod.info.name]
            }
            let seededInitialQuery = initialQuery.isEmpty ? (UITestSearchQuerySeed.consume() ?? "") : initialQuery
            _ = applyInitialQueryIfNeeded(seededInitialQuery)
            checkIndex()
        }
        .onChange(of: initialQuery) { _, newValue in
            let didApply = applyInitialQueryIfNeeded(newValue)
            if didApply, case .ready = viewState {
                performSearch()
            }
        }
        .onChange(of: scopeOption) { _, _ in
            if case .ready = viewState, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                performSearch()
            }
        }
        .onChange(of: wordMode) { _, _ in
            if case .ready = viewState, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                performSearch()
            }
        }
        .onChange(of: selectedModules) { _, _ in
            if case .ready = viewState, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                checkIndex()
            }
        }
    }

    /// Navigation title derived from the active state and latest result summary.
    private var navigationTitle: String {
        switch viewState {
        case .needsIndex, .creatingIndex:
            return String(localized: "search_index")
        case .ready:
            if !resultSummary.isEmpty {
                return resultSummary
            }
            if let mod = swordModule {
                return String(localized: "Find in \(mod.info.name)")
            }
            return String(localized: "search")
        case .checkingIndex:
            return String(localized: "search")
        }
    }

    /**
     Deterministic XCUITest summary of the current Search screen state.

     The UI harness reads this compact value instead of walking volatile SwiftUI search-field and
     result-list hierarchies while searches rerun.

     - Returns: A semicolon-delimited state string containing lifecycle, query, result, option, and
       focus tokens.
     - Side effects: none.
     - Failure modes: This computed export cannot fail; missing or renamed tokens break only the
       UI-test contract that consumes the value.
     */
    private var searchAccessibilityValue: String {
        let stateToken: String = switch viewState {
        case .checkingIndex: "checkingIndex"
        case .needsIndex: "needsIndex"
        case .creatingIndex: "creatingIndex"
        case .ready: "ready"
        }
        let baseState = "state=\(stateToken);query=\(query);searching=\(isSearching);results=\(results.count);scope=\(searchScopeToken(for: scopeOption));wordMode=\(searchWordModeToken(for: wordMode));searchFieldFocused=\(isSearchFieldFocused);\(searchAccessibilityTranslationPickerToken)"
        guard UITestRuntimeConfiguration.enablesDetailedAccessibilityExports else {
            return baseState
        }
        return "\(baseState);\(searchAccessibilitySelectionToken);\(searchAccessibilityGroupToken);rows=\(searchAccessibilityRowsToken)"
    }

    /// Stable selected-translation token exported for UI automation.
    private var searchAccessibilitySelectionToken: String {
        let orderedModules = Self.androidOrderedSelectedSearchModuleNames(
            selectedModuleNames: selectedModules,
            primaryModuleName: swordModule?.info.name,
            installedModules: installedBibleModules
        )
        return "selectedModules=\(selectedModules.sorted().joined(separator: ","));selectedModuleOrder=\(orderedModules.joined(separator: ","))"
    }

    /**
     User-visible selected translation summary shown on the Search translation picker button.

     Android renders the committed selected translations as a comma-separated abbreviation list after
     moving the primary document to the front. iOS uses the same helper as search execution so the
     visible control, request order, and grouped result order cannot drift independently.

     - Returns: Ordered abbreviations such as `KJV, UITESTWEB`, or a localized fallback label when
       no module can be resolved.
     - Side effects: none.
     - Failure modes: Empty selection and missing primary module metadata produce the generic
       `search_translations` fallback instead of a malformed empty button.
     */
    private var selectedTranslationSummaryLabel: String {
        let orderedModules = Self.androidOrderedSelectedSearchModuleNames(
            selectedModuleNames: selectedModules,
            primaryModuleName: swordModule?.info.name,
            installedModules: installedBibleModules
        )
        guard !orderedModules.isEmpty else {
            return String(localized: "search_translations", defaultValue: "Translations")
        }
        return orderedModules.joined(separator: ", ")
    }

    /**
     Stable translation-picker presentation token exported for UI automation.
     *
     - Returns: `translationPicker=open` while Search is presenting the custom picker overlay, otherwise
       `translationPicker=closed`.
     - Side effects: none.
     - Failure modes: This computed token does not fail.
     */
    private var searchAccessibilityTranslationPickerToken: String {
        "translationPicker=\(showTranslationPicker ? "open" : "closed")"
    }

    /// Stable grouped-result totals exported for UI automation.
    private var searchAccessibilityGroupToken: String {
        guard let multiResults else {
            return "groupedTotal=none;groupedCounts=none"
        }
        let counts = multiResults.perModule
            .map { "\($0.name):\($0.count)" }
            .joined(separator: ",")
        return "groupedTotal=\(multiResults.totalCount);groupedCounts=\(counts)"
    }

    /// Compact dedicated state export used by the UI harness instead of the full Search container.
    @ViewBuilder
    private var searchStateExport: some View {
        if UITestRuntimeConfiguration.enablesDetailedAccessibilityExports {
            Text(searchAccessibilityValue)
                .font(.system(size: 1))
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityIdentifier("searchStateExport")
                .accessibilityLabel("searchStateExport")
                .accessibilityValue(searchAccessibilityValue)
        }
    }

    /// Stable search-result row tokens exported for UI automation.
    private var searchAccessibilityRowsToken: String {
        results.prefix(UITestRuntimeConfiguration.detailedAccessibilityRowTokenLimit)
            .map { "|\(searchResultIdentifier(for: $0))|" }
            .joined(separator: ",")
    }

    // MARK: - Index Prompt

    /**
     Builds the prompt shown when the active module needs an FTS index before search can proceed.

     - Parameters:
       - moduleName: Module identifier used for index creation bookkeeping.
       - moduleDescription: User-visible description shown in the prompt text.
     */
    private func indexPromptView(moduleName: String, moduleDescription: String) -> some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                Text(String(localized: "search_need_index"))
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text("Create an index for \(moduleDescription)?")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)

            Spacer()

            HStack(spacing: 40) {
                Button(String(localized: "cancel")) {
                    dismiss()
                }
                .foregroundStyle(.secondary)

                Button(String(localized: "search_create_index")) {
                    startIndexCreation()
                }
                .fontWeight(.semibold)
            }
            .font(.headline)
            .padding(.bottom, 40)
        }
    }

    // MARK: - Index Progress

    /// Progress view shown while `SearchIndexService` builds one or more module indexes.
    private var indexProgressView: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 16) {
                Text(String(localized: "search_indexing_message"))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                if let service = searchIndexService {
                    VStack(spacing: 8) {
                        Text("Creating index. Processing \(service.indexingModule)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        if !service.indexingKey.isEmpty {
                            Text(service.indexingKey)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }

                        ProgressView(value: service.indexProgress)
                            .tint(.accentColor)
                            .padding(.horizontal, 24)
                    }
                } else {
                    ProgressView()
                }
            }

            Spacer()
            Spacer()
        }
    }

    // MARK: - Search Content

    /// Main search UI shown once the view reaches the `.ready` state.
    private var searchContent: some View {
        VStack(spacing: 0) {
            searchQueryBar

            if showOptions {
                searchOptionsPanel
            }

            List {
                if isSearching {
                    ProgressView(String(localized: "search_searching"))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowSeparator(.hidden)
                } else if let multi = multiResults, selectedModules.count > 1 {
                    multiResultsSection(multi)
                } else if !results.isEmpty {
                    singleResultsSection
                } else if query.isEmpty {
                    ContentUnavailableView(
                        String(localized: "search_bible"),
                        systemImage: "magnifyingglass",
                        description: Text(String(localized: "search_enter_prompt"))
                    )
                } else if !resultSummary.isEmpty {
                    ContentUnavailableView(
                        String(localized: "no_results"),
                        systemImage: "magnifyingglass",
                        description: Text("No matches found for \"\(query)\"")
                    )
                }
            }
            .accessibilityIdentifier("searchResultsList")
        }
    }

    /// Stable app-owned query field used for both user input and UI automation.
    private var searchQueryBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(String(localized: "search_bible_text"), text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .submitLabel(.search)
                .focused($isSearchFieldFocused)
                .accessibilityIdentifier("searchQueryField")
                .onSubmit {
                    isSearchFieldFocused = false
                    performSearch()
                }

            if !query.isEmpty {
                Button {
                    query = ""
                    clearSearchResults()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "clear"))
                .accessibilityIdentifier("searchClearQueryButton")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary)
        )
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .onAppear {
            if UITestRuntimeConfiguration.shouldAutofocusSearchField {
                DispatchQueue.main.async {
                    isSearchFieldFocused = true
                }
            }
        }
    }

    // MARK: - Search Options Panel

    /// Search-mode, scope, and translation controls shown above the result list.
    private var searchOptionsPanel: some View {
        VStack(spacing: 12) {
            Picker(String(localized: "search_match"), selection: $wordMode) {
                ForEach(SearchWordMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue)
                        .tag(mode)
                        .accessibilityIdentifier("searchWordModeButton::\(searchWordModeToken(for: mode))")
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("searchWordModePicker")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    scopeButton(String(localized: "search_scope_all"), choice: .wholeBible)
                    scopeButton(String(localized: "search_scope_ot"), choice: .oldTestament)
                    scopeButton(String(localized: "search_scope_nt"), choice: .newTestament)
                    scopeButton(currentBook, choice: .currentBook)
                }
                .font(.subheadline)
            }
            .accessibilityIdentifier("searchScopeStrip")

            if installedBibleModules.count > 1 {
                Button {
                    openTranslationPicker()
                } label: {
                    HStack {
                        Image(systemName: "book.closed")
                            .font(.caption)
                        Text(selectedTranslationSummaryLabel)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("searchTranslationPickerButton")
                .accessibilityValue("\(searchAccessibilitySelectionToken);\(searchAccessibilityTranslationPickerToken)")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("searchOptionsPanel")
        .accessibilityValue("visible")
    }

    /**
     Builds one pill-style scope selector button.

     - Parameters:
       - label: User-visible scope label.
       - choice: Scope value activated when the button is tapped.
     */
    private func scopeButton(_ label: String, choice: ScopeChoice) -> some View {
        Button(label) {
            scopeOption = choice
        }
        .font(.subheadline)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            scopeOption == choice ? Color.accentColor.opacity(0.2) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .foregroundStyle(scopeOption == choice ? Color.accentColor : Color.primary)
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(scopeOption == choice ? "selected" : "unselected")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(searchScopeIdentifier(for: choice))
    }

    /**
     Returns a stable accessibility identifier for one Search scope selector.
     *
     * - Parameter choice: Scope value represented by the button.
     * - Returns: Identifier formatted as `searchScopeButton::<scope>`.
     * - Side effects: none.
     * - Failure modes: none.
     */
    private func searchScopeIdentifier(for choice: ScopeChoice) -> String {
        "searchScopeButton::\(searchScopeToken(for: choice))"
    }

    /**
     Returns the stable exported token for one Search scope choice.
     *
     * - Parameter choice: Scope value to serialize for accessibility state and identifiers.
     * - Returns: Deterministic lowercase token for the scope.
     * - Side effects: none.
     * - Failure modes: none.
     */
    private func searchScopeToken(for choice: ScopeChoice) -> String {
        switch choice {
        case .wholeBible:
            return "wholeBible"
        case .oldTestament:
            return "oldTestament"
        case .newTestament:
            return "newTestament"
        case .currentBook:
            return "currentBook"
        }
    }

    /**
     Returns the stable exported token for one Search word-matching mode.
     *
     * - Parameter mode: Word-mode value to serialize for accessibility state.
     * - Returns: Deterministic lowercase token for the word mode.
     * - Side effects: none.
     * - Failure modes: none.
     */
    private func searchWordModeToken(for mode: SearchWordMode) -> String {
        switch mode {
        case .allWords:
            return "allWords"
        case .anyWord:
            return "anyWord"
        case .phrase:
            return "phrase"
        }
    }

    /// Resets Search result state when the visible query is explicitly cleared.
    private func clearSearchResults() {
        results = []
        multiResults = nil
        resultSummary = ""
        isSearching = false
    }

    // MARK: - Results Sections

    /// Result section used for single-translation searches.
    private var singleResultsSection: some View {
        Section {
            ForEach(results) { hit in
                Button(action: { navigateTo(hit) }) {
                    searchHitRow(hit)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(searchResultIdentifier(for: hit))
            }
        }
    }

    /**
     Builds the grouped-results UI for multi-translation searches.

     - Parameter multi: Aggregate result counts and module summary data for the current search.
     */
    private func multiResultsSection(_ multi: MultiResultGroup) -> some View {
        Group {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(multi.perModule, id: \.name) { entry in
                            HStack(spacing: 4) {
                                Text(entry.name)
                                    .font(.caption.weight(.semibold))
                                Text("\(entry.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.quaternary, in: Capsule())
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(entry.name)
                            .accessibilityValue("count=\(entry.count)")
                            .accessibilityIdentifier("searchResultGroupPill::\(sanitizedAccessibilitySegment(entry.name))")
                        }
                    }
                }
            }

            Section {
                ForEach(results) { hit in
                    Button(action: { navigateTo(hit) }) {
                        searchHitRow(hit)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(searchResultIdentifier(for: hit))
                }
            }
        }
    }

    /**
     Builds one result-row view for a search hit.

     - Parameter hit: Passage-level search result to render.
     */
    private func searchHitRow(_ hit: SearchHit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let moduleName = hit.moduleName {
                Text("\(hit.reference) (\(moduleName))")
                    .font(.headline)
            } else {
                Text(hit.reference)
                    .font(.headline)
            }
            highlightedText(hit.text)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(.vertical, 2)
    }

    /**
     Returns the stable accessibility identifier for one result row.

     - Parameter hit: Search hit whose verse reference should back the identifier.
     - Returns: Identifier formatted as `searchResultRow::<sanitized reference>`.
     */
    private func searchResultIdentifier(for hit: SearchHit) -> String {
        "searchResultRow::\(sanitizedAccessibilitySegment(hit.reference))"
    }

    /**
     Returns an accessibility-safe token derived from user-visible text.

     - Parameter value: Raw string that may contain spaces or punctuation.
     - Returns: Alphanumeric identifier segment with non-word runs normalized to underscores.
     */
    private func sanitizedAccessibilitySegment(_ value: String) -> String {
        let collapsed = value.replacingOccurrences(
            of: "[^A-Za-z0-9]+",
            with: "_",
            options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    /**
     Returns a `Text` value with query terms and Strong's tags visually emphasized.

     - Parameter text: Source snippet text returned by indexed or SWORD search.
     - Returns: Styled text that bolds query-term matches and formats Strong's tags as superscripts.
     */
    private func highlightedText(_ text: String) -> Text {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        let lower = text.lowercased()

        var result = Text("")
        var currentIndex = text.startIndex

        while currentIndex < text.endIndex {
            // Check for Strong's tag <H\d+> or <G\d+>
            if text[currentIndex] == "<",
               let closingIdx = Self.strongsTagClosingIndex(in: text, from: currentIndex) {
                let inner = String(text[text.index(after: currentIndex)..<closingIdx])
                let isMatch = !terms.isEmpty && terms.contains(where: { inner.lowercased().contains($0) })
                if isMatch {
                    result = result + Text(inner)
                        .font(.system(size: 9))
                        .baselineOffset(-3)
                        .foregroundColor(.accentColor)
                } else {
                    result = result + Text(inner)
                        .font(.system(size: 9))
                        .baselineOffset(-3)
                        .foregroundColor(Color.secondary.opacity(0.5))
                }
                currentIndex = text.index(after: closingIdx)
                continue
            }

            // Check for query term match
            var matched = false
            if !terms.isEmpty {
                for term in terms {
                    if lower[currentIndex...].hasPrefix(term) {
                        let end = text.index(currentIndex, offsetBy: term.count, limitedBy: text.endIndex) ?? text.endIndex
                        result = result + Text(text[currentIndex..<end]).bold().foregroundColor(.accentColor)
                        currentIndex = end
                        matched = true
                        break
                    }
                }
            }

            if !matched {
                let start = currentIndex
                currentIndex = text.index(after: currentIndex)
                while currentIndex < text.endIndex {
                    if text[currentIndex] == "<",
                       Self.strongsTagClosingIndex(in: text, from: currentIndex) != nil {
                        break
                    }
                    if !terms.isEmpty {
                        var foundTerm = false
                        for term in terms {
                            if lower[currentIndex...].hasPrefix(term) {
                                foundTerm = true
                                break
                            }
                        }
                        if foundTerm { break }
                    }
                    currentIndex = text.index(after: currentIndex)
                }
                result = result + Text(text[start..<currentIndex])
            }
        }
        return result
    }

    /**
     Returns the closing angle-bracket index for a Strong's tag at the given position.

     - Parameters:
       - text: Full snippet text being scanned for inline Strong's tags.
       - start: Candidate index that may begin a tag like `<H12345>` or `<G999>`.
     - Returns: The index of the closing `>` when a valid Strong's tag is found, otherwise `nil`.
     */
    private static func strongsTagClosingIndex(in text: String, from start: String.Index) -> String.Index? {
        guard text[start] == "<" else { return nil }
        let afterLt = text.index(after: start)
        guard afterLt < text.endIndex else { return nil }
        let ch = text[afterLt]
        guard ch == "H" || ch == "G" || ch == "h" || ch == "g" else { return nil }
        var idx = text.index(after: afterLt)
        guard idx < text.endIndex, text[idx].isNumber else { return nil }
        while idx < text.endIndex, text[idx].isNumber {
            idx = text.index(after: idx)
        }
        guard idx < text.endIndex, text[idx] == ">" else { return nil }
        return idx
    }

    // MARK: - Translation Picker

    /**
     Builds the dimmed modal layer used for Android-style multi-translation selection.

     The overlay is owned by `SearchView` rather than SwiftUI sheet presentation so Search matches
     Android's in-place `AlertDialog` behavior: the picker edits a local draft, Cancel discards it,
     and OK is the only commit path.

     - Returns: Full-screen modal dimmer and centered picker dialog.
     - Side effects: Button actions inside the dialog can mutate `pendingTranslationSelection`,
       commit to `selectedModules`, or dismiss the overlay; tapping the dimmer follows Android's
       dialog-cancel path and discards the draft.
     - Failure modes: Empty module sets render an empty scroll region; the caller only presents the
       picker when more than one installed Bible module exists.
     */
    private var translationPickerOverlay: some View {
        ZStack {
            Color.black.opacity(colorScheme == .dark ? 0.45 : 0.32)
                .ignoresSafeArea()
                .onTapGesture {
                    cancelTranslationPicker()
                }
                .accessibilityHidden(true)

            makeTranslationPicker(modules: installedBibleModules)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("searchTranslationPickerOverlay")
    }

    /**
     Builds the Android-style Search translation multiselect dialog.

     Android's `Search.showTranslationSelector` presents a multi-choice `AlertDialog` with all
     Bible modules sorted by abbreviation, existing selections prechecked, explicit Cancel/OK
     buttons, and a neutral Select all/none toggle. This SwiftUI surface mirrors that contract
     without using an iOS sheet or committing row taps directly to Search state.

     - Parameter modules: Installed Bible modules available for selection.
     - Returns: Centered modal dialog containing title, selectable rows, and dialog actions.
     - Side effects: Row and Select all/none actions mutate only `pendingTranslationSelection`; OK
       may commit to `selectedModules` through `commitTranslationPickerSelection()`.
     - Failure modes: Missing index-service state is treated as unknown and therefore does not add
       the unindexed warning label.
     */
    private func makeTranslationPicker(modules: [ModuleInfo]) -> some View {
        VStack(spacing: 0) {
            Text(String(localized: "compare_choose_translations"))
                .font(.headline)
                .foregroundStyle(dialogPrimaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .padding(.bottom, 12)

            Divider()
                .background(dialogSecondaryText.opacity(0.25))

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Self.androidSortedTranslationModules(modules)) { mod in
                        translationRow(mod)
                        Divider()
                            .background(dialogSecondaryText.opacity(0.18))
                            .padding(.leading, 22)
                    }
                }
                .accessibilityIdentifier("searchTranslationPickerList")
            }
            .frame(maxHeight: 420)

            Divider()
                .background(dialogSecondaryText.opacity(0.25))

            HStack(spacing: 14) {
                Button(String(localized: "cancel")) {
                    cancelTranslationPicker()
                }
                .foregroundStyle(dialogAccent)
                .accessibilityIdentifier("searchTranslationCancelButton")

                Spacer(minLength: 8)

                Button(searchTranslationSelectToggleTitle) {
                    toggleAllTranslationRows()
                }
                .foregroundStyle(dialogAccent)
                .accessibilityIdentifier("searchTranslationSelectAllButton")
                .accessibilityValue(searchTranslationSelectToggleAccessibilityValue)

                Button(String(localized: "ok", defaultValue: "OK")) {
                    commitTranslationPickerSelection()
                }
                .fontWeight(.semibold)
                .foregroundStyle(dialogAccent)
                .accessibilityIdentifier("searchTranslationOKButton")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(maxWidth: 430)
        .background(dialogBackground, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(dialogSecondaryText.opacity(0.28), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 20, x: 0, y: 12)
    }

    /**
     Builds one Android-style checkbox row in the Search translation picker.

     - Parameter mod: Installed module metadata for the row being rendered.
     - Returns: A full-width button that toggles the row's draft checked state.
     - Side effects: Mutates `pendingTranslationSelection`; it does not mutate committed Search
       module selection until the dialog OK action runs.
     - Failure modes: If index readiness cannot be determined, the row label omits the unindexed
       suffix rather than presenting possibly false status.
     */
    private func translationRow(_ mod: ModuleInfo) -> some View {
        let modName = mod.name
        let isSelected = pendingTranslationSelection.contains(modName)
        let rowLabel = Self.androidTranslationPickerLabel(
            for: mod,
            isIndexed: isTranslationModuleIndexed(modName),
            unindexedStatus: String(localized: "search_index_not_created", defaultValue: "Search index not created")
        )
        return Button {
            togglePendingTranslationSelection(modName)
        } label: {
            HStack(spacing: 14) {
                if isSelected {
                    Image(systemName: "checkmark.square.fill")
                        .foregroundStyle(dialogAccent)
                } else {
                    Image(systemName: "square")
                        .foregroundStyle(dialogSecondaryText)
                }
                Text(rowLabel)
                    .font(.body)
                    .foregroundStyle(dialogPrimaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("searchTranslationRow::\(sanitizedAccessibilitySegment(modName))")
        .accessibilityValue(isSelected ? "selected" : "unselected")
    }

    /// Android-dialog background color for the current system appearance.
    private var dialogBackground: Color {
        AndroidDialogSurfacePalette.background(for: colorScheme)
    }

    /// Android-dialog primary text color for the current system appearance.
    private var dialogPrimaryText: Color {
        AndroidDialogSurfacePalette.primaryText(for: colorScheme)
    }

    /// Android-dialog secondary text color for the current system appearance.
    private var dialogSecondaryText: Color {
        AndroidDialogSurfacePalette.secondaryText(for: colorScheme)
    }

    /// Android-dialog accent color for interactive picker actions.
    private var dialogAccent: Color {
        AndroidDialogSurfacePalette.accent(for: colorScheme)
    }

    /**
     Opens the Search translation picker with a draft that mirrors Android prechecked rows.

     Android loads the existing saved/current selection before presenting the multiselect dialog,
     then lets the dialog mutate temporary checked state until an action is pressed. This method
     seeds that draft from the committed iOS Search selection and the current primary module.

     Side effects:
     - clears Search field focus so the dialog is not obscured by the keyboard
     - mutates `pendingTranslationSelection`
     - sets `showTranslationPicker` to present the overlay

     Failure modes:
     - if no committed selection and no primary module exist, the draft is empty and OK will leave
       the committed Search selection unchanged.
     */
    private func openTranslationPicker() {
        isSearchFieldFocused = false
        pendingTranslationSelection = Set(Self.androidOrderedSelectedSearchModuleNames(
            selectedModuleNames: selectedModules,
            primaryModuleName: swordModule?.info.name,
            installedModules: installedBibleModules
        ))
        showTranslationPicker = true
    }

    /**
     Dismisses the Search translation picker without committing the draft selection.

     Android's dialog Cancel path returns an empty result and leaves the existing selected
     translations untouched. iOS mirrors that by clearing only the draft state.

     Side effects:
     - clears `pendingTranslationSelection`
     - sets `showTranslationPicker` to false
     */
    private func cancelTranslationPicker() {
        pendingTranslationSelection.removeAll()
        showTranslationPicker = false
    }

    /**
     Commits the Search translation picker draft according to Android's non-empty result contract.

     Android ignores an empty selected result, including the case where the user presses OK after
     toggling all rows off. This method preserves the previous selection for empty drafts, otherwise
     it commits the draft while preserving the primary module first for downstream search ordering.

     Side effects:
     - may mutate `selectedModules`
     - clears the draft and dismisses the overlay
     - triggers the existing `selectedModules` change observer when the committed set changes
     */
    private func commitTranslationPickerSelection() {
        let orderedSelection = Self.androidCommittedTranslationSelection(
            previousModuleNames: selectedModules,
            draftModuleNames: pendingTranslationSelection,
            primaryModuleName: swordModule?.info.name,
            installedModules: installedBibleModules
        )
        if !orderedSelection.isEmpty {
            selectedModules = Set(orderedSelection)
        }
        pendingTranslationSelection.removeAll()
        showTranslationPicker = false
    }

    /**
     Toggles one draft module check state in the Search translation picker.

     Android allows the dialog's checked set to become empty while the dialog remains open; the
     empty OK result is ignored later. This method intentionally does not enforce "at least one"
     selection at row-tap time.

     - Parameter moduleName: SWORD module abbreviation for the tapped row.
     - Side effects: Mutates `pendingTranslationSelection`.
     */
    private func togglePendingTranslationSelection(_ moduleName: String) {
        if pendingTranslationSelection.contains(moduleName) {
            pendingTranslationSelection.remove(moduleName)
        } else {
            pendingTranslationSelection.insert(moduleName)
        }
    }

    /**
     Selects every module or clears the draft selection using Android's neutral-button behavior.

     Android's multiselect neutral button toggles between Select all and Select none without
     closing the dialog. This method mirrors that behavior against the abbreviation-sorted module
     list.

     Side effects: Mutates `pendingTranslationSelection`; does not commit to `selectedModules`.
     */
    private func toggleAllTranslationRows() {
        let allModuleNames = Set(Self.androidSortedTranslationModules(installedBibleModules).map(\.name))
        if pendingTranslationSelection.count == allModuleNames.count {
            pendingTranslationSelection.removeAll()
        } else {
            pendingTranslationSelection = allModuleNames
        }
    }

    /**
     Resolves whether one module has a completed Search index for picker labeling.

     Android appends "Search index not created" when JSword reports an index status other than
     done. iOS can only render that status when a `SearchIndexService` is available; absent service
     means direct SWORD fallback is in use, so the picker omits an unverified warning.

     - Parameter moduleName: SWORD module abbreviation to inspect.
     - Returns: `true` when the module should render without the unindexed suffix.
     - Side effects: Reads Search index metadata through `SearchIndexService`.
     */
    private func isTranslationModuleIndexed(_ moduleName: String) -> Bool {
        searchIndexService?.hasIndex(for: moduleName) ?? true
    }

    /// Visible Select all/none label for the Search translation picker neutral action.
    private var searchTranslationSelectToggleTitle: String {
        let allCount = Self.androidSortedTranslationModules(installedBibleModules).count
        if allCount > 0, pendingTranslationSelection.count == allCount {
            return String(localized: "select_none", defaultValue: "Select none")
        }
        return String(localized: "select_all", defaultValue: "Select all")
    }

    /// Stable UI-test semantic state for the picker neutral select toggle.
    private var searchTranslationSelectToggleAccessibilityValue: String {
        let allCount = Self.androidSortedTranslationModules(installedBibleModules).count
        return allCount > 0 && pendingTranslationSelection.count == allCount
            ? "selectNone"
            : "selectAll"
    }

    // MARK: - Navigation

    /**
     Forwards the selected result to the caller and dismisses Search.

     - Parameter hit: Selected search result.
     */
    private func navigateTo(_ hit: SearchHit) {
        onNavigate?(hit.book, hit.chapter, hit.verse)
        dismiss()
    }

    // MARK: - Index Management

    /**
     Checks whether the selected search target modules already have indexes.

     Android checks JSword index readiness before launching indexed searches, including Strong's
     "find all occurrences" queries. iOS mirrors that behavior by resolving Strong's-capable Bible
     modules for Strong's input and ordinary selected modules for text input, then prompting for
     the first missing index before allowing the search to auto-run.

     Side effects:
     - mutates `viewState` to `.ready`, `.needsIndex`, or `.creatingIndex`
     - may trigger `autoSearchIfNeeded()` when the search UI becomes ready
     - reads index availability from `SearchIndexService`

     Failure modes:
     - if `searchIndexService` is unavailable, the method intentionally skips index inspection,
       marks the view ready, and leaves `performSearch()` to use its non-indexed SWORD fallback
     - if no Strong's-capable module can be resolved for a Strong's query, the method marks the
       view ready so the search can finish with zero results rather than blocking on an index that
       cannot be built
     */
    private func checkIndex() {
        if StrongsSearchSupport.normalizedQueryOptions(for: query) != nil {
            guard let service = searchIndexService else {
                viewState = .ready
                autoSearchIfNeeded()
                return
            }

            let strongsModules = Self.resolveStrongsSearchModules(
                currentModule: swordModule,
                installedModules: installedBibleModules,
                swordManager: swordManager,
                searchIndexService: service
            )
            guard !strongsModules.isEmpty else {
                viewState = .ready
                autoSearchIfNeeded()
                return
            }

            if let missingModule = strongsModules.first(where: { !service.hasStrongsIndex(for: $0.info.name) }) {
                viewState = .needsIndex(
                    moduleName: missingModule.info.name,
                    moduleDescription: moduleDescription(for: missingModule.info.name)
                )
                return
            }

            viewState = .ready
            autoSearchIfNeeded()
            return
        }

        guard let service = searchIndexService, let mod = swordModule else {
            // No service or module — skip index check, go directly to ready
            viewState = .ready
            autoSearchIfNeeded()
            return
        }

        let moduleNames = Self.androidOrderedSelectedSearchModuleNames(
            selectedModuleNames: selectedModules,
            primaryModuleName: mod.info.name,
            installedModules: installedBibleModules
        )
        if let missingModuleName = moduleNames.first(where: { !service.hasIndex(for: $0) }) {
            viewState = .needsIndex(
                moduleName: missingModuleName,
                moduleDescription: moduleDescription(for: missingModuleName)
            )
        } else {
            viewState = .ready
            autoSearchIfNeeded()
        }
    }

    /**
     Resolves a user-visible description for one installed module name.

     - Parameter moduleName: SWORD module abbreviation to describe.
     - Returns: Module description when available, otherwise the module abbreviation.
     */
    private func moduleDescription(for moduleName: String) -> String {
        if let info = installedBibleModules.first(where: { $0.name == moduleName }) {
            return info.description.isEmpty ? info.name : info.description
        }
        if let mod = swordModule, mod.info.name == moduleName {
            return mod.info.description.isEmpty ? mod.info.name : mod.info.description
        }
        if let mod = swordManager?.module(named: moduleName) {
            return mod.info.description.isEmpty ? mod.info.name : mod.info.description
        }
        return moduleName
    }

    /**
     Auto-executes a search once the view becomes ready and a non-empty query is already present.

     This covers both externally seeded queries and text the user entered while the view was still
     waiting on index readiness.
     */
    private func autoSearchIfNeeded() {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            performSearch()
        }
    }

    /**
     Seeds the query field from an externally provided initial query when it changes meaningfully.

     - Parameter value: Proposed initial query passed in from the presenting screen.
     - Returns: `true` when the helper updated the visible query field, otherwise `false`.
     - Side effects:
     *   - mutates `query` when `value` is non-empty and differs from the current field content
     - Failure modes:
     *   - ignores empty values and duplicate assignments so repeated parent re-renders do not
     *     restart the search loop unnecessarily
     */
    private func applyInitialQueryIfNeeded(_ value: String) -> Bool {
        guard !value.isEmpty, query != value else { return false }
        query = value
        return true
    }

    /**
     Starts asynchronous index creation for the modules required by the current query.

     Ordinary text searches index the primary and selected translation modules. Strong's searches
     index Strong's-capable Bible modules so the later query can use the same indexed lexical-token
     architecture Android gets from JSword. Once all requested indexes are built, the view
     transitions back to `.ready`.

     Side effects:
     - mutates `viewState` to `.creatingIndex` and later back to `.ready`
     - queries `SearchIndexService` and `SwordManager` to collect modules requiring indexes
     - launches asynchronous index creation work for each queued module

     Failure modes:
     - if `searchIndexService` is unavailable, the method skips index creation and immediately
       transitions the view back to `.ready`
     - if a selected module cannot be resolved from `SwordManager`, it is silently skipped
     - `SearchIndexService.createIndex` does not surface thrown errors here; any internal failure is
       treated as a best-effort attempt and the view still returns to `.ready`
     */
    private func startIndexCreation() {
        guard let service = searchIndexService else {
            viewState = .ready
            return
        }

        viewState = .creatingIndex

        // Collect all modules that need indexing
        let modulesToIndex: [(SwordModule, String)] = {
            var list: [(SwordModule, String)] = []
            if StrongsSearchSupport.normalizedQueryOptions(for: query) != nil {
                let strongsModules = Self.resolveStrongsSearchModules(
                    currentModule: swordModule,
                    installedModules: installedBibleModules,
                    swordManager: swordManager,
                    searchIndexService: service
                )
                for mod in strongsModules where !service.hasStrongsIndex(for: mod.info.name) {
                    list.append((mod, mod.info.name))
                }
                return list
            }

            // Always index the primary module
            if let mod = swordModule, !service.hasIndex(for: mod.info.name) {
                list.append((mod, mod.info.name))
            }
            // Also index any other selected modules
            if let mgr = swordManager {
                let selectedNames = Self.androidOrderedSelectedSearchModuleNames(
                    selectedModuleNames: selectedModules,
                    primaryModuleName: swordModule?.info.name,
                    installedModules: installedBibleModules
                )
                for name in selectedNames where !service.hasIndex(for: name) {
                    if let existing = list.first(where: { $0.1 == name }) {
                        _ = existing // already queued
                    } else if let mod = mgr.module(named: name) {
                        list.append((mod, name))
                    }
                }
            }
            return list
        }()

        Task {
            for (mod, _) in modulesToIndex {
                await service.createIndex(module: mod)
            }
            viewState = .ready
            autoSearchIfNeeded()
        }
    }

    // MARK: - Search Execution

    /**
     Executes the current search query using indexed Strong's lookup, indexed FTS, or SWORD fallback.

     The method snapshots current view state, then performs the potentially expensive work in a
     detached task so UI updates remain responsive. Results are marshalled back to the main actor.

     Side effects:
     - clears current results and marks the view as actively searching
     - snapshots search configuration and dispatches background work in a detached task
     - publishes result hits, summaries, and final loading state back on the main actor

     Failure modes:
     - if the trimmed query is empty, the method returns without starting a search
     - if the current module, search index service, or SWORD manager are unavailable, the detached
       search logic falls back to whichever strategies remain possible and may legitimately yield no results
     - zero-hit searches are treated as a valid outcome and update the UI with empty results rather than an error
     */
    private func performSearch() {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isSearching = true
        multiResults = nil
        results = []
        resultSummary = ""

        let currentQuery = query
        let currentWordMode = wordMode
        let currentScope = scopeOption
        let currentSelectedModules = Self.androidOrderedSelectedSearchModuleNames(
            selectedModuleNames: selectedModules,
            primaryModuleName: swordModule?.info.name,
            installedModules: installedBibleModules
        )
        let bookName = currentBook
        let osisBookId = currentOsisBookId
        let currentSwordModule = swordModule
        let currentSwordManager = swordManager
        let currentSearchIndexService = searchIndexService
        let currentInstalledBibleModules = installedBibleModules
        let strongsQueryOptions = StrongsSearchSupport.normalizedQueryOptions(for: currentQuery)
        let (scopeBookName, scopeTestament) = Self.resolveScopeParams(
            scope: currentScope, bookName: bookName
        )
        let swordScope = Self.swordScope(for: currentScope, osisBookId: osisBookId)
        let strongsModules: [SwordModule] = if strongsQueryOptions != nil {
            Self.resolveStrongsSearchModules(
                currentModule: currentSwordModule,
                installedModules: currentInstalledBibleModules,
                swordManager: currentSwordManager,
                searchIndexService: currentSearchIndexService
            )
        } else {
            []
        }
        let singleModuleName = currentSelectedModules.first ?? currentSwordModule?.info.name ?? ""

        Task.detached(priority: .userInitiated) {
            // Android parity: find-all occurrences uses canonical Strong's tokens from the
            // module index and a Strong's-capable Bible module, not plain-text FTS.
            if let strongsQueryOptions {
                if !strongsModules.isEmpty {
                    var hits: [SearchHit] = []
                    for strongsModule in strongsModules {
                        if let service = currentSearchIndexService,
                           service.hasStrongsIndex(for: strongsModule.info.name) {
                            hits = Self.convertIndexResults(service.searchStrongs(
                                canonicalTokens: strongsQueryOptions.canonicalStrongTokens,
                                moduleName: strongsModule.info.name,
                                scopeBookName: scopeBookName,
                                scopeTestament: scopeTestament
                            ))
                        } else {
                            hits = StrongsSearchSupport.searchVerseHits(
                                in: strongsModule,
                                queryOptions: strongsQueryOptions,
                                scope: swordScope
                            ).map {
                                SearchHit(
                                    book: $0.book,
                                    chapter: $0.chapter,
                                    verse: $0.verse,
                                    text: $0.previewText,
                                    moduleName: nil
                                )
                            }
                        }
                        if !hits.isEmpty { break }
                    }
                    let resolvedHits = hits
                    await MainActor.run {
                        results = resolvedHits
                        resultSummary = String(localized: "\(resolvedHits.count) verses in 1 translation")
                        isSearching = false
                    }
                    return
                }
            }

            if let service = currentSearchIndexService {
                // FTS5 index search
                if currentSelectedModules.count > 1 {
                    let grouped = service.searchMultiple(
                        query: currentQuery,
                        moduleNames: currentSelectedModules,
                        wordMode: currentWordMode,
                        scopeBookName: scopeBookName,
                        scopeTestament: scopeTestament
                    )
                    let hits = Self.convertGroupedResults(
                        grouped,
                        moduleOrder: currentSelectedModules
                    )
                    let perModule = Self.orderedGroupedModuleNames(
                        grouped,
                        moduleOrder: currentSelectedModules
                    ).map { moduleName in
                        (name: moduleName, count: grouped[moduleName]?.count ?? 0)
                    }
                    let totalCount = perModule.reduce(0) { $0 + $1.count }

                    await MainActor.run {
                        results = hits
                        multiResults = MultiResultGroup(perModule: perModule, totalCount: totalCount)
                        resultSummary = String(localized: "\(totalCount) verses in \(perModule.count) translations")
                        isSearching = false
                    }
                } else {
                    let ftsResults = service.search(
                        query: currentQuery,
                        moduleName: singleModuleName,
                        wordMode: currentWordMode,
                        scopeBookName: scopeBookName,
                        scopeTestament: scopeTestament
                    )
                    let hits = Self.convertIndexResults(ftsResults)

                    await MainActor.run {
                        results = hits
                        resultSummary = String(localized: "\(hits.count) verses in 1 translation")
                        isSearching = false
                    }
                }
            } else {
                // Fallback: direct SWORD search (no index service)
                if let module = currentSwordModule {
                    let decorated = currentWordMode.decorateQuery(currentQuery)
                    let options = SearchOptions(
                        query: decorated,
                        searchType: currentWordMode.searchType,
                        scope: swordScope
                    )
                    let swordResults = module.search(options)
                    let hits: [SearchHit] = swordResults.results.prefix(5000).compactMap { result in
                        guard let parsed = StrongsSearchSupport.parseVerseKey(result.key) else { return nil }
                        return SearchHit(
                            book: parsed.book, chapter: parsed.chapter,
                            verse: parsed.verse, text: result.previewText, moduleName: nil
                        )
                    }

                    await MainActor.run {
                        results = hits
                        resultSummary = String(localized: "\(hits.count) results")
                        isSearching = false
                    }
                } else {
                    await MainActor.run {
                        isSearching = false
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    /**
     Sorts Search translation picker modules using Android's abbreviation ordering.

     Android builds the Search translation multiselect with
     `SwordDocumentFacade.bibles.sortedBy { it.abbreviation }`. The iOS picker and commit helpers
     use this shared function so row order, select-all order, and result grouping do not depend on
     installer order or `Set` iteration.

     - Parameter modules: Installed Bible modules available to Search.
     - Returns: Modules sorted by their SWORD abbreviation (`ModuleInfo.name`).
     - Side effects: none.
     - Failure modes: Duplicate module names retain Swift's sort stability expectations only for
       equal keys; installed SWORD modules should have unique abbreviations.
     */
    nonisolated static func androidSortedTranslationModules(_ modules: [ModuleInfo]) -> [ModuleInfo] {
        modules.sorted { lhs, rhs in
            lhs.name < rhs.name
        }
    }

    /**
     Resolves selected Search module names in Android commit/search order.

     Android collects selected rows from the abbreviation-sorted dialog and then moves the current
     document to the front with `ensurePrimaryDocumentFirst()`. This function provides the same
     deterministic order for Search requests, grouped-result summaries, and UI-test state exports.

     - Parameters:
       - selectedModuleNames: Committed module abbreviations selected for Search.
       - primaryModuleName: Current reader/search module abbreviation, preferred first when present.
       - installedModules: Installed Bible modules used to derive Android dialog order.
     - Returns: Selected module abbreviations with the primary module first, followed by remaining
       selected modules in Android abbreviation order and unknown selections alphabetically.
     - Side effects: none.
     - Failure modes: If `selectedModuleNames` is empty and no primary exists, returns an empty
       array so callers can preserve their existing no-selection fallback.
     */
    nonisolated static func androidOrderedSelectedSearchModuleNames(
        selectedModuleNames: Set<String>,
        primaryModuleName: String?,
        installedModules: [ModuleInfo]
    ) -> [String] {
        var effectiveSelection = selectedModuleNames
        if effectiveSelection.isEmpty, let primaryModuleName {
            effectiveSelection.insert(primaryModuleName)
        }

        var orderedNames = androidSortedTranslationModules(installedModules)
            .map(\.name)
            .filter { effectiveSelection.contains($0) }

        let unknownNames = effectiveSelection.subtracting(orderedNames).sorted()
        orderedNames.append(contentsOf: unknownNames)

        if let primaryModuleName,
           let primaryIndex = orderedNames.firstIndex(of: primaryModuleName) {
            orderedNames.remove(at: primaryIndex)
            orderedNames.insert(primaryModuleName, at: 0)
        }

        return orderedNames
    }

    /**
     Applies Android's Search translation dialog commit rule to a picker draft.

     Android's positive button returns checked rows, but `Search.showTranslationSelector` only
     commits when that result is non-empty. This helper keeps iOS OK-with-no-selection equivalent
     to Android's ignored empty result while still returning a deterministic module order for
     non-empty commits.

     - Parameters:
       - previousModuleNames: Currently committed Search selection.
       - draftModuleNames: Draft checked rows from the open picker dialog.
       - primaryModuleName: Current reader/search module abbreviation, preferred first.
       - installedModules: Installed Bible modules used to derive Android dialog order.
     - Returns: Ordered effective selection: draft when non-empty, otherwise previous selection.
     - Side effects: none.
     - Failure modes: If both previous and draft selections are empty and no primary exists, returns
       an empty array.
     */
    nonisolated static func androidCommittedTranslationSelection(
        previousModuleNames: Set<String>,
        draftModuleNames: Set<String>,
        primaryModuleName: String?,
        installedModules: [ModuleInfo]
    ) -> [String] {
        let effectiveSelection = draftModuleNames.isEmpty ? previousModuleNames : draftModuleNames
        return androidOrderedSelectedSearchModuleNames(
            selectedModuleNames: effectiveSelection,
            primaryModuleName: primaryModuleName,
            installedModules: installedModules
        )
    }

    /**
     Builds the Android Search translation picker row label for one module.

     Android renders each row as "ABBR - Name" and appends the localized
     `search_index_not_created` text in parentheses when the module lacks a completed index. iOS
     keeps that exact information model while allowing the caller to supply localized status text.

     - Parameters:
       - module: Installed Bible module metadata for the row.
       - isIndexed: Whether Search can treat the module as index-ready.
       - unindexedStatus: Localized status suffix for modules without an index.
     - Returns: User-visible row label matching Android's abbreviation, description, and index
       readiness semantics.
     - Side effects: none.
     - Failure modes: Empty descriptions fall back to the module abbreviation to avoid rendering an
       incomplete "ABBR - " label.
     */
    nonisolated static func androidTranslationPickerLabel(
        for module: ModuleInfo,
        isIndexed: Bool,
        unindexedStatus: String
    ) -> String {
        let moduleName = module.description.isEmpty ? module.name : module.description
        let baseLabel = "\(module.name) - \(moduleName)"
        guard !isIndexed else { return baseLabel }
        return "\(baseLabel) (\(unindexedStatus))"
    }

    /**
     Resolves `SearchIndexService` scope parameters from the selected scope choice.

     - Parameters:
       - scope: Current scope selection from the UI.
       - bookName: User-visible current book name used for the current-book scope.
     - Returns: Book-name and testament filters appropriate for indexed search APIs.
     */
    nonisolated private static func resolveScopeParams(
        scope: ScopeChoice, bookName: String
    ) -> (scopeBookName: String?, scopeTestament: String?) {
        switch scope {
        case .wholeBible: return (nil, nil)
        case .oldTestament: return (nil, "OT")
        case .newTestament: return (nil, "NT")
        case .currentBook: return (bookName, nil)
        }
    }

    /**
     Converts a scope choice into the SWORD scope string used by non-indexed search APIs.

     - Parameters:
       - choice: Current scope selection from the UI.
       - osisBookId: Current OSIS book identifier for current-book searches.
     - Returns: SWORD scope expression or `nil` for whole-Bible search.
     */
    nonisolated private static func swordScope(for choice: ScopeChoice, osisBookId: String) -> String? {
        switch choice {
        case .wholeBible: return nil
        case .oldTestament: return "Gen-Mal"
        case .newTestament: return "Matt-Rev"
        case .currentBook: return osisBookId
        }
    }

    /**
     Converts indexed single-module results into list rows.

     - Parameter ftsResults: Raw index-search results returned by `SearchIndexService`.
     - Returns: Passage-level hits suitable for UI presentation.
     */
    nonisolated private static func convertIndexResults(
        _ ftsResults: [SearchIndexService.IndexSearchResult]
    ) -> [SearchHit] {
        ftsResults.compactMap { result in
            guard let parsed = StrongsSearchSupport.parseVerseKey(result.key) else { return nil }
            return SearchHit(
                book: parsed.book, chapter: parsed.chapter,
                verse: parsed.verse,
                text: SearchIndexService.cleanText(result.snippet),
                moduleName: nil
            )
        }
    }

    /**
     Flattens grouped multi-translation results into one ordered hit list.

     - Parameters:
       - grouped: Raw grouped index results keyed by module name.
       - moduleOrder: Android-ordered module names selected for the search.
     - Returns: Flat passage-level hits annotated with their source module name.
     - Side effects: none.
     - Failure modes: Groups whose module names are not in `moduleOrder` are appended
       alphabetically so no Search hits are dropped.
     */
    nonisolated private static func convertGroupedResults(
        _ grouped: [String: [SearchIndexService.IndexSearchResult]],
        moduleOrder: [String]
    ) -> [SearchHit] {
        var allHits: [SearchHit] = []
        for moduleName in orderedGroupedModuleNames(grouped, moduleOrder: moduleOrder) {
            for result in grouped[moduleName] ?? [] {
                guard let parsed = StrongsSearchSupport.parseVerseKey(result.key) else { continue }
                allHits.append(SearchHit(
                    book: parsed.book, chapter: parsed.chapter,
                    verse: parsed.verse,
                    text: SearchIndexService.cleanText(result.snippet),
                    moduleName: moduleName
                ))
            }
        }
        return allHits
    }

    /**
     Resolves grouped Search result module names in selected Android order.

     `SearchIndexService.searchMultiple` returns a dictionary, so iOS must restore Android's
     primary-first selected module order before building summaries or flattening rows. Any
     unexpected dictionary keys are appended alphabetically to preserve data without hiding drift.

     - Parameters:
       - grouped: Raw grouped Search results keyed by module abbreviation.
       - moduleOrder: Android-ordered selected modules used for the search request.
     - Returns: Module names to render for grouped Search summaries and rows.
     - Side effects: none.
     - Failure modes: Missing selected modules are omitted from the ordered prefix when the grouped
       response has no entry for them.
     */
    nonisolated private static func orderedGroupedModuleNames(
        _ grouped: [String: [SearchIndexService.IndexSearchResult]],
        moduleOrder: [String]
    ) -> [String] {
        let groupedNames = Set(grouped.keys)
        var orderedNames = moduleOrder.filter { groupedNames.contains($0) }
        let remainingNames = groupedNames.subtracting(orderedNames).sorted()
        orderedNames.append(contentsOf: remainingNames)
        return orderedNames
    }

    /**
     Resolves the effective module for Strong's "find all occurrences" searches.

     Android uses the current Bible when it has Strong's data; otherwise it chooses a default
     Strong's Bible, preferring one that already has a completed index. This resolver returns at
     most one module so iOS does not require indexing unrelated Strong's translations before a
     single find-all search can run.

     - Parameters:
       - currentModule: Currently open Bible module, preferred when it advertises Strong's support.
       - installedModules: Installed Bible modules available to the reader.
       - swordManager: Module manager used to resolve the fallback Strong's-capable module.
       - searchIndexService: Optional index service used to prefer an already-indexed fallback
         module when the current module is not Strong's-capable.
     - Returns: A single Strong's-capable module when one can be resolved, otherwise an empty list.
     */
    nonisolated private static func resolveStrongsSearchModules(
        currentModule: SwordModule?,
        installedModules: [ModuleInfo],
        swordManager: SwordManager?,
        searchIndexService: SearchIndexService?
    ) -> [SwordModule] {
        if let currentModule, currentModule.info.features.contains(.strongsNumbers) {
            return [currentModule]
        }

        guard let swordManager else { return [] }
        let strongsBibleInfos = installedModules
            .enumerated()
            .filter { $0.element.features.contains(.strongsNumbers) }
            .sorted { lhs, rhs in
                let leftIndexed = searchIndexService?.hasIndex(for: lhs.element.name) ?? false
                let rightIndexed = searchIndexService?.hasIndex(for: rhs.element.name) ?? false
                if leftIndexed != rightIndexed {
                    return leftIndexed && !rightIndexed
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)

        guard let defaultInfo = strongsBibleInfos.first,
              let defaultModule = swordManager.module(named: defaultInfo.name) else {
            return []
        }
        return [defaultModule]
    }

}
