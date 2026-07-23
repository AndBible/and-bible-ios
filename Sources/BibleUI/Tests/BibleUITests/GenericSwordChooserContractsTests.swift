import XCTest
@testable import BibleUI
import SwordKit

/** Android dictionary and general-book chooser behavior tests. */
final class GenericSwordChooserContractsTests: XCTestCase {
    /**
     Verifies dictionary filtering consults exact keys and never asynchronous snippets.

     Android displays `orth`/snippet text in each row but filters only `KeyInfo.key.name`. A failure
     would make rows appear after cache loading or make search results differ by scroll position.
     */
    func testDictionaryFilterUsesLocaleLowercasedKeysOnly() {
        let keys = ["G0001", "LogosEntry", "BDB-אָב"]

        XCTAssertEqual(
            DictionaryKeyFilter.filteredKeys(keys, searchText: "logos"),
            ["LogosEntry"]
        )
        XCTAssertEqual(
            DictionaryKeyFilter.filteredKeys(keys, searchText: "definition shown only in snippet"),
            []
        )
        XCTAssertEqual(DictionaryKeyFilter.filteredKeys(keys, searchText: ""), keys)
        XCTAssertEqual(DictionaryKeyFilter.filteredKeys([], searchText: ""), [])
    }

    /**
     Verifies the dictionary display cache loads a key once and evicts deterministically.

     Large Strong's/BDB lexicons must not reread every visible entry during scrolling. The small
     capacity fixture also proves eviction does not return a presentation for a neighboring key.
     */
    func testDictionaryDisplayCacheLoadsOnceAndEvictsOldestExactKey() async {
        let counter = DictionaryLoaderCounter()
        let cache = DictionaryEntryDisplayCache(capacity: 2) { key in
            await counter.record(key)
            return SwordDictionaryEntryPresentation(
                key: key,
                snippet: "snippet-\(key)",
                displayText: "\(key) - snippet-\(key)"
            )
        }

        let first = await cache.presentation(for: "G0001")
        let repeated = await cache.presentation(for: "G0001")
        _ = await cache.presentation(for: "G0002")
        _ = await cache.presentation(for: "G0003")
        let firstWasEvicted = !(await cache.contains("G0001"))
        let reloaded = await cache.presentation(for: "G0001")
        let counts = await counter.snapshot()

        XCTAssertEqual(first, repeated)
        XCTAssertEqual(reloaded.key, "G0001")
        XCTAssertTrue(firstWasEvicted)
        XCTAssertEqual(counts["G0001"], 2)
        XCTAssertEqual(counts["G0002"], 1)
        XCTAssertEqual(counts["G0003"], 1)
    }

    /**
     Verifies concurrent row requests share one exact SWORD read.

     - Setup: Starts multiple requests for the same uncached key against a loader that suspends once.
     - Expected result: Every caller receives the same row and the loader runs exactly once.
     - Failure meaning: SwiftUI can multiply expensive lexicon reads while rapidly creating visible
       rows, undermining the Android-equivalent cached chooser model.
     - Note: The loader's suspension makes actor reentrancy deterministic without wall-clock timing.
     */
    func testDictionaryDisplayCacheCoalescesConcurrentExactKeyLoads() async {
        let counter = DictionaryLoaderCounter()
        let cache = DictionaryEntryDisplayCache { key in
            await counter.record(key)
            await Task.yield()
            return SwordDictionaryEntryPresentation(
                key: key,
                snippet: "snippet-\(key)",
                displayText: "\(key) - snippet-\(key)"
            )
        }

        let rows = await withTaskGroup(
            of: SwordDictionaryEntryPresentation.self,
            returning: [SwordDictionaryEntryPresentation].self
        ) { group in
            for _ in 0..<12 {
                group.addTask { await cache.presentation(for: "BDB-01") }
            }
            var values: [SwordDictionaryEntryPresentation] = []
            for await row in group { values.append(row) }
            return values
        }
        let counts = await counter.snapshot()

        XCTAssertEqual(Set(rows.map(\.displayText)), Set(["BDB-01 - snippet-BDB-01"]))
        XCTAssertEqual(counts["BDB-01"], 1)
    }

    /**
     Verifies Android's cached chooser preserves every nonempty SWORD key exactly.

     Trimming, deduplicating, or reordering a valid key can trigger SWORD nearest-key behavior or
     change chooser rows. Lists containing no nonempty key follow Android's `itemSelected(null)` and
     activity-dismiss path.
     */
    func testGenericChooserPreservesExactKeysAndDismissesMalformedEmptyLists() {
        XCTAssertEqual(
            GenericSwordChooserResolver.resolve(
                keys: ["  exact key  ", "", " \n\t", "  exact key  ", "plain"]
            ),
            .present(["  exact key  ", " \n\t", "  exact key  ", "plain"])
        )
        XCTAssertEqual(
            GenericSwordChooserResolver.resolve(keys: ["", "", ""]),
            .dismissWithoutSelection
        )
        XCTAssertEqual(
            GenericSwordChooserResolver.resolve(keys: []),
            .dismissWithoutSelection
        )
    }

    /**
     Verifies a key-list backend failure never takes the successful empty-module path.

     - Setup: Resolves an empty successful result and a localized SWORD-like failure separately.
     - Expected result: Empty content dismisses the general-key chooser, while failure retains an
       actionable message for retry UI.
     - Failure meaning: A backend outage can masquerade as a genuinely keyless module and silently
       dismiss the chooser.
     - Side effects: None.
     */
    func testGenericChooserKeepsBackendFailureDistinctFromEmptyModule() {
        let empty = GenericSwordChooserResolver.resolve(
            result: Result<[String], Error>.success([])
        )
        let failed = GenericSwordChooserResolver.resolve(
            result: Result<[String], Error>.failure(GenericKeyListFixtureError.unavailable)
        )

        XCTAssertEqual(empty, .dismissWithoutSelection)
        XCTAssertEqual(failed, .failed(message: "Fixture key backend unavailable."))
        XCTAssertNotEqual(failed, empty)
    }

    /**
     Guards the full module picker's typed retain-or-choose routing.

     - Setup: Reads only the picker's unlocked-selection and generic-outcome handlers because SwiftUI
       keeps their presentation state private.
     - Expected result: Dictionary, general-book, and map controller outcomes all reach one typed
       handler; preservation dismisses, absence opens the matching chooser, and failure stores a
       retry request without dismissing the picker.
     - Failure meaning: A picker selection can ignore the typed outcome, reopen a chooser for a valid
       key, or hide a backend failure after state remains unchanged.
     - Side effects: Reads repository source without mutating app state.
     */
    func testFullModulePickerConsumesTypedGenericSwitchOutcome() throws {
        let source = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderModulePicker.swift"
        )
        let selection = try BibleUITestSourceLocator.extractFunction(
            named: "selectUnlockedModule",
            from: source
        )
        let routing = try BibleUITestSourceLocator.extractFunction(
            named: "handleGenericModuleSwitch",
            from: source
        )

        XCTAssertTrue(selection.contains("controller.switchDictionaryDocument(to: module.name)"))
        XCTAssertTrue(selection.contains("controller.switchGeneralBookDocument(to: module.name)"))
        XCTAssertTrue(selection.contains("controller.switchMapDocument(to: module.name)"))
        XCTAssertEqual(selection.components(separatedBy: "handleGenericModuleSwitch(").count - 1, 3)
        XCTAssertTrue(routing.contains("case .switchedPreservingKey:"))
        XCTAssertTrue(routing.contains("case .switchedRequiringKeySelection:"))
        XCTAssertTrue(routing.contains("case .failed(let message):"))
        XCTAssertTrue(routing.contains("onDismiss()"))
        XCTAssertTrue(routing.contains("dismissAndPresentAuxiliaryBrowser(onOpenBrowser)"))
        XCTAssertTrue(routing.contains("pendingGenericSwitchRetry = module"))
        XCTAssertTrue(routing.contains("genericSwitchFailureMessage = message"))
    }

    /**
     Guards commentary quick-selection routing for typed generic switch outcomes.

     - Setup: Reads the pane-scoped selection and outcome handlers from `BibleReaderView` while
       leaving the unrelated synchronized-scrolling callback outside the inspected functions.
     - Expected result: Dictionary/general-book outcomes route to their choosers only when selection
       is required, exact preservation presents nothing, and failures retain module plus pane id for
       a user-visible retry.
     - Failure meaning: Quick selection can target the wrong pane, reload stale content, or swallow a
       SWORD failure instead of offering retry.
     - Side effects: Reads repository source without mutating app state.
     */
    func testCommentaryQuickSelectorConsumesTypedGenericSwitchOutcome() throws {
        let source = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderView.swift"
        )
        let selection = try BibleUITestSourceLocator.extractFunction(
            named: "selectCommentaryQuickModule",
            from: source
        )
        let routing = try BibleUITestSourceLocator.extractFunction(
            named: "handleGenericQuickModuleSwitch",
            from: source
        )
        let retryDialog = try BibleUITestSourceLocator.extractFunction(
            named: "genericQuickModuleSwitchRetryDialog",
            from: source
        )

        XCTAssertTrue(selection.contains("controller.switchDictionaryDocument(to: module.name)"))
        XCTAssertTrue(selection.contains("browser: .dictionaryBrowser"))
        XCTAssertTrue(selection.contains("controller.switchGeneralBookDocument(to: module.name)"))
        XCTAssertTrue(selection.contains("browser: .generalBookBrowser"))
        XCTAssertEqual(selection.components(separatedBy: "handleGenericQuickModuleSwitch(").count - 1, 2)
        XCTAssertTrue(routing.contains("case .switchedPreservingKey:"))
        XCTAssertTrue(routing.contains("case .switchedRequiringKeySelection:"))
        XCTAssertTrue(routing.contains("presentReaderDestinationPreservingPane(browser)"))
        XCTAssertTrue(routing.contains("case .failed(let message):"))
        XCTAssertTrue(routing.contains("pendingGenericQuickModuleSwitchRetry = GenericQuickModuleSwitchRetry("))
        XCTAssertTrue(routing.contains("targetWindowId: targetWindowId"))
        XCTAssertTrue(retryDialog.contains("AndroidDecisionDialog("))
        XCTAssertTrue(retryDialog.contains("title: String(localized: \"retry\")"))
        XCTAssertTrue(retryDialog.contains("selectCommentaryQuickModule("))
    }

    /**
     Guards the dictionary activity's backend-independent source and owner handoff.

     - Setup: Reads the dictionary destination branch from `BibleReaderView`.
     - Expected result: The destination passes the controller's captured dictionary source, active
       reader palette, and explicit Back command to the app-owned browser without requiring a
       native SWORD module.
     - Failure meaning: Exact SQLite dictionary keys can become unavailable, or the route can drift
       back into an independently styled modal instead of inheriting reader-window ownership.
     - Side effects: Reads repository source without mutating app state.
     */
    func testDictionaryActivityUsesActiveBackendIndependentSourceAndOwner() throws {
        let source = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderView.swift"
        )

        XCTAssertTrue(source.contains("controller.activeDictionaryBrowserSource()"))
        XCTAssertTrue(source.contains("DictionaryBrowserView("))
        XCTAssertTrue(source.contains("source: source"))
        XCTAssertTrue(source.contains("surfacePalette: readerThemeSurfacePalette"))
        XCTAssertTrue(source.contains("onBack: { activeReaderDestination = nil }"))
        XCTAssertFalse(source.contains("let module = controller.activeDictionaryModule {\n                DictionaryBrowserView"))
    }

    /**
     Guards all generic-key browsers against native iOS collection and navigation ownership.

     - Setup: Reads the dictionary, SWORD general-book/map, and EPUB table-of-contents sources.
     - Expected result: Every route uses the shared Android activity, loading, and list-row
       structures with the launching reader palette and explicit Back behavior.
     - Failure meaning: One of the less-visible document types can silently regress to a native
       sheet, navigation stack, searchable list, or independently drawn row implementation.
     - Side effects: Reads repository source without mutating app state.
     */
    func testGenericKeyBrowsersReuseSharedAndroidActivityStructures() throws {
        let paths = [
            "Sources/BibleUI/Sources/BibleUI/Dictionary/DictionaryBrowserView.swift",
            "Sources/BibleUI/Sources/BibleUI/Dictionary/GeneralBookBrowserView.swift",
            "Sources/BibleUI/Sources/BibleUI/Dictionary/EpubBrowserView.swift",
        ]
        let sources = try paths.map { try BibleUITestSourceLocator.source(at: $0) }

        for source in sources {
            XCTAssertTrue(source.contains("AndroidActivityScreen("))
            XCTAssertTrue(source.contains("AndroidActivityLoadingView("))
            XCTAssertTrue(source.contains("AndroidActivityListRow("))
            XCTAssertTrue(source.contains("palette: surfacePalette"))
            XCTAssertTrue(source.contains("onBack: onBack"))

            for forbidden in [
                "NavigationStack {",
                "List {",
                ".searchable(",
                ".navigationTitle(",
                ".sheet(",
                "Menu {",
                "Picker(",
            ] {
                XCTAssertFalse(source.contains(forbidden), "Unexpected native presentation token: \(forbidden)")
            }
        }

        XCTAssertTrue(sources[0].contains("AndroidActivityTextInput("))
        XCTAssertTrue(sources[0].contains("search_dictionary_hint"))
        XCTAssertTrue(sources[1].contains("onEmptyKeys(rawKeys.first)"))
        XCTAssertTrue(sources[2].contains("reader.firstKey()"))
    }

    /**
     Guards Android EPUB Search as a complete multi-activity lifecycle, including index rebuilding.

     - Setup: Reads the EPUB Search implementation and its reader-owned destination wiring.
     - Expected result: Criteria, results, rebuild confirmation, and rebuild progress reuse shared
       app-owned controls; Help targets SQLite FTS5; and rebuilt immutable generations must be
       adopted by the active reader owner before use.
     - Failure meaning: Search can collapse into a native iOS list/modal, omit Android's Rebuild
       action, or publish an index generation that the visible reader never adopts.
     - Side effects: Reads repository source without mutating app state.
     */
    func testEpubSearchPreservesAndroidLifecycleAndSharedOwnership() throws {
        let searchSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Dictionary/EpubSearchView.swift"
        )
        let readerSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderView.swift"
        )

        for expected in [
            "case criteria",
            "case results",
            "case rebuildPrompt",
            "case rebuilding",
            "AndroidActivityScreen(",
            "AndroidActivityTextInput(",
            "AndroidRadioRow(",
            "AndroidActivityListRow(",
            "AndroidActivitySingleActionBar(",
            "AndroidActivityCommitBar(",
            ".androidAnchoredPopupMenu(",
            "AndroidSearchHelpDialog(",
            "documentation: .sqliteFTS5",
            "EpubReader.rebuildSearchIndex(identifier: identifier)",
            "guard onAdoptRebuiltReader(rebuiltReader) else",
        ] {
            XCTAssertTrue(searchSource.contains(expected), "Missing EPUB Search contract: \(expected)")
        }

        for forbidden in [
            "NavigationStack {",
            "List {",
            ".searchable(",
            ".navigationTitle(",
            ".sheet(",
            "Menu {",
            "Picker(",
        ] {
            XCTAssertFalse(searchSource.contains(forbidden), "Unexpected native presentation token: \(forbidden)")
        }

        XCTAssertTrue(readerSource.contains("EpubSearchView("))
        XCTAssertTrue(readerSource.contains("surfacePalette: readerThemeSurfacePalette"))
        XCTAssertTrue(readerSource.contains("onBack: { activeReaderDestination = nil }"))
        XCTAssertTrue(readerSource.contains("panePresentationController?.adoptRebuiltEpubReader(rebuiltReader) ?? false"))
    }
}

/** Deterministic localized key-enumeration failure used by chooser result tests. */
private enum GenericKeyListFixtureError: LocalizedError {
    case unavailable

    /// Actionable fixture message projected into the chooser's retry state.
    var errorDescription: String? { "Fixture key backend unavailable." }
}

/** Actor-backed exact loader counter used by cache concurrency tests. */
private actor DictionaryLoaderCounter {
    /// Exact load count by key.
    private var counts: [String: Int] = [:]

    /** Records one loader invocation. */
    func record(_ key: String) {
        counts[key, default: 0] += 1
    }

    /** Returns an immutable count snapshot. */
    func snapshot() -> [String: Int] {
        counts
    }
}
