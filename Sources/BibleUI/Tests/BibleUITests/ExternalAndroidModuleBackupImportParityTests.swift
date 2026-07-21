import Foundation
import XCTest
import BibleCore
@testable import BibleUI
import SwordKit

/**
 Verifies Android module-backup preflight and confirmation behavior at the shared external-import
 boundary used by Files, Downloads, Settings, and the reader module picker.

 The parity source is Android `InstallZip.ZipHandler` at commit `0f3b85823`: `checkZipFile()` scans
 every archive entry and records existing destinations before `execute()` offers Yes/Cancel. These
 tests use real ZIP fixtures and isolated module roots; failures indicate that iOS can skip conflict
 discovery, mutate storage after cancellation/rejection, bypass transactional replacement, or offer
 confirmation for an archive Android would reject as malformed or unsafe.

 Side effects:
 - creates temporary ZIP archives, transaction staging directories, and module roots
 - removes all registered temporary directories after each test

 Failure modes: Fixture I/O and production validation errors are surfaced through XCTest failures.
 */
final class ExternalAndroidModuleBackupImportParityTests: XCTestCase {
    /// Temporary directory roots removed after each test.
    private var temporaryDirectories: [URL] = []

    /**
     Removes archive fixtures, module roots, and transaction staging created by the completed test.

     - Side effects: Best-effort recursive deletion under the process temporary directory.
     - Failure modes: Cleanup errors are ignored so the behavior assertion remains the reported
       failure; every test uses UUID-scoped paths to avoid cross-test coupling.
     */
    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    /**
     A valid conflict-free Android backup is ready after read-only preflight.

     Setup uses an absent module root and a real manifest/config/payload archive. `.ready` plus the
     still-absent root proves preflight validated the archive without creating live storage.
     */
    func testAndroidModuleBackupPreflightIsReadyWithoutConflicts() throws {
        let fixture = try makeFixture()
        let archiveURL = try writeArchive(
            in: fixture.root,
            entries: validModuleEntries(payload: "incoming")
        )
        let service = makeImportService(fixture: fixture)

        let result = service.preflightDocument(ExternalDocumentImportRequest(url: archiveURL))

        XCTAssertEqual(result, .ready)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.moduleRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.epubRoot.path))
    }

    /**
     Android backup preflight reports exact archive-file conflicts before installation.

     The existing payload is one archive destination. Only that file is disclosed because Android's
     installer overlays exact entries and preserves siblings absent from the archive.
     */
    func testAndroidModuleBackupConflictRequiresExplicitConfirmation() throws {
        let fixture = try makeFixture()
        let existingURL = fixture.moduleRoot.appendingPathComponent("modules/texts/rawtext/kjv/ot")
        try write("local", to: existingURL)
        let archiveURL = try writeArchive(
            in: fixture.root,
            entries: validModuleEntries(payload: "incoming")
        )
        let service = makeImportService(fixture: fixture)

        let result = service.preflightDocument(ExternalDocumentImportRequest(url: archiveURL))

        guard case .moduleOverwriteRequired(let inspection) = result else {
            return XCTFail("Expected Android module-backup overwrite confirmation, got \(result)")
        }
        XCTAssertEqual(inspection.moduleNames, ["KJV"])
        XCTAssertEqual(
            inspection.conflictingPaths,
            ["modules/texts/rawtext/kjv/ot"]
        )
        XCTAssertEqual(inspection.installableEntryCount, 2)
        XCTAssertEqual(
            inspection.estimatedExpandedBytes,
            Int64(moduleConfig().count + "incoming".utf8.count)
        )
        XCTAssertEqual(try String(contentsOf: existingURL, encoding: .utf8), "local")
    }

    /**
     Canceling after conflict discovery and invoking the default reject path both preserve live data.

     The first snapshot models UI cancellation by deliberately stopping after preflight. The second
     calls the noninteractive/default importer, which must pass reject authorization into the real
     backup transaction and fail without changing any config, payload, or unrelated file.
     */
    func testAndroidModuleBackupCancelAndDefaultRejectCauseNoMutation() throws {
        let fixture = try makeFixture()
        try write(
            "local",
            to: fixture.moduleRoot.appendingPathComponent("modules/texts/rawtext/kjv/ot")
        )
        try write("keep", to: fixture.moduleRoot.appendingPathComponent("unrelated/marker"))
        let archiveURL = try writeArchive(
            in: fixture.root,
            entries: validModuleEntries(payload: "incoming")
        )
        let request = ExternalDocumentImportRequest(url: archiveURL)
        let service = makeImportService(fixture: fixture)
        let before = try fileSnapshot(under: fixture.moduleRoot)

        guard case .moduleOverwriteRequired = service.preflightDocument(request) else {
            return XCTFail("Expected preflight to pause for overwrite confirmation")
        }
        XCTAssertEqual(try fileSnapshot(under: fixture.moduleRoot), before)

        let rejectedResult = service.importDocument(request)

        guard case .failed = rejectedResult else {
            return XCTFail("Default Android backup import must reject conflicts, got \(rejectedResult)")
        }
        XCTAssertEqual(try fileSnapshot(under: fixture.moduleRoot), before)
    }

    /**
     Explicit archive-bound authorization commits the Android backup through an exact-file overlay.

     Existing KJV payload absent from the archive and an unrelated ASV file must remain untouched,
     matching Android's installer. Failure indicates consent broadened from displayed paths to an
     owned-directory replacement or bypassed canonical rollback-safe publication.
     */
    func testAndroidModuleBackupConfirmedReplacementCommitsTransactionally() throws {
        let fixture = try makeFixture()
        let incomingURL = fixture.moduleRoot.appendingPathComponent("modules/texts/rawtext/kjv/ot")
        let staleURL = fixture.moduleRoot.appendingPathComponent("modules/texts/rawtext/kjv/nt")
        let unrelatedURL = fixture.moduleRoot.appendingPathComponent("modules/texts/rawtext/asv/ot")
        try write("local", to: incomingURL)
        try write("stale", to: staleURL)
        try write("keep", to: unrelatedURL)
        let archiveURL = try writeArchive(
            in: fixture.root,
            entries: validModuleEntries(payload: "incoming")
        )
        let request = ExternalDocumentImportRequest(url: archiveURL)
        let service = makeImportService(fixture: fixture)

        guard case .moduleOverwriteRequired(let inspection) = service.preflightDocument(request) else {
            return XCTFail("Expected replacement confirmation before transactional restore")
        }
        let result = service.importDocument(
            request,
            moduleOverwritePolicy: .replaceExisting(inspection.overwriteAuthorization),
            progressState: nil
        )

        XCTAssertEqual(
            result,
            .installedAndroidModuleBackup(moduleNames: ["KJV"], installedEntryCount: 2)
        )
        XCTAssertEqual(try String(contentsOf: incomingURL, encoding: .utf8), "incoming")
        XCTAssertEqual(try String(contentsOf: staleURL, encoding: .utf8), "stale")
        XCTAssertEqual(try String(contentsOf: unrelatedURL, encoding: .utf8), "keep")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.moduleRoot.appendingPathComponent("mods.d/kjv.conf").path
            )
        )
    }

    /**
     Malformed ZIP bytes and unsafe entry paths fail before conflict confirmation.

     Both fixtures use the Android suffix, so routing cannot hide behind generic ZIP detection. A
     failure means preflight can offer overwrite consent before validating every archive entry or can
     mutate live storage while rejecting a hostile path.
     */
    func testAndroidModuleBackupMalformedAndUnsafeArchivesFailBeforeConfirmation() throws {
        let fixture = try makeFixture()
        let existingURL = fixture.moduleRoot.appendingPathComponent("modules/texts/rawtext/kjv/ot")
        try write("local", to: existingURL)
        let malformedURL = fixture.root.appendingPathComponent("malformed.abmd.zip")
        try Data("not a zip".utf8).write(to: malformedURL)
        let unsafeURL = try writeArchive(
            named: "unsafe.abmd.zip",
            in: fixture.root,
            entries: validModuleEntries(payload: "incoming") + [
                ("../outside", Data("escape".utf8)),
            ]
        )
        let service = makeImportService(fixture: fixture)
        let before = try fileSnapshot(under: fixture.moduleRoot)

        for archiveURL in [malformedURL, unsafeURL] {
            let result = service.preflightDocument(ExternalDocumentImportRequest(url: archiveURL))
            guard case .failed = result else {
                XCTFail(
                    "Invalid archive must fail before confirmation: "
                        + "\(archiveURL.lastPathComponent), \(result)"
                )
                continue
            }
        }

        XCTAssertEqual(try fileSnapshot(under: fixture.moduleRoot), before)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent("outside").path
            )
        )
    }

    /**
     Isolated paths shared by one test's archive, module root, and transaction staging.

     Side effects: none; construction only groups already-created URLs.
     */
    private struct Fixture {
        /// UUID-scoped temporary directory registered for teardown.
        let root: URL

        /// Live SWORD module root passed to the production backup service.
        let moduleRoot: URL

        /// Scratch root used by the production transactional restore.
        let stagingRoot: URL

        /// Explicit native EPUB root that read-only preflight must not create or migrate.
        let epubRoot: URL
    }

    /**
     Creates one UUID-scoped fixture root without creating the live module directory.

     - Returns: Paths for archive storage, live modules, and transaction staging.
     - Side effects: Creates and registers one temporary root for teardown.
     - Failure modes: Rethrows directory-creation errors.
     */
    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("external-android-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryDirectories.append(root)
        return Fixture(
            root: root,
            moduleRoot: root.appendingPathComponent("sword", isDirectory: true),
            stagingRoot: root.appendingPathComponent("staging", isDirectory: true),
            epubRoot: root.appendingPathComponent("epub", isDirectory: true)
        )
    }

    /**
     Builds the shared external service around real Android backup inspection and restore contracts.

     - Parameter fixture: Isolated live and staging roots for the current test.
     - Returns: Import service whose Android branch uses production validation and transactions.
     - Side effects: none until a returned closure is invoked.
     - Failure modes: Inspector and installer closures rethrow production archive and filesystem
       errors for conversion into `ExternalDocumentImportPreflightResult` or import failure results.
     */
    private func makeImportService(fixture: Fixture) -> ExternalDocumentImportService {
        let moduleRoot = fixture.moduleRoot
        let stagingRoot = fixture.stagingRoot
        return ExternalDocumentImportService(
            androidModuleBackupInspector: { archiveURL in
                try AndroidModuleBackupService(
                    moduleDirectory: moduleRoot,
                    temporaryDirectory: stagingRoot,
                    epubLibraryRootURL: fixture.epubRoot
                ).inspectArchive(fromArchiveAt: archiveURL)
            },
            androidModuleBackupInstallerWithPolicy: { archiveURL, overwritePolicy in
                try AndroidModuleBackupService(
                    moduleDirectory: moduleRoot,
                    temporaryDirectory: stagingRoot,
                    epubLibraryRootURL: fixture.epubRoot
                ).restoreArchive(
                    fromArchiveAt: archiveURL,
                    overwritePolicy: overwritePolicy
                )
            }
        )
    }

    /**
     Returns a valid KJV config/payload pair for Android module-backup fixtures.

     - Parameter payload: Text written to the incoming module payload entry.
     - Returns: Ordered archive entries after the Android manifest.
     - Side effects: none.
     - Failure modes: none.
     */
    private func validModuleEntries(payload: String) -> [(String, Data)] {
        [
            ("mods.d/kjv.conf", moduleConfig()),
            ("modules/texts/rawtext/kjv/ot", Data(payload.utf8)),
        ]
    }

    /**
     Builds a minimal directory-backed RawText SWORD config used by every valid fixture.

     - Returns: UTF-8 config bytes binding KJV to `modules/texts/rawtext/kjv/`.
     - Side effects: none.
     - Failure modes: none.
     */
    private func moduleConfig() -> Data {
        Data(
            """
            [KJV]
            DataPath=./modules/texts/rawtext/kjv/
            ModDrv=RawText
            Description=KJV

            """.utf8
        )
    }

    /**
     Writes an Android `MODULE_BACKUP` ZIP fixture.

     - Parameters:
       - name: Archive filename; the Android suffix keeps external routing deterministic.
       - root: Temporary directory that owns the archive.
       - entries: Validated or intentionally unsafe entries written after the manifest.
     - Returns: File URL for the completed stored ZIP.
     - Side effects: Writes one archive file under `root`.
     - Failure modes: Rethrows ZIP construction and filesystem write failures.
     */
    private func writeArchive(
        named name: String = "modules.abmd.zip",
        in root: URL,
        entries: [(String, Data)]
    ) throws -> URL {
        let manifest = Data(#"{"backupType":"MODULE_BACKUP","manifestVersion":1}"#.utf8)
        let archiveData = try ZipArchiveWriter.storedArchive(
            entries: [ZipArchiveWriterEntry(name: "AndBibleBackupManifest.json", data: manifest)]
                + entries.map { ZipArchiveWriterEntry(name: $0.0, data: $0.1) }
        )
        let archiveURL = root.appendingPathComponent(name)
        try archiveData.write(to: archiveURL)
        return archiveURL
    }

    /**
     Writes one UTF-8 live-module or marker file, creating parent directories as needed.

     - Parameters:
       - value: File text.
       - url: Destination under the test's isolated module root.
     - Side effects: Creates parent directories and atomically writes the destination file.
     - Failure modes: Rethrows directory or file write failures.
     */
    private func write(_ value: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(value.utf8).write(to: url, options: .atomic)
    }

    /**
     Captures every regular file beneath a module root for zero-mutation assertions.

     - Parameter root: Live module directory, which may not exist yet.
     - Returns: Relative-path-to-bytes map, or an empty map for an absent root.
     - Side effects: Reads directory metadata and file bytes only.
     - Failure modes: Rethrows directory enumeration or file read failures.
     */
    private func fileSnapshot(under root: URL) throws -> [String: Data] {
        guard FileManager.default.fileExists(atPath: root.path) else {
            return [:]
        }
        var snapshot: [String: Data] = [:]
        let relativePaths = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()
        for relativePath in relativePaths {
            let fileURL = root.appendingPathComponent(relativePath)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                continue
            }
            snapshot[relativePath] = try Data(contentsOf: fileURL)
        }
        return snapshot
    }
}
