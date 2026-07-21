// AndroidModuleBackupSettingsWorkflowTests.swift -- Settings picker and cancellation contracts

import XCTest
import BibleCore
@testable import BibleUI

/**
 Pins the production Settings workflow that selects and stages Android-compatible module backups.
 */
final class AndroidModuleBackupSettingsWorkflowTests: XCTestCase {
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
     Verifies cancelling a large provider copy removes its partially written staging archive.

     The sparse source keeps fixture setup bounded while the production 64 KiB loop performs real
     reads and writes. Failure means closing the picker or leaving Settings can leave a large orphan
     archive or continue consuming storage after cancellation.
     */
    func testProviderArchiveCopyCancellationRemovesPartialOutput() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("android-module-picker-test-\(UUID().uuidString)", isDirectory: true)
        let sourceURL = root.appendingPathComponent("provider.abmd.zip")
        let destinationURL = root.appendingPathComponent("staged.abmd.zip")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(FileManager.default.createFile(atPath: sourceURL.path, contents: Data()))
        let source = try FileHandle(forWritingTo: sourceURL)
        try source.truncate(atOffset: 1_073_741_824)
        try source.close()

        let task = Task.detached(priority: .userInitiated) {
            try AndroidModuleBackupArchiveFileStager.copy(
                from: sourceURL,
                to: destinationURL
            )
        }
        var observedPartialOutput = false
        for _ in 0..<10_000 {
            if let size = try? destinationURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size > 0 {
                observedPartialOutput = true
                break
            }
            try await Task.sleep(nanoseconds: 100_000)
        }
        XCTAssertTrue(observedPartialOutput, "Production copy never reached its streamed write phase")

        task.cancel()
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
