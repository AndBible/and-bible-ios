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
        guard !terms.isEmpty else { return Text(text) }

        var result = Text("")
        let lower = text.lowercased()
        var currentIndex = text.startIndex

        while currentIndex < text.endIndex {
            var matched = false
            for term in terms {
                if lower[currentIndex...].hasPrefix(term) {
                    let end = text.index(currentIndex, offsetBy: term.count, limitedBy: text.endIndex) ?? text.endIndex
                    result = result + Text(text[currentIndex..<end]).bold().foregroundColor(.accentColor)
                    currentIndex = end
                    matched = true
                    break
                }
            }
            if !matched {
                let start = currentIndex
                while currentIndex < text.endIndex {
                    var foundTerm = false
                    for term in terms {
                        if lower[currentIndex...].hasPrefix(term) {
                            foundTerm = true
                            break
                        }
                    }
                    if foundTerm { break }
                    currentIndex = text.index(after: currentIndex)
                }
                result = result + Text(text[start..<currentIndex])
            }
        }
        return result
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
        let strongsQueries = Self.normalizedStrongsEntryAttributeQueries(for: currentQuery)

        Task.detached(priority: .userInitiated) {
            let (scopeBookName, scopeTestament) = Self.resolveScopeParams(
                scope: currentScope, bookName: bookName
            )
            let swordScope = Self.swordScope(for: currentScope, osisBookId: osisBookId)

            // Strong's find-all queries must use SWORD entry-attribute search; the FTS index
            // intentionally strips Strong's markup from indexed plain text.
            if !strongsQueries.isEmpty {
                let targetModuleNames: [String] = {
                    if currentSelectedModules.isEmpty {
                        if let primary = swordModule?.info.name {
                            return [primary]
                        }
                        return []
                    }
                    return Array(currentSelectedModules).sorted()
                }()

                var modules: [(name: String, module: SwordModule)] = []
                for moduleName in targetModuleNames {
                    if let module = swordManager?.module(named: moduleName) {
                        modules.append((name: moduleName, module: module))
                    } else if let primary = swordModule, primary.info.name == moduleName {
                        modules.append((name: moduleName, module: primary))
                    }
                }
                if modules.isEmpty, let primary = swordModule {
                    modules = [(name: primary.info.name, module: primary)]
                }

                if modules.count > 1 {
                    var allHits: [SearchHit] = []
                    var perModule: [(name: String, count: Int)] = []
                    for (moduleName, module) in modules {
                        let hits = Self.searchStrongsInModule(
                            module,
                            strongsQueries: strongsQueries,
                            moduleName: moduleName,
                            scope: swordScope
                        )
                        perModule.append((name: moduleName, count: hits.count))
                        allHits.append(contentsOf: hits)
                    }
                    let totalCount = perModule.reduce(0) { $0 + $1.count }
                    await MainActor.run {
                        results = allHits
                        multiResults = MultiResultGroup(perModule: perModule, totalCount: totalCount)
                        resultSummary = String(localized: "\(totalCount) verses in \(perModule.count) translations")
                        isSearching = false
                    }
                    return
                }

                if let module = modules.first {
                    let hits = Self.searchStrongsInModule(
                        module.module,
                        strongsQueries: strongsQueries,
                        moduleName: nil,
                        scope: swordScope
                    )
                    await MainActor.run {
                        results = hits
                        resultSummary = String(localized: "\(hits.count) verses in 1 translation")
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
                        guard let parsed = Self.parseVerseKey(result.key) else { return nil }
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
            guard let parsed = parseVerseKey(result.key) else { return nil }
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
                guard let parsed = parseVerseKey(result.key) else { continue }
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

    private static func parseVerseKey(_ key: String) -> (book: String, chapter: Int, verse: Int)? {
        guard let colonIdx = key.lastIndex(of: ":") else { return nil }
        let verseStr = String(key[key.index(after: colonIdx)...])
        let beforeColon = String(key[..<colonIdx])
        guard let spaceIdx = beforeColon.lastIndex(of: " ") else { return nil }
        let chapterStr = String(beforeColon[beforeColon.index(after: spaceIdx)...])
        let bookPart = String(beforeColon[..<spaceIdx])
        guard let chapter = Int(chapterStr), let verse = Int(verseStr) else { return nil }
        return (bookPart, chapter, verse)
    }

    private static func normalizedStrongsEntryAttributeQueries(for query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var candidate = trimmed.uppercased()
        if candidate.hasPrefix("LEMMA:STRONG:") {
            candidate = String(candidate.dropFirst("LEMMA:STRONG:".count))
        } else if candidate.hasPrefix("STRONG:") {
            candidate = String(candidate.dropFirst("STRONG:".count))
        } else if candidate.hasPrefix("LEMMA:") {
            candidate = String(candidate.dropFirst("LEMMA:".count))
        }

        guard let prefix = candidate.first, prefix == "H" || prefix == "G" else { return [] }
        let digitsRaw = String(candidate.dropFirst())
        guard !digitsRaw.isEmpty, digitsRaw.allSatisfy(\.isNumber) else { return [] }

        let stripped = String(digitsRaw.drop(while: { $0 == "0" }))
        let normalizedDigits = stripped.isEmpty ? "0" : stripped

        var normalizedKeys: [String] = []
        normalizedKeys.append("lemma:strong:\(prefix)\(digitsRaw)")
        if normalizedDigits != digitsRaw {
            normalizedKeys.append("lemma:strong:\(prefix)\(normalizedDigits)")
        }
        return normalizedKeys
    }

    private static func searchStrongsInModule(
        _ module: SwordModule,
        strongsQueries: [String],
        moduleName: String?,
        scope: String?
    ) -> [SearchHit] {
        for strongsQuery in strongsQueries {
            let options = SearchOptions(
                query: strongsQuery,
                searchType: .entryAttribute,
                scope: scope
            )
            let swordResults = module.search(options)
            let hits: [SearchHit] = swordResults.results.prefix(5000).compactMap { result in
                guard let parsed = parseVerseKey(result.key) else { return nil }
                return SearchHit(
                    book: parsed.book,
                    chapter: parsed.chapter,
                    verse: parsed.verse,
                    text: result.previewText,
                    moduleName: moduleName
                )
            }
            if !hits.isEmpty {
                return hits
            }
        }
        return []
    }
}
