// BibleUIEpubTestSupport.swift -- low-level EPUB fixtures isolated from production publication APIs

import Foundation
import SwordKit
@testable import BibleCore

/**
 Installs one EPUB fixture into the app-default test library without constructing UI import state.

 - Parameter epubURL: Test-owned archive URL that remains readable for the duration of installation.
 - Returns: Stable fixture identifier used by `EpubReader` open and cleanup calls.
 - Side effects: Acquires the production module-store mutation coordinator, writes one staged EPUB
   generation into the simulator test container, and publishes its current-generation pointer.
 - Throws: Propagates archive, validation, indexing, coordinator, and filesystem failures.
 - Important: This helper exists only in the `BibleUITests` target. It intentionally supplies a
   no-op registry validator so controller tests can seed backend state without restoring the removed
   production bypass. Every caller must delete the returned identifier or reset its app container.
 */
func installDefaultLibraryEpubFixture(epubURL: URL) throws -> String {
    try EpubReader.install(
        epubURL: epubURL,
        moduleStoreRootURL: URL(
            fileURLWithPath: SwordManager.defaultModulePath(),
            isDirectory: true
        ),
        admittingCandidateWith: { _ in }
    )
}
