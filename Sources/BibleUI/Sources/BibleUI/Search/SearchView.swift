// SearchView.swift — Full-text search with FTS5 index support
//
// Matches Android's search UX: checks for search index, prompts creation if
// missing, shows progress during indexing, then enables fast FTS5 searching.

import SwiftUI
import BibleCore
import SwordKit

/// Full-text search interface with index management, scope, and multi-translation support.
public struct SearchView: View {
    let onNavigate: ((String, Int) -> Void)?
    var swordModule: SwordModule?
    var swordManager: SwordManager?
    var searchIndexService: SearchIndexService?
    var installedBibleModules: [ModuleInfo]
    var currentBook: String
    var currentOsisBookId: String

    @State private var viewState: ViewState = .checkingIndex
    @State private var query = ""
    @State private var isSearching = false
    @State private var results: [SearchHit] = []
    @State private var multiResults: MultiResultGroup?
    @State private var wordMode: SearchWordMode = .allWords
    @State private var scopeOption: ScopeChoice = .wholeBible
    @State private var showTranslationPicker = false
    @State private var selectedModules: Set<String> = []
    @State private var showOptions = true
    @State private var resultSummary: String = ""
    @Environment(\.dismiss) private var dismiss

    enum ViewState {
        case checkingIndex
        case needsIndex(moduleName: String, moduleDescription: String)
        case creatingIndex
        case ready
    }

    enum ScopeChoice: Hashable {
        case wholeBible, oldTestament, newTestament, currentBook
    }

    struct SearchHit: Identifiable {
        let id = UUID()
        let book: String
        let chapter: Int
        let verse: Int
        let text: String
        let moduleName: String?
        var reference: String { "\(book) \(chapter):\(verse)" }
    }

    struct MultiResultGroup {
        let perModule: [(name: String, count: Int)]
        let totalCount: Int
    }

    /// Optional initial query to auto-populate and execute (e.g. from "Find all occurrences").
    private var initialQuery: String

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
            if !initialQuery.isEmpty {
                query = initialQuery
            }
            checkIndex()
        }
    }

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

    // MARK: - Index Prompt

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

    private var searchContent: some View {
        VStack(spacing: 0) {
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
        }
        .searchable(text: $query, prompt: String(localized: "search_bible_text"))
        .onSubmit(of: .search) {
            performSearch()
        }
    }

    // MARK: - Search Options Panel

    private var searchOptionsPanel: some View {
        VStack(spacing: 12) {
            Picker(String(localized: "search_match"), selection: $wordMode) {
                ForEach(SearchWordMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 8) {
                scopeButton(String(localized: "search_scope_all"), choice: .wholeBible)
                scopeButton(String(localized: "search_scope_ot"), choice: .oldTestament)
                scopeButton(String(localized: "search_scope_nt"), choice: .newTestament)
                scopeButton(currentBook, choice: .currentBook)
            }
            .font(.subheadline)

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
    }

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
    }

    // MARK: - Results Sections

    private var singleResultsSection: some View {
        Section {
            ForEach(results) { hit in
                Button(action: { navigateTo(hit) }) {
                    searchHitRow(hit)
                }
                .buttonStyle(.plain)
            }
        }
    }

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
                }
            }
        }
    }

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

    /// Returns the index of '>' if text[from] starts a Strong's tag like <H12345> or <G999>.
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

    private func navigateTo(_ hit: SearchHit) {
        dismiss()
        onNavigate?(hit.book, hit.chapter)
    }

    // MARK: - Index Management

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

    /// Auto-execute search if an initialQuery was provided (e.g. "Find all occurrences").
    private func autoSearchIfNeeded() {
        if !initialQuery.isEmpty && !query.isEmpty {
            performSearch()
        }
    }

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
        }
    }

    // MARK: - Search Execution

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
        let strongsQueryOptions = StrongsSearchSupport.normalizedQueryOptions(for: currentQuery)

        Task.detached(priority: .userInitiated) {
            let (scopeBookName, scopeTestament) = Self.resolveScopeParams(
                scope: currentScope, bookName: bookName
            )
            let swordScope = Self.swordScope(for: currentScope, osisBookId: osisBookId)

            // Android parity: find-all occurrences uses "strong:<key>" query syntax and
            // a Strong's-capable Bible module, not plain-text FTS.
            if let strongsQueryOptions {
                let strongsModules = Self.resolveStrongsSearchModules(
                    currentModule: swordModule,
                    installedModules: installedBibleModules,
                    swordManager: swordManager
                )
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

            if let service = searchIndexService {
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
                    let moduleName = currentSelectedModules.first ?? swordModule?.info.name ?? ""
                    let ftsResults = service.search(
                        query: currentQuery,
                        moduleName: moduleName,
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
                if let module = swordModule {
                    let decorated = currentWordMode.decorateQuery(currentQuery)
                    let scope = Self.swordScope(for: currentScope, osisBookId: currentOsisBookId)
                    let options = SearchOptions(
                        query: decorated,
                        searchType: currentWordMode.searchType,
                        scope: scope
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

    private static func resolveScopeParams(
        scope: ScopeChoice, bookName: String
    ) -> (scopeBookName: String?, scopeTestament: String?) {
        switch scope {
        case .wholeBible: return (nil, nil)
        case .oldTestament: return (nil, "OT")
        case .newTestament: return (nil, "NT")
        case .currentBook: return (bookName, nil)
        }
    }

    private static func swordScope(for choice: ScopeChoice, osisBookId: String) -> String? {
        switch choice {
        case .wholeBible: return nil
        case .oldTestament: return "Gen-Mal"
        case .newTestament: return "Matt-Rev"
        case .currentBook: return osisBookId
        }
    }

    private static func convertIndexResults(
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

    private static func convertGroupedResults(
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

    private static func resolveStrongsSearchModules(
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
