import XCTest
@testable import BibleCore

extension AndBibleTests {
    /**
     Verifies that Android module backups are recognized by the `.abmd.zip` suffix and rejected
     when their manifest declares the database-backup type.

     Setup:
     - checks Android's module-backup filename suffix
     - builds a ZIP with `AndBibleBackupManifest.json` declaring `DB_BACKUP`

     Expected result:
     - `.abmd.zip` recognition is case-insensitive
     - the module backup service rejects the database manifest before looking for module files

     Failure meaning:
     - iOS could route Android database and module backups through the wrong restore path, causing
       confusing UI behavior or unsafe file writes.
     */
    func testAndroidModuleBackupRecognizesSuffixAndRejectsDatabaseManifest() throws {
        XCTAssertTrue(AndroidModuleBackupService.isAndroidModuleBackupFileName("AndBibleModulesBackup.abmd.zip"))
        XCTAssertTrue(AndroidModuleBackupService.isAndroidModuleBackupFileName("ANDBIBLEMODULESBACKUP.ABMD.ZIP"))
        XCTAssertFalse(AndroidModuleBackupService.isAndroidModuleBackupFileName("AndBibleDatabaseBackup.abdb.zip"))

        let archiveData = try makeAndroidModuleBackupArchiveData(
            manifestBackupType: "DB_BACKUP",
            entries: []
        )
        let service = AndroidModuleBackupService(moduleDirectory: try makeTemporaryAndroidModuleBackupRoot())

        XCTAssertThrowsError(try service.inspectArchive(from: archiveData)) { error in
            XCTAssertEqual(error as? AndroidModuleBackupError, .unsupportedBackupType("DB_BACKUP"))
        }
    }

    /**
     Verifies that archive entry paths are normalized before duplicate detection.

     Setup:
     - builds an Android module backup containing the same SWORD config path with `\` and `./`
       spelling variants
     - includes a valid module data file so the archive would otherwise be restorable

     Expected result:
     - inspection rejects the normalized duplicate before any restore file writes can occur
     - the duplicate path reported to users and logs is the normalized archive path

     Failure meaning:
     - iOS could accept an archive that overwrites one restored file with another spelling of the
       same path, drifting from Android's collision-safe restore expectations.
     */
    func testAndroidModuleBackupRejectsNormalizedDuplicateEntryPaths() throws {
        let moduleRoot = try makeTemporaryAndroidModuleBackupRoot()
        let service = AndroidModuleBackupService(moduleDirectory: moduleRoot)
        let archiveData = try makeAndroidModuleBackupArchiveData(entries: [
            ("mods.d\\kjv.conf", makeAndroidModuleBackupConf(moduleName: "KJV")),
            ("./mods.d/kjv.conf", makeAndroidModuleBackupConf(moduleName: "KJV")),
            ("modules/texts/rawtext/kjv/ot", Data("Genesis content".utf8)),
        ])

        XCTAssertThrowsError(try service.inspectArchive(from: archiveData)) { error in
            XCTAssertEqual(error as? AndroidModuleBackupError, .duplicateEntry("mods.d/kjv.conf"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: moduleRoot.appendingPathComponent("mods.d/kjv.conf").path))
    }

    /**
     Verifies that iOS restores the shared SWORD portion of Android module backups and reports
     Android-only manual module payloads as skipped.

     Setup:
     - builds an Android-shaped `.abmd.zip` with one SWORD config/data pair
     - includes one `mybible/` payload that Android can install but this iOS path cannot restore

     Expected result:
     - supported `mods.d/` and `modules/` files are written under the local module root
     - the manifest and unsupported MyBible payload are not written
     - the restore report lists the installed SWORD module and skipped Android-only entry

     Failure meaning:
     - iOS would either skip valid Android SWORD backups or silently pretend unsupported Android
       formats were restored.
     */
    func testAndroidModuleBackupRestoresSwordPayloadAndSkipsUnsupportedEntries() throws {
        let moduleRoot = try makeTemporaryAndroidModuleBackupRoot()
        let service = AndroidModuleBackupService(moduleDirectory: moduleRoot)
        let archiveData = try makeAndroidModuleBackupArchiveData(entries: [
            ("mods.d/kjv.conf", makeAndroidModuleBackupConf(moduleName: "KJV")),
            ("modules/texts/rawtext/kjv/ot", Data("Genesis content".utf8)),
            ("mybible/example.SQLite3", Data("unsupported".utf8)),
        ])

        let inspection = try service.inspectArchive(from: archiveData)
        XCTAssertEqual(inspection.supportedModuleNames, ["KJV"])
        XCTAssertEqual(inspection.supportedEntryCount, 2)
        XCTAssertEqual(inspection.unsupportedEntryPaths, ["mybible/example.SQLite3"])

        let report = try service.restoreArchive(from: archiveData)

        XCTAssertEqual(report.installedModuleNames, ["KJV"])
        XCTAssertEqual(report.installedEntryCount, 2)
        XCTAssertEqual(report.skippedUnsupportedEntryPaths, ["mybible/example.SQLite3"])
        XCTAssertEqual(
            try String(contentsOf: moduleRoot.appendingPathComponent("modules/texts/rawtext/kjv/ot"), encoding: .utf8),
            "Genesis content"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: moduleRoot.appendingPathComponent("mods.d/kjv.conf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: moduleRoot.appendingPathComponent("AndBibleBackupManifest.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: moduleRoot.appendingPathComponent("mybible/example.SQLite3").path))
    }

    /**
     Verifies that overwrite protection matches the UI confirmation contract for Android module
     backup restore.

     Setup:
     - creates an existing local module data file
     - builds an Android backup that would replace that same file

     Expected result:
     - inspection reports the existing file path for confirmation UI
     - restore with overwrites disabled fails without changing the local file
     - restore with overwrites enabled replaces the file

     Failure meaning:
     - iOS could overwrite installed module data without confirmation or fail to apply the user's
       confirmed overwrite choice.
     */
    func testAndroidModuleBackupReportsAndControlsExistingFileOverwrite() throws {
        let moduleRoot = try makeTemporaryAndroidModuleBackupRoot()
        let existingURL = moduleRoot.appendingPathComponent("modules/texts/rawtext/kjv/ot")
        try FileManager.default.createDirectory(
            at: existingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("local".utf8).write(to: existingURL)

        let service = AndroidModuleBackupService(moduleDirectory: moduleRoot)
        let archiveData = try makeAndroidModuleBackupArchiveData(entries: [
            ("mods.d/kjv.conf", makeAndroidModuleBackupConf(moduleName: "KJV")),
            ("modules/texts/rawtext/kjv/ot", Data("remote".utf8)),
        ])

        let inspection = try service.inspectArchive(from: archiveData)
        XCTAssertEqual(inspection.existingEntryPaths, ["modules/texts/rawtext/kjv/ot"])

        XCTAssertThrowsError(
            try service.restoreArchive(from: archiveData, allowOverwritingExistingFiles: false)
        ) { error in
            XCTAssertEqual(
                error as? AndroidModuleBackupError,
                .moduleFilesAlreadyExist(["modules/texts/rawtext/kjv/ot"])
            )
        }
        XCTAssertEqual(try String(contentsOf: existingURL, encoding: .utf8), "local")

        _ = try service.restoreArchive(from: archiveData, allowOverwritingExistingFiles: true)
        XCTAssertEqual(try String(contentsOf: existingURL, encoding: .utf8), "remote")
    }

    /**
     Verifies that archives containing only Android-only module formats fail with a clear
     unsupported-content error and do not create local files.

     Setup:
     - builds an Android module backup containing only an optimized Android EPUB payload

     Expected result:
     - inspection fails with `noSupportedModules`
     - no `epub/` payload is written into the iOS SWORD module root

     Failure meaning:
     - iOS would either silently ignore a user-selected backup or install Android-specific files
       that the iOS module/document pipeline cannot read.
     */
    func testAndroidModuleBackupRejectsUnsupportedOnlyContentWithoutWritingFiles() throws {
        let moduleRoot = try makeTemporaryAndroidModuleBackupRoot()
        let service = AndroidModuleBackupService(moduleDirectory: moduleRoot)
        let archiveData = try makeAndroidModuleBackupArchiveData(entries: [
            ("epub/Example/book.xhtml", Data("<html></html>".utf8)),
        ])

        XCTAssertThrowsError(try service.inspectArchive(from: archiveData)) { error in
            XCTAssertEqual(error as? AndroidModuleBackupError, .noSupportedModules(["epub/Example/book.xhtml"]))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: moduleRoot.appendingPathComponent("epub/Example/book.xhtml").path))
    }

    /**
     Verifies that iOS exports installed SWORD modules in Android's module-backup ZIP shape.

     Setup:
     - creates a local SWORD config and data file under a temporary module root
     - exports the module through `AndroidModuleBackupService`
     - re-reads the ZIP with the production `ZipArchiveReader`

     Expected result:
     - the archive filename uses Android's `.abmd.zip` name
     - the manifest declares `MODULE_BACKUP`
     - the config and data entries are relative to the module root, matching Android's export

     Failure meaning:
     - Android would be unable to restore an iOS-created module backup, breaking round-trip parity.
     */
    func testAndroidModuleBackupExportsInstalledSwordModulesWithAndroidManifest() throws {
        let moduleRoot = try makeTemporaryAndroidModuleBackupRoot()
        try writeAndroidModuleBackupInstalledModule(
            moduleRoot: moduleRoot,
            moduleName: "KJV",
            data: Data("exported".utf8)
        )
        let service = AndroidModuleBackupService(moduleDirectory: moduleRoot)

        let export = try service.exportArchive(moduleNames: ["KJV"])

        XCTAssertEqual(export.fileName, AndroidModuleBackupService.moduleBackupFileName)
        XCTAssertEqual(export.moduleNames, ["KJV"])
        let entries = try ZipArchiveReader.entries(in: export.data)
        let entriesByName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.data) })
        XCTAssertEqual(
            String(data: try XCTUnwrap(entriesByName["AndBibleBackupManifest.json"]), encoding: .utf8),
            #"{"backupType":"MODULE_BACKUP","manifestVersion":1}"#
        )
        XCTAssertEqual(
            String(data: try XCTUnwrap(entriesByName["mods.d/kjv.conf"]), encoding: .utf8),
            String(data: makeAndroidModuleBackupConf(moduleName: "KJV"), encoding: .utf8)
        )
        XCTAssertEqual(
            String(data: try XCTUnwrap(entriesByName["modules/texts/rawtext/kjv/ot"]), encoding: .utf8),
            "exported"
        )
    }

    /**
     Verifies that Android-compatible ZIP exports mark entry names as UTF-8.

     Setup:
     - writes a minimal stored ZIP archive through `ZipArchiveWriter`
     - reads the general-purpose bit flag from both local and central-directory headers

     Expected result:
     - both headers set the ZIP EFS/UTF-8 flag that Android's Java ZIP readers use for path
       decoding

     Failure meaning:
     - Android restore could reinterpret iOS-exported module paths with a platform-default
       encoding, especially for localized module filenames.
     */
    func testZipArchiveWriterMarksEntryNamesAsUTF8ForAndroidReaders() throws {
        let archiveData = try ZipArchiveWriter.storedArchive(entries: [
            ZipArchiveWriterEntry(name: "mods.d/kjv.conf", data: Data("payload".utf8)),
        ])
        let expectedFlag: UInt16 = 0x0800
        let endOfCentralDirectoryOffset = archiveData.count - 22
        let centralDirectoryOffset = Int(try readZipUInt32(archiveData, at: endOfCentralDirectoryOffset + 16))

        XCTAssertEqual(try readZipUInt32(archiveData, at: endOfCentralDirectoryOffset), 0x0605_4b50)
        XCTAssertEqual(try readZipUInt32(archiveData, at: centralDirectoryOffset), 0x0201_4b50)
        XCTAssertEqual(try readZipUInt16(archiveData, at: 6), expectedFlag)
        XCTAssertEqual(try readZipUInt16(archiveData, at: centralDirectoryOffset + 8), expectedFlag)
    }

    /**
     Verifies that Android-compatible module export honors the selected-module list.

     Setup:
     - creates two installed SWORD modules under a temporary root
     - requests export of only one module, matching Android's multiselect backup flow

     Expected result:
     - the generated archive includes the selected module config/data
     - the unselected module does not appear in the archive

     Failure meaning:
     - iOS would present a selectable module backup UI but still export unselected documents,
       breaking Android parity and user intent.
     */
    func testAndroidModuleBackupExportsOnlySelectedInstalledModules() throws {
        let moduleRoot = try makeTemporaryAndroidModuleBackupRoot()
        try writeAndroidModuleBackupInstalledModule(
            moduleRoot: moduleRoot,
            moduleName: "KJV",
            data: Data("selected".utf8)
        )
        try writeAndroidModuleBackupInstalledModule(
            moduleRoot: moduleRoot,
            moduleName: "ASV",
            data: Data("unselected".utf8)
        )
        let service = AndroidModuleBackupService(moduleDirectory: moduleRoot)

        let export = try service.exportArchive(moduleNames: ["KJV"])

        XCTAssertEqual(export.moduleNames, ["KJV"])
        let entryNames = Set(try ZipArchiveReader.entries(in: export.data).map(\.name))
        XCTAssertTrue(entryNames.contains("mods.d/kjv.conf"))
        XCTAssertTrue(entryNames.contains("modules/texts/rawtext/kjv/ot"))
        XCTAssertFalse(entryNames.contains("mods.d/asv.conf"))
        XCTAssertFalse(entryNames.contains("modules/texts/rawtext/asv/ot"))
    }

    /**
     Creates a temporary SWORD module root for Android module-backup tests.

     - Returns: Empty module root URL with `mods.d/` present.
     - Side effects: Creates a temporary directory and registers it for teardown cleanup.
     - Failure modes: Rethrows file-system directory creation failures.
     */
    private func makeTemporaryAndroidModuleBackupRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sword", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("mods.d", isDirectory: true),
            withIntermediateDirectories: true
        )
        temporarySwordModulePaths.append(root.path)
        return root
    }

    /**
     Builds an Android-shaped module backup ZIP fixture.

     - Parameters:
       - manifestBackupType: Manifest `backupType` value to emit.
       - entries: Additional archive entries after the manifest.
     - Returns: Stored ZIP data readable by production archive services.
     - Side effects: none.
     - Failure modes: Rethrows `ZipArchiveWriter` size failures.
     */
    private func makeAndroidModuleBackupArchiveData(
        manifestBackupType: String = "MODULE_BACKUP",
        entries: [(String, Data)]
    ) throws -> Data {
        let manifest = Data(#"{"backupType":"\#(manifestBackupType)","manifestVersion":1}"#.utf8)
        let zipEntries = [ZipArchiveWriterEntry(name: "AndBibleBackupManifest.json", data: manifest)]
            + entries.map { ZipArchiveWriterEntry(name: $0.0, data: $0.1) }
        return try ZipArchiveWriter.storedArchive(entries: zipEntries)
    }

    /**
     Builds a minimal SWORD config for module backup restore/export tests.

     - Parameter moduleName: Module initials to place in the config section.
     - Returns: UTF-8 SWORD config bytes with `RawText` data under `modules/texts/rawtext`.
     - Side effects: none.
     - Failure modes: none.
     */
    private func makeAndroidModuleBackupConf(moduleName: String) -> Data {
        Data(
            """
            [\(moduleName)]
            DataPath=./modules/texts/rawtext/\(moduleName.lowercased())/
            ModDrv=RawText
            Description=\(moduleName)

            """.utf8
        )
    }

    /**
     Writes a minimal installed SWORD module fixture under a temporary module root.

     - Parameters:
       - moduleRoot: Temporary SWORD root.
       - moduleName: Module initials for the config filename and section.
       - data: Module data payload to write.
     - Side effects: Creates config and data files under `moduleRoot`.
     - Failure modes: Rethrows file-system write failures.
     */
    private func writeAndroidModuleBackupInstalledModule(
        moduleRoot: URL,
        moduleName: String,
        data: Data
    ) throws {
        let confURL = moduleRoot
            .appendingPathComponent("mods.d", isDirectory: true)
            .appendingPathComponent("\(moduleName.lowercased()).conf")
        try makeAndroidModuleBackupConf(moduleName: moduleName).write(to: confURL)

        let dataURL = moduleRoot
            .appendingPathComponent("modules/texts/rawtext/\(moduleName.lowercased())", isDirectory: true)
            .appendingPathComponent("ot")
        try FileManager.default.createDirectory(
            at: dataURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: dataURL)
    }

    /**
     Reads a little-endian UInt16 from a ZIP fixture at an exact byte offset.

     - Parameters:
       - data: ZIP fixture bytes.
       - offset: Zero-based byte offset of the two-byte integer.
     - Returns: Decoded UInt16 value.
     - Side effects: none.
     - Failure modes: Throws a test-fixture error if the offset is outside the fixture.
     */
    private func readZipUInt16(_ data: Data, at offset: Int) throws -> UInt16 {
        let bytes = [UInt8](data)
        guard offset >= 0, offset + 1 < bytes.count else {
            throw AndroidModuleBackupTestFixtureError.invalidZipOffset
        }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    /**
     Reads a little-endian UInt32 from a ZIP fixture at an exact byte offset.

     - Parameters:
       - data: ZIP fixture bytes.
       - offset: Zero-based byte offset of the four-byte integer.
     - Returns: Decoded UInt32 value.
     - Side effects: none.
     - Failure modes: Throws a test-fixture error if the offset is outside the fixture.
     */
    private func readZipUInt32(_ data: Data, at offset: Int) throws -> UInt32 {
        let bytes = [UInt8](data)
        guard offset >= 0, offset + 3 < bytes.count else {
            throw AndroidModuleBackupTestFixtureError.invalidZipOffset
        }
        return UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    /**
     Reports malformed local ZIP fixtures as XCTest failures instead of runtime traps.
     */
    private enum AndroidModuleBackupTestFixtureError: Error {
        case invalidZipOffset
    }
}
