import XCTest
@testable import BibleUI

/**
 Tests the shared Search-index cleanup sequence used by both installed-module uninstall surfaces.

 The closures append to local memory only, so the suite performs no filesystem or SQLite work. A
 failure means a production route can remove a module before its generated index or skip repository
 errors that must remain user-visible.
 */
final class ModuleSearchIndexUninstallerTests: XCTestCase {
    /**
     Verifies both user-facing SWORD uninstall routes delegate to the index-first coordinator.

     The coordinator's sequencing tests cannot observe private SwiftUI action methods directly, so
     this focused source guard extracts only those two function bodies. A failure means Downloads or
     the reader module picker bypassed cleanup while the shared coordinator tests remained green.
     */
    func testDownloadsAndReaderPickerUseIndexFirstUninstallCoordinator() throws {
        let routes = [
            (
                "Sources/BibleUI/Sources/BibleUI/Downloads/ModuleBrowserView.swift",
                "uninstallModuleAfterCancellingInstall"
            ),
            (
                "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderModulePicker.swift",
                "uninstallInstalledModule"
            ),
        ]

        for (relativePath, functionName) in routes {
            let source = try BibleUITestSourceLocator.source(at: relativePath)
            let function = try BibleUITestSourceLocator.extractFunction(
                named: functionName,
                from: source
            )
            XCTAssertTrue(function.contains("ModuleSearchIndexUninstaller.uninstall("))
            XCTAssertTrue(function.contains("await searchIndexService.deleteIndex(for: moduleName)"))
            XCTAssertTrue(function.contains("repository.uninstallModule(named: moduleName)"))
        }
    }

    /**
     Verifies index deletion completes before repository removal starts for the same initials.

     The ordered event log is deterministic because the coordinator awaits each closure. A failure
     permits reinstalling the same initials while stale rows from the old module remain queryable.
     */
    func testUninstallDeletesSearchIndexBeforeRemovingModule() async throws {
        var events: [String] = []

        try await ModuleSearchIndexUninstaller.uninstall(
            moduleName: "KJV",
            deleteSearchIndex: { moduleName in
                events.append("delete-index:\(moduleName)")
            },
            removeModule: { moduleName in
                events.append("remove-module:\(moduleName)")
            }
        )

        XCTAssertEqual(events, ["delete-index:KJV", "remove-module:KJV"])
    }

    /**
     Verifies repository failures propagate after the best-effort index cleanup has run.

     Android logs index cleanup failures separately but treats document deletion as the authoritative
     uninstall result. A failure means Downloads or the reader picker can report false success.
     */
    func testUninstallPropagatesModuleRemovalFailureAfterIndexCleanup() async {
        var events: [String] = []

        do {
            try await ModuleSearchIndexUninstaller.uninstall(
                moduleName: "KJV",
                deleteSearchIndex: { moduleName in
                    events.append("delete-index:\(moduleName)")
                },
                removeModule: { moduleName in
                    events.append("remove-module:\(moduleName)")
                    throw FixtureError.removalFailed
                }
            )
            XCTFail("Expected repository removal failure")
        } catch {
            XCTAssertEqual(error as? FixtureError, .removalFailed)
        }

        XCTAssertEqual(events, ["delete-index:KJV", "remove-module:KJV"])
    }
}

/// Deterministic repository failure used by uninstall sequencing tests.
private enum FixtureError: Error {
    /// Simulates a repository file-removal failure after index cleanup.
    case removalFailed
}
