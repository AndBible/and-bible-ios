// ReaderModuleSwitchCoordinatorTests.swift -- Reader document-switch planner coverage

import XCTest
import BibleCore
import SwordKit
@testable import BibleUI

/**
 Package-level tests for `BibleReaderModuleSwitchCoordinator` switch-plan behavior.

 The suite exercises pure BibleUI planner contracts without the app host, WebView bridge, or
 temporary SWORD fixtures. Failures mean Android-style current-document transitions can regress by
 splitting selected-module persistence from visible-category persistence or by accepting mismatched
 document categories.
 */
final class ReaderModuleSwitchCoordinatorTests: XCTestCase {
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
}
