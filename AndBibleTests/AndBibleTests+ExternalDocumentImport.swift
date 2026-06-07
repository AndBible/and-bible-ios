import XCTest
@testable import BibleUI
import SwordKit
import UniformTypeIdentifiers

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

    /// URLs passed to the TTF font installer.
    private var fontURLs: [(url: URL, displayName: String?)] = []

    /// Number of ZIP archive detector calls.
    private var epubArchiveDetectionCount = 0

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
     Records a TTF font installer call and returns a deterministic font name.

     - Parameters:
       - url: URL routed to the font installer.
       - displayName: Provider filename passed through to preserve Android's display-name behavior.
     - Returns: Stable font name used for feedback assertions.
     - Side effects: Appends the call to the font-call log.
     - Failure modes: This test double does not throw.
     */
    func installFont(from url: URL, displayName: String?) throws -> String {
        lock.lock()
        fontURLs.append((url, displayName))
        lock.unlock()
        return "Gentium"
    }

    /**
     Records an EPUB archive detection pass and classifies the archive as a SWORD ZIP.

     - Parameter url: URL inspected by the ZIP classifier.
     - Returns: `false` so the service continues to the module installer branch.
     - Side effects: Increments the archive-detection count under a lock.
     - Failure modes: This test double cannot fail.
     */
    func detectNonEpubArchive(_ url: URL) -> Bool {
        _ = url
        lock.lock()
        epubArchiveDetectionCount += 1
        lock.unlock()
        return false
    }

    /**
     Returns the recorded installer calls.

     - Returns: Module and EPUB URL arrays captured so far.
     - Side effects: Reads test-double state under a lock.
     - Failure modes: This helper cannot fail.
     */
    func snapshot() -> (
        moduleURLs: [URL],
        epubURLs: [URL],
        fontURLs: [(url: URL, displayName: String?)],
        epubArchiveDetectionCount: Int
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (moduleURLs, epubURLs, fontURLs, epubArchiveDetectionCount)
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
     Creates an external-document import service wired to a thread-safe test probe.

     The helper keeps installer closure construction identical across routing tests and preserves the
     production service's `@Sendable` closure contract.

     - Parameters:
       - probe: Probe that records module, EPUB, and TTF installer calls.
       - epubArchiveDetector: Optional ZIP classifier override for EPUB fallback tests.
     - Returns: Service instance with deterministic installer outputs.
     - Side effects: none during construction.
     - Failure modes: This helper cannot fail.
     */
    private func makeExternalDocumentImportService(
        probe: ExternalDocumentImportProbe,
        epubArchiveDetector: ExternalDocumentImportService.EpubArchiveDetector? = nil
    ) -> ExternalDocumentImportService {
        ExternalDocumentImportService(
            moduleInstaller: { url in try probe.installModule(from: url) },
            epubInstaller: { url in try probe.installEpub(from: url) },
            fontInstaller: { url, displayName in try probe.installFont(from: url, displayName: displayName) },
            epubArchiveDetector: epubArchiveDetector
        )
    }

    /**
     ZIP files are Android's SWORD module package path and must call only the module installer.

     Failure indicates that Files/Mail opens could drift from the Backup & Restore document import
     behavior or that arbitrary ZIP handling stopped using the SWORD repository path.
     */
    func testExternalDocumentImportZipUsesModuleInstaller() {
        let probe = ExternalDocumentImportProbe()
        let service = makeExternalDocumentImportService(probe: probe)
        let url = URL(fileURLWithPath: "/tmp/FinRK.zip")

        let result = service.importDocument(at: url)

        XCTAssertEqual(result, .installedModule(name: "FinRK"))
        XCTAssertEqual(result.feedbackMessage, "Installed module: FinRK")
        XCTAssertEqual(probe.snapshot().moduleURLs, [url])
        XCTAssertEqual(probe.snapshot().epubURLs, [])
        XCTAssertEqual(probe.snapshot().fontURLs.map(\.url), [])
    }

    /**
     EPUB files are imported through the EPUB reader store and must not be treated as SWORD ZIPs.

     Failure indicates that the scene-open path no longer matches the existing Settings document
     import branch for EPUB documents.
     */
    func testExternalDocumentImportEpubUsesEpubInstaller() {
        let probe = ExternalDocumentImportProbe()
        let service = makeExternalDocumentImportService(probe: probe)
        let url = URL(fileURLWithPath: "/tmp/StudyNotes.epub")

        let result = service.importDocument(at: url)

        XCTAssertEqual(result, .installedEpub(title: "Study Notes"))
        XCTAssertEqual(result.feedbackMessage, "Installed EPUB: Study Notes")
        XCTAssertEqual(probe.snapshot().moduleURLs, [])
        XCTAssertEqual(probe.snapshot().epubURLs, [url])
        XCTAssertEqual(probe.snapshot().fontURLs.map(\.url), [])
    }

    /**
     TTF files follow Android's app-owned font installer route.

     Failure indicates that iOS advertises Android's font document type without backing it with the
     same `modulesDir/ttf` install semantics.
     */
    func testExternalDocumentImportTtfUsesFontInstaller() {
        let probe = ExternalDocumentImportProbe()
        let service = makeExternalDocumentImportService(probe: probe)
        let url = URL(fileURLWithPath: "/tmp/custom.ttf")

        let result = service.importDocument(at: url)

        XCTAssertEqual(result, .installedFont(name: "Gentium"))
        XCTAssertEqual(result.feedbackMessage, "Installed font: Gentium")
        XCTAssertEqual(probe.snapshot().moduleURLs, [])
        XCTAssertEqual(probe.snapshot().epubURLs, [])
        XCTAssertEqual(probe.snapshot().fontURLs.map(\.url), [url])
        XCTAssertEqual(probe.snapshot().fontURLs.map(\.displayName), ["custom.ttf"])
    }

    /**
     Provider display names are normalized once before confirmation and TTF installation.

     Failure means iOS document-provider metadata could show whitespace in the Android-style
     confirmation prompt or create drift between the displayed name and installed font metadata.
     */
    func testExternalDocumentImportTrimsProviderDisplayNameForFontInstaller() {
        let probe = ExternalDocumentImportProbe()
        let service = makeExternalDocumentImportService(probe: probe)
        let url = URL(fileURLWithPath: "/tmp/provider-source.ttf")
        let request = ExternalDocumentImportRequest(
            url: url,
            suggestedFileName: "  Folder/Gentium.ttf  \n"
        )

        let result = service.importDocument(request)

        XCTAssertEqual(result, .installedFont(name: "Gentium"))
        XCTAssertEqual(request.displayFileName, "Gentium.ttf")
        XCTAssertEqual(probe.snapshot().fontURLs.map(\.url), [url])
        XCTAssertEqual(probe.snapshot().fontURLs.map(\.displayName), ["Gentium.ttf"])
    }

    /**
     Unsupported extensions return feedback without invoking any installer.

     Failure means the importer could claim a document type it cannot actually install.
     */
    func testExternalDocumentImportUnsupportedDocumentDoesNotCallInstallers() {
        let probe = ExternalDocumentImportProbe()
        let service = makeExternalDocumentImportService(probe: probe)

        let result = service.importDocument(at: URL(fileURLWithPath: "/tmp/custom.txt"))

        XCTAssertEqual(result, .unsupportedFormat(fileExtension: "txt"))
        XCTAssertEqual(result.feedbackMessage, "Error: Unsupported file format (txt)")
        XCTAssertEqual(probe.snapshot().moduleURLs, [])
        XCTAssertEqual(probe.snapshot().epubURLs, [])
        XCTAssertEqual(probe.snapshot().fontURLs.map(\.url), [])
    }

    /**
     Non-file URLs are not importable documents, even when their path looks like a handled type.

     SwiftUI `.onOpenURL` can receive unrelated app links. The shared service must keep the import
     contract file-only so those links do not mutate SWORD, EPUB, or font storage.
     */
    func testExternalDocumentImportNonFileURLDoesNotCallInstallers() throws {
        let probe = ExternalDocumentImportProbe()
        let service = makeExternalDocumentImportService(probe: probe)
        let url = try XCTUnwrap(URL(string: "https://example.invalid/custom.ttf"))

        let result = service.importDocument(at: url)

        XCTAssertEqual(result, .unsupportedFormat(fileExtension: "ttf"))
        XCTAssertEqual(probe.snapshot().moduleURLs, [])
        XCTAssertEqual(probe.snapshot().epubURLs, [])
        XCTAssertEqual(probe.snapshot().fontURLs.map(\.url), [])
    }

    /**
     Generic `public.data` metadata is accepted by the picker but must not identify a font.

     The Settings importer includes `.data` so provider-backed files remain selectable. Routing must
     still rely on specific document types, filename extensions, or archive inspection before
     invoking an installer.
     */
    func testExternalDocumentImportGenericDataContentTypeDoesNotRouteToFontInstaller() {
        let probe = ExternalDocumentImportProbe()
        let service = makeExternalDocumentImportService(probe: probe)
        let url = URL(fileURLWithPath: "/tmp/provider-data.bin")
        let request = ExternalDocumentImportRequest(
            url: url,
            contentTypeIdentifier: UTType.data.identifier
        )

        let result = service.importDocument(request)

        XCTAssertEqual(result, .unsupportedFormat(fileExtension: "bin"))
        XCTAssertEqual(probe.snapshot().moduleURLs, [])
        XCTAssertEqual(probe.snapshot().epubURLs, [])
        XCTAssertEqual(probe.snapshot().fontURLs.map(\.url), [])
    }

    /**
     ZIP-looking EPUB archives are rerouted to the EPUB installer before SWORD module install.

     Android's `installZip` catches EPUB packages that arrive through the ZIP path and calls
     `installEpub`. This test protects that fallback for providers that expose only a ZIP-like URL.
     */
    func testExternalDocumentImportZipEpubFallbackUsesEpubInstaller() {
        let probe = ExternalDocumentImportProbe()
        let service = makeExternalDocumentImportService(
            probe: probe,
            epubArchiveDetector: { _ in true }
        )
        let url = URL(fileURLWithPath: "/tmp/StudyNotes.zip")

        let result = service.importDocument(at: url)

        XCTAssertEqual(result, .installedEpub(title: "Study Notes"))
        XCTAssertEqual(probe.snapshot().moduleURLs, [])
        XCTAssertEqual(probe.snapshot().epubURLs, [url])
        XCTAssertEqual(probe.snapshot().fontURLs.map(\.url), [])
    }

    /**
     ZIP archive classification is cached during a single module-install attempt.

     The default detector reads archive metadata from disk. A failed SWORD install must not trigger a
     second identical ZIP scan before returning the module installer error.
     */
    func testExternalDocumentImportZipModuleFailureDoesNotReinspectArchive() {
        let probe = ExternalDocumentImportProbe()
        let service = ExternalDocumentImportService(
            moduleInstaller: { _ in throw ExternalDocumentImportTestError.rejected },
            epubInstaller: { url in try probe.installEpub(from: url) },
            fontInstaller: { url, displayName in try probe.installFont(from: url, displayName: displayName) },
            epubArchiveDetector: { url in probe.detectNonEpubArchive(url) }
        )

        let result = service.importDocument(at: URL(fileURLWithPath: "/tmp/FinRK.zip"))

        XCTAssertEqual(result, .failed(message: "installer rejected file"))
        XCTAssertEqual(probe.snapshot().epubArchiveDetectionCount, 1)
        XCTAssertEqual(probe.snapshot().epubURLs, [])
    }

    /**
     Multiple import requests are processed in Android `ACTION_SEND_MULTIPLE` order.

     Failure indicates that a multi-file share/open flow could reorder side effects or stop after
     the first handled file.
     */
    func testExternalDocumentImportMultipleDocumentsPreservesOrder() {
        let probe = ExternalDocumentImportProbe()
        let service = makeExternalDocumentImportService(probe: probe)
        let requests = [
            ExternalDocumentImportRequest(url: URL(fileURLWithPath: "/tmp/FinRK.zip")),
            ExternalDocumentImportRequest(url: URL(fileURLWithPath: "/tmp/custom.ttf")),
            ExternalDocumentImportRequest(url: URL(fileURLWithPath: "/tmp/StudyNotes.epub")),
        ]

        let results = service.importDocuments(requests)

        XCTAssertEqual(results, [
            .installedModule(name: "FinRK"),
            .installedFont(name: "Gentium"),
            .installedEpub(title: "Study Notes"),
        ])
        XCTAssertEqual(probe.snapshot().moduleURLs, [requests[0].url])
        XCTAssertEqual(probe.snapshot().fontURLs.map(\.url), [requests[1].url])
        XCTAssertEqual(probe.snapshot().epubURLs, [requests[2].url])
    }

    /**
     Installer failures retain the existing import/export error-prefix surface.

     Failure means handled external documents could fail silently or show a different feedback shape
     than the in-app Backup & Restore importer.
     */
    func testExternalDocumentImportInstallerFailureUsesSharedErrorFeedback() {
        let service = ExternalDocumentImportService(
            moduleInstaller: { _ in throw ExternalDocumentImportTestError.rejected },
            epubInstaller: { _ in "unused" },
            fontInstaller: { _, _ in "unused" }
        )

        let result = service.importDocument(at: URL(fileURLWithPath: "/tmp/invalid.zip"))

        XCTAssertEqual(result, .failed(message: "installer rejected file"))
        XCTAssertEqual(result.feedbackMessage, "Error: installer rejected file")
    }

    /**
     TTF font installation creates Android-shaped addon metadata in the SWORD root.

     Failure means the importer copied a font without making it discoverable as an And Bible addon,
     which would preserve the original iOS parity gap despite accepting the file type.
     */
    func testTtfFontRepositoryInstallsAndroidStyleAddonConfig() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sourceURL = tempDir.appendingPathComponent("SourceGentium.ttf")
        try Data([0x00, 0x01, 0x00, 0x00]).write(to: sourceURL)

        let repository = TtfFontRepository(swordPath: tempDir.path)

        let installed = try repository.installFont(from: sourceURL, displayName: "Gentium.ttf")

        XCTAssertEqual(installed, InstalledTtfFont(fontName: "Gentium", moduleName: "TTF_Gentium", fileName: "Gentium.ttf"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("ttf/Gentium.ttf").path))
        let configURL = tempDir.appendingPathComponent("mods.d/ttf_gentium.conf")
        let config = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(config.contains("[TTF_Gentium]"))
        XCTAssertTrue(config.contains("Category=And Bible"))
        XCTAssertTrue(config.contains("AndBibleProvidesFont=Gentium;Gentium.ttf"))
    }

    /**
     TTF copy failures from unreadable sources surface as read errors.

     This protects the import feedback contract: a missing or inaccessible provider file should not be
     reported as a destination write problem.
     */
    func testTtfFontRepositoryReportsUnreadableSourceWhenCopyFails() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let missingSourceURL = tempDir.appendingPathComponent("Missing.ttf")
        let repository = TtfFontRepository(swordPath: tempDir.path)

        do {
            _ = try repository.installFont(from: missingSourceURL)
            XCTFail("Expected unreadable TTF source to fail")
        } catch TtfFontRepositoryError.cantRead(let fileName) {
            XCTAssertEqual(fileName, "Missing.ttf")
        } catch {
            XCTFail("Expected cantRead, got \(error)")
        }
    }
}
