import XCTest
import BibleCore
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

    /// URLs passed to the Android module-backup installer.
    private var androidModuleBackupURLs: [URL] = []

    /// URLs passed to the Android module-backup archive detector.
    private var androidModuleBackupDetectionURLs: [URL] = []

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
     Records an Android module-backup installer call and returns a deterministic restore report.

     - Parameter url: URL routed to the Android module-backup installer.
     - Returns: Stable restore report used for feedback and routing assertions.
     - Side effects: Appends `url` to the Android module-backup call log.
     - Failure modes: This test double does not throw.
     */
    func installAndroidModuleBackup(from url: URL) throws -> AndroidModuleBackupRestoreReport {
        lock.lock()
        androidModuleBackupURLs.append(url)
        lock.unlock()
        return AndroidModuleBackupRestoreReport(
            installedModuleNames: ["ESV2001", "ESV2011"],
            installedEntryCount: 14,
            skippedUnsupportedEntryPaths: []
        )
    }

    /**
     Records Android module-backup detection and classifies the archive as a backup.

     - Parameter url: ZIP URL inspected before generic module installation.
     - Returns: `true` so the service routes the file to the Android backup installer.
     - Side effects: Appends `url` to the Android module-backup detector log.
     - Failure modes: This test double cannot fail.
     */
    func detectAndroidModuleBackup(_ url: URL) -> Bool {
        lock.lock()
        androidModuleBackupDetectionURLs.append(url)
        lock.unlock()
        return true
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
        androidModuleBackupURLs: [URL],
        androidModuleBackupDetectionURLs: [URL],
        epubArchiveDetectionCount: Int
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (
            moduleURLs,
            epubURLs,
            fontURLs,
            androidModuleBackupURLs,
            androidModuleBackupDetectionURLs,
            epubArchiveDetectionCount
        )
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
       - androidModuleBackupDetector: Optional archive classifier override for renamed backup ZIPs.
       - epubArchiveDetector: Optional ZIP classifier override for EPUB fallback tests.
     - Returns: Service instance with deterministic installer outputs.
     - Side effects: none during construction.
     - Failure modes: This helper cannot fail.
     */
    private func makeExternalDocumentImportService(
        probe: ExternalDocumentImportProbe,
        androidModuleBackupDetector: ExternalDocumentImportService.AndroidModuleBackupDetector? = nil,
        epubArchiveDetector: ExternalDocumentImportService.EpubArchiveDetector? = nil
    ) -> ExternalDocumentImportService {
        ExternalDocumentImportService(
            moduleInstaller: { url in try probe.installModule(from: url) },
            epubInstaller: { url in try probe.installEpub(from: url) },
            fontInstaller: { url, displayName in try probe.installFont(from: url, displayName: displayName) },
            androidModuleBackupInstaller: { url in try probe.installAndroidModuleBackup(from: url) },
            androidModuleBackupDetector: androidModuleBackupDetector,
            epubArchiveDetector: epubArchiveDetector
        )
    }

    /**
     ZIP files are Android's SWORD module package path and must call only the module installer.

     Android reports successful `InstallZip` work through the generic `install_zip_successfull`
     short toast, not through a blocking module-specific alert. Failure indicates that Files/Mail
     opens could drift from the Backup & Restore document import behavior, that arbitrary ZIP
     handling stopped using the SWORD repository path, or that iOS reintroduced an install-success
     presentation that does not match Android.
     */
    func testExternalDocumentImportZipUsesModuleInstaller() {
        let probe = ExternalDocumentImportProbe()
        let service = makeExternalDocumentImportService(probe: probe)
        let url = URL(fileURLWithPath: "/tmp/FinRK.zip")

        let result = service.importDocument(at: url)

        XCTAssertEqual(result, .installedModule(name: "FinRK"))
        XCTAssertEqual(result.feedbackMessage, "Module was installed successfully")
        XCTAssertTrue(result.usesAndroidInstallToastFeedback)
        XCTAssertEqual(probe.snapshot().moduleURLs, [url])
        XCTAssertEqual(probe.snapshot().epubURLs, [])
        XCTAssertEqual(probe.snapshot().fontURLs.map(\.url), [])
        XCTAssertEqual(probe.snapshot().androidModuleBackupURLs, [])
    }

    /**
     Android module backups opened from Files use the Android backup restore path, not generic ZIP.

     Android's install activity accepts document/module backup ZIPs through the same external-open
     surface as SWORD ZIPs, but the backup payload contains `AndBibleBackupManifest.json` and should
     be restored through the Android module-backup service so manifest validation, unsupported
     Android-only entries, cache invalidation, and overwrite handling remain centralized. Android's
     success surface is the generic InstallZip success toast, so feedback must not enumerate every
     module from a large backup.

     Failure means `.abmd.zip` files can be routed into the plain SWORD ZIP installer, producing
     misleading decompression errors and bypassing Android backup semantics, or iOS has drifted back
     to a blocking module-list presentation that Android does not show.
     */
    func testExternalDocumentImportAndroidModuleBackupUsesBackupInstaller() {
        let probe = ExternalDocumentImportProbe()
        let service = makeExternalDocumentImportService(probe: probe)
        let url = URL(fileURLWithPath: "/tmp/ESV.abmd.zip")

        let result = service.importDocument(at: url)

        XCTAssertEqual(
            result,
            .installedAndroidModuleBackup(moduleNames: ["ESV2001", "ESV2011"], installedEntryCount: 14)
        )
        XCTAssertEqual(result.feedbackMessage, "Module was installed successfully")
        XCTAssertTrue(result.usesAndroidInstallToastFeedback)
        XCTAssertFalse(result.feedbackMessage.contains("ESV2001"))
        XCTAssertEqual(probe.snapshot().androidModuleBackupURLs, [url])
        XCTAssertEqual(probe.snapshot().moduleURLs, [])
        XCTAssertEqual(probe.snapshot().epubURLs, [])
        XCTAssertEqual(probe.snapshot().fontURLs.map(\.url), [])
    }

    /**
     Android module-backup success presentation follows InstallZip instead of listing modules.

     Android's `InstallZip` posts the generic `install_zip_successfull` toast after a successful
     module or document backup install. The iOS restore report can contain many module names and
     skipped Android-only entries, but the completion copy must remain generic so large Android
     backups do not produce a blocking, scroll-sized module list.

     Failure means the Settings restore path can drift from Android's visible behavior even when
     the underlying restore report is correct.
     */
    func testAndroidModuleBackupPresentationUsesGenericInstallSuccessCopy() {
        let report = AndroidModuleBackupRestoreReport(
            installedModuleNames: ["BDBT", "HebrewGreek", "StrongsHebrew"],
            installedEntryCount: 124,
            skippedUnsupportedEntryPaths: ["mybible/example.SQLite3"]
        )

        let message = AndroidModuleBackupPresentation.localizedRestoreSuccessMessage(for: report)

        XCTAssertEqual(message, "Module was installed successfully")
        XCTAssertFalse(message.contains("BDBT"))
        XCTAssertFalse(message.contains("mybible"))
    }

    /**
     Provider display names keep Android module-backup routing when URLs have generic ZIP names.

     Some document providers hand iOS a temporary URL while preserving the real filename separately.
     The importer must use the same normalized display name shown in the confirmation prompt when
     deciding whether a file is Android's `.abmd.zip` module backup.

     Failure means Files/Mail providers can show `ESV.abmd.zip` to the user but still route the
     confirmed import into the generic ZIP installer.
     */
    func testExternalDocumentImportAndroidModuleBackupUsesProviderDisplayName() {
        let probe = ExternalDocumentImportProbe()
        let service = makeExternalDocumentImportService(probe: probe)
        let url = URL(fileURLWithPath: "/tmp/provider-temporary.zip")
        let request = ExternalDocumentImportRequest(
            url: url,
            suggestedFileName: "  Backups/ESV.abmd.zip  "
        )

        let result = service.importDocument(request)

        XCTAssertEqual(
            result,
            .installedAndroidModuleBackup(moduleNames: ["ESV2001", "ESV2011"], installedEntryCount: 14)
        )
        XCTAssertEqual(probe.snapshot().androidModuleBackupURLs, [url])
        XCTAssertEqual(probe.snapshot().moduleURLs, [])
    }

    /**
     Manifest detection preserves Android backup routing when iOS rewrites repeated filenames.

     Files can copy repeated external opens into Inbox-style names such as `ESV.abmd-1.zip`, which
     no longer satisfy Android's literal `.abmd.zip` suffix. The router must inspect ZIP contents
     before generic module installation so backup semantics are preserved even when the provider
     filename changes.

     Failure means repeated imports can silently fall back to the plain SWORD ZIP installer and
     report only the last module installed, as the simulator did with `ESV.abmd-1.zip`.
     */
    func testExternalDocumentImportAndroidModuleBackupUsesManifestWhenFileNameChanges() {
        let probe = ExternalDocumentImportProbe()
        let service = makeExternalDocumentImportService(
            probe: probe,
            androidModuleBackupDetector: { url in probe.detectAndroidModuleBackup(url) }
        )
        let url = URL(fileURLWithPath: "/tmp/ESV.abmd-1.zip")

        let result = service.importDocument(at: url)

        XCTAssertEqual(
            result,
            .installedAndroidModuleBackup(moduleNames: ["ESV2001", "ESV2011"], installedEntryCount: 14)
        )
        XCTAssertEqual(probe.snapshot().androidModuleBackupDetectionURLs, [url])
        XCTAssertEqual(probe.snapshot().androidModuleBackupURLs, [url])
        XCTAssertEqual(probe.snapshot().moduleURLs, [])
    }

    /**
     EPUB files are imported through the EPUB reader store and must not be treated as SWORD ZIPs.

     Android's EPUB fallback still reports success through the generic InstallZip toast. Failure
     indicates that the scene-open path no longer matches the existing Settings document import
     branch for EPUB documents or that successful EPUB installs drifted back to iOS-specific alert
     copy.
     */
    func testExternalDocumentImportEpubUsesEpubInstaller() {
        let probe = ExternalDocumentImportProbe()
        let service = makeExternalDocumentImportService(probe: probe)
        let url = URL(fileURLWithPath: "/tmp/StudyNotes.epub")

        let result = service.importDocument(at: url)

        XCTAssertEqual(result, .installedEpub(title: "Study Notes"))
        XCTAssertEqual(result.feedbackMessage, "Module was installed successfully")
        XCTAssertTrue(result.usesAndroidInstallToastFeedback)
        XCTAssertEqual(probe.snapshot().moduleURLs, [])
        XCTAssertEqual(probe.snapshot().epubURLs, [url])
        XCTAssertEqual(probe.snapshot().fontURLs.map(\.url), [])
    }

    /**
     TTF files follow Android's app-owned font installer route.

     Android stores fonts under `modulesDir/ttf` and reports success through the generic InstallZip
     toast. Failure indicates that iOS advertises Android's font document type without backing it
     with the same storage semantics or that successful font installs use an iOS-specific alert.
     */
    func testExternalDocumentImportTtfUsesFontInstaller() {
        let probe = ExternalDocumentImportProbe()
        let service = makeExternalDocumentImportService(probe: probe)
        let url = URL(fileURLWithPath: "/tmp/custom.ttf")

        let result = service.importDocument(at: url)

        XCTAssertEqual(result, .installedFont(name: "Gentium"))
        XCTAssertEqual(result.feedbackMessage, "Module was installed successfully")
        XCTAssertTrue(result.usesAndroidInstallToastFeedback)
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
        XCTAssertFalse(result.usesAndroidInstallToastFeedback)
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
        XCTAssertFalse(result.usesAndroidInstallToastFeedback)
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
        XCTAssertFalse(result.usesAndroidInstallToastFeedback)
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
     The production ZIP classifier reroutes ZIP-looking EPUB archives without an injected detector.

     Setup:
     - writes a real stored ZIP with EPUB's `META-INF/container.xml` marker
     - imports it through the `.zip` path using the default archive classifier

     Expected result:
     - the EPUB installer receives the URL
     - the SWORD module installer is not called

     Failure meaning:
     - iOS no longer mirrors Android's `installZip` fallback that detects EPUB structure from ZIP
       entries before attempting a module install.
     */
    func testExternalDocumentImportZipEpubFallbackUsesProductionZipClassifier() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let url = tempDir.appendingPathComponent("StudyNotes.zip")
        let archiveData = try ZipArchiveWriter.storedArchive(entries: [
            ZipArchiveWriterEntry(name: "mimetype", data: Data("application/epub+zip".utf8)),
            ZipArchiveWriterEntry(name: "META-INF/container.xml", data: Data("<container/>".utf8)),
        ])
        try archiveData.write(to: url)
        let probe = ExternalDocumentImportProbe()
        let service = makeExternalDocumentImportService(probe: probe)

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
        XCTAssertFalse(result.usesAndroidInstallToastFeedback)
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
     than the in-app Backup & Restore importer. Errors must not use the Android success-toast path.
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
        XCTAssertFalse(result.usesAndroidInstallToastFeedback)
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
     TTF import rejects special path components before constructing an install destination.

     Android routes TTF imports through display names that end in `.ttf`; iOS mirrors that extension
     gate after reducing provider names to one basename. Failure means `.` or `..` could reach
     destination URL construction and weaken the `ttf/` containment contract.
     */
    func testTtfFontRepositoryRejectsSpecialPathComponentDisplayNames() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sourceURL = tempDir.appendingPathComponent("SourceGentium.ttf")
        try Data([0x00, 0x01, 0x00, 0x00]).write(to: sourceURL)
        let repository = TtfFontRepository(swordPath: tempDir.path)

        for displayName in [".", ".."] {
            do {
                _ = try repository.installFont(from: sourceURL, displayName: displayName)
                XCTFail("Expected special path component \(displayName) to be rejected")
            } catch TtfFontRepositoryError.invalidFont(let fileName) {
                XCTAssertEqual(fileName, displayName)
            } catch {
                XCTFail("Expected invalidFont for special path component \(displayName), got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("ttf").path))
    }

    /**
     TTF addon-config write failures keep import feedback anchored to the selected font filename.

     Android's TTF installer only exposes the imported TTF filename to the user; iOS persists an
     extra SWORD `.conf` file as platform plumbing. Failure means an internal config filename can leak
     through `ExternalDocumentImportService` as a misleading font-write error.
     */
    func testTtfFontRepositoryReportsFontNameWhenAddonConfigWriteFails() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sourceURL = tempDir.appendingPathComponent("SourceGentium.ttf")
        try Data([0x00, 0x01, 0x00, 0x00]).write(to: sourceURL)
        let modsDirectory = tempDir.appendingPathComponent("mods.d", isDirectory: true)
        try FileManager.default.createDirectory(at: modsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: modsDirectory.appendingPathComponent("ttf_gentium.conf", isDirectory: true),
            withIntermediateDirectories: true
        )
        let repository = TtfFontRepository(swordPath: tempDir.path)

        do {
            _ = try repository.installFont(from: sourceURL, displayName: "Gentium.ttf")
            XCTFail("Expected TTF config write to fail")
        } catch TtfFontRepositoryError.cantWrite(let fileName) {
            XCTAssertEqual(fileName, "Gentium.ttf")
        } catch {
            XCTFail("Expected cantWrite for selected TTF file, got \(error)")
        }
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
