import XCTest
@testable import BibleCore
@testable import SwordKit
import SQLite3
@testable import BibleUI
@testable import BibleView

/// SQLite destructor marker used by the temporary MyBible dictionary fixtures in this file.
private let myBibleDictionaryFixtureSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/**
 Thread-safe recorder for SWORD concurrency regression failures.

 The stress test below intentionally runs native SWORD reads from multiple Dispatch worker threads.
 XCTest assertions are collected here and asserted after `concurrentPerform` returns so failures are
 deterministic and reported from the test method rather than from racing background closures.

 - Side effects: Stores failure messages in memory behind an `NSLock`.
 - Failure modes: None expected; lock contention only serializes recorder access, not SWORD access.
 */
private final class SwordConcurrencyFailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    /**
     Records one validation failure from a concurrent worker.

     - Parameter message: Human-readable failure evidence including the worker index.
     - Side effects: Appends to the protected message list.
     */
    func record(_ message: String) {
        lock.lock()
        messages.append(message)
        lock.unlock()
    }

    /**
     Returns all collected failures in insertion order.

     - Returns: A copied array so XCTest can inspect it after worker execution completes.
     - Side effects: Acquires the recorder lock while copying.
     */
    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }
}

/**
 BibleUI Strongs, dictionary, and search parity coverage.

 These tests protect Android-aligned Strong's query normalization, SWORD-backed Strong's search,
 dictionary rendering, restored MyBible dictionary handling, and related reader document builders.
 They run in the app-host-free BibleUI package lane while still using temporary SWORD fixture
 fixtures through `BibleUISwordFixtureTestCase`.
 */
final class StrongsAndDictionaryTests: BibleUISwordFixtureTestCase {
    func testCSVSetEncodingAndDecodingRoundTrip() {
        let encoded = AppPreferenceRegistry.encodeCSVSet(["  KJV  ", "", "ESV", "KJV", "  "])
        XCTAssertEqual(encoded, "ESV,KJV,KJV")
        XCTAssertEqual(AppPreferenceRegistry.decodeCSVSet(encoded), ["ESV", "KJV", "KJV"])
        XCTAssertEqual(AppPreferenceRegistry.decodeCSVSet(nil), [])
        XCTAssertEqual(AppPreferenceRegistry.decodeCSVSet(""), [])
    }

    /**
     Verifies Search's translation picker orders Bible modules the same way Android builds its
     multiselect dialog.

     Android `Search.showTranslationSelector` sorts all Bible modules by abbreviation before
     rendering rows. This pure helper test keeps iOS from drifting back to installer order or
     SwiftUI list order, both of which make subsequent primary-first ordering ambiguous.

     - Setup: Uses intentionally unsorted installed Bible module metadata.
     - Expected result: Abbreviations are returned in Android's sorted order.
     - Failure meaning: Search may present or commit multi-translation choices in an iOS-specific
       order instead of Android's deterministic dialog order.
     - Side effects: none.
     */
    func testSearchTranslationPickerSortsModulesByAndroidAbbreviationOrder() {
        let modules = [
            ModuleInfo(name: "WEB", description: "World English Bible", category: .bible, language: "en"),
            ModuleInfo(name: "KJV", description: "King James Version", category: .bible, language: "en"),
            ModuleInfo(name: "ASV", description: "American Standard Version", category: .bible, language: "en"),
        ]

        XCTAssertEqual(
            SearchView.androidSortedTranslationModules(modules).map(\.name),
            ["ASV", "KJV", "WEB"]
        )
    }

    /**
     Verifies Search commits Android multiselect choices with the active document preserved first.

     Android collects the checked rows from its abbreviation-sorted dialog, then calls
     `ensurePrimaryDocumentFirst()` so the current document remains the primary search target.
     This protects the iOS search request and grouped result order from `Set` iteration.

     - Setup: Selects all modules while the primary/current module is in the middle of Android's
       sorted order.
     - Expected result: The primary module is first, with all other selected modules still in
       Android abbreviation order.
     - Failure meaning: Multi-translation Search can send or display modules in unstable iOS order.
     - Side effects: none.
     */
    func testSearchTranslationSelectionKeepsPrimaryFirstAfterAndroidSortedCommit() {
        let modules = [
            ModuleInfo(name: "WEB", description: "World English Bible", category: .bible, language: "en"),
            ModuleInfo(name: "KJV", description: "King James Version", category: .bible, language: "en"),
            ModuleInfo(name: "ASV", description: "American Standard Version", category: .bible, language: "en"),
        ]

        XCTAssertEqual(
            SearchView.androidOrderedSelectedSearchModuleNames(
                selectedModuleNames: ["WEB", "KJV", "ASV"],
                primaryModuleName: "KJV",
                installedModules: modules
            ),
            ["KJV", "ASV", "WEB"]
        )
    }

    /**
     Verifies empty Search translation dialog confirmation preserves the prior selection.

     Android's multiselect dialog returns an empty list for both cancel and OK-with-no-checked-rows,
     and `Search.showTranslationSelector` ignores that empty result. iOS must not clear the active
     search modules when the draft selection has been toggled down to none.

     - Setup: Provides an existing two-module selection and an empty draft.
     - Expected result: The committed order still reflects the previous selection, with the primary
       module first.
     - Failure meaning: Users can accidentally clear Search translations through an iOS-only empty
       commit path.
     - Side effects: none.
     */
    func testSearchTranslationEmptyDialogConfirmationPreservesPreviousSelection() {
        let modules = [
            ModuleInfo(name: "WEB", description: "World English Bible", category: .bible, language: "en"),
            ModuleInfo(name: "KJV", description: "King James Version", category: .bible, language: "en"),
            ModuleInfo(name: "ASV", description: "American Standard Version", category: .bible, language: "en"),
        ]

        XCTAssertEqual(
            SearchView.androidCommittedTranslationSelection(
                previousModuleNames: ["KJV", "WEB"],
                draftModuleNames: [],
                primaryModuleName: "KJV",
                installedModules: modules
            ),
            ["KJV", "WEB"]
        )
    }

    /**
     Verifies Search translation picker drafts preserve Android Cancel, dismiss, and empty-OK semantics.

     Android's multiselect dialog mutates a temporary checked-row set while open. Cancel and
     outside dismiss discard the draft, while OK with no checked rows preserves the previously
     committed selection. This reducer-level coverage replaces the removed full-app Cancel/dismiss
     UI path without adding another slow launched Search smoke.

     - Setup: Opens a draft from a two-module committed selection, mutates it, then exercises
       Cancel, outside dismiss, and empty OK result paths.
     - Expected result: Cancel/dismiss clear only draft state, and empty OK preserves the previous
       primary-first committed selection while dismissing the draft.
     - Failure meaning: Search can drift into iOS-specific sheet semantics where transient row
       toggles leak into the committed Search modules or empty OK clears translations.
     - Side effects: none.
     */
    func testSearchTranslationPickerDraftStateDiscardsCancelAndOutsideDismissDrafts() {
        let modules = [
            ModuleInfo(name: "WEB", description: "World English Bible", category: .bible, language: "en"),
            ModuleInfo(name: "KJV", description: "King James Version", category: .bible, language: "en"),
            ModuleInfo(name: "ASV", description: "American Standard Version", category: .bible, language: "en"),
        ]

        let opened = SearchTranslationPickerDraftState.opened(
            selectedModuleNames: ["KJV", "WEB"],
            primaryModuleName: "KJV",
            installedModules: modules
        )
        XCTAssertTrue(opened.isPresented)
        XCTAssertEqual(opened.pendingSelection, ["KJV", "WEB"])

        let cancelled = opened.toggled("ASV").toggled("KJV").cancelled()
        XCTAssertFalse(cancelled.isPresented)
        XCTAssertTrue(cancelled.pendingSelection.isEmpty)

        let outsideDismiss = opened.toggled("ASV").cancelled()
        XCTAssertFalse(outsideDismiss.isPresented)
        XCTAssertTrue(outsideDismiss.pendingSelection.isEmpty)

        let emptyOK = SearchTranslationPickerDraftState(
            isPresented: true,
            pendingSelection: []
        ).committedSelection(
            previousModuleNames: ["KJV", "WEB"],
            primaryModuleName: "KJV",
            installedModules: modules
        )
        XCTAssertEqual(emptyOK.orderedModuleNames, ["KJV", "WEB"])
        XCTAssertFalse(emptyOK.draftState.isPresented)
        XCTAssertTrue(emptyOK.draftState.pendingSelection.isEmpty)
    }

    /**
     Verifies Search's visible translation summary uses Android's primary-first abbreviation list.

     Android presents the committed translation selection as a comma-separated abbreviation list
     after preserving the active document first. This package-level assertion replaces the former
     full-app Search UI smoke assertion for the visible `KJV, AATESTWEB` label.

     - Setup: Selects KJV and AATESTWEB while installed module metadata is intentionally unsorted.
     - Expected result: The primary KJV abbreviation is first and empty selections use the localized
       fallback label.
     - Failure meaning: Search can drift back to an iOS count/generic label or unstable module
       order even though the picker commit itself succeeds.
     - Side effects: none.
     */
    func testSearchTranslationSummaryUsesAndroidPrimaryFirstAbbreviationList() {
        let modules = [
            ModuleInfo(name: "AATESTWEB", description: "World English Bible", category: .bible, language: "en"),
            ModuleInfo(name: "KJV", description: "King James Version", category: .bible, language: "en"),
            ModuleInfo(name: "ASV", description: "American Standard Version", category: .bible, language: "en"),
        ]

        XCTAssertEqual(
            SearchView.androidSelectedTranslationSummaryLabel(
                selectedModuleNames: ["AATESTWEB", "KJV"],
                primaryModuleName: "KJV",
                installedModules: modules,
                fallbackLabel: "Translations"
            ),
            "KJV, AATESTWEB"
        )
        XCTAssertEqual(
            SearchView.androidSelectedTranslationSummaryLabel(
                selectedModuleNames: [],
                primaryModuleName: nil,
                installedModules: modules,
                fallbackLabel: "Translations"
            ),
            "Translations"
        )
    }

    /**
     Verifies Search translation picker row labels expose index readiness like Android.

     Android appends the localized `search_index_not_created` status to unindexed modules inside
     the multiselect dialog. This protects the iOS picker from showing visually selectable modules
     without the same readiness warning.

     - Setup: Builds one Bible module label with indexed and unindexed status inputs.
     - Expected result: Indexed rows omit the status suffix; unindexed rows include it in
       parentheses.
     - Failure meaning: Search can hide Android's index-readiness information from the picker.
     - Side effects: none.
     */
    func testSearchTranslationPickerLabelsExposeAndroidIndexReadiness() {
        let module = ModuleInfo(
            name: "KJV",
            description: "King James Version",
            category: .bible,
            language: "en"
        )

        XCTAssertEqual(
            SearchView.androidTranslationPickerLabel(
                for: module,
                isIndexed: true,
                unindexedStatus: "Search index not created"
            ),
            "KJV - King James Version"
        )
        XCTAssertEqual(
            SearchView.androidTranslationPickerLabel(
                for: module,
                isIndexed: false,
                unindexedStatus: "Search index not created"
            ),
            "KJV - King James Version (Search index not created)"
        )
    }

    /**
     Verifies both Search activities compose shared Android-owned presentation primitives.

     Android `Search` renders a top edit field, two radio groups, a translations row, and a bottom
     submit button from `search.xml`; submitting launches the separate `SearchResults` activity.
     Both activities use the shared action bar, dialogs, and popup-menu infrastructure rather than
     native iOS navigation, lists, sheets, or one-off picker/menu facsimiles.

     - Expected result: `SearchView` contains the shared activity, input, radio, multiselect, and
       anchored-popup components plus distinct results content and exact Android-derived icons.
     - Failure meaning: Search has drifted into a native iOS surface, recombined criteria/results,
       or reinvented an app-owned component instead of reusing the established implementation.
     - Side effects: Reads `SearchView.swift` from the checked-out source tree.
     */
    func testSearchCriteriaScreenUsesAndroidFormStructure() throws {
        let source = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Search/SearchView.swift"
        )

        XCTAssertTrue(source.contains("AndroidActivityScreen("))
        XCTAssertTrue(source.contains("AndroidActivityTextInput("))
        XCTAssertTrue(source.contains("AndroidRadioRow("))
        XCTAssertTrue(source.contains("AndroidMultiselectDialogContent("))
        XCTAssertTrue(source.contains(".androidAnchoredPopupMenu("))
        XCTAssertTrue(source.contains("private var searchCriteriaForm"))
        XCTAssertTrue(source.contains("private var searchSubmitButton"))
        XCTAssertTrue(source.contains("private var searchResultsContent"))
        XCTAssertTrue(source.contains(".asset(\"SearchDocuments\")"))
        XCTAssertTrue(source.contains("AndBibleIconView(name: \"SearchExpand\""))
        XCTAssertFalse(source.contains(".pickerStyle(.segmented)"))
        XCTAssertFalse(source.contains("ContentUnavailableView("))
        XCTAssertFalse(source.contains("searchOptionsToggleButton"))
        XCTAssertFalse(source.contains("List {"))
        XCTAssertFalse(source.contains(".navigationTitle"))
        XCTAssertFalse(source.contains(".sheet("))
        XCTAssertFalse(source.contains("Menu {"))
        XCTAssertFalse(source.split(separator: "\n").contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("Picker(")
        })
        XCTAssertFalse(source.contains("makeTranslationPicker"))
    }

    func testStrongsQueryNormalizationHandlesLeadingZeroes() {
        let options = StrongsSearchSupport.normalizedQueryOptions(for: "H02022")
        XCTAssertEqual(options?.canonicalStrongTokens, ["H2022"])
        XCTAssertEqual(
            options?.entryAttributeQueries,
            ["Word//Lemma./H02022", "Word//Lemma./H2022"]
        )
    }

    func testStrongsQueryNormalizationAcceptsDecoratedInput() {
        let options = StrongsSearchSupport.normalizedQueryOptions(for: "lemma:strong:g00123")
        XCTAssertEqual(options?.canonicalStrongTokens, ["G0123"])
        XCTAssertEqual(
            options?.entryAttributeQueries,
            ["Word//Lemma./G00123", "Word//Lemma./G0123", "Word//Lemma./G123"]
        )
    }

    func testStrongsQueryNormalizationIncludesIntermediateZeroTrimVariants() {
        let options = StrongsSearchSupport.normalizedQueryOptions(for: "H00430")
        XCTAssertEqual(options?.canonicalStrongTokens, ["H0430"])
        XCTAssertEqual(
            options?.entryAttributeQueries,
            ["Word//Lemma./H00430", "Word//Lemma./H0430", "Word//Lemma./H430"]
        )
    }

    /** Strong's normalization and SearchView readiness must select the same index facet. */
    func testSearchIndexRequirementFollowsNormalizedQueryContract() {
        XCTAssertEqual(SearchView.indexRequirement(for: "faith hope"), .text)
        XCTAssertEqual(SearchView.indexRequirement(for: "H00430"), .strongs)
        XCTAssertEqual(SearchView.indexRequirement(for: "strong:H0430"), .strongs)
    }

    /**
     Verifies iOS tokenizes Strong's OSIS lemma values the same way JSword populates the Lucene
     `strong` field.

     JSword `OSISUtil.getStrongsNumbers` extracts `strong:` lemma values from `<w>` elements, and
     `StrongsNumberFilter` normalizes each number to four digits. Part-suffixed values are indexed
     twice: once as the base number and once as the full part token. A failure means iOS "find all
     occurrences" can disagree with Android even when both apps read the same SWORD verse content.
     */
    func testStrongsRawLemmaExtractionUsesJSwordCanonicalTokens() {
        let rawEntry = """
        <verse osisID="Gen.1.1">
          <w lemma="strong:H00430 strong:H01234!b">God</w>
          <w lemma="lemma:noise strong:g00123a">made</w>
        </verse>
        """

        XCTAssertEqual(
            StrongsSearchSupport.canonicalStrongTokens(
                rawEntry: rawEntry,
                renderedText: "",
                book: "Genesis"
            ),
            ["H0430", "H1234", "H1234b", "G0123", "G0123a"]
        )
    }

    /**
     Verifies Strong's token extraction keeps the JSword raw-OSIS path primary and does not render
     verse text when raw lexical tokens are already present.

     JSword builds its `strong` field from parsed OSIS `<w lemma="strong:...">` values. Rendering a
     verse to recover `showStrong` links is an iOS compatibility fallback for modules that do not
     expose usable raw OSIS, not part of Android's primary search path. A failure means "find all
     occurrences" may pay unnecessary render cost or merge fallback tokens into a verse whose raw
     lexical data is already authoritative.
     */
    func testStrongsCanonicalExtractionSkipsRenderedFallbackWhenRawOSISHasLexicalTokens() {
        var renderCount = 0

        let tokens = StrongsSearchSupport.canonicalStrongTokens(
            rawEntry: #"<w lemma="strong:H00430">God</w>"#,
            renderedTextProvider: {
                renderCount += 1
                return #"<a href="passagestudy.jsp?action=showStrong=01234#cv">unexpected</a>"#
            },
            book: "Genesis"
        )

        XCTAssertEqual(tokens, ["H0430"])
        XCTAssertEqual(renderCount, 0)
    }

    /**
     Verifies the rendered-text fallback remains reachable for modules whose raw entries do not
     expose JSword-style lexical tokens.

     Some SWORD modules only expose Strong's links after rendering. iOS should still recover those
     `showStrong` links when raw OSIS extraction finds no tokens, while keeping the same canonical
     four-digit token shape used by JSword's Strong's index.
     */
    func testStrongsCanonicalExtractionUsesRenderedFallbackWhenRawOSISHasNoLexicalTokens() {
        var renderCount = 0

        let tokens = StrongsSearchSupport.canonicalStrongTokens(
            rawEntry: "<p>God created.</p>",
            renderedTextProvider: {
                renderCount += 1
                return #"<a href="passagestudy.jsp?action=showStrong=0430#cv">God</a>"#
            },
            book: "Genesis"
        )

        XCTAssertEqual(tokens, ["H0430"])
        XCTAssertEqual(renderCount, 1)
    }

    func testParseVerseKeySupportsHumanReadableFormat() {
        let parsed = StrongsSearchSupport.parseVerseKey("I Samuel 2:3")
        XCTAssertEqual(parsed?.book, "I Samuel")
        XCTAssertEqual(parsed?.chapter, 2)
        XCTAssertEqual(parsed?.verse, 3)
    }

    func testParseVerseKeySupportsOsisFormat() {
        let parsed = StrongsSearchSupport.parseVerseKey("Gen.1.1")
        XCTAssertEqual(parsed?.book, "Genesis")
        XCTAssertEqual(parsed?.chapter, 1)
        XCTAssertEqual(parsed?.verse, 1)
    }

    func testParseVerseKeySupportsOsisFormatWithSuffix() {
        let parsed = StrongsSearchSupport.parseVerseKey("Gen.1.1!crossReference.a")
        XCTAssertEqual(parsed?.book, "Genesis")
        XCTAssertEqual(parsed?.chapter, 1)
        XCTAssertEqual(parsed?.verse, 1)
    }

    func testStrongsSearchFindAllOccurrencesReturnsKJVFixtureMatches() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(
            SwordManager(modulePath: modulePath),
            "Expected SwordManager to initialize against a temporary SWORD fixture path"
        )
        let installedModules = manager.installedModules()
        XCTAssertTrue(
            installedModules.contains(where: { $0.name == "KJV" && $0.features.contains(.strongsNumbers) }),
            "Expected KJV test fixture module with Strong's support to be installed for regression testing"
        )

        let module = try XCTUnwrap(
            manager.module(named: "KJV"),
            "Expected KJV test fixture module to be available for Strong's regression testing"
        )
        let queryOptions = try XCTUnwrap(
            StrongsSearchSupport.normalizedQueryOptions(for: "H02022"),
            "Expected H02022 to normalize into entry-attribute Strong's search queries"
        )

        let hits = StrongsSearchSupport.searchVerseHits(in: module, queryOptions: queryOptions, scope: "Gen")

        XCTAssertFalse(
            hits.isEmpty,
            "Expected the KJV test fixture Strong's search for H02022 to return at least one verse"
        )
        XCTAssertTrue(
            hits.allSatisfy { !$0.reference.isEmpty },
            "Expected Strong's hits to parse into verse references"
        )
    }

    func testStrongsSearchFindAllOccurrencesSupportsIntermediateZeroTrimVariant() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(
            SwordManager(modulePath: modulePath),
            "Expected SwordManager to initialize against a temporary SWORD fixture path"
        )
        let module = try XCTUnwrap(
            manager.module(named: "KJV"),
            "Expected KJV test fixture module to be available for Strong's regression testing"
        )
        let queryOptions = try XCTUnwrap(
            StrongsSearchSupport.normalizedQueryOptions(for: "H00430"),
            "Expected H00430 to normalize into Strong's search queries"
        )

        let hits = StrongsSearchSupport.searchVerseHits(in: module, queryOptions: queryOptions, scope: "Gen")

        XCTAssertFalse(
            hits.isEmpty,
            "Expected the KJV test fixture Strong's search for H00430 to return at least one verse"
        )
        XCTAssertTrue(
            hits.contains { $0.book == "Genesis" && $0.chapter == 1 && $0.verse == 1 },
            "Expected JSword-style Strong's token search for H00430/H0430 to find Genesis 1:1"
        )
    }

    /**
     Verifies text-index readiness is not treated as Strong's-index readiness.

     Android's JSword index has distinct fields for normal verse text and Strong's tokens. A
     text-only SQLite fixture or stale partial index must therefore remain usable for ordinary text
     search while being rejected as an indexed Strong's source. The fallback/index-creation decision
     in Search depends on this distinction; otherwise a Strong's query can short-circuit to an empty
     `verse_strongs` table and report zero hits.

     - Setup: Creates an isolated search database with KJV `verse_fts` rows and current metadata,
       then adds a matching `verse_strongs` row in a second serialized mutation.
     - Expected result: `hasIndex` is true for the text facet, `hasStrongsIndex` is false until the
       lexical row exists, and indexed Strong's search returns the seeded row only after that point.
     - Failure meaning: Search can confuse text-only indexes with Android/JSword-style Strong's
       indexes, recreating the UI failure where `H00430` settles with zero results.
     - Side effects: Creates and removes one temporary SQLite database.
     */
    func testSearchIndexDistinguishesTextAndStrongsReadiness() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-index-text-only-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let service = SearchIndexService(databasePath: databaseURL.path)
        let analyzer = SearchTextAnalyzer.profile(for: "en")
        let analyzerIdentifier = analyzer.identifier
        let indexedText = try SearchTextAnalyzer.analyzedText(
            "And the Spirit of God moved upon the face of the waters.",
            profile: analyzer
        )
        try await service.performIndexMutationForTesting { db in
            let sql = """
            INSERT INTO verse_fts (
                search_text, verse_key, plain_text, module_name, entry_order, osis_book,
                display_book, display_book_mode, chapter, verse, book_order, canon_scope
            ) VALUES (
                '\(indexedText)',
                'Genesis 1:2', 'And the Spirit of God moved upon the face of the waters.',
                'KJV', 0, 'Gen', 'Genesis', 'source', 1, 2, 2, 'ot'
            );
            INSERT INTO indexed_modules (
                module_name, verse_count, indexed_at, schema_version, language_code, analyzer_id,
                strongs_complete, source_version, source_fingerprint, store_generation
            ) VALUES (
                'KJV', 1, datetime('now'), \(SearchIndexService.currentSchemaVersion),
                'en', '\(analyzerIdentifier)', 0, '',
                'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 0
            );
            """
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                let message = sqlite3_errmsg(db).map { String(cString: $0) } ?? "SQLite write failed"
                throw NSError(domain: "SearchIndexFixture", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: message
                ])
            }
        }

        let queryOptions = try XCTUnwrap(
            StrongsSearchSupport.normalizedQueryOptions(for: "H00430"),
            "Expected H00430 to normalize into canonical Strong's tokens"
        )

        XCTAssertTrue(service.hasIndex(for: "KJV"))
        XCTAssertFalse(
            service.hasStrongsIndex(for: "KJV"),
            "A text-only index must not satisfy the Strong's index facet."
        )
        let textOnlyResults = try service.searchStrongs(
            canonicalTokens: queryOptions.canonicalStrongTokens,
            moduleName: "KJV"
        )
        XCTAssertEqual(textOnlyResults.moduleName, "KJV")
        XCTAssertTrue(
            textOnlyResults.hits.isEmpty,
            "Strong's search must not synthesize hits from text-only FTS rows."
        )
        XCTAssertFalse(textOnlyResults.isTruncated)
        XCTAssertThrowsError(
            try service.searchStrongs(
                canonicalTokens: queryOptions.canonicalStrongTokens,
                moduleName: "UNINDEXED"
            )
        ) { error in
            XCTAssertEqual(error as? SearchIndexError, .indexUnavailable(moduleName: "UNINDEXED"))
        }

        try await service.performIndexMutationForTesting { db in
            let sql = """
            INSERT INTO verse_strongs (
                module_name, token, verse_key, entry_order, highlight_ranges
            ) VALUES ('KJV', 'H0430', 'Genesis 1:2', 0, '');
            """
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                let message = sqlite3_errmsg(db).map { String(cString: $0) } ?? "SQLite write failed"
                throw NSError(domain: "SearchIndexFixture", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: message
                ])
            }
        }

        XCTAssertTrue(service.hasStrongsIndex(for: "KJV"))
        let moduleResults = try service.searchStrongs(
            canonicalTokens: queryOptions.canonicalStrongTokens,
            moduleName: "KJV"
        )
        XCTAssertEqual(moduleResults.moduleName, "KJV")
        XCTAssertEqual(moduleResults.hits.map(\.key), ["Genesis 1:2"])
        XCTAssertEqual(moduleResults.hits.map(\.moduleName), ["KJV"])
        XCTAssertEqual(moduleResults.hits.map(\.identity.osisBookId), ["Gen"])
        XCTAssertFalse(moduleResults.isTruncated)
    }

    /**
     Verifies seeded Search index metadata satisfies the app's index-readiness checks.

     UI fixtures write deterministic metadata directly into `search_indexes.sqlite` before the app
     launches. SearchView decides whether to prompt `state=needsIndex` through
     `SearchIndexService.hasIndex` and `hasStrongsIndex`, so this test anchors that schema to the
     same app-side readiness contract instead of only checking that rows exist.

     - Setup: Creates an isolated SQLite search-index database with KJV text/Strong's rows and
       AATESTWEB text rows matching the multi-module fixture shape.
     - Expected result: KJV and AATESTWEB do not need indexing, and KJV is Strong's-ready.
     - Failure meaning: Normal Search UI tests can fall back to runtime index creation despite the
       fixture claiming to be preseeded.
     - Side effects: Creates and removes one temporary SQLite database.
     */
    func testSeededSearchFixtureMetadataSatisfiesSearchIndexReadiness() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-fixture-readiness-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let service = SearchIndexService(databasePath: databaseURL.path)
        let analyzer = SearchTextAnalyzer.profile(for: "en")
        let analyzerIdentifier = analyzer.identifier
        let kjvRows = try [
            "And the Spirit of God moved upon the face of the waters.",
            "The book of the generation of Jesus Christ.",
            "But Noah found grace in the eyes of the Lord.",
        ].map { try SearchTextAnalyzer.analyzedText($0, profile: analyzer) }
        let webRows = try [
            "The earth was formless and empty.",
            "For God so loved the world.",
        ].map { try SearchTextAnalyzer.analyzedText($0, profile: analyzer) }
        try await service.performIndexMutationForTesting { db in
            let sql = """
            INSERT INTO verse_fts (
                search_text, verse_key, plain_text, module_name, entry_order, osis_book,
                display_book, display_book_mode, chapter, verse, book_order, canon_scope
            )
            VALUES
                ('\(kjvRows[0])', 'Genesis 1:2',
                 'And the Spirit of God moved upon the face of the waters.', 'KJV', 0,
                 'Gen', 'Genesis', 'source', 1, 2, 2, 'ot'),
                ('\(kjvRows[1])', 'Matthew 1:1',
                 'The book of the generation of Jesus Christ.', 'KJV', 1,
                 'Matt', 'Matthew', 'source', 1, 1, 42, 'nt'),
                ('\(kjvRows[2])', 'Genesis 6:8',
                 'But Noah found grace in the eyes of the Lord.', 'KJV', 2,
                 'Gen', 'Genesis', 'source', 6, 8, 2, 'ot'),
                ('\(webRows[0])', 'Genesis 1:2',
                 'The earth was formless and empty.', 'AATESTWEB', 0,
                 'Gen', 'Genesis', 'source', 1, 2, 2, 'ot'),
                ('\(webRows[1])', 'John 3:16',
                 'For God so loved the world.', 'AATESTWEB', 1,
                 'John', 'John', 'source', 3, 16, 45, 'nt');
            INSERT INTO verse_strongs (
                module_name, token, verse_key, entry_order, highlight_ranges
            ) VALUES ('KJV', 'H0430', 'Genesis 1:2', 0, '');
            INSERT INTO indexed_modules (
                module_name, verse_count, indexed_at, schema_version, language_code, analyzer_id,
                strongs_complete, source_version, source_fingerprint, store_generation
            )
            VALUES
                ('KJV', 3, datetime('now'), \(SearchIndexService.currentSchemaVersion),
                 'en', '\(analyzerIdentifier)', 1, '',
                 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 0),
                ('AATESTWEB', 2, datetime('now'), \(SearchIndexService.currentSchemaVersion),
                 'en', '\(analyzerIdentifier)', 1, '',
                 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', 0);
            """
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                let message = sqlite3_errmsg(db).map { String(cString: $0) } ?? "SQLite write failed"
                throw NSError(domain: "SearchIndexFixture", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: message
                ])
            }
        }

        XCTAssertTrue(service.hasIndex(for: "KJV"))
        XCTAssertTrue(service.hasStrongsIndex(for: "KJV"))
        XCTAssertTrue(service.hasIndex(for: "AATESTWEB"))
        XCTAssertEqual(service.modulesNeedingIndex(from: ["KJV", "AATESTWEB"]), [])
    }

    /**
     Verifies SWORD entry-attribute candidates remain semantic-only and cursor-neutral.

     Android's find-all path reads JSword's canonical `strong` field, so iOS must still validate
     candidate verses against parsed Strong's lemma tokens. A failure means the UI search path may
     either fall back to an expensive full-module scan when SWORD already has candidate verses, or
     return entry-attribute hits that do not match JSword token semantics. Both matching and rejected
     candidate exits must restore the caller's exact key and VerseKey ordinal.

     - Setup: Positions a real KJV fixture on Genesis 1:2, then validates H0430 candidates once with
       the matching canonical token and once with a deliberately different semantic token.
     - Expected result: Only the matching candidate is returned and both calls restore key and index.
     - Failure meaning: Candidate search can publish a false hit or mutate shared module navigation.
     - Side effects: Creates one temporary native SWORD fixture and performs bounded searches.
     */
    func testStrongsSearchEntryAttributeCandidatesAreCanonicallyValidated() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(
            SwordManager(modulePath: modulePath),
            "Expected SwordManager to initialize against a temporary SWORD fixture path"
        )
        let module = try XCTUnwrap(
            manager.module(named: "KJV"),
            "Expected KJV test fixture module to be available for Strong's candidate regression testing"
        )
        let queryOptions = try XCTUnwrap(
            StrongsSearchSupport.normalizedQueryOptions(for: "H00430"),
            "Expected H00430 to normalize into Strong's search queries"
        )
        module.setKey("Gen.1.2")
        let originalKey = module.currentKey()
        let originalVerseIndex = module.currentVerseKeyChildren()?.index

        let candidateResult = StrongsSearchSupport.searchVerseHitsByEntryAttributeCandidates(
            in: module,
            queryOptions: queryOptions,
            scope: "Gen"
        )

        XCTAssertTrue(
            candidateResult.sawLexicalTokens,
            "Expected SWORD candidate verses to expose JSword-style lexical Strong's tokens"
        )
        XCTAssertTrue(
            candidateResult.hits.contains { $0.book == "Genesis" && $0.chapter == 1 && $0.verse == 1 },
            "Expected candidate-index search to validate Genesis 1:1 against canonical H0430 tokens"
        )
        XCTAssertEqual(module.currentKey(), originalKey)
        XCTAssertEqual(module.currentVerseKeyChildren()?.index, originalVerseIndex)

        let rejectedResult = StrongsSearchSupport.searchVerseHitsByEntryAttributeCandidates(
            in: module,
            queryOptions: NormalizedStrongsQueryOptions(
                canonicalStrongTokens: ["H9999"],
                entryAttributeQueries: queryOptions.entryAttributeQueries
            ),
            scope: "Gen"
        )
        XCTAssertTrue(rejectedResult.hits.isEmpty)
        XCTAssertTrue(rejectedResult.sawLexicalTokens)
        XCTAssertEqual(module.currentKey(), originalKey)
        XCTAssertEqual(module.currentVerseKeyChildren()?.index, originalVerseIndex)
    }

    /**
     Verifies both retained native key-collection boundaries restore a chapter-introduction cursor.

     - Setup: Positions a fresh real KJV fixture at Genesis 1:0 before any key-list cache exists,
       then executes hit, zero-limit, and miss native searches followed by first-read enumeration.
     - Expected result: Every exit returns the module to the identical introduction key and
       VerseKey ordinal; enumeration succeeds and its subsequent cached read is cursor-neutral.
     - Failure meaning: A retained #393 key-only helper can move shared reader state from verse zero
       to verse one even though the structured preview inspection itself restores correctly.
     - Side effects: Creates one isolated SWORD fixture, runs bounded searches, and fills its
       module-lifetime immutable key cache.
     */
    func testRetainedKeySearchAndColdEnumerationRestoreIntroductionCursor() throws {
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let queryOptions = try XCTUnwrap(
            StrongsSearchSupport.normalizedQueryOptions(for: "H00430")
        )
        let candidateQuery = try XCTUnwrap(queryOptions.entryAttributeQueries.first)
        let missOptions = SearchOptions(
            query: "Word//Lemma./strong:H9999",
            searchType: .entryAttribute,
            caseInsensitive: true,
            scope: "Gen"
        )
        module.setKey("=Gen.1.0")
        let originalKey = module.currentKey()
        let originalVerseIndex = module.currentVerseKeyIndex()

        XCTAssertEqual(originalKey, "Genesis 1:0")
        var hitKeys: [String] = []
        for query in queryOptions.entryAttributeQueries {
            hitKeys.append(contentsOf: try module.searchKeys(SearchOptions(
                query: query,
                searchType: .entryAttribute,
                caseInsensitive: true,
                scope: "Gen"
            ), limit: 5000))
            XCTAssertEqual(module.currentKey(), originalKey)
            XCTAssertEqual(module.currentVerseKeyIndex(), originalVerseIndex)
        }
        XCTAssertFalse(hitKeys.isEmpty)

        XCTAssertTrue(try module.searchKeys(SearchOptions(
            query: candidateQuery,
            searchType: .entryAttribute,
            caseInsensitive: true,
            scope: "Gen"
        ), limit: 0).isEmpty)
        XCTAssertEqual(module.currentKey(), originalKey)
        XCTAssertEqual(module.currentVerseKeyIndex(), originalVerseIndex)

        XCTAssertTrue(try module.searchKeys(missOptions, limit: 5000).isEmpty)
        XCTAssertEqual(module.currentKey(), originalKey)
        XCTAssertEqual(module.currentVerseKeyIndex(), originalVerseIndex)

        let coldKeys = try module.loadAllKeys()
        XCTAssertFalse(coldKeys.isEmpty)
        XCTAssertEqual(module.currentKey(), originalKey)
        XCTAssertEqual(module.currentVerseKeyIndex(), originalVerseIndex)

        XCTAssertEqual(try module.loadAllKeys(), coldKeys)
        XCTAssertEqual(module.currentKey(), originalKey)
        XCTAssertEqual(module.currentVerseKeyIndex(), originalVerseIndex)
    }

    /**
     Verifies SWORD Bible book discovery exposes the full Protestant canon for a complete module.

     The KJV test fixture contains content for all 66 books and exercises the same
     `SwordModule.getBookList()` path used by restored Android `.abmd.zip` Bible modules such as
     ESV. A failure means the reader's dynamic book picker can hide valid restored content even
     though the module files and verse entries are present. The test copies SWORD test resources
     into a temporary directory and relies on the shared test cleanup to remove those files.
     */
    func testKJVFixtureBookListIncludesAllCanonicalBooks() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(
            SwordManager(modulePath: modulePath),
            "Expected SwordManager to initialize against a temporary SWORD fixture path"
        )
        let module = try XCTUnwrap(
            manager.module(named: "KJV"),
            "Expected KJV test fixture module to be available for book-list regression testing"
        )

        let discoveredBookIds = module.getBookList().map(\.osisId)

        XCTAssertEqual(discoveredBookIds.count, 66)
        XCTAssertEqual(
            discoveredBookIds,
            [
                "Gen", "Exod", "Lev", "Num", "Deut", "Josh", "Judg", "Ruth",
                "1Sam", "2Sam", "1Kgs", "2Kgs", "1Chr", "2Chr", "Ezra", "Neh",
                "Esth", "Job", "Ps", "Prov", "Eccl", "Song", "Isa", "Jer",
                "Lam", "Ezek", "Dan", "Hos", "Joel", "Amos", "Obad", "Jonah",
                "Mic", "Nah", "Hab", "Zeph", "Hag", "Zech", "Mal", "Matt",
                "Mark", "Luke", "John", "Acts", "Rom", "1Cor", "2Cor", "Gal",
                "Eph", "Phil", "Col", "1Thess", "2Thess", "1Tim", "2Tim", "Titus",
                "Phlm", "Heb", "Jas", "1Pet", "2Pet", "1John", "2John", "3John",
                "Jude", "Rev",
            ]
        )
    }

    /**
     Verifies iOS expands OSIS reference ranges through the same SWORD key parser boundary that
     backs JSword-style passage semantics.

     Android uses JSword `PassageKeyFactory` for OSIS references, so a range such as
     `Gen.1.1-Gen.1.3` resolves to every verse in the range rather than only the textual endpoints.
     The setup loads the KJV test fixture and asks the active SWORD module to parse the range;
     a failure means reader cross-reference links can silently omit middle verses.
     */
    func testKJVFixtureParseKeyListExpandsOsisRanges() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(
            SwordManager(modulePath: modulePath),
            "Expected SwordManager to initialize against a temporary SWORD fixture path"
        )
        let module = try XCTUnwrap(
            manager.module(named: "KJV"),
            "Expected KJV test fixture module to be available for key-list parsing parity testing"
        )

        XCTAssertEqual(
            module.parseKeyList("Gen.1.1-Gen.1.3"),
            ["Gen.1.1", "Gen.1.2", "Gen.1.3"]
        )
    }

    /**
     Verifies iOS obtains chapter verse counts from the active module's SWORD `VerseKey` metadata.

     Android's passage chooser uses JSword `Versification.getLastVerse(book, chapterNo)`, not a
     partial hard-coded table. The KJV fixture exercises common and uncommon chapter counts; Ruth 4
     is intentionally included because the previous fallback returned `30` for unknown chapters.
     A failure means the native verse picker can offer invalid verses or hide valid verses.
     */
    func testKJVFixtureVerseCountUsesModuleVersification() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(
            SwordManager(modulePath: modulePath),
            "Expected SwordManager to initialize against a temporary SWORD fixture path"
        )
        let module = try XCTUnwrap(
            manager.module(named: "KJV"),
            "Expected KJV test fixture module to be available for verse-count parity testing"
        )

        XCTAssertEqual(module.verseCount(osisBookId: "Gen", chapter: 1), 31)
        XCTAssertEqual(module.verseCount(osisBookId: "Ruth", chapter: 4), 22)
        XCTAssertEqual(module.verseCount(osisBookId: "Ps", chapter: 119), 176)
        XCTAssertEqual(module.verseCount(osisBookId: "Rev", chapter: 22), 21)
        XCTAssertNil(module.verseCount(osisBookId: "Bogus", chapter: 1))
    }

    /**
     Verifies iOS uses SWORD/JSword-style verse ordinals instead of per-chapter arithmetic.

     JSword `Versification.getOrdinal(Verse)` includes Bible, testament, book, and chapter intro
     slots before the first normal verse. SWORD's `VerseKey.getIndex()` follows the same convention,
     so `Gen.1.1` is ordinal 4 and `Gen.2.1` is ordinal 36, not ordinals 1 and 41. The reverse
     lookup assertion protects bookmark, memorization, and bridge code that must map persisted
     Android ordinals back to exact verse references.
     */
    func testKJVFixtureVerseOrdinalsUseIntroInclusiveVersification() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(
            SwordManager(modulePath: modulePath),
            "Expected SwordManager to initialize against a temporary SWORD fixture path"
        )
        let module = try XCTUnwrap(
            manager.module(named: "KJV"),
            "Expected KJV test fixture module to be available for ordinal parity testing"
        )

        module.setKey("=Gen.1.1")
        XCTAssertEqual(module.currentVerseKeyIndex(), 4)
        XCTAssertEqual(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1), 4)
        XCTAssertEqual(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 31), 34)
        XCTAssertEqual(module.verseOrdinal(osisBookId: "Gen", chapter: 2, verse: 1), 36)
        XCTAssertEqual(
            module.verseReference(ordinal: 4),
            VerseKeyReference(osisBookId: "Gen", chapter: 1, verse: 1, ordinal: 4)
        )
        XCTAssertEqual(
            module.verseReference(osisBookId: "Gen", ordinal: 36),
            VerseKeyReference(osisBookId: "Gen", chapter: 2, verse: 1, ordinal: 36)
        )
        XCTAssertNil(module.verseReference(ordinal: 1))
        XCTAssertNil(module.verseReference(osisBookId: "Exod", ordinal: 36))
        XCTAssertNil(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 99))
        XCTAssertNil(module.verseOrdinal(osisBookId: "Gen", chapter: 99, verse: 1))
        XCTAssertNil(module.verseCount(osisBookId: "Gen", chapter: 99))
    }

    /**
     Verifies concurrent Swift SWORD wrappers cannot interleave native libsword state.

     The app can create fresh `SwordManager` instances after imports, restores, and module-store
     refreshes while other reader/search code is still reading existing modules. The local C bridge
     and libsword hold process-global pointer caches, so per-instance queues leave a race that can
     surface as the CI-only `SIGSEGV` seen in the ordinal test. This regression runs many managers
     against the same KJV test fixture in parallel; success means every worker received stable
     JSword-parity verse ordinals, reverse references, verse counts, and parsed ranges.

     - Setup: Copies the SWORD test fixture into one temporary module path shared by all workers.
     - Expected result: No worker records a missing manager/module or inconsistent SWORD result.
     - Failure meaning: Native SWORD access is not serialized at the process boundary, risking app
       crashes during restore/import refreshes or parallel reader/search activity.
     - Side effects: Creates temporary SWORD fixture files that shared test cleanup removes.
     */
    func testKJVFixtureNativeAccessSerializesAcrossConcurrentManagers() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let failures = SwordConcurrencyFailureRecorder()

        DispatchQueue.concurrentPerform(iterations: 48) { index in
            autoreleasepool {
                guard let manager = SwordManager(modulePath: modulePath) else {
                    failures.record("worker \(index): missing SwordManager")
                    return
                }
                guard let module = manager.module(named: "KJV") else {
                    failures.record("worker \(index): missing KJV module")
                    return
                }

                let target = index.isMultiple(of: 2)
                    ? (osisBookId: "Gen", chapter: 1, verse: 1, ordinal: 4)
                    : (osisBookId: "Gen", chapter: 2, verse: 1, ordinal: 36)
                let ordinal = module.verseOrdinal(
                    osisBookId: target.osisBookId,
                    chapter: target.chapter,
                    verse: target.verse
                )
                let reference = module.verseReference(ordinal: target.ordinal)

                if ordinal != target.ordinal {
                    failures.record("worker \(index): expected ordinal \(target.ordinal), got \(String(describing: ordinal))")
                }
                if reference?.osisRef != "\(target.osisBookId).\(target.chapter).\(target.verse)" {
                    failures.record("worker \(index): expected reference for ordinal \(target.ordinal), got \(String(describing: reference))")
                }
                if module.verseCount(osisBookId: "Gen", chapter: 1) != 31 {
                    failures.record("worker \(index): unexpected Genesis 1 verse count")
                }
                if module.parseKeyList("Gen.1.1-Gen.1.3") != ["Gen.1.1", "Gen.1.2", "Gen.1.3"] {
                    failures.record("worker \(index): OSIS range did not expand deterministically")
                }
            }
        }

        XCTAssertEqual(failures.all, [])
    }

    /**
     Verifies the Swift VerseKey parser preserves SWORD-provided metadata from the native adapter.

     iOS must not collapse all text fields to the OSIS reference, because book discovery, chapter
     rendering, and reference validation consume the copied book name, abbreviation, and OSIS book
     fields. The KJV test fixture exercises the same SWORD bridge used by imported Android
     backup modules.
     */
    func testKJVFixtureVerseKeyChildrenExposeBookMetadata() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(
            SwordManager(modulePath: modulePath),
            "Expected SwordManager to initialize against a temporary SWORD fixture path"
        )
        let module = try XCTUnwrap(
            manager.module(named: "KJV"),
            "Expected KJV test fixture module to be available for VerseKey metadata parity testing"
        )

        module.setKey("=Gen.1.1")
        let children = try XCTUnwrap(module.currentVerseKeyChildren())

        XCTAssertEqual(children.testament, 1)
        XCTAssertEqual(children.book, 1)
        XCTAssertEqual(children.chapter, 1)
        XCTAssertEqual(children.verse, 1)
        XCTAssertEqual(children.index, 4)
        XCTAssertEqual(children.chapterMax, 50)
        XCTAssertEqual(children.verseMax, 31)
        XCTAssertEqual(children.bookName, "Genesis")
        XCTAssertEqual(children.osisRef, "Gen.1.1")
        XCTAssertFalse(children.shortText.isEmpty)
        XCTAssertEqual(children.bookAbbreviation, "Gen")
        XCTAssertEqual(children.osisBookName, "Gen")
    }

    func testBibleChapterDocumentBuilderPreservesSecondCorinthiansIntroAndChapterMarker() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let builder = BibleChapterDocumentBuilder(module: module, includeHeadings: true)

        let chapter = try XCTUnwrap(builder.loadChapter(osisBookId: "2Cor", chapter: 1))

        XCTAssertFalse(chapter.addChapter)
        XCTAssertGreaterThan(chapter.verseCount, 0)
        XCTAssertTrue(chapter.xml.contains("THE SECOND EPISTLE OF PAUL THE APOSTLE TO THE CORINTHIANS"))
        XCTAssertTrue(chapter.xml.contains("<chapter"))
        XCTAssertTrue(chapter.xml.contains("CHAPTER 1."))
    }

    func testBibleChapterDocumentBuilderStillEmitsChapterMarkerWhenSectionTitlesAreDisabled() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let builder = BibleChapterDocumentBuilder(module: module, includeHeadings: false)

        let chapter = try XCTUnwrap(builder.loadChapter(osisBookId: "2Cor", chapter: 1))

        XCTAssertFalse(chapter.addChapter)
        XCTAssertTrue(chapter.xml.contains("<chapter osisID=\"2Cor.1\""))
        XCTAssertFalse(chapter.xml.contains("THE SECOND EPISTLE OF PAUL THE APOSTLE TO THE CORINTHIANS"))
    }

    func testBibleChapterDocumentBuilderKeepsRenderableChapterStartMarkers() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let builder = BibleChapterDocumentBuilder(module: module, includeHeadings: true)

        let chapter = try XCTUnwrap(builder.loadChapter(osisBookId: "2Cor", chapter: 2))
        let hasOpeningMarker = chapter.xml.range(
            of: #"<chapter\b[^>]*osisID="2Cor\.2"[^>]*sID="#,
            options: .regularExpression
        ) != nil

        XCTAssertFalse(chapter.addChapter)
        XCTAssertTrue(
            hasOpeningMarker || chapter.xml.contains("<chapter n=\"2\""),
            "Expected a visible chapter start marker, not only a closing chapter tag. XML: \(chapter.xml)"
        )
        XCTAssertFalse(
            chapter.xml.contains("<chapter eID=") && !hasOpeningMarker,
            "A closing-only chapter tag suppresses Vue's synthetic chapter number without rendering a visible one. XML: \(chapter.xml)"
        )
    }

    func testSwordModuleRawChapterKeysExposeIntroStructure() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let module = try XCTUnwrap(manager.module(named: "KJV"))

        module.setKey("=2Cor.0.0")
        _ = module.currentVerseKeyChildren()
        let bookIntro = module.rawEntry()

        module.setKey("=2Cor.1.0")
        let chapterIntroKey = module.currentVerseKeyChildren()
        let chapterIntro = module.rawEntry()

        module.setKey("=2Cor.2.0")
        let secondChapterIntroKey = module.currentVerseKeyChildren()
        let secondChapterIntro = module.rawEntry()

        module.setKey("2Cor 1")
        let chapterKeyRawEntry = module.rawEntry()

        XCTAssertFalse(bookIntro.isEmpty)
        XCTAssertFalse(chapterIntro.isEmpty)
        XCTAssertFalse(secondChapterIntro.isEmpty)
        XCTAssertEqual(chapterIntroKey?.chapter, 1)
        XCTAssertEqual(chapterIntroKey?.verse, 0)
        XCTAssertEqual(secondChapterIntroKey?.chapter, 2)
        XCTAssertEqual(secondChapterIntroKey?.verse, 0)
        XCTAssertTrue(
            bookIntro.contains("THE SECOND EPISTLE OF PAUL THE APOSTLE TO THE CORINTHIANS")
                || chapterIntro.contains("THE SECOND EPISTLE OF PAUL THE APOSTLE TO THE CORINTHIANS")
        )
        XCTAssertTrue(
            chapterIntro.contains("<chapter")
                || secondChapterIntro.contains("<chapter")
                || chapterKeyRawEntry.contains("<chapter"),
            "Expected libsword to expose a chapter marker somewhere in chapter-intro access paths"
        )
    }

    func testLinkifyRawDictionaryXMLLinksStructuredAndPlainStrongsReferences() {
        let rawEntry = """
        <entryFree n="6440"><def>From 6437; see HEBREW for 05774 and <ref target="StrongsHebrew/02421">2421</ref>.</def></entryFree>
        """

        let linkified = BibleReaderStrongsDocumentBuilder.linkifyRawDictionaryXML(rawEntry, defaultPrefix: "H")

        XCTAssertTrue(linkified.contains("<entryFree"))
        XCTAssertTrue(linkified.contains("<a href=\"ab-w://?strong=H6437\">6437</a>"))
        XCTAssertTrue(linkified.contains("see HEBREW for <a href=\"ab-w://?strong=H05774\">05774</a>"))
        XCTAssertTrue(linkified.contains("<a href=\"ab-w://?strong=H02421\">2421</a>"))
    }

    /**
     Protects Android fragment metadata from being inferred from the requested route.

     - Setup: Projects a source advertising both definition families and sanitizes a decorated
       accepted key containing a hyphen and carriage return.
     - Expected result: Features serialize as `hebrew-and-greek` with the exact key name, while
       only the DOM-safe fragment identity replaces non-letter/non-digit characters.
     - Failure meaning: iOS loses accepted-key identity or labels an explicit source using the
       caller's requested Hebrew/Greek route instead of the source's actual feature metadata.
     - Side effects: None.
     */
    func testAndroidDictionaryFragmentMetadataUsesActualFeaturesAndSanitizedExactKey() {
        let features = AndroidDictionaryFragmentMetadata.features(
            from: [.hebrewDef, .greekDef],
            keyName: "G-243\r"
        )

        XCTAssertEqual(features.type, "hebrew-and-greek")
        XCTAssertEqual(features.keyName, "G-243\r")
        XCTAssertEqual(
            AndroidDictionaryFragmentMetadata.fragmentKey(
                bookInitials: "Combined",
                keyOsisID: "G-243\r"
            ),
            "Combined--G_243_"
        )
        XCTAssertEqual(
            AndroidDictionaryFragmentMetadata.fragmentKey(
                bookInitials: "Combined",
                keyOsisID: "A١B"
            ),
            "Combined--A_B",
            "Android's default regex keeps Unicode letters but treats only ASCII 0...9 as digits"
        )
        XCTAssertTrue(
            AndroidDictionaryFragmentMetadata.usesStrongsContentType([.greekParse])
        )
        XCTAssertFalse(
            AndroidDictionaryFragmentMetadata.usesStrongsContentType([.strongsNumbers])
        )
    }

    /**
     Protects Android's exact typed family values for an already padded Strong's key.

     - Setup: Builds candidates for `H00430`, whose raw and numeric forms have five digits.
     - Expected result: Only Android's raw, padded, padded-plus-CR, and category families appear.
     - Failure meaning: iOS added a libsword-only alias that can turn an Android miss into content.
     - Side effects: None.
     */
    func testStrongsLookupKeyOptionsUseOnlyAndroidFamiliesForPaddedNumber() {
        XCTAssertEqual(
            BibleReaderStrongsDocumentBuilder.strongsLookupKeyOptions(for: "H00430"),
            ["H00430", "00430", "00430\r", "H430"]
        )
    }

    /**
     Protects Android's canonical five-digit lookup family for an unpadded Strong's link.

     - Setup: Builds lookup candidates for the issue-388 request `G243`.
     - Expected result: Android's four typed families remain in enum order, including the duplicate
       `G243` values whose distinct families participate in preferred-family caching.
     - Failure meaning: A dictionary that stores canonical padded keys cannot resolve an unpadded
       link even though Android resolves the same request.
     - Side effects: None.
     */
    func testStrongsLookupKeyOptionsPadUnpaddedGreekNumberLikeAndroid() {
        XCTAssertEqual(
            BibleReaderStrongsDocumentBuilder.strongsLookupKeyOptions(for: "G243"),
            ["G243", "00243", "00243\r", "G243"]
        )
    }

    /**
     Protects Android's decorated-key parsing and typed duplicate retention.

     - Setup: Builds candidates for decorated Strong's key `G00243a`.
     - Expected result: The raw decoration remains only on the raw family; numeric families use
       significant digits `243`, with five-digit and category normalization matching Android.
     - Failure meaning: Decorations are rejected, included in numeric aliases, or normalized using
       an iOS-only family that Android never queries.
     - Side effects: None.
     */
    func testStrongsLookupKeyOptionsNormalizeDecoratedKeyLikeAndroid() {
        XCTAssertEqual(
            BibleReaderStrongsDocumentBuilder.strongsLookupKeyOptions(for: "G00243a"),
            ["G00243a", "00243", "00243\r", "G243"]
        )
    }

    /**
     Protects Android's greedy all-zero Strong's grammar and raw-prefix category choice.

     - Setup: Builds typed candidates for prefixed `G000` and prefixless `000`.
     - Expected result: Both retain one significant zero; only the raw uppercase-G input receives a
       Greek category key, while prefixless input receives Android's Hebrew `H0` category key.
     - Failure meaning: iOS drops all zeroes, rejects the request, or infers Greek from normalized
       numeric content instead of the raw URI prefix.
     - Side effects: None.
     */
    func testStrongsLookupKeyOptionsPreserveAllZeroGrammarAndRawCategory() {
        XCTAssertEqual(
            BibleReaderStrongsDocumentBuilder.strongsLookupKeyOptions(for: "G000"),
            ["G000", "00000", "00000\r", "G0"]
        )
        XCTAssertEqual(
            BibleReaderStrongsDocumentBuilder.strongsLookupKeyOptions(for: "000"),
            ["000", "00000", "00000\r", "H0"]
        )
    }

    /**
     Protects Android's per-module preferred-family history without global test state.

     - Setup: Records the padded family for one isolated cache and orders `G243` candidates.
     - Expected result: The padded family moves first; every other typed family, including the
       duplicate raw/category value, keeps Android enum order.
     - Failure meaning: Reader-route builder recreation loses observable Android lookup history or
       string deduplication erases a behaviorally distinct family.
     - Side effects: Mutates only an isolated in-memory cache.
     */
    func testStrongsLookupPreferenceCacheReordersTypedFamilyPerModule() {
        let candidates = AndroidStrongsKeyResolution.candidates(
            for: "G243",
            categoryPrefix: "G"
        )
        let cache = AndroidStrongsKeyPreferenceCache()
        cache.record(.zeroPaddedKey, moduleInitials: "MixedGreek")

        XCTAssertEqual(
            cache.orderedCandidates(candidates, moduleInitials: "MixedGreek"),
            [
                .init(family: .zeroPaddedKey, value: "00243"),
                .init(family: .key, value: "G243"),
                .init(family: .zeroPaddedKeyWithCarriageReturn, value: "00243\r"),
                .init(family: .category, value: "G243"),
            ]
        )
        XCTAssertEqual(
            cache.orderedCandidates(candidates, moduleInitials: "OtherGreek"),
            candidates,
            "Preferred-family history must remain scoped to canonical module initials"
        )
    }

    /**
     Protects JSword's directional zero-size midpoint selection and iOS's bounded corrupt-index
     safety guard.

     - Setup: Resolves synthetic physical RawLD slots whose first midpoint is zero-size for odd and
       even cardinalities, then exercises Android's known two-slot no-progress shape.
     - Expected result: Five slots move right, four tied slots move left, and the corrupt two-slot
       search returns a miss instead of repeating unchanged bounds forever.
     - Failure meaning: iOS selects a different stored key than Android for recoverable zero slots,
       or a malformed installed dictionary can hang the reader route.
     - Side effects: None; all slot metadata is immutable and in memory.
     */
    func testRawLDResolutionMatchesDirectionalZeroSlotSelectionAndFailsClosedOnNoProgress() {
        let configuration = AndroidJSwordRawLDKeyResolution.Configuration(
            moduleInitials: "Fixture",
            category: .dictionary,
            features: [],
            caseSensitiveKeys: false,
            strongsPadding: false
        )
        let oddSlots = [
            SwordRawDictionaryIndexSlot(index: 0, key: "A", size: 2),
            SwordRawDictionaryIndexSlot(index: 1, key: "B", size: 2),
            SwordRawDictionaryIndexSlot(index: 2, key: nil, size: 0),
            SwordRawDictionaryIndexSlot(index: 3, key: "D", size: 2),
            SwordRawDictionaryIndexSlot(index: 4, key: "E", size: 2),
        ]
        let evenSlots = [
            SwordRawDictionaryIndexSlot(index: 0, key: "A", size: 2),
            SwordRawDictionaryIndexSlot(index: 1, key: "B", size: 2),
            SwordRawDictionaryIndexSlot(index: 2, key: nil, size: 0),
            SwordRawDictionaryIndexSlot(index: 3, key: "D", size: 2),
        ]
        let noProgressSlots = [
            SwordRawDictionaryIndexSlot(index: 0, key: "A", size: 2),
            SwordRawDictionaryIndexSlot(index: 1, key: nil, size: 0),
        ]

        XCTAssertEqual(
            AndroidJSwordRawLDKeyResolution.resolve(
                requestedKey: "D",
                storedSlots: oddSlots,
                configuration: configuration
            ),
            .init(index: 3, storedKey: "D")
        )
        XCTAssertEqual(
            AndroidJSwordRawLDKeyResolution.resolve(
                requestedKey: "B",
                storedSlots: evenSlots,
                configuration: configuration
            ),
            .init(index: 1, storedKey: "B")
        )
        XCTAssertNil(AndroidJSwordRawLDKeyResolution.resolve(
            requestedKey: "Z",
            storedSlots: noProgressSlots,
            configuration: configuration
        ))
    }

    /**
     Protects RawLD's case-sensitive fallback from aborting at an empty physical slot.

     - Setup: Supplies an intentionally non-sorted corrupt index where binary search misses `Z`,
       index zero is zero-size, and the later exact record remains readable by JSword's raw scan.
     - Expected result: The fallback treats the zero-size slot as an empty key, continues, and
       returns the later exact physical record.
     - Failure meaning: One placeholder hides all later exact records from case-sensitive modules.
     - Side effects: None; resolution reads only synthetic slot metadata.
     */
    func testRawLDCaseSensitiveFallbackContinuesPastZeroSizeSlot() {
        let slots = [
            SwordRawDictionaryIndexSlot(index: 0, key: nil, size: 0),
            SwordRawDictionaryIndexSlot(index: 1, key: "Z", size: 2),
            SwordRawDictionaryIndexSlot(index: 2, key: "A", size: 2),
            SwordRawDictionaryIndexSlot(index: 3, key: "B", size: 2),
        ]
        let configuration = AndroidJSwordRawLDKeyResolution.Configuration(
            moduleInitials: "CaseSensitive",
            category: .dictionary,
            features: [],
            caseSensitiveKeys: true,
            strongsPadding: false
        )

        XCTAssertEqual(
            AndroidJSwordRawLDKeyResolution.resolve(
                requestedKey: "Z",
                storedSlots: slots,
                configuration: configuration
            ),
            .init(index: 1, storedKey: "Z")
        )
    }

    /**
     Protects the deterministic lookup tiers shared with pinned `SwordGenBook.getKey`.

     - Setup: Supplies separate unique-winner TreeKey sets for exact, case-insensitive, prefix, and
       substring resolution, including libsword's leading root slash.
     - Expected result: Exact source paths remain readable while leaf key names, full OSIS paths,
       and selected-node subtree cardinality stay distinct for every tier.
     - Failure meaning: General-book definitions flatten TreeKey identity, case-fold prefix tiers,
       or depend on one JVM's undefined ambiguous HashMap order.
     - Side effects: None.
     */
    func testGenBookKeyResolutionPreservesFourTiersAndTreeIdentities() {
        XCTAssertEqual(
            AndroidJSwordGenBookKeyResolution.resolve(
                candidate: "G243",
                sourceKeys: ["/", "/G243"]
            ),
            .init(
                sourceKey: "/G243",
                keyName: "G243",
                osisRef: "G243",
                subtreeCardinality: 1
            )
        )
        XCTAssertEqual(
            AndroidJSwordGenBookKeyResolution.resolve(
                candidate: "Root/G243",
                sourceKeys: ["/", "/Root/g243"]
            ),
            .init(
                sourceKey: "/Root/g243",
                keyName: "g243",
                osisRef: "Root/g243",
                subtreeCardinality: 1
            )
        )
        XCTAssertEqual(
            AndroidJSwordGenBookKeyResolution.resolve(
                candidate: "G243",
                sourceKeys: ["/", "/G243Child"]
            ),
            .init(
                sourceKey: "/G243Child",
                keyName: "G243Child",
                osisRef: "G243Child",
                subtreeCardinality: 1
            )
        )
        XCTAssertEqual(
            AndroidJSwordGenBookKeyResolution.resolve(
                candidate: "G243",
                sourceKeys: ["/", "/Root/G243"]
            ),
            .init(
                sourceKey: "/Root/G243",
                keyName: "G243",
                osisRef: "Root/G243",
                subtreeCardinality: 1
            )
        )
        XCTAssertEqual(
            AndroidJSwordGenBookKeyResolution.resolve(
                candidate: "G243",
                sourceKeys: ["/", "/G243", "/G243/Child", "/Sibling"]
            ),
            .init(
                sourceKey: "/G243",
                keyName: "G243",
                osisRef: "G243",
                subtreeCardinality: 2
            ),
            "A selected parent includes itself and descendants but excludes siblings"
        )
    }

    /**
     Protects Android's generated dictionary title for an exact empty restored MyBible row.

     - Setup: Creates one exact MyBible dictionary topic with an empty definition and resolves it
       through the restored Strong's facade.
     - Expected result: Row presence succeeds and payload-ready OSIS contains Android's hidden
       generated key title with no fabricated definition body.
     - Failure meaning: iOS treats an empty definition as row absence and emits a download fallback
       even though Android opens the valid title-only `SwordDictionary` fragment.
     - Side effects: Creates and removes one temporary SQLite fixture.
     */
    func testMyBibleEmptyDictionaryRowProducesGeneratedTitleOnly() throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mybible-empty-dictionary-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        let databaseURL = fixtureDirectory.appendingPathComponent("module.SQLite3")
        try writeMyBibleStrongDictionaryDatabase(
            at: databaseURL,
            topic: "G243",
            definition: ""
        )
        let reader = try XCTUnwrap(MyBibleReader(filePath: databaseURL.path))

        let lookup = try XCTUnwrap(
            BibleReaderStrongsDocumentBuilder.lookupInMyBibleDictionary(
                reader,
                keyOptions: ["G243"]
            )
        )
        XCTAssertEqual(lookup.actualKey, "G243")
        XCTAssertFalse(lookup.isNativeHtml)
        XCTAssertEqual(
            lookup.rawEntry,
            #"<div><title type="x-gen">G243</title></div>"#
        )
        XCTAssertEqual(
            lookup.payloadReadyXML,
            #"<div><title type="x-gen"><BVA ordinal="0" xmlns="http://www.w3.org/1999/xhtml">G243</BVA></title></div>"#
        )
    }

    /**
     Protects Android's carriage-return Strong key family through an exact installed backend.

     - Setup: Installs a MyBible Strong dictionary whose sole exact topic is `00243\r`, then asks
       for external key `G243` with an isolated preferred-family cache.
     - Expected result: The third Android family resolves end to end; key metadata retains the
       carriage return, only the fragment identity sanitizes it, and the accepted family becomes
       first for the same module's next lookup.
     - Failure meaning: iOS drops the carriage-return family, flattens actual key identity, or fails
       to persist Android's materially observable per-book family preference.
     - Side effects: Creates and removes one temporary restored MyBible fixture.
     */
    func testMyBibleCarriageReturnStrongKeyPreservesIdentityAndCachesFamily() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try installMyBibleStrongDictionaryFixture(
            named: "CRDICT",
            modulePath: URL(fileURLWithPath: modulePath, isDirectory: true),
            topic: "00243\r",
            definition: "Carriage return definition"
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let cache = AndroidStrongsKeyPreferenceCache()
        let builder = BibleReaderStrongsDocumentBuilder(
            swordManager: manager,
            selectedPreferenceValues: { _ in [] },
            moduleDisplayLabel: { $0.info.name },
            localizedString: { _, defaultValue in defaultValue },
            strongsLookupKeyPreferenceCache: cache
        )

        let json = try XCTUnwrap(
            builder.buildStrongsMultiDocumentJSON(strongs: ["G243"], robinson: [])
        )
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let fragment = try XCTUnwrap(
            (payload["osisFragments"] as? [[String: Any]])?.first {
                $0["bookInitials"] as? String == "CRDICT"
            }
        )
        let features = try XCTUnwrap(fragment["features"] as? [String: Any])

        XCTAssertEqual(fragment["key"] as? String, "CRDICT--00243_")
        XCTAssertEqual(fragment["keyName"] as? String, "00243\r")
        XCTAssertEqual(fragment["osisRef"] as? String, "00243\r")
        XCTAssertEqual(features["keyName"] as? String, "00243\r")
        XCTAssertTrue(
            (fragment["xml"] as? String)?.contains("Carriage return definition") == true,
            fragment["xml"] as? String ?? "Missing XML"
        )
        XCTAssertTrue(
            (fragment["xml"] as? String)?.contains("00243&#xD;") == true,
            "JDOM preserves the generated-title CR as an entity through Multi JSON cleanup"
        )

        let reordered = cache.orderedCandidates(
            AndroidStrongsKeyResolution.candidates(for: "G243", categoryPrefix: "G"),
            moduleInitials: "CRDICT"
        )
        XCTAssertEqual(reordered.first?.family, .zeroPaddedKeyWithCarriageReturn)
        XCTAssertEqual(reordered.first?.value, "00243\r")
    }

    func testIsSupportedStrongsDictionaryModuleNameMatchesAndroidCuratedPolicy() {
        XCTAssertFalse(BibleReaderStrongsDocumentBuilder.isSupportedStrongsDictionaryModuleName("BDBGlosses_Strongs"))
        XCTAssertTrue(BibleReaderStrongsDocumentBuilder.isSupportedStrongsDictionaryModuleName("StrongsHebrew"))
        XCTAssertTrue(BibleReaderStrongsDocumentBuilder.isSupportedStrongsDictionaryModuleName("InvStrongsRealHebrew"))
    }

    /**
     Verifies restored Android MyBible Strong's dictionaries are detected as dictionaries, not Bible
     texts.

     Android's MyBible adapter treats a module with a `dictionary` table and `info.is_strong=true`
     as a Hebrew/Greek Strong's dictionary. The iOS reader must expose that schema shape so restored
     Android module backups can participate in dictionary lookup instead of being ignored as
     non-Bible MyBible files.

     - Setup: Creates a minimal MyBible `module.SQLite3` with `info` and `dictionary` tables.
     - Expected result: The reader reports dictionary/Strong's metadata and resolves the unpadded
       Android topic key `H430`.
     - Failure meaning: Restored MyBible dictionaries such as BDBT will not appear in the Strong's
       multi-window on iOS.
     - Side effects: Creates and removes a temporary SQLite database.
     */
    func testMyBibleReaderDetectsStrongDictionarySchema() throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mybible-dictionary-reader-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        let databaseURL = fixtureDirectory.appendingPathComponent("module.SQLite3")
        try writeMyBibleStrongDictionaryDatabase(
            at: databaseURL,
            topic: "H430",
            definition: "Original: <b>אלהים</b><p>BDB Definition : God, gods</p>"
        )

        let reader = try XCTUnwrap(MyBibleReader(filePath: databaseURL.path))

        XCTAssertFalse(reader.isBible)
        XCTAssertTrue(reader.isDictionary)
        XCTAssertTrue(reader.hasStrongsDefinitions)
        XCTAssertEqual(
            reader.getDictionaryEntry(key: "H430"),
            "Original: <b>אלהים</b><p>BDB Definition : God, gods</p>"
        )
        XCTAssertEqual(reader.dictionaryKeys(), ["H430"])
    }

    /**
     Verifies Strong's lookup includes MyBible dictionaries restored from Android module backups.

     Android imports BDBT as `ModDrv=MyBibleDictionary`, marks it with Greek/Hebrew definition
     features, and then includes it in Strong's dictionary tabs. iOS must scan those restored configs
     beside normal SWORD modules because libsword does not enumerate MyBibleDictionary modules.

     - Setup: Adds a BDBT-style `.conf` and `module.SQLite3` to the temporary SWORD fixture path.
     - Expected result: A Hebrew Strong's lookup produces a BDBT dictionary fragment preserving
       Android's actual resolved `H430` key name and OSIS identity.
     - Failure meaning: Android backups can restore the files successfully while the dictionary still
       remains invisible in the iOS Multi window.
     - Side effects: Creates temporary module files under the test SWORD path.
     */
    func testStrongsDocumentBuilderIncludesRestoredMyBibleStrongDictionary() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try installMyBibleStrongDictionaryFixture(
            named: "BDBT",
            modulePath: URL(fileURLWithPath: modulePath, isDirectory: true),
            topic: "H430",
            definition: """
            Original: <b><he>אלהים</he></b><p/>Transliteration: <b>'ĕlôhı̂ym</b><p/>Phonetic: <b>el-o-heem'</b><p class="bdb_def"><b>BDB Definition</b>:</p><ol><li>(plural)<ol type="a"><li>rulers, judges</li><li>divine ones</li></ol></li><li>(plural intensive - singular meaning)<ol type="a"><li>god, goddess</li><li>God</li></ol></li></ol><p/>Origin: plural of <a href="S:H433">H433</a>
            """
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let builder = BibleReaderStrongsDocumentBuilder(
            swordManager: manager,
            selectedPreferenceValues: { _ in [] },
            moduleDisplayLabel: { $0.info.name },
            localizedString: { _, defaultValue in defaultValue }
        )

        let json = try XCTUnwrap(builder.buildStrongsMultiDocumentJSON(strongs: ["H00430"], robinson: []))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let fragments = try XCTUnwrap(payload["osisFragments"] as? [[String: Any]])
        let bdbt = try XCTUnwrap(fragments.first { $0["bookInitials"] as? String == "BDBT" })
        let features = try XCTUnwrap(bdbt["features"] as? [String: Any])
        let xml = try XCTUnwrap(bdbt["xml"] as? String)

        XCTAssertEqual(bdbt["bookAbbreviation"] as? String, "BDBT")
        XCTAssertEqual(bdbt["key"] as? String, "BDBT--H430")
        XCTAssertEqual(bdbt["keyName"] as? String, "H430")
        XCTAssertEqual(bdbt["osisRef"] as? String, "H430")
        XCTAssertEqual(bdbt["bookCategory"] as? String, DocumentCategory.dictionary.rawValue)
        XCTAssertTrue(bdbt["v11n"] is NSNull)
        XCTAssertFalse(bdbt["hasStrongs"] as? Bool ?? true)
        XCTAssertEqual(bdbt["isNativeHtml"] as? Bool, false)
        XCTAssertEqual(features["type"] as? String, "hebrew-and-greek")
        XCTAssertEqual(features["keyName"] as? String, "H430")
        XCTAssertTrue(xml.contains(#"<title type="x-gen"><BVA"#))
        XCTAssertTrue(xml.contains("<b><he><BVA"), xml)
        XCTAssertTrue(xml.contains("אלהים</BVA></he></b>"), xml)
        XCTAssertTrue(xml.contains("<ol><li><BVA"), xml)
        XCTAssertTrue(xml.contains(#"<a href="S:H433"><BVA"#), xml)
        XCTAssertFalse(xml.contains("type=\"paragraph\""))
        XCTAssertFalse(xml.contains("No dictionary module installed"))
    }

    /**
     Verifies the Android `Multi` toolbar title is derived from the first dictionary fragment.

     Android keeps the page document as `FakeBookFactory.multiDocument`, but the toolbar title uses
     the first child `BookAndKey` display name such as `BDBT: H430` and the subtitle remains
     `multi_description`. This test protects that display contract without changing durable
     `general_book/Multi` identity.
     */
    func testAndroidMultiDocumentHeaderSummaryUsesFirstDictionaryFragmentLikeAndroidToolbar() throws {
        let json = try XCTUnwrap(BibleReaderMultiFragmentDocumentBuilder.buildJSON(
            fragments: [(
                xml: "<div><p>BDB entry</p></div>",
                key: "BDBT--00430",
                keyName: "00430",
                osisRef: "00430",
                bookCategory: DocumentCategory.dictionary.rawValue,
                bookInitials: "BDBT",
                bookAbbreviation: "BDBT",
                v11n: "KJV",
                language: "en",
                direction: "ltr",
                features: OsisFeatures(type: "hebrew", keyName: "00430"),
                hasStrongs: false,
                isNativeHtml: false
            )],
            contentType: "strongs"
        ))

        let summary = try XCTUnwrap(AndroidSpecialDocumentIdentity.multiDocumentHeaderSummary(
            from: json,
            subtitle: "Multiple references"
        ))

        XCTAssertEqual(summary.title, "BDBT: H430")
        XCTAssertEqual(summary.subtitle, "Multiple references")
    }

    /**
     Verifies selected-word lookup preserves Android's dictionary rendering contract.

     Android `LinkControl.lookupInDictionaries` resolves exact dictionary keys through JSword and
     opens a `MultiDocument` made from the matched entries. The iOS builder must therefore project
     the rendered entry text into the bridge payload; a failure here means users would see Swift
     diagnostic text or lose dictionary body content even though the dictionary lookup succeeded.
     */
    func testWordLookupDocumentUsesRenderedDictionaryText() throws {
        let builder = BibleReaderWordLookupDocumentBuilder(modules: {
            [
                BibleReaderWordLookupDocumentBuilder.DictionaryModule(
                    name: "Websters",
                    abbreviation: "Websters",
                    category: .glossary,
                    features: [.strongsNumbers],
                    lookup: { keyOptions in
                        XCTAssertEqual(keyOptions, ["Grace"])
                        return BibleReaderStrongsDocumentBuilder.DictionaryLookupResult(
                            actualKey: "GRACE",
                            osisID: "Root/GRACE",
                            osisRef: "Root/GRACE",
                            rawEntry: "raw dictionary bytes",
                            renderedText: "<p>Grace rendered from SWORD</p>"
                        )
                    }
                )
            ]
        })

        let json = try XCTUnwrap(builder.buildWordLookupMultiDocumentJSON(query: "Grace"))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let fragments = try XCTUnwrap(payload["osisFragments"] as? [[String: Any]])
        let fragment = try XCTUnwrap(fragments.first)
        let xml = try XCTUnwrap(fragment["xml"] as? String)

        XCTAssertEqual(payload["type"] as? String, "multi")
        XCTAssertEqual(fragment["key"] as? String, "Websters--Root_GRACE")
        XCTAssertEqual(fragment["keyName"] as? String, "GRACE")
        XCTAssertEqual(fragment["osisRef"] as? String, "Root/GRACE")
        XCTAssertEqual(fragment["bookCategory"] as? String, "GLOSSARY")
        XCTAssertEqual(fragment["bookInitials"] as? String, "Websters")
        XCTAssertEqual(fragment["hasStrongs"] as? Bool, true)
        XCTAssertTrue((fragment["features"] as? [String: Any])?.isEmpty == true)
        XCTAssertTrue(xml.contains("Grace rendered from SWORD"))
        XCTAssertFalse(xml.contains("DictionaryLookupResult"))
    }

    /**
     Verifies iOS selected-word normalization stays aligned with Android `LinkControl`.

     Android trims surrounding whitespace and removes trailing punctuation before calling
     `Book.getKey`. A failure means selected text with punctuation could resolve differently on iOS
     than Android, causing avoidable "not found" feedback for the same installed dictionaries.
     */
    func testWordLookupQueryNormalizationMatchesAndroid() {
        XCTAssertEqual(
            BibleReaderWordLookupDocumentBuilder.normalizeQuery("  Grace?!  "),
            "Grace"
        )
        XCTAssertEqual(
            BibleReaderWordLookupDocumentBuilder.normalizeQuery("faith."),
            "faith"
        )
    }

    func testRenderedContentStateDefaultsToNeutralToken() {
        let controller = BibleReaderController(bridge: BibleBridge())

        XCTAssertEqual(
            controller.renderedContentState,
            BibleReaderController.emptyRenderedContentState
        )
    }

    /**
     Installs a minimal restored MyBible Strong's dictionary into a SWORD module directory.

     - Parameters:
       - name: Module initials and config header, for example `BDBT`.
       - modulePath: Root SWORD path containing `mods.d` and `modules`.
       - topic: MyBible dictionary topic key to insert.
       - definition: Raw definition text returned by dictionary lookup.
     - Side effects: Writes one `.conf` file and one SQLite database under the temporary module path.
     - Failure modes: File and SQLite errors are thrown to the calling test.
     */
    private func installMyBibleStrongDictionaryFixture(
        named name: String,
        modulePath: URL,
        topic: String,
        definition: String
    ) throws {
        let modsDirectory = modulePath.appendingPathComponent("mods.d", isDirectory: true)
        let dataDirectory = modulePath
            .appendingPathComponent("modules/texts/MyBible/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: modsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)

        let config = """
        [\(name)]
        Abbreviation=\(name)
        DataPath=./modules/texts/MyBible/\(name)/
        AndBibleMinimumVersion=641
        ModDrv=MyBibleDictionary
        CompressType=ZIP
        BlockType=BOOK
        Encoding=UTF-8
        SourceType=OSIS
        Lang=en
        LCSH=Dictionary.English
        Feature=GreekDef
        Feature=HebrewDef
        Description=Brown-Driver-Briggs' Hebrew Definitions / Thayer's Greek Definitions
        DistributionLicense=Public Domain
        """
        try config.write(
            to: modsDirectory.appendingPathComponent("\(name).conf"),
            atomically: true,
            encoding: .utf8
        )
        try writeMyBibleStrongDictionaryDatabase(
            at: dataDirectory.appendingPathComponent("module.SQLite3"),
            topic: topic,
            definition: definition
        )
    }

    /**
     Writes the minimum MyBible dictionary SQLite schema needed by Android's Strong's adapter.

     - Parameters:
       - databaseURL: Destination SQLite file.
       - topic: Dictionary topic key to insert.
       - definition: Raw definition text returned for the topic.
     - Side effects: Creates and writes a SQLite database file.
     - Failure modes: Throws `NSError` with SQLite diagnostics for open, schema, prepare, bind, or
       step failures.
     */
    private func writeMyBibleStrongDictionaryDatabase(
        at databaseURL: URL,
        topic: String,
        definition: String
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE,
            nil
        ) == SQLITE_OK, let database else {
            throw NSError(domain: "MyBibleDictionaryFixture", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not open fixture database"
            ])
        }
        defer { sqlite3_close(database) }

        let schema = """
        CREATE TABLE info (name TEXT, value TEXT);
        INSERT INTO info (name, value) VALUES
            ('description', 'BDBT fixture'),
            ('language', 'en'),
            ('is_strong', 'true');
        CREATE TABLE dictionary (
            topic TEXT,
            definition TEXT,
            lexeme TEXT,
            transliteration TEXT,
            pronunciation TEXT,
            short_definition TEXT
        );
        CREATE UNIQUE INDEX dictionary_topic ON dictionary(topic);
        """
        guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
            throw sqliteFixtureError(database, message: "Could not create MyBible dictionary schema")
        }

        let insert = """
        INSERT INTO dictionary (
            topic, definition, lexeme, transliteration, pronunciation, short_definition
        ) VALUES (?, ?, '', '', '', '')
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, insert, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw sqliteFixtureError(database, message: "Could not prepare MyBible dictionary insert")
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, topic, -1, myBibleDictionaryFixtureSQLiteTransient)
        sqlite3_bind_text(statement, 2, definition, -1, myBibleDictionaryFixtureSQLiteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw sqliteFixtureError(database, message: "Could not insert MyBible dictionary entry")
        }
    }

    /**
     Builds a test failure error containing SQLite's latest diagnostic message.
     */
    private func sqliteFixtureError(_ database: OpaquePointer, message: String) -> NSError {
        let detail = sqlite3_errmsg(database).map { String(cString: $0) } ?? message
        return NSError(domain: "MyBibleDictionaryFixture", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "\(message): \(detail)"
        ])
    }
}
