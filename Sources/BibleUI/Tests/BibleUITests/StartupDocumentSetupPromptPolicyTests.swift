import XCTest
@testable import BibleUI
import SwordKit

/**
 Verifies the reader startup setup prompt policy independently from the app-host lifecycle.

 These tests protect the Android-parity startup contract: reading begins only with a readable Bible,
 locked-only inventory starts an app-owned full credential queue before setup, and iOS must not ship
 a bundled KJV module that creates a separate first-run path. Failures mean iOS has drifted toward
 unauthorized activation, incomplete queue handling, bundled content, or setup-marker behavior that
 Android does not have.
 */
final class StartupDocumentSetupPromptPolicyTests: XCTestCase {
    /**
     Classifies a resolved locked-only Bible inventory for startup authorization.

     - Setup: Supplies one installed encrypted Bible whose fresh metadata has no verified key.
     - Expected result: The startup inventory predicate reports no readable Bible and returns the
       distinct reason consumed by the automatic queue, even though inclusive catalog is non-empty.
     - Failure meaning: Startup can activate encrypted content or collapse issue #389 back into the
       no-Bible path before the app-owned queue receives its input.
     - Side effects: None; the test uses immutable metadata only.
     */
    func testLockedOnlyBibleInventoryRequiresStartupAuthorization() {
        let lockedBible = ModuleInfo(
            name: "LOCKED",
            description: "Locked Bible",
            category: .bible,
            language: "en",
            isEncrypted: true,
            isUnlocked: false
        )

        XCTAssertTrue(
            StartupDocumentSetupPromptPolicy.hasNoReadableBibleModules(in: [lockedBible])
        )
        XCTAssertEqual(
            StartupDocumentSetupPromptPolicy.promptReason(in: [lockedBible]),
            .lockedBibleModules
        )
    }

    /**
     Keeps empty startup inventory distinct from installed encrypted Bibles.

     - Setup: Evaluates an empty inclusive inventory and one locked Bible inventory.
     - Expected result: Empty inventory requires installation while locked inventory exposes the
       distinct automatic-queue input reason.
     - Failure meaning: Locked users can bypass credential authorization or be treated as though no
       installed module exists.
     - Side effects: None; both snapshots use immutable metadata.
     */
    func testStartupPromptReasonDistinguishesEmptyFromLockedOnlyInventory() {
        let lockedBible = ModuleInfo(
            name: "LOCKED",
            description: "Locked Bible",
            category: .bible,
            language: "en",
            isEncrypted: true,
            isUnlocked: false
        )

        XCTAssertEqual(
            StartupDocumentSetupPromptPolicy.promptReason(in: []),
            .noBibleModules
        )
        XCTAssertEqual(
            StartupDocumentSetupPromptPolicy.promptReason(in: [lockedBible]),
            .lockedBibleModules
        )
    }

    /**
     Allows startup as soon as one Bible in an otherwise locked inventory becomes readable.

     - Setup: Supplies one locked Bible plus one unencrypted Bible in stable catalog order.
     - Expected result: The readable Bible satisfies startup without removing the locked row needed
       by the full chooser and Downloads.
     - Failure meaning: The fail-closed locked-only route can trap users on setup despite a valid
       reader fallback.
     - Side effects: None; the test uses immutable metadata only.
     */
    func testReadableBibleSuppressesSetupAlongsideLockedInventory() {
        let lockedBible = ModuleInfo(
            name: "LOCKED",
            description: "Locked Bible",
            category: .bible,
            language: "en",
            isEncrypted: true,
            isUnlocked: false
        )
        let readableBible = ModuleInfo(
            name: "KJV",
            description: "King James Version",
            category: .bible,
            language: "en"
        )

        XCTAssertFalse(
            StartupDocumentSetupPromptPolicy.hasNoReadableBibleModules(
                in: [lockedBible, readableBible]
            )
        )
        XCTAssertNil(
            StartupDocumentSetupPromptPolicy.promptReason(
                in: [lockedBible, readableBible]
            )
        )
    }

    /**
     Models the fresh access transition consumed after the full startup queue completes.

     - Setup: Evaluates the same encrypted Bible first locked and then unlocked in a new metadata
       snapshot, matching final manager inventory after every initial locked row was processed.
     - Expected result: The first evaluation remains blocking with `.lockedBibleModules`; the next
       resolved snapshot clears setup and permits the reader.
     - Failure meaning: A successful unlock can leave startup stuck or clear it from stale metadata.
     - Side effects: None; real manager cipher verification is covered by `SwordManagerTests`.
     */
    func testFreshUnlockedSnapshotClearsLockedOnlyStartupSetup() {
        let lockedBible = ModuleInfo(
            name: "LOCKED",
            description: "Locked Bible",
            category: .bible,
            language: "en",
            isEncrypted: true,
            isUnlocked: false
        )
        let unlockedBible = ModuleInfo(
            name: "LOCKED",
            description: "Locked Bible",
            category: .bible,
            language: "en",
            isEncrypted: true,
            isUnlocked: true
        )

        XCTAssertEqual(
            StartupDocumentSetupPromptPolicy.evaluation(modules: [lockedBible]),
            .init(promptReason: .lockedBibleModules, didEvaluateInventory: true)
        )
        XCTAssertEqual(
            StartupDocumentSetupPromptPolicy.evaluation(modules: [unlockedBible]),
            .init(promptReason: nil, didEvaluateInventory: true)
        )
    }

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
     Locked-only setup matches Android's first-download actions after the automatic queue finishes.

     - Setup: Builds a non-English locked-only presentation so Easy Start does not affect ordering.
     - Expected result: Download, restore, and import remain available without an iOS-only manual
       unlock row; Skip remains unavailable.
     - Failure meaning: iOS has invented a post-queue action that Android's `showFirstLayout()` does
       not expose, or has lost one of Android's recovery routes.
     - Side effects: None.
     */
    func testLockedOnlyPresentationMatchesAndroidSetupAfterQueueExhaustion() {
        let presentation = StartupDocumentSetupPresentation(
            reason: .lockedBibleModules,
            isEasyStartAvailable: false
        )

        XCTAssertEqual(
            presentation.actions,
            [
                .downloadDocuments,
                .restoreDatabase,
                .loadDocumentsFromFiles,
            ]
        )
        XCTAssertFalse(presentation.allowsSkip)
        XCTAssertTrue(presentation.usesReaderStackSurface)
    }

    /**
     Guards automatic startup-queue wiring without changing the ordinary inclusive picker.

     - Setup: Extracts startup evaluation/completion plus the queue and ordinary picker sources.
     - Expected result: Locked-only evaluation starts the automatic queue, the queue reuses shared
       passphrase behavior, final reconciliation occurs after queue completion, and setup/picker do
       not expose startup-specific routing callbacks.
     - Failure meaning: Startup can regress to an extra-tap-only picker flow, stop reconciling fresh
       access, or fork credential validation away from the ordinary picker.
     - Side effects: Reads package source only.
     */
    func testLockedOnlyStartupUsesSharedUnlockBehaviorWithoutSpecialPickerRouting() throws {
        let readerSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderView.swift"
        )
        let pickerSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderModulePicker.swift"
        )
        let setupSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Bible/StartupDocumentSetupView.swift"
        )
        let queueSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Bible/StartupLockedBibleUnlockQueue.swift"
        )
        let evaluateSource = try BibleUITestSourceLocator.extractFunction(
            named: "evaluateStartupDownloadPromptIfNeeded",
            from: readerSource
        )
        let completionSource = try BibleUITestSourceLocator.extractFunction(
            named: "completeStartupLockedBibleUnlockQueue",
            from: readerSource
        )

        XCTAssertFalse(setupSource.contains("unlockInstalledBible"))
        XCTAssertFalse(setupSource.contains("localized: \"enter_module_passphrase\""))
        XCTAssertFalse(setupSource.contains("startup_locked_bibles_message"))
        XCTAssertTrue(evaluateSource.contains("beginStartupLockedBibleUnlockQueueIfNeeded"))
        XCTAssertTrue(queueSource.contains("ModuleUnlockActionCoordinator.submit"))
        XCTAssertTrue(queueSource.contains("ModulePickerUnlockDialog"))
        XCTAssertTrue(queueSource.contains("localized: \"enter_module_passphrase\""))
        XCTAssertTrue(completionSource.contains("StartupDocumentSetupPromptPolicy.evaluation"))
        XCTAssertTrue(pickerSource.contains("ModuleUnlockActionCoordinator.submit"))
        XCTAssertFalse(readerSource.contains("presentStartupLockedBiblePicker"))
        XCTAssertFalse(pickerSource.contains("onBibleSelected"))
        XCTAssertFalse(readerSource.contains("controller.presentStartupUnlock"))
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
