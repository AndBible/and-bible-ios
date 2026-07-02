import XCTest
@testable import BibleUI

/**
 Verifies the reader startup setup prompt policy independently from the app-host lifecycle.

 These tests protect the Android-parity startup contract: setup appears only while no Bible module
 is installed, and iOS must not ship a bundled KJV module that creates a separate first-run path.
 Failures mean iOS has drifted back toward bundled-content or setup-marker behavior that Android
 does not have.
 */
final class StartupDocumentSetupPromptPolicyTests: XCTestCase {
    /**
     Unresolved Bible inventory does not complete startup setup evaluation.

     Android's first-download gate is based on a resolved `SwordDocumentFacade.bibles` snapshot. If
     iOS cannot yet resolve module inventory because the reader controller is still registering or
     `SwordManager` is temporarily unavailable, the startup evaluator must stay pending so a later
     controller-registration pass can retry.
     */
    func testUnresolvedBibleInventoryKeepsStartupEvaluationPending() {
        let evaluation = StartupDocumentSetupPromptPolicy.evaluation(hasNoBibleModules: nil)

        XCTAssertNil(evaluation.promptReason)
        XCTAssertFalse(evaluation.didEvaluateInventory)
    }

    /**
     Resolved no-Bible inventory completes evaluation with Android's blocking setup reason.

     This keeps the no-Bible state distinct from unresolved inventory: both have no usable Bible at
     the moment, but only a resolved empty Bible list should present setup.
     */
    func testResolvedNoBibleInventoryCompletesEvaluationWithSetupPrompt() {
        let evaluation = StartupDocumentSetupPromptPolicy.evaluation(hasNoBibleModules: true)

        XCTAssertEqual(evaluation.promptReason, .noBibleModules)
        XCTAssertTrue(evaluation.didEvaluateInventory)
    }

    /**
     Resolved installed-Bible inventory completes evaluation without a prompt.

     Android goes straight to the reader when at least one Bible is installed. iOS mirrors that
     resolved state without retrying or showing an informational first-run setup prompt.
     */
    func testResolvedBibleInventoryCompletesEvaluationWithoutPrompt() {
        let evaluation = StartupDocumentSetupPromptPolicy.evaluation(hasNoBibleModules: false)

        XCTAssertNil(evaluation.promptReason)
        XCTAssertTrue(evaluation.didEvaluateInventory)
    }

    /**
     No-Bible module state opens Android's first-download setup route.

     Android keeps users on its first-download setup surface while no Bible is installed. iOS mirrors
     that predicate directly instead of relying on bundled fallback content.
     */
    func testNoBiblePromptMatchesAndroidFirstDownloadGate() {
        XCTAssertEqual(
            StartupDocumentSetupPromptPolicy.promptReason(
                hasNoBibleModules: true
            ),
            .noBibleModules
        )
    }

    /**
     Existing Bible modules suppress startup setup even when no iOS first-run marker exists.

     Android does not have a one-time "first-run setup handled" flag for users who already have a
     Bible; it goes straight to the main reader when `SwordDocumentFacade.bibles` is not empty.

     Failure means existing users who already installed documents will see Easy Start again when an
     app update adds or resets an iOS-only handled flag.
     */
    func testBiblePresenceSuppressesStartupSetupEvenWhenFirstRunMarkerAbsent() {
        XCTAssertNil(
            StartupDocumentSetupPromptPolicy.promptReason(
                hasNoBibleModules: false
            )
        )
    }

    /**
     The app target must not copy bundled SWORD modules into the application bundle.

     Android ships without KJV Bible text and Easy Start downloads recommended defaults only after
     the user chooses that route. The iOS project file is source-inspected here because the SWORD
     files would otherwise be copied by Xcode before runtime code can observe the app bundle.

     Failure means iOS is again installing KJV by packaging `AndBible/Resources/sword`.
     */
    func testAppProjectDoesNotBundleSwordModules() throws {
        let project = try BibleUITestSourceLocator.source(at: "AndBible.xcodeproj/project.pbxproj")
        XCTAssertFalse(project.contains("Resources/sword"))
        XCTAssertFalse(project.contains("sword in Resources"))
    }

    /**
     Held Downloads installs require both UI-test exports and an explicit module match.

     The downloads row-order smoke uses this fixture hook to keep one row in Android's
     `BEING_INSTALLED` state without relying on a real network. Requiring detailed accessibility
     exports and a named module keeps the hook unavailable to production launches and unrelated UI
     tests.
     */
    func testUITestRuntimeHeldDownloadInstallRequiresExportAndModuleMatch() {
        XCTAssertTrue(
            UITestRuntimeConfiguration.isDownloadInstallHeld(
                for: "UITESTDLWARN",
                environment: [
                    "UITEST_ENABLE_DETAILED_ACCESSIBILITY_EXPORTS": "1",
                    "UITEST_HELD_DOWNLOAD_MODULES": "OTHER, UITESTDLWARN",
                ],
                arguments: []
            )
        )
        XCTAssertTrue(
            UITestRuntimeConfiguration.isDownloadInstallHeld(
                for: "UITESTDLWARN",
                environment: [:],
                arguments: [
                    "-UITEST_ENABLE_DETAILED_ACCESSIBILITY_EXPORTS",
                    "-UITEST_HELD_DOWNLOAD_MODULES",
                    "UITESTDLWARN",
                ]
            )
        )
        XCTAssertFalse(
            UITestRuntimeConfiguration.isDownloadInstallHeld(
                for: "UITESTDLWARN",
                environment: ["UITEST_HELD_DOWNLOAD_MODULES": "UITESTDLWARN"],
                arguments: []
            )
        )
        XCTAssertFalse(
            UITestRuntimeConfiguration.isDownloadInstallHeld(
                for: "UITESTDLWARN",
                environment: [
                    "UITEST_ENABLE_DETAILED_ACCESSIBILITY_EXPORTS": "1",
                    "UITEST_HELD_DOWNLOAD_MODULES": "OTHER",
                ],
                arguments: []
            )
        )
    }

    /**
     English no-Bible setup exposes Android's setup actions without using a transient dialog.

     Android's first-download surface exposes English-only Easy Start, Download, database restore,
     and file import actions as a setup screen.
     */
    func testNoBibleEnglishPresentationUsesAndroidSetupActionsWithoutSkip() {
        let presentation = StartupDocumentSetupPresentation(
            reason: .noBibleModules,
            isEasyStartAvailable: true
        )

        XCTAssertEqual(
            presentation.actions,
            [.easyStart, .downloadDocuments, .restoreDatabase, .loadDocumentsFromFiles]
        )
        XCTAssertFalse(presentation.allowsSkip)
        XCTAssertTrue(presentation.usesReaderStackSurface)
    }

    /**
     Required no-Bible setup remains blocking while still exposing Android's setup entry points.

     Skip is intentionally absent here because Android keeps users on first-download setup until a
     readable Bible/document path is installed.
     */
    func testNoBiblePresentationUsesBlockingAndroidSetupActionsWithoutSkip() {
        let presentation = StartupDocumentSetupPresentation(
            reason: .noBibleModules,
            isEasyStartAvailable: false
        )

        XCTAssertEqual(
            presentation.actions,
            [.downloadDocuments, .restoreDatabase, .loadDocumentsFromFiles]
        )
        XCTAssertFalse(presentation.allowsSkip)
        XCTAssertTrue(presentation.usesReaderStackSurface)
    }

    /**
     Startup file actions target the same Android BackupActivity categories as their button labels.

     Android's first-download Restore button opens database restore, while Load Documents From Files
     opens the document/module loader. Keeping this mapping explicit prevents the iOS startup page
     from routing both buttons through an indistinct Backup & Restore landing screen.
     */
    func testStartupFileActionsResolveSpecificRestoreImportTargets() {
        XCTAssertEqual(StartupDocumentSetupPresentation.Action.restoreDatabase.restoreImportTarget, .database)
        XCTAssertEqual(StartupDocumentSetupPresentation.Action.loadDocumentsFromFiles.restoreImportTarget, .documents)
        XCTAssertNil(StartupDocumentSetupPresentation.Action.downloadDocuments.restoreImportTarget)
        XCTAssertNil(StartupDocumentSetupPresentation.Action.easyStart.restoreImportTarget)
    }
}
