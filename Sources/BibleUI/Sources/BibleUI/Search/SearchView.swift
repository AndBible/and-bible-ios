// SearchView.swift — Full-text search with FTS5 index support
//
// Matches Android's search UX: checks for search index, prompts creation if
// missing, shows progress during indexing, then enables fast FTS5 searching.

import SwiftUI
import BibleCore
import SwordKit

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
 - `navigateTo(_:)` dismisses the sheet and notifies the caller with the selected passage
 */
public struct SearchView: View {
    /// Callback invoked when the user selects a search hit and wants to navigate to it.
    let onNavigate: ((String, Int) -> Void)?

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

    /// Whether the options panel is expanded above the results list.
    @State private var showOptions = true

    /// Whether the system search field currently owns focus.
    @FocusState private var isSearchFieldFocused: Bool

    /// Navigation-title summary of the most recent search results.
    @State private var resultSummary: String = ""

    /// Dismiss action for closing the search sheet after navigation or cancellation.
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
        onNavigate: ((String, Int) -> Void)? = nil
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
     search interface while also wiring the toolbar and translation-picker sheet.
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
        .navigationTitle(navigationTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "done")) { dismiss() }
            }
            if case .ready = viewState {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        withAnimation { showOptions.toggle() }
                    } label: {
                        Image(systemName: showOptions ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $showTranslationPicker) {
            makeTranslationPicker(modules: installedBibleModules)
        }
        .onAppear {
            if selectedModules.isEmpty, let mod = swordModule {
                selectedModules = [mod.info.name]
            }
            _ = applyInitialQueryIfNeeded(initialQuery)
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

    /// Deterministic XCUITest summary of the current search screen state.
    private var searchAccessibilityValue: String {
        let stateToken: String = switch viewState {
        case .checkingIndex: "checkingIndex"
        case .needsIndex: "needsIndex"
        case .creatingIndex: "creatingIndex"
        case .ready: "ready"
        }
        let baseState = "state=\(stateToken);query=\(query);searching=\(isSearching);results=\(results.count);scope=\(searchScopeToken(for: scopeOption));wordMode=\(searchWordModeToken(for: wordMode))"
        guard UITestRuntimeConfiguration.enablesDetailedAccessibilityExports else {
            return baseState
        }
        return "\(baseState);rows=\(searchAccessibilityRowsToken)"
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
            DispatchQueue.main.async {
                isSearchFieldFocused = true
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
                    showTranslationPicker = true
                } label: {
                    HStack {
                        Image(systemName: "book.closed")
                            .font(.caption)
                        if selectedModules.count == 1, let name = selectedModules.first {
                            Text(name)
                        } else {
                            Text("\(selectedModules.count) translations")
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
        .accessibilityIdentifier("searchOptionsPanel")
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
                        }
                    }
                }
            }

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
     Builds the translation picker used for multi-translation searches.

     - Parameter modules: Installed Bible modules available for selection.
     */
    private func makeTranslationPicker(modules: [ModuleInfo]) -> some View {
        NavigationStack {
            List {
                ForEach(modules) { (mod: ModuleInfo) in
                    translationRow(mod)
                }
            }
            .navigationTitle(String(localized: "search_translations"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "done")) { showTranslationPicker = false }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(String(localized: "search_all")) {
                        selectedModules = Set(installedBibleModules.map(\.name))
                    }
                }
            }
        }
    }

    @ViewBuilder
    /**
     Builds one row in the translation picker.

     - Parameter mod: Installed module metadata for the row being rendered.
     */
    private func translationRow(_ mod: ModuleInfo) -> some View {
        let modName = mod.name
        let modDesc = mod.description
        let isSelected = selectedModules.contains(modName)
        Button {
            if isSelected {
                if selectedModules.count > 1 { selectedModules.remove(modName) }
            } else {
                selectedModules.insert(modName)
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(modName).font(.headline)
                    Text(modDesc).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                } else {
                    Image(systemName: "circle").foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Navigation

    /**
     Dismisses the search sheet and forwards the selected result to the caller.

     - Parameter hit: Selected search result.
     */
    private func navigateTo(_ hit: SearchHit) {
        dismiss()
        onNavigate?(hit.book, hit.chapter)
    }

    // MARK: - Index Management

    /**
     Checks whether the active module already has an index and updates `viewState` accordingly.

     Side effects:
     - mutates `viewState` to `.ready`, `.needsIndex`, or `.creatingIndex`
     - may trigger `autoSearchIfNeeded()` when the search UI becomes ready
     - reads index availability from `SearchIndexService`

     Failure modes:
     - if either `searchIndexService` or `swordModule` is unavailable, the method intentionally
       skips index inspection, marks the view ready, and continues without indexed search setup
     */
    private func checkIndex() {
        guard let service = searchIndexService, let mod = swordModule else {
            // No service or module — skip index check, go directly to ready
            viewState = .ready
            autoSearchIfNeeded()
            return
        }

        if service.hasIndex(for: mod.info.name) {
            viewState = .ready
            autoSearchIfNeeded()
        } else {
            viewState = .needsIndex(
                moduleName: mod.info.name,
                moduleDescription: mod.info.description.isEmpty ? mod.info.name : mod.info.description
            )
        }
    }

    /// Auto-executes a search when the view was launched with a seeded query.
    private func autoSearchIfNeeded() {
        if !initialQuery.isEmpty && !query.isEmpty {
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
     Starts asynchronous index creation for the primary and any selected unindexed modules.

     Once all requested indexes are built, the view transitions back to `.ready`.

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
            // Always index the primary module
            if let mod = swordModule, !service.hasIndex(for: mod.info.name) {
                list.append((mod, mod.info.name))
            }
            // Also index any other selected modules
            if let mgr = swordManager {
                for name in selectedModules where !service.hasIndex(for: name) {
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
     Executes the current search query using Strong's lookup, indexed FTS, or SWORD fallback.

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
        let currentSelectedModules = selectedModules
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
                swordManager: currentSwordManager
            )
        } else {
            []
        }
        let singleModuleName = currentSelectedModules.first ?? currentSwordModule?.info.name ?? ""

        Task.detached(priority: .userInitiated) {
            // Android parity: find-all occurrences uses "strong:<key>" query syntax and
            // a Strong's-capable Bible module, not plain-text FTS.
            if let strongsQueryOptions {
                if !strongsModules.isEmpty {
                    var hits: [SearchHit] = []
                    for strongsModule in strongsModules {
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
                        moduleNames: Array(currentSelectedModules),
                        wordMode: currentWordMode,
                        scopeBookName: scopeBookName,
                        scopeTestament: scopeTestament
                    )
                    let hits = Self.convertGroupedResults(grouped, query: currentQuery)
                    let perModule = grouped.map { (name: $0.key, count: $0.value.count) }
                        .sorted { $0.name < $1.name }
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
       - query: Original query string. Present for signature parity with earlier helpers.
     - Returns: Flat passage-level hits annotated with their source module name.
     */
    nonisolated private static func convertGroupedResults(
        _ grouped: [String: [SearchIndexService.IndexSearchResult]],
        query: String
    ) -> [SearchHit] {
        var allHits: [SearchHit] = []
        for (moduleName, results) in grouped.sorted(by: { $0.key < $1.key }) {
            for result in results {
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
     Resolves the best modules to use for Strong's "find all occurrences" searches.

     - Parameters:
       - currentModule: Currently open Bible module, preferred when it advertises Strong's support.
       - installedModules: Installed Bible modules available to the reader.
       - swordManager: Module manager used to resolve additional Strong's-capable modules.
     - Returns: Ordered modules to try for Strong's search, without duplicates.
     */
    nonisolated private static func resolveStrongsSearchModules(
        currentModule: SwordModule?,
        installedModules: [ModuleInfo],
        swordManager: SwordManager?
    ) -> [SwordModule] {
        var modules: [SwordModule] = []
        var seenNames = Set<String>()

        func appendUnique(_ module: SwordModule?) {
            guard let module else { return }
            if seenNames.insert(module.info.name).inserted {
                modules.append(module)
            }
        }

        // Prefer the currently-open module when it already has Strong's data.
        if let currentModule, currentModule.info.features.contains(.strongsNumbers) {
            appendUnique(currentModule)
        }

        // Then try every installed Strong's-capable Bible module.
        if let swordManager {
            let strongsBibleNames = installedModules
                .filter { $0.features.contains(.strongsNumbers) }
                .map(\.name)
                .sorted()
            for moduleName in strongsBibleNames {
                appendUnique(swordManager.module(named: moduleName))
            }
        }

        // Final fallback to current module even if feature metadata is missing/stale.
        appendUnique(currentModule)
        return modules
    }

}
