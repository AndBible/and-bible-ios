import XCTest
@testable import BibleUI

/**
 Verifies the reader startup setup prompt policy independently from the app-host lifecycle.

 These tests protect the Android-parity startup contract: no-Bible setup remains blocking and
 repeatable, while iOS' bundled fallback Bible does not suppress the one-time recommended setup
 entry point. Failures mean first-run users can again lose the discoverable Easy Start/Downloads
 path because module presence and setup completion were conflated.
 */
final class StartupDocumentSetupPromptPolicyTests: XCTestCase {
    /**
     No-Bible module state must take priority over the informational first-run setup marker.

     Android keeps users on its first-download setup surface while no Bible is installed. iOS mirrors
     that as a startup prompt even if the user previously skipped the recommended setup message.
     */
    func testNoBiblePromptTakesPriorityOverHandledFirstRunSetup() {
        XCTAssertEqual(
            StartupDocumentSetupPromptPolicy.promptReason(
                hasNoBibleModules: true,
                hasHandledFirstRunSetup: true
            ),
            .noBibleModules
        )
    }

    /**
     A bundled fallback Bible must not count as completing first-run setup.

     Fresh iOS installs include KJV so the reader can render immediately, but issue #320 requires a
     discoverable recommended setup path until the user explicitly enters setup or skips it.
     */
    func testFirstRunSetupPromptAppearsWhenBibleExistsButSetupNotHandled() {
        XCTAssertEqual(
            StartupDocumentSetupPromptPolicy.promptReason(
                hasNoBibleModules: false,
                hasHandledFirstRunSetup: false
            ),
            .firstRunSetup
        )
    }

    /**
     The startup setup prompt is suppressed after the user has handled first-run setup.

     This keeps the first-run prompt durable and one-time after the user opens setup/downloads or
     explicitly skips it, while leaving the no-Bible prompt covered by the priority test above.
     */
    func testPromptIsSuppressedWhenBibleExistsAndFirstRunSetupHandled() {
        XCTAssertNil(
            StartupDocumentSetupPromptPolicy.promptReason(
                hasNoBibleModules: false,
                hasHandledFirstRunSetup: true
            )
        )
    }

    /**
     UI tests can explicitly keep their existing seeded-reader startup contract.

     The flag is intentionally opt-in and test-namespaced so production launches still show the
     first-run setup prompt, while hosted route tests that seed reader state do not get blocked by
     the informational prompt.
     */
    func testUITestRuntimeCanTreatFirstRunSetupAsHandledOnlyWhenExplicit() {
        XCTAssertTrue(
            UITestRuntimeConfiguration.isFirstRunDocumentSetupHandled(
                environment: ["UITEST_FIRST_RUN_DOCUMENT_SETUP_HANDLED": "1"],
                arguments: []
            )
        )
        XCTAssertTrue(
            UITestRuntimeConfiguration.isFirstRunDocumentSetupHandled(
                environment: [:],
                arguments: ["-UITEST_FIRST_RUN_DOCUMENT_SETUP_HANDLED"]
            )
        )
        XCTAssertFalse(
            UITestRuntimeConfiguration.isFirstRunDocumentSetupHandled(
                environment: ["UITEST_FIRST_RUN_DOCUMENT_SETUP_HANDLED": "0"],
                arguments: []
            )
        )
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
     English first-run setup exposes Android's setup actions without using a transient dialog.

     Android's first-download surface exposes English-only Easy Start, Download, database restore,
     and file import actions as a setup screen. iOS keeps the same discoverable action set while
     adding Skip only for the non-blocking bundled-Bible first-run case.
     */
    func testFirstRunEnglishPresentationUsesAndroidSetupActionsWithSkip() {
        let presentation = StartupDocumentSetupPresentation(
            reason: .firstRunSetup,
            isEasyStartAvailable: true
        )

        XCTAssertEqual(
            presentation.actions,
            [.easyStart, .downloadDocuments, .restoreDatabase, .loadDocumentsFromFiles, .skip]
        )
        XCTAssertTrue(presentation.allowsSkip)
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
        XCTAssertNil(StartupDocumentSetupPresentation.Action.skip.restoreImportTarget)
    }
}
