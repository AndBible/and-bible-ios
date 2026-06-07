import XCTest
@testable import BibleUI

/**
 Thread-safe probe for the injectable external document installers.

 The production service accepts `@Sendable` closures because app-open handling can call it from a
 detached task. The probe records synchronous calls behind a lock so tests can assert the routing
 contract without depending on real SWORD or EPUB file contents.
 */
private final class ExternalDocumentImportProbe: @unchecked Sendable {
    /// Lock protecting recorded installer URLs.
    private let lock = NSLock()

    /// URLs passed to the module installer.
    private var moduleURLs: [URL] = []

    /// URLs passed to the EPUB installer.
    private var epubURLs: [URL] = []

    /**
     Records a SWORD module installer call and returns a deterministic module name.

     - Parameter url: URL routed to the module installer.
     - Returns: Stable module name used for feedback assertions.
     - Side effects: Appends `url` to the module-call log.
     - Failure modes: This test double does not throw.
     */
    func installModule(from url: URL) throws -> String {
        lock.lock()
        moduleURLs.append(url)
        lock.unlock()
        return "FinRK"
    }

    /**
     Records an EPUB installer call and returns a deterministic document title.

     - Parameter url: URL routed to the EPUB installer.
     - Returns: Stable EPUB title used for feedback assertions.
     - Side effects: Appends `url` to the EPUB-call log.
     - Failure modes: This test double does not throw.
     */
    func installEpub(from url: URL) throws -> String {
        lock.lock()
        epubURLs.append(url)
        lock.unlock()
        return "Study Notes"
    }

    /**
     Returns the recorded installer calls.

     - Returns: Module and EPUB URL arrays captured so far.
     - Side effects: Reads test-double state under a lock.
     - Failure modes: This helper cannot fail.
     */
    func snapshot() -> (moduleURLs: [URL], epubURLs: [URL]) {
        lock.lock()
        defer { lock.unlock() }
        return (moduleURLs, epubURLs)
    }
}

/**
 Error thrown by installer test doubles when validating failure feedback.

 The localized description is deterministic so the service's shared error-prefix formatting can be
 asserted without depending on platform-specific NSError text.
 */
private enum ExternalDocumentImportTestError: LocalizedError {
    /// Simulates an installer rejecting a handled document.
    case rejected

    /// User-visible error body returned to the service.
    var errorDescription: String? {
        "installer rejected file"
    }
}

extension AndBibleTests {
    /**
     ZIP files are Android's SWORD module package path and must call only the module installer.

     Failure indicates that Files/Mail opens could drift from the Backup & Restore document import
     behavior or that arbitrary ZIP handling stopped using the SWORD repository path.
     */
    func testExternalDocumentImportZipUsesModuleInstaller() {
        let probe = ExternalDocumentImportProbe()
        let service = ExternalDocumentImportService(
            moduleInstaller: probe.installModule(from:),
            epubInstaller: probe.installEpub(from:)
        )
        let url = URL(fileURLWithPath: "/tmp/FinRK.zip")

        let result = service.importDocument(at: url)

        XCTAssertEqual(result, .installedModule(name: "FinRK"))
        XCTAssertEqual(result.feedbackMessage, "Installed module: FinRK")
        XCTAssertEqual(probe.snapshot().moduleURLs, [url])
        XCTAssertEqual(probe.snapshot().epubURLs, [])
    }

    /**
     EPUB files are imported through the EPUB reader store and must not be treated as SWORD ZIPs.

     Failure indicates that the scene-open path no longer matches the existing Settings document
     import branch for EPUB documents.
     */
    func testExternalDocumentImportEpubUsesEpubInstaller() {
        let probe = ExternalDocumentImportProbe()
        let service = ExternalDocumentImportService(
            moduleInstaller: probe.installModule(from:),
            epubInstaller: probe.installEpub(from:)
        )
        let url = URL(fileURLWithPath: "/tmp/StudyNotes.epub")

        let result = service.importDocument(at: url)

        XCTAssertEqual(result, .installedEpub(title: "Study Notes"))
        XCTAssertEqual(result.feedbackMessage, "Installed EPUB: Study Notes")
        XCTAssertEqual(probe.snapshot().moduleURLs, [])
        XCTAssertEqual(probe.snapshot().epubURLs, [url])
    }

    /**
     Unsupported extensions return feedback without invoking either installer.

     Android declares TTF MIME types, but iOS has no app-owned font install path yet. This test keeps
     the iOS service honest by rejecting those files until a real font importer exists.
     */
    func testExternalDocumentImportUnsupportedDocumentDoesNotCallInstallers() {
        let probe = ExternalDocumentImportProbe()
        let service = ExternalDocumentImportService(
            moduleInstaller: probe.installModule(from:),
            epubInstaller: probe.installEpub(from:)
        )

        let result = service.importDocument(at: URL(fileURLWithPath: "/tmp/custom.ttf"))

        XCTAssertEqual(result, .unsupportedFormat(fileExtension: "ttf"))
        XCTAssertEqual(result.feedbackMessage, "Error: Unsupported file format (ttf)")
        XCTAssertEqual(probe.snapshot().moduleURLs, [])
        XCTAssertEqual(probe.snapshot().epubURLs, [])
    }

    /**
     Installer failures retain the existing import/export error-prefix surface.

     Failure means handled external documents could fail silently or show a different feedback shape
     than the in-app Backup & Restore importer.
     */
    func testExternalDocumentImportInstallerFailureUsesSharedErrorFeedback() {
        let service = ExternalDocumentImportService(
            moduleInstaller: { _ in throw ExternalDocumentImportTestError.rejected },
            epubInstaller: { _ in "unused" }
        )

        let result = service.importDocument(at: URL(fileURLWithPath: "/tmp/invalid.zip"))

        XCTAssertEqual(result, .failed(message: "installer rejected file"))
        XCTAssertEqual(result.feedbackMessage, "Error: installer rejected file")
    }
}
