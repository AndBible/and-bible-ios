// AndroidModuleBackupSettingsWorkflowTests.swift -- Settings picker and cancellation contracts

import XCTest
import BibleCore
@testable import BibleUI

/**
 Pins the production Settings workflow that selects and stages Android-compatible module backups.
 */
final class AndroidModuleBackupSettingsWorkflowTests: XCTestCase {
    /**
     Verifies Android's unchecked opening state and non-dismissing neutral toggle contract.

     The first neutral action selects every visible exact identity; invoking it again clears every
     row. The selected result must retain visible catalog order rather than Set iteration order.

     Side effects: none; exercises pure production selection helpers.

     Failure modes: A failure means the iOS dialog preselects modules, loses Android identity
     semantics, or implements Select all/none differently from `Dialogs.multiselect`.
     */
    func testExportPickerStartsUncheckedAndNeutralActionTogglesAllThenNone() {
        let rows = [
            installedContent("KJV", family: .swordConfiguration),
            installedContent("WEB", family: .myBible),
        ]

        let initial = AndroidModuleBackupExportSheet.initialSelectedModuleIdentities
        XCTAssertTrue(initial.isEmpty)
        let dialogRows = AndroidModuleBackupExportSheet.multiselectRows(for: rows)

        let selectedAll = AndroidMultiselectDialogContent<SQLiteDocumentIdentity>.toggledAllSelection(
            in: dialogRows,
            selectedIDs: initial
        )
        XCTAssertEqual(
            AndroidModuleBackupExportSheet.selectedModuleNames(
                inDisplayOrder: rows,
                selectedIdentities: selectedAll
            ),
            ["KJV", "WEB"]
        )

        let selectedNone = AndroidMultiselectDialogContent<SQLiteDocumentIdentity>.toggledAllSelection(
            in: dialogRows,
            selectedIDs: selectedAll
        )
        XCTAssertTrue(selectedNone.isEmpty)
    }

    /**
     Verifies the module row uses Android's single parenthesized label rather than invented family
     metadata or a split native-iOS title/detail row.

     Side effects: Resolves the active localization for Android's shared format key.

     Failure modes: A failure means the visible label no longer follows
     `something_with_parenthesis(name, "initials, language")`.
     */
    func testExportPickerRowTitleMatchesAndroidVisibleLabelContract() {
        let row = AndroidModuleBackupInstalledContent(
            initials: "WEB",
            displayName: "World English Bible",
            language: "en",
            family: .myBible
        )

        XCTAssertEqual(
            AndroidModuleBackupExportSheet.moduleRowTitle(for: row),
            "World English Bible (WEB, en)"
        )
    }

    /**
     Verifies the real picker preserves canonical catalog order and Android identity semantics.

     Canonically equivalent Unicode spellings must remain distinct because Android compares Java
     UTF-16 strings without normalization. Every supported content family participates in the same
     selection path, and the callback order must follow the visible catalog rather than `Set` order.
     */
    func testExportPickerPreservesAllFamilyDisplayOrderAndExactAndroidIdentities() {
        let composed = "Caf\u{00E9}"
        let decomposed = "Cafe\u{0301}"
        let rows = [
            installedContent(composed, family: .swordConfiguration),
            installedContent(decomposed, family: .myBible),
            installedContent("MYSWORD", family: .mySword),
            installedContent("ESWORD", family: .eSword),
            installedContent("EPUB", family: .epub),
            installedContent("FONT", family: .ttf),
            installedContent("BGIMG_image", family: .background),
            installedContent("PROMPT_prompt", family: .prompts),
        ]
        let selected = Set([
            SQLiteDocumentIdentity(decomposed),
            SQLiteDocumentIdentity("ESWORD"),
            SQLiteDocumentIdentity("FONT"),
            SQLiteDocumentIdentity("PROMPT_prompt"),
        ])

        XCTAssertNotEqual(SQLiteDocumentIdentity(composed), SQLiteDocumentIdentity(decomposed))
        XCTAssertEqual(
            AndroidModuleBackupExportSheet.selectedModuleNames(
                inDisplayOrder: rows,
                selectedIdentities: selected
            ),
            [decomposed, "ESWORD", "FONT", "PROMPT_prompt"]
        )
    }

    /**
     Verifies cancelling a provider copy removes its partially written staging archive.

     A synchronous observer pauses the production copier after its only chunk write. The test
     cancels at that exact event boundary, then releases the copier so its next cooperative
     cancellation check must remove the destination before propagating `CancellationError`.

     Side effects: Creates and removes a bounded temporary archive pair.

     Failure modes: A failure means cancellation no longer reaches the production cleanup path, or
     the staging archive can survive after the Settings operation is cancelled.
     */
    func testProviderArchiveCopyCancellationRemovesPartialOutput() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("android-module-picker-test-\(UUID().uuidString)", isDirectory: true)
        let sourceURL = root.appendingPathComponent("provider.abmd.zip")
        let destinationURL = root.appendingPathComponent("staged.abmd.zip")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0xA5, count: 64 * 1_024).write(to: sourceURL, options: .atomic)

        let reachedWrite = DispatchSemaphore(value: 0)
        let resumeCopy = DispatchSemaphore(value: 0)
        let task = Task.detached {
            try AndroidModuleBackupArchiveFileStager.copy(
                from: sourceURL,
                to: destinationURL,
                didWriteChunk: { byteCount in
                    guard byteCount > 0 else { return }
                    reachedWrite.signal()
                    resumeCopy.wait()
                }
            )
        }

        XCTAssertEqual(
            reachedWrite.wait(timeout: .now() + 5),
            .success,
            "Production copy never reached its deterministic write checkpoint"
        )
        task.cancel()
        resumeCopy.signal()
        do {
            try await task.value
            XCTFail("Expected cooperative cancellation")
        } catch is CancellationError {
            // Expected: the stager removes the partial destination before propagating cancellation.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    /**
     Guards retained task ownership at the private SwiftUI call sites.

     The behavioral copy test pins cancellation below the view boundary. This wiring assertion pins
     the complementary guarantee that replacement and teardown cancel detached workers and that an
     older task cannot clear the operation identity owned by its replacement.
     */
    func testSettingsRetainsAndInvalidatesArchiveWorkersByOperationIdentity() throws {
        let source = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Settings/ImportExportView.swift"
        )

        XCTAssertTrue(source.contains("@State private var androidModuleBackupExportTask"))
        XCTAssertTrue(source.contains("@State private var androidModuleBackupRestoreTask"))
        XCTAssertTrue(source.contains("@State private var androidModuleBackupExportOperationID"))
        XCTAssertTrue(source.contains("@State private var androidModuleBackupRestoreOperationID"))
        XCTAssertTrue(source.contains("withTaskCancellationHandler"))
        XCTAssertTrue(source.contains("worker.cancel()"))
        XCTAssertTrue(source.contains("androidModuleBackupExportOperationID == operationID"))
        XCTAssertTrue(source.contains("androidModuleBackupRestoreOperationID == operationID"))
        XCTAssertTrue(source.contains("AndroidModuleBackupArchiveFileStager.copy"))
        XCTAssertTrue(source.contains(".onDisappear"))
        XCTAssertTrue(source.contains("androidModuleBackupExportTask?.cancel()"))
        XCTAssertTrue(source.contains("androidModuleBackupRestoreTask?.cancel()"))
        XCTAssertTrue(source.contains("isExportingAndroidModuleBackup = false"))
        XCTAssertTrue(source.contains("isRestoringAndroidModuleBackup = false"))
    }

    /**
     Creates one real canonical catalog row for picker-selection assertions.

     - Parameters:
       - initials: Exact Android identity retained without Unicode normalization.
       - family: Installed-content family represented by the picker row.
     - Returns: Canonical production picker row.
     - Side effects: none.
     - Failure modes: none.
     */
    private func installedContent(
        _ initials: String,
        family: AndroidModuleBackupContentFamily
    ) -> AndroidModuleBackupInstalledContent {
        AndroidModuleBackupInstalledContent(
            initials: initials,
            displayName: initials,
            language: "en",
            family: family
        )
    }
}
