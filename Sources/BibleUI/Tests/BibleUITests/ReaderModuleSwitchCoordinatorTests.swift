// ReaderModuleSwitchCoordinatorTests.swift -- Reader document-switch planner coverage

import XCTest
import BibleCore
import SwordKit
@testable import BibleUI

/**
 Package-level tests for `BibleReaderModuleSwitchCoordinator` switch-plan behavior.

 The suite exercises pure planner contracts and transaction behavior against temporary discoverable
 SWORD modules without the app host or WebView bridge. Failures mean Android-style current-document
 transitions can regress by splitting selected-module persistence from visible-category persistence,
 accepting mismatched categories, or committing state before key preflight succeeds.
 */
final class ReaderModuleSwitchCoordinatorTests: BibleUISwordFixtureTestCase {
    /**
     Protects the extracted document-switch category guard used by Android-style current-document
     changes.

     A Bible document switch must not accept a commentary module because that would persist a Bible
     page identity with non-Bible initials. Controller APIs add logging and reload behavior around
     this planner; this package-level contract keeps the category rule isolated from those side
     effects.
     */
    func testRejectsMismatchedDocumentCategory() {
        let coordinator = BibleReaderModuleSwitchCoordinator()

        let result = coordinator.documentSwitchPlan(
            moduleName: "MHC",
            moduleCategory: .commentary,
            targetCategory: .bible
        )

        XCTAssertEqual(
            result,
            .failure(.categoryMismatch(moduleName: "MHC", expected: .bible, actual: .commentary))
        )
    }

    /**
     Protects Android's atomic dictionary document switch persistence contract.

     Selecting a dictionary from the commentary/document chooser updates the visible category and
     selected dictionary together while clearing a stale dictionary key. A failure here means the
     controller could again split module selection from category persistence.
     */
    func testPersistsDictionaryDocumentAndClearsStaleKey() throws {
        let coordinator = BibleReaderModuleSwitchCoordinator()
        let pageManager = PageManager(currentCategoryName: DocumentCategory.bible.pageManagerKey)
        pageManager.dictionaryDocument = "OldDict"
        pageManager.dictionaryKey = "stale-key"

        let plan = try coordinator.documentSwitchPlan(
            moduleName: "BDBT",
            moduleCategory: .dictionary,
            targetCategory: .dictionary
        ).get()

        plan.apply(to: pageManager)

        XCTAssertEqual(plan.category, .dictionary)
        XCTAssertTrue(plan.updatesVisibleCategory)
        XCTAssertEqual(pageManager.currentCategoryName, DocumentCategory.dictionary.pageManagerKey)
        XCTAssertEqual(pageManager.dictionaryDocument, "BDBT")
        XCTAssertNil(pageManager.dictionaryKey)
    }

    /**
     Protects Android's atomic map document switch persistence contract.

     Selecting a map from the document chooser updates the visible category and selected map
     together while clearing stale map entry state. A failure here means map selection can again
     split module selection from category persistence.
     */
    func testPersistsMapDocumentAndClearsStaleKey() throws {
        let coordinator = BibleReaderModuleSwitchCoordinator()
        let pageManager = PageManager(currentCategoryName: DocumentCategory.bible.pageManagerKey)
        pageManager.mapDocument = "OldMap"
        pageManager.mapKey = "stale-key"

        let plan = try coordinator.documentSwitchPlan(
            moduleName: "BibleMap",
            moduleCategory: .map,
            targetCategory: .map
        ).get()

        plan.apply(to: pageManager)

        XCTAssertEqual(plan.category, .map)
        XCTAssertTrue(plan.updatesVisibleCategory)
        XCTAssertEqual(pageManager.currentCategoryName, DocumentCategory.map.pageManagerKey)
        XCTAssertEqual(pageManager.mapDocument, "BibleMap")
        XCTAssertNil(pageManager.mapKey)
    }

    /**
     Protects module-only switching as separate from visible category switching.

     Direct module-switch paths can update the selected module for an inactive category. That must
     remain separate from full current-document chooser paths, which update the selected module and
     visible category together.
     */
    func testModuleOnlyPlanDoesNotChangeVisibleCategory() {
        let coordinator = BibleReaderModuleSwitchCoordinator()
        let pageManager = PageManager(currentCategoryName: DocumentCategory.bible.pageManagerKey)
        pageManager.mapDocument = "OldMap"
        pageManager.mapKey = "stale-map-key"

        let plan = coordinator.moduleOnlySwitchPlan(
            moduleName: "BibleMap",
            targetCategory: .map
        )

        plan.apply(to: pageManager)

        XCTAssertEqual(plan.category, .map)
        XCTAssertFalse(plan.updatesVisibleCategory)
        XCTAssertEqual(pageManager.currentCategoryName, DocumentCategory.bible.pageManagerKey)
        XCTAssertEqual(pageManager.mapDocument, "BibleMap")
        XCTAssertNil(pageManager.mapKey)
    }

    /**
     Protects category-only reload decisions from being hidden inside controller code.

     Switching to the same category should persist the category but not request a WebView reload;
     switching to a different category should request one. The controller remains responsible for
     checking client readiness before actually reloading.
     */
    func testCategoryPlanRequestsReloadOnlyWhenCategoryChanges() {
        let coordinator = BibleReaderModuleSwitchCoordinator()

        let unchanged = coordinator.categorySwitchPlan(from: .bible, to: .bible)
        let changed = coordinator.categorySwitchPlan(from: .bible, to: .commentary)

        XCTAssertFalse(unchanged.shouldReloadContent)
        XCTAssertTrue(changed.shouldReloadContent)
    }

    /**
     Verifies Android's generic key decision retains only an exact target key.

     - Setup: Supplies exact-match, absent-key, missing-current-key, and throwing exact-lookup
       closures while recording validation and snapshot-load calls.
     - Expected result: Exact keys are retained, absent keys require a chooser, and read failures
       remain a failure outcome instead of being treated as absence. Missing/invalid keys preflight a
       successful snapshot while exact matches and validation failures do not enumerate.
     - Failure meaning: Module switches can clear valid keys, suppress the chooser for invalid keys,
       or mutate state after a backend validation error.
     - Side effects: Records exact-lookup and snapshot-load invocation counts only.
     */
    func testGenericKeyResolutionSeparatesExactMissingAndBackendFailure() {
        let coordinator = BibleReaderModuleSwitchCoordinator()
        var lookupCount = 0
        var snapshotLoadCount = 0

        let exact = coordinator.resolveGenericKey(
            currentKey: "shared-key",
            containsExactKey: { key in
                lookupCount += 1
                return key == "shared-key"
            },
            loadKeys: {
                snapshotLoadCount += 1
                return ["shared-key"]
            }
        )
        let absent = coordinator.resolveGenericKey(
            currentKey: "missing-key",
            containsExactKey: { _ in
                lookupCount += 1
                return false
            },
            loadKeys: {
                snapshotLoadCount += 1
                return ["shared-key"]
            }
        )
        let noCurrentKey = coordinator.resolveGenericKey(
            currentKey: nil,
            containsExactKey: { _ in
                lookupCount += 1
                return true
            },
            loadKeys: {
                snapshotLoadCount += 1
                return ["shared-key"]
            }
        )
        let validationFailed = coordinator.resolveGenericKey(
            currentKey: "shared-key",
            containsExactKey: { _ in
                lookupCount += 1
                throw GenericKeyValidationFixtureError.unavailable
            },
            loadKeys: {
                snapshotLoadCount += 1
                return ["shared-key"]
            }
        )

        XCTAssertEqual(exact, .preserve("shared-key"))
        XCTAssertEqual(absent, .requireSelection)
        XCTAssertEqual(noCurrentKey, .requireSelection)
        XCTAssertEqual(validationFailed, .failed(message: "Fixture generic-key backend unavailable."))
        XCTAssertEqual(lookupCount, 3)
        XCTAssertEqual(snapshotLoadCount, 2)
    }

    /**
     Verifies exact keys are preserved across every generic document category.

     - Setup: Uses real discoverable dictionary, general-book, and map modules while injecting an
       exact-key validator that accepts whitespace-sensitive keys.
     - Expected result: Each switch commits the identical key, category, and module once, reloads
       once, and never enumerates chooser keys.
     - Failure meaning: A valid current key can be normalized, cleared, or routed through an
       unnecessary chooser instead of rendering the target document immediately.
     - Side effects: Creates temporary SWORD modules and mutates in-memory pane fixtures.
     */
    func testGenericDocumentSwitchPreservesOnlyExactTargetKeys() throws {
        let manager = try makeGenericModuleManager()
        let coordinator = BibleReaderModuleSwitchCoordinator()
        let cases: [(DocumentCategory, String)] = [
            (.dictionary, "UITestDict"),
            (.generalBook, "UITestGB"),
            (.map, "UITestMap"),
        ]

        for (category, moduleName) in cases {
            let exactKey = "  exact/\(moduleName) key  "
            var validationCount = 0
            var enumerationCount = 0
            let harness = GenericModuleSwitchHarness(
                manager: manager,
                targetCategory: category,
                currentKey: exactKey,
                containsExactKey: { module, key in
                    validationCount += 1
                    XCTAssertEqual(module.info.name, moduleName)
                    return key == exactKey
                },
                loadKeys: { _ in
                    enumerationCount += 1
                    return []
                }
            )

            let outcome = switchGenericDocument(
                category: category,
                moduleName: moduleName,
                coordinator: coordinator,
                context: harness.makeContext()
            )

            XCTAssertEqual(outcome, .switchedPreservingKey)
            XCTAssertEqual(harness.selectedModuleName, moduleName)
            XCTAssertEqual(harness.selectedKey, exactKey)
            XCTAssertEqual(harness.currentCategory, category)
            XCTAssertEqual(harness.persistedModuleName, moduleName)
            XCTAssertEqual(harness.persistedKey, exactKey)
            XCTAssertEqual(harness.pageManager.currentCategoryName, category.pageManagerKey)
            XCTAssertEqual(harness.moduleAssignments, [category])
            XCTAssertEqual(harness.keyAssignments, [category])
            XCTAssertEqual(harness.persistCount, 1)
            XCTAssertEqual(harness.reloadCount, 1)
            XCTAssertEqual(validationCount, 1)
            XCTAssertEqual(enumerationCount, 0)
        }
    }

    /**
     Verifies only genuine missing or empty keys commit a chooser-required switch.

     - Setup: Covers an exact-key miss, an empty string, and a nil key across dictionary,
       general-book, and map modules with successful enumeration preflight.
     - Expected result: Each switch clears the key, persists module/category once, returns the typed
       chooser outcome, and performs no content reload before selection.
     - Failure meaning: The reader can show stale generic content, skip a required chooser, or call
       exact-key validation for a key that does not exist.
     - Side effects: Creates temporary SWORD modules and mutates in-memory pane fixtures.
     */
    func testGenericDocumentSwitchRequiresSelectionWithoutReloadForMissingOrEmptyKeys() throws {
        let manager = try makeGenericModuleManager()
        let coordinator = BibleReaderModuleSwitchCoordinator()
        let cases: [(DocumentCategory, String, String?, Int)] = [
            (.dictionary, "UITestDict", "missing-key", 1),
            (.generalBook, "UITestGB", "", 0),
            (.map, "UITestMap", nil, 0),
        ]

        for (category, moduleName, currentKey, expectedValidationCount) in cases {
            var validationCount = 0
            var enumerationCount = 0
            let harness = GenericModuleSwitchHarness(
                manager: manager,
                targetCategory: category,
                currentKey: currentKey,
                containsExactKey: { _, _ in
                    validationCount += 1
                    return false
                },
                loadKeys: { module in
                    enumerationCount += 1
                    XCTAssertEqual(module.info.name, moduleName)
                    return ["first-chooser-key"]
                }
            )

            let outcome = switchGenericDocument(
                category: category,
                moduleName: moduleName,
                coordinator: coordinator,
                context: harness.makeContext()
            )

            XCTAssertEqual(outcome, .switchedRequiringKeySelection)
            XCTAssertEqual(harness.selectedModuleName, moduleName)
            XCTAssertNil(harness.selectedKey)
            XCTAssertEqual(harness.currentCategory, category)
            XCTAssertEqual(harness.persistedModuleName, moduleName)
            XCTAssertNil(harness.persistedKey)
            XCTAssertEqual(harness.pageManager.currentCategoryName, category.pageManagerKey)
            XCTAssertEqual(harness.persistCount, 1)
            XCTAssertEqual(harness.reloadCount, 0)
            XCTAssertEqual(validationCount, expectedValidationCount)
            XCTAssertEqual(enumerationCount, 1)
        }
    }

    /**
     Verifies validation and chooser-enumeration failures abort before every observable mutation.

     - Setup: Forces an exact-key validation error for a dictionary and an enumeration error after a
       map-key miss while both panes hold non-default module/key/category state.
     - Expected result: Typed retry messages are returned while controller-equivalent state,
       `PageManager`, persistence callbacks, and reload callbacks remain untouched.
     - Failure meaning: A transient SWORD outage can commit a partial document switch or lose the
       user's current key before retry.
     - Side effects: Creates temporary SWORD modules; failed switches perform no fixture mutation.
     */
    func testGenericDocumentSwitchBackendFailuresLeaveAllStateUntouched() throws {
        let manager = try makeGenericModuleManager()
        let coordinator = BibleReaderModuleSwitchCoordinator()
        let validationHarness = GenericModuleSwitchHarness(
            manager: manager,
            targetCategory: .dictionary,
            currentKey: "current-dictionary-key",
            containsExactKey: { _, _ in
                throw GenericKeyValidationFixtureError.unavailable
            },
            loadKeys: { _ in
                XCTFail("Validation failure must abort before enumeration.")
                return []
            }
        )
        let enumerationHarness = GenericModuleSwitchHarness(
            manager: manager,
            targetCategory: .map,
            currentKey: "missing-map-key",
            containsExactKey: { _, _ in false },
            loadKeys: { module in
                throw SwordModuleKeyAccessError.keyListReadFailed(
                    moduleName: module.info.name,
                    errorCode: 7
                )
            }
        )

        let validationOutcome = switchGenericDocument(
            category: .dictionary,
            moduleName: "UITestDict",
            coordinator: coordinator,
            context: validationHarness.makeContext()
        )
        let enumerationOutcome = switchGenericDocument(
            category: .map,
            moduleName: "UITestMap",
            coordinator: coordinator,
            context: enumerationHarness.makeContext()
        )

        XCTAssertEqual(
            validationOutcome,
            .failed(message: "Fixture generic-key backend unavailable.")
        )
        XCTAssertEqual(
            enumerationOutcome,
            .failed(message: "Could not read entries from UITestMap (SWORD error 7).")
        )
        assertFailedSwitchDidNotMutate(validationHarness)
        assertFailedSwitchDidNotMutate(enumerationHarness)
    }

    /**
     Verifies retained generic keys persist through every category-specific PageManager plan.

     - Setup: Applies dictionary, general-book, and map document plans with explicit retained keys.
     - Expected result: Each target module/category and its exact key are written atomically.
     - Failure meaning: Controller validation can succeed while persistence still clears the key,
       causing a chooser to open after relaunch or pane restoration.
     - Side effects: Mutates three in-memory `PageManager` fixtures.
     */
    func testGenericDocumentPlansPersistRetainedKeysForEveryCategory() throws {
        let coordinator = BibleReaderModuleSwitchCoordinator()
        let dictionaryPage = PageManager()
        let generalBookPage = PageManager()
        let mapPage = PageManager()

        try coordinator.documentSwitchPlan(
            moduleName: "TargetDict",
            moduleCategory: .dictionary,
            targetCategory: .dictionary
        ).get().retainingGenericKey("dictionary-key").apply(to: dictionaryPage)
        try coordinator.documentSwitchPlan(
            moduleName: "TargetBook",
            moduleCategory: .generalBook,
            targetCategory: .generalBook
        ).get().retainingGenericKey("general-book-key").apply(to: generalBookPage)
        try coordinator.documentSwitchPlan(
            moduleName: "TargetMap",
            moduleCategory: .map,
            targetCategory: .map
        ).get().retainingGenericKey("map-key").apply(to: mapPage)

        XCTAssertEqual(dictionaryPage.dictionaryDocument, "TargetDict")
        XCTAssertEqual(dictionaryPage.dictionaryKey, "dictionary-key")
        XCTAssertEqual(dictionaryPage.currentCategoryName, DocumentCategory.dictionary.pageManagerKey)
        XCTAssertEqual(generalBookPage.generalBookDocument, "TargetBook")
        XCTAssertEqual(generalBookPage.generalBookKey, "general-book-key")
        XCTAssertEqual(generalBookPage.currentCategoryName, DocumentCategory.generalBook.pageManagerKey)
        XCTAssertEqual(mapPage.mapDocument, "TargetMap")
        XCTAssertEqual(mapPage.mapKey, "map-key")
        XCTAssertEqual(mapPage.currentCategoryName, DocumentCategory.map.pageManagerKey)
    }

    /**
     Creates discoverable empty modules for each generic category used by transaction tests.

     - Returns: A manager rooted at the test's isolated SWORD directory.
     - Side effects: Writes temporary module descriptors/data and registers the root for teardown.
     - Throws: Filesystem errors or manager initialization failure.
     */
    private func makeGenericModuleManager() throws -> SwordManager {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedEmptyRawDictionaryModule(in: modulePath)
        try seedEmptyRawGeneralBookModule(in: modulePath)
        try seedEmptyRawMapModule(in: modulePath)
        return try XCTUnwrap(SwordManager(modulePath: modulePath))
    }

    /**
     Invokes the category-specific generic document switch under test.

     - Parameters:
       - category: Dictionary, general-book, or map category to route.
       - moduleName: Installed target module initials.
       - coordinator: Coordinator whose transaction behavior is under test.
       - context: Recording mutation context for the target pane.
     - Returns: Typed switch outcome from the selected generic route.
     - Side effects: Delegates all state changes to `context`.
     - Failure modes: Unsupported categories record an XCTest failure and return a failure outcome.
     */
    private func switchGenericDocument(
        category: DocumentCategory,
        moduleName: String,
        coordinator: BibleReaderModuleSwitchCoordinator,
        context: BibleReaderModuleSwitchContext
    ) -> BibleReaderGenericModuleSwitchOutcome {
        switch category {
        case .dictionary:
            return coordinator.switchDictionaryDocument(to: moduleName, context: context)
        case .generalBook:
            return coordinator.switchGeneralBookDocument(to: moduleName, context: context)
        case .map:
            return coordinator.switchMapDocument(to: moduleName, context: context)
        default:
            XCTFail("Expected a generic document category, received \(category).")
            return .failed(message: "Unsupported test category.")
        }
    }

    /**
     Asserts a failed transaction retained every controller-equivalent and persisted state value.

     - Parameters:
       - harness: Recording context after a failed switch attempt.
       - file: Calling test's source file for assertion diagnostics.
       - line: Calling test's source line for assertion diagnostics.
     - Side effects: Emits XCTest failures only.
     - Failure modes: Any assertion failure identifies an observable mutation before SWORD preflight
       completed.
     */
    private func assertFailedSwitchDidNotMutate(
        _ harness: GenericModuleSwitchHarness,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(harness.selectedModuleName, harness.originalModuleName, file: file, line: line)
        XCTAssertEqual(harness.selectedKey, harness.originalKey, file: file, line: line)
        XCTAssertEqual(harness.currentCategory, .bible, file: file, line: line)
        XCTAssertEqual(harness.persistedModuleName, harness.originalModuleName, file: file, line: line)
        XCTAssertEqual(harness.persistedKey, harness.originalKey, file: file, line: line)
        XCTAssertEqual(
            harness.pageManager.currentCategoryName,
            DocumentCategory.bible.pageManagerKey,
            file: file,
            line: line
        )
        XCTAssertTrue(harness.moduleAssignments.isEmpty, file: file, line: line)
        XCTAssertTrue(harness.keyAssignments.isEmpty, file: file, line: line)
        XCTAssertEqual(harness.persistCount, 0, file: file, line: line)
        XCTAssertEqual(harness.reloadCount, 0, file: file, line: line)
    }
}

/** Deterministic generic-key backend failure used by coordinator reducer tests. */
private enum GenericKeyValidationFixtureError: LocalizedError {
    case unavailable

    /// Actionable fixture message expected in the public switch outcome.
    var errorDescription: String? { "Fixture generic-key backend unavailable." }
}

/**
 Records every observable mutation a generic coordinator switch can perform.

 The harness uses real `SwordManager` module lookup while injecting deterministic key operations.
 It replaces WebView and SwiftData implementations with counters so tests can prove preflight
 failures are side-effect free.
 */
private final class GenericModuleSwitchHarness {
    /// SWORD manager containing the target generic module.
    private let manager: SwordManager

    /// Generic category whose state the harness projects into the coordinator context.
    private let targetCategory: DocumentCategory

    /// Injected exact-key validation behavior.
    private let containsExactKey: (SwordModule, String) throws -> Bool

    /// Injected chooser-enumeration behavior.
    private let loadKeys: (SwordModule) throws -> [String]

    /// In-memory pane state mutated by persistence plans.
    let pageManager: PageManager

    /// Window that owns `pageManager` for coordinator persistence.
    private let window: Window

    /// Initial selected module used to prove failure paths retain state.
    let originalModuleName: String

    /// Initial selected key used to prove failure paths retain exact optional state.
    let originalKey: String?

    /// Controller-equivalent selected module name.
    private(set) var selectedModuleName: String

    /// Controller-equivalent selected generic key.
    private(set) var selectedKey: String?

    /// Controller-equivalent visible category.
    private(set) var currentCategory: DocumentCategory = .bible

    /// Categories whose active module setter ran.
    private(set) var moduleAssignments: [DocumentCategory] = []

    /// Categories whose current-key setter ran.
    private(set) var keyAssignments: [DocumentCategory] = []

    /// Number of durable persistence callbacks.
    private(set) var persistCount = 0

    /// Number of requested content reloads.
    private(set) var reloadCount = 0

    /**
     Creates a pane recorder with Bible visibility and category-owned generic state.

     - Parameters:
       - manager: Manager used for real target-module resolution.
       - targetCategory: Generic category under test.
       - currentKey: Exact optional key visible before the switch.
       - containsExactKey: Injected throwing validation operation.
       - loadKeys: Injected throwing enumeration operation.
     - Side effects: Creates and attaches an in-memory `PageManager` to a new window.
     - Failure modes: Unsupported categories retain placeholder state for test diagnostics.
     */
    init(
        manager: SwordManager,
        targetCategory: DocumentCategory,
        currentKey: String?,
        containsExactKey: @escaping (SwordModule, String) throws -> Bool,
        loadKeys: @escaping (SwordModule) throws -> [String]
    ) {
        self.manager = manager
        self.targetCategory = targetCategory
        self.containsExactKey = containsExactKey
        self.loadKeys = loadKeys
        originalModuleName = "Original-\(targetCategory.pageManagerKey)"
        originalKey = currentKey
        selectedModuleName = originalModuleName
        selectedKey = currentKey

        let window = Window()
        let pageManager = PageManager(
            id: window.id,
            currentCategoryName: DocumentCategory.bible.pageManagerKey
        )
        switch targetCategory {
        case .dictionary:
            pageManager.dictionaryDocument = originalModuleName
            pageManager.dictionaryKey = currentKey
        case .generalBook:
            pageManager.generalBookDocument = originalModuleName
            pageManager.generalBookKey = currentKey
        case .map:
            pageManager.mapDocument = originalModuleName
            pageManager.mapKey = currentKey
        default:
            break
        }
        window.pageManager = pageManager
        self.window = window
        self.pageManager = pageManager
    }

    /// Category-owned module currently persisted in `pageManager`.
    var persistedModuleName: String? {
        switch targetCategory {
        case .dictionary:
            return pageManager.dictionaryDocument
        case .generalBook:
            return pageManager.generalBookDocument
        case .map:
            return pageManager.mapDocument
        default:
            return nil
        }
    }

    /// Category-owned exact key currently persisted in `pageManager`.
    var persistedKey: String? {
        switch targetCategory {
        case .dictionary:
            return pageManager.dictionaryKey
        case .generalBook:
            return pageManager.generalBookKey
        case .map:
            return pageManager.mapKey
        default:
            return nil
        }
    }

    /**
     Builds the complete coordinator context backed by this recorder.

     - Returns: A synchronous context snapshot with throwing key operations and recording setters.
     - Side effects: None until the coordinator invokes a returned closure.
     - Failure modes: Injected validation/enumeration closures may throw to simulate SWORD failures.
     */
    func makeContext() -> BibleReaderModuleSwitchContext {
        BibleReaderModuleSwitchContext(
            swordManager: manager,
            activeWindow: window,
            clientReady: true,
            currentCategory: currentCategory,
            currentDictionaryKey: targetCategory == .dictionary ? selectedKey : nil,
            currentGeneralBookKey: targetCategory == .generalBook ? selectedKey : nil,
            currentMapKey: targetCategory == .map ? selectedKey : nil,
            containsExactGenericKey: containsExactKey,
            loadGenericKeys: loadKeys,
            setBibleModule: { _, _ in },
            setCommentaryModule: { _, _ in },
            setDictionaryModule: { [weak self] _, name in
                self?.moduleAssignments.append(.dictionary)
                self?.selectedModuleName = name
            },
            setGeneralBookModule: { [weak self] _, name in
                self?.moduleAssignments.append(.generalBook)
                self?.selectedModuleName = name
            },
            setMapModule: { [weak self] _, name in
                self?.moduleAssignments.append(.map)
                self?.selectedModuleName = name
            },
            setDictionaryKey: { [weak self] key in
                self?.keyAssignments.append(.dictionary)
                self?.selectedKey = key
            },
            setGeneralBookKey: { [weak self] key in
                self?.keyAssignments.append(.generalBook)
                self?.selectedKey = key
            },
            setMapKey: { [weak self] key in
                self?.keyAssignments.append(.map)
                self?.selectedKey = key
            },
            setCurrentCategory: { [weak self] category in
                self?.currentCategory = category
            },
            refreshBookList: {},
            moduleBookListCount: { 0 },
            persistState: { [weak self] in
                self?.persistCount += 1
            },
            loadCurrentContent: { [weak self] in
                self?.reloadCount += 1
            }
        )
    }
}
