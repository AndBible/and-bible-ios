// CompareView.swift — Compare translations for a passage

import SwiftUI
import BibleCore
import SwordKit

/**
 Presents a verse-by-verse translation comparison for the current passage across multiple modules.

 The view loads installed Bible modules, lets the user choose which translations to compare, and
 then builds an interleaved verse list where each verse shows all available translations together.

 Data dependencies:
 - `book`, `chapter`, `startVerse`, and `endVerse` define the passage range to compare
 - `currentModuleName` is highlighted first in each verse's translation list
 - `resolvedOsisBookId` can supply a pre-resolved book identifier for non-standard canons

 Side effects:
 - `onAppear` loads installed modules and may automatically present the module picker
 - translation selection mutates local state and triggers asynchronous SWORD module loading
 - `loadComparisons()` performs detached background work and then publishes verse results on the main actor
 */
struct CompareView: View {
    /// User-visible book name for the compared passage.
    let book: String

    /// One-based chapter number for the compared passage.
    let chapter: Int

    /// Module currently active in the main reader and prioritized in sorting/highlighting.
    let currentModuleName: String

    /// Optional first verse in the comparison range.
    var startVerse: Int? = nil

    /// Optional last verse in the comparison range.
    var endVerse: Int? = nil

    /// Optional pre-resolved OSIS book ID — avoids static 66-book fallback for apocrypha modules.
    var resolvedOsisBookId: String? = nil

    /// Dismiss action for closing the comparison screen.
    @Environment(\.dismiss) private var dismiss

    /// Names of installed modules eligible for comparison.
    @State private var installedModules: [String] = []

    /// User-selected module names to compare against each other.
    @State private var selectedModules: Set<String> = []

    /// Verse-by-verse comparison results currently rendered on screen.
    @State private var verses: [VerseComparison] = []

    /// Whether asynchronous comparison loading is currently in progress.
    @State private var isLoading = false

    /// Whether the translation-selection sheet is presented.
    @State private var showModulePicker = false

    /**
     Represents one verse and all translation texts available for that verse.
     */
    struct VerseComparison: Identifiable {
        /// One-based verse number used for display and stable identity.
        let verseNumber: Int

        /// Translation texts keyed by module name for the current verse.
        let translations: [(name: String, text: String)]

        /// Stable identifier derived from `verseNumber`.
        var id: Int { verseNumber }
    }

    /// Title string describing the currently compared book, chapter, and optional verse range.
    private var compareTitle: String {
        if let sv = startVerse, let ev = endVerse, sv != ev {
            return "\(book) \(chapter):\(sv)-\(ev)"
        } else if let sv = startVerse {
            return "\(book) \(chapter):\(sv)"
        }
        return "\(book) \(chapter)"
    }

    /**
     Builds the empty state, loading state, or verse comparison list with translation picker controls.
     */
    var body: some View {
        Group {
            if verses.isEmpty && !isLoading {
                VStack(spacing: 16) {
                    ContentUnavailableView(
                        String(localized: "compare_select_translations"),
                        systemImage: "books.vertical",
                        description: Text("Choose which translations to compare for \(book) \(chapter).")
                    )
                    if installedModules.count > 1 {
                        Button(String(localized: "compare_choose_translations")) {
                            showModulePicker = true
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Text(String(localized: "compare_install_additional_modules"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
            } else if isLoading {
                ProgressView(String(localized: "compare_loading_translations"))
            } else {
                verseComparisonList
            }
        }
        .navigationTitle(compareTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "done")) { dismiss() }
            }
            if !installedModules.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button(String(localized: "translations"), systemImage: "checklist") {
                        showModulePicker = true
                    }
                }
            }
        }
        .sheet(isPresented: $showModulePicker) {
            NavigationStack {
                modulePicker
            }
            .presentationDetents([.medium])
        }
        .onAppear {
            loadInstalledModules()
            if selectedModules.isEmpty {
                selectedModules.insert(currentModuleName)
            }
        }
    }

    /**
     Scrollable verse list that interleaves all selected translations for each verse.
     */
    private var verseComparisonList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(verses) { verse in
                    VStack(alignment: .leading, spacing: 6) {
                        // Verse number header
                        Text("Verse \(verse.verseNumber)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(.top, verse.verseNumber == 1 ? 4 : 12)

                        // Each translation for this verse
                        ForEach(verse.translations, id: \.name) { translation in
                            HStack(alignment: .top, spacing: 8) {
                                Text(translation.name)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(translation.name == currentModuleName ? .blue : .secondary)
                                    .frame(width: 48, alignment: .trailing)

                                Text(translation.text)
                                    .font(.body)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.horizontal)

                    Divider()
                        .padding(.top, 8)
                }
            }
            .padding(.vertical)
        }
    }

    /**
     Translation picker sheet used to toggle the modules included in comparison loading.
     */
    private var modulePicker: some View {
        List {
            Section {
                ForEach(installedModules, id: \.self) { name in
                    Button {
                        if selectedModules.contains(name) {
                            selectedModules.remove(name)
                        } else {
                            selectedModules.insert(name)
                        }
                    } label: {
                        HStack {
                            Text(name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if selectedModules.contains(name) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                }
            } header: {
                Text(String(localized: "compare_select_translations_header"))
            } footer: {
                Text("\(selectedModules.count) selected")
            }
        }
        .navigationTitle(String(localized: "translations"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "compare")) {
                    showModulePicker = false
                    loadComparisons()
                }
                .disabled(selectedModules.count < 2)
            }
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "cancel")) { showModulePicker = false }
            }
        }
    }

    /**
     Loads installed module names and decides whether to auto-open the picker or compare directly.

     Side effects:
     - performs detached SWORD manager access off the main actor
     - updates `installedModules`, `selectedModules`, and `showModulePicker` on the main actor
     - may trigger `loadComparisons()` automatically when only one eligible module exists
     */
    private func loadInstalledModules() {
        Task.detached {
            guard let mgr = SwordManager() else { return }
            // Get all installed modules — don't filter by category since
            // getCategory() may not reliably return "Biblical Texts" for all Bibles.
            // Instead, include all text-type modules (zText, RawText, etc.)
            let allModules = mgr.installedModules()
            let bibleNames = allModules
                .filter { mod in
                    // Include modules categorized as Bible, or those with text-based drivers
                    mod.category == .bible || mod.category == .unknown
                }
                .map(\.name)
                .sorted()

            // Fallback: if category filtering gives too few results, show all modules
            let moduleNames = bibleNames.count > 1 ? bibleNames : allModules.map(\.name).sorted()

            await MainActor.run {
                installedModules = moduleNames
                if moduleNames.count > 1 && verses.isEmpty {
                    showModulePicker = true
                } else if moduleNames.count == 1 {
                    selectedModules = Set(moduleNames)
                    loadComparisons()
                }
            }
        }
    }

    /**
     Loads verse-by-verse comparison data for the currently selected modules.

     Side effects:
     - sets `isLoading` before starting background work
     - resolves module handles, computes the available verse range, and builds interleaved results
     - publishes `verses` and clears `isLoading` on the main actor when loading finishes
     */
    private func loadComparisons() {
        guard selectedModules.count >= 2 else { return }
        isLoading = true

        let modulesToLoad = Array(selectedModules).sorted()
        Task.detached {
            guard let mgr = SwordManager() else {
                await MainActor.run { isLoading = false }
                return
            }

            let osisBookId = resolvedOsisBookId ?? BibleReaderController.osisBookId(for: book)

            // Get SwordModule handles for all selected modules
            var modules: [(name: String, mod: SwordModule)] = []
            for name in modulesToLoad {
                if let mod = mgr.module(named: name) {
                    modules.append((name: name, mod: mod))
                }
            }

            guard !modules.isEmpty else {
                await MainActor.run {
                    isLoading = false
                }
                return
            }

            // Determine the number of verses in this chapter using the first module
            let firstMod = modules[0].mod
            var maxVerse = 0
            firstMod.setKey("\(osisBookId) \(chapter):1")
            while true {
                let key = firstMod.currentKey()
                guard let colonIdx = key.lastIndex(of: ":"),
                      let spaceIdx = key[..<colonIdx].lastIndex(of: " ") else { break }
                let chapterStr = String(key[key.index(after: spaceIdx)..<colonIdx])
                let verseStr = String(key[key.index(after: colonIdx)...])
                guard let parsedChapter = Int(chapterStr),
                      let parsedVerse = Int(verseStr) else { break }
                if parsedChapter != chapter { break }
                maxVerse = parsedVerse
                if !firstMod.next() { break }
            }

            guard maxVerse > 0 else {
                await MainActor.run { isLoading = false }
                return
            }

            // Build verse-by-verse comparisons (respecting optional verse range)
            var verseComparisons: [VerseComparison] = []
            let firstVerse = startVerse ?? 1
            let lastVerse = endVerse ?? maxVerse

            for verse in firstVerse...min(lastVerse, maxVerse) {
                var translations: [(name: String, text: String)] = []

                for (name, mod) in modules {
                    mod.setKey("\(osisBookId) \(chapter):\(verse)")
                    let text = mod.stripText().trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        translations.append((name: name, text: text))
                    }
                }

                if !translations.isEmpty {
                    verseComparisons.append(VerseComparison(
                        verseNumber: verse,
                        translations: translations
                    ))
                }
            }

            // Sort module names: current module first
            let currentName = currentModuleName
            let sortedVerses = verseComparisons.map { verse in
                VerseComparison(
                    verseNumber: verse.verseNumber,
                    translations: verse.translations.sorted { a, b in
                        if a.name == currentName { return true }
                        if b.name == currentName { return false }
                        return a.name < b.name
                    }
                )
            }

            await MainActor.run {
                verses = sortedVerses
                isLoading = false
            }
        }
    }
}
