import Foundation
import XCTest
@testable import SwordKit

/**
 Crash-state coverage for exact-path module-store overlay recovery.

 Tests persist the same intent checkpoints used by production and then stop mutating the fixture,
 simulating process termination at that boundary before a new journal instance performs recovery.
 */
final class ModuleStoreRecoveryJournalTests: XCTestCase {
    /**
     Verifies an interrupted replacement removes new bytes and restores the displaced old file.

     Failure means a crash after publication can leave a mixed Android/local ZIP overlay live on the
     next launch even though the old destination is still available in transaction backup storage.
     */
    func testActiveReplacementRestoresBackupAndRemovesPublishedFile() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let destination = fixture.root.appendingPathComponent("modules/texts/rawtext/demo/ot")
        let backup = fixture.backupRoot.appendingPathComponent("modules/texts/rawtext/demo/ot")
        try write("old", to: destination)

        let transaction = try fixture.journal.begin(backupRoot: fixture.backupRoot)
        try transaction.recordBackupMove(originalURL: destination, backupURL: backup)
        try FileManager.default.createDirectory(
            at: backup.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: destination, to: backup)
        try transaction.markBackupMoveCompleted(originalURL: destination)
        try transaction.recordPublishedURL(destination)
        try write("new", to: destination)

        XCTAssertTrue(try ModuleStoreRecoveryJournal(
            rootURL: fixture.root,
            fileManager: .default
        ).recoverInterruptedTransactions())
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backupRoot.path))
        try assertNoJournalResidue(in: fixture.root)
    }

    /**
     Verifies a durable backup intent does not delete an old file when the move never occurred.

     Failure means a crash between journal persistence and the matching filesystem operation could
     turn a recoverable untouched module into data loss during startup recovery.
     */
    func testPendingBackupIntentPreservesUntouchedDestination() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let destination = fixture.root.appendingPathComponent("mods.d/demo.conf")
        let backup = fixture.backupRoot.appendingPathComponent("mods.d/demo.conf")
        try write("old", to: destination)

        let transaction = try fixture.journal.begin(backupRoot: fixture.backupRoot)
        try transaction.recordBackupMove(originalURL: destination, backupURL: backup)

        XCTAssertTrue(try fixture.journal.recoverInterruptedTransactions())
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "old")
        try assertNoJournalResidue(in: fixture.root)
    }

    /**
     Verifies a fresh destination from an active transaction is removed on recovery.

     Failure means a crash can publish a config or payload with no corresponding prior file to
     restore, leaving a partial fresh module visible after relaunch.
     */
    func testActiveFreshPublishIsRemoved() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let destination = fixture.root.appendingPathComponent("mods.d/fresh.conf")
        let transaction = try fixture.journal.begin(backupRoot: fixture.backupRoot)
        try transaction.recordPublishedURL(destination)
        try write("fresh", to: destination)

        XCTAssertTrue(try fixture.journal.recoverInterruptedTransactions())
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try assertNoJournalResidue(in: fixture.root)
    }

    /**
     Verifies the durable commit marker preserves new bytes while cleaning old backup residue.

     Failure means a crash after a successful publish could incorrectly roll a committed module
     back on the next launch or retain stale transaction directories indefinitely.
     */
    func testCommittedJournalPreservesPublishedFileAndCleansBackup() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let destination = fixture.root.appendingPathComponent("modules/texts/rawtext/demo/ot")
        let backup = fixture.backupRoot.appendingPathComponent("modules/texts/rawtext/demo/ot")
        try write("old", to: destination)
        let transaction = try fixture.journal.begin(backupRoot: fixture.backupRoot)
        try transaction.recordBackupMove(originalURL: destination, backupURL: backup)
        try FileManager.default.createDirectory(
            at: backup.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: destination, to: backup)
        try transaction.markBackupMoveCompleted(originalURL: destination)
        try transaction.recordPublishedURL(destination)
        try write("new", to: destination)
        try transaction.synchronizePublishedState()
        try transaction.markCommitted()

        XCTAssertTrue(try fixture.journal.recoverInterruptedTransactions())
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backupRoot.path))
        try assertNoJournalResidue(in: fixture.root)
    }

    /**
     Verifies interrupted cleanup leaves a durable rolled-back journal that startup can finish.

     Recovery restores an old file from retained backup storage, persists `rolledBack`, removes the
     backup, and then receives an injected journal-removal failure. A second recovery must treat the
     residual record as cleanup-only, preserve restored bytes, and remove the harmless journal.
     Failure means startup can either repeat destructive rollback or precondition-fail forever after
     the data transaction itself was already recovered.
     */
    func testRolledBackJournalSurvivesDiscardFailureAndNextRecoveryCleansIt() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let destination = fixture.root.appendingPathComponent("mods.d/demo.conf")
        let backup = fixture.backupRoot.appendingPathComponent("mods.d/demo.conf")
        try write("old", to: destination)
        let transaction = try fixture.journal.begin(backupRoot: fixture.backupRoot)
        try transaction.recordBackupMove(originalURL: destination, backupURL: backup)
        try FileManager.default.createDirectory(
            at: backup.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: destination, to: backup)
        try transaction.markBackupMoveCompleted(originalURL: destination)
        try transaction.recordPublishedURL(destination)
        try write("new", to: destination)

        let faultingJournal = ModuleStoreRecoveryJournal(
            rootURL: fixture.root,
            fileManager: ModuleStoreJournalDiscardFaultFileManager()
        )
        XCTAssertThrowsError(try faultingJournal.recoverInterruptedTransactions()) { error in
            let cocoaError = error as NSError
            XCTAssertEqual(cocoaError.domain, NSCocoaErrorDomain)
            XCTAssertEqual(cocoaError.code, CocoaError.fileWriteNoPermission.rawValue)
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backupRoot.path))
        let residualRecord = try JSONDecoder().decode(
            ModuleStoreRecoveryJournal.Record.self,
            from: Data(contentsOf: transaction.journalURL)
        )
        XCTAssertEqual(residualRecord.phase, .rolledBack)

        XCTAssertTrue(try fixture.journal.recoverInterruptedTransactions())
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "old")
        try assertNoJournalResidue(in: fixture.root)
    }

    /**
     Verifies recovery fails closed when a completed displacement has lost its backup bytes.

     Failure means startup could erase the only remaining published file and discard the journal
     even though the old destination can no longer be restored.
     */
    func testMissingCompletedBackupRetainsJournalAndCurrentFile() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let destination = fixture.root.appendingPathComponent("mods.d/demo.conf")
        let backup = fixture.backupRoot.appendingPathComponent("mods.d/demo.conf")
        try write("old", to: destination)
        let transaction = try fixture.journal.begin(backupRoot: fixture.backupRoot)
        try transaction.recordBackupMove(originalURL: destination, backupURL: backup)
        try FileManager.default.createDirectory(
            at: backup.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: destination, to: backup)
        try transaction.markBackupMoveCompleted(originalURL: destination)
        try transaction.recordPublishedURL(destination)
        try write("new", to: destination)
        try FileManager.default.removeItem(at: backup)

        XCTAssertThrowsError(try fixture.journal.recoverInterruptedTransactions())
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "new")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent(".module-recovery").path
        ))
    }

    /**
     Verifies corrupt journal traversal fails before touching either the module root or outside data.

     Failure means an altered recovery record could redirect startup deletion/restoration beyond the
     canonical SWORD root.
     */
    func testUnsafeJournalPathFailsClosedWithoutFilesystemMutation() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let outside = fixture.parent.appendingPathComponent("outside.txt")
        try write("outside", to: outside)
        let journalDirectory = fixture.root.appendingPathComponent(".module-recovery")
        try FileManager.default.createDirectory(
            at: journalDirectory,
            withIntermediateDirectories: true
        )
        let record = ModuleStoreRecoveryJournal.Record(
            version: 1,
            transactionID: UUID(),
            backupRootPath: "../outside",
            phase: .active,
            backupMoves: [],
            publishedPaths: ["../outside.txt"],
            createdDirectoryPaths: []
        )
        try JSONEncoder().encode(record).write(
            to: journalDirectory.appendingPathComponent("unsafe.json")
        )

        XCTAssertThrowsError(try fixture.journal.recoverInterruptedTransactions())
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "outside")
    }

    /**
     Verifies the public publisher recovery boundary invalidates stale SWORD inventory cache.

     Failure means filesystem rollback can succeed while the next manager scan still reads cached
     metadata describing the interrupted overlay.
     */
    func testPublisherRecoveryInvalidatesModuleCache() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let destination = fixture.root.appendingPathComponent("mods.d/fresh.conf")
        let cache = fixture.root.appendingPathComponent("mods.d/modules-conf.cache")
        let transaction = try fixture.journal.begin(backupRoot: fixture.backupRoot)
        try transaction.recordPublishedURL(destination)
        try write("fresh", to: destination)
        try write("stale", to: cache)

        try ModuleStoreTransactionPublisher(
            moduleRootURL: fixture.root,
            fileManager: .default
        ).recoverInterruptedTransactions()

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        try assertNoJournalResidue(in: fixture.root)
    }

    /** Creates one isolated canonical root and journal store. */
    private func makeFixture() throws -> ModuleStoreRecoveryFixture {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = parent.appendingPathComponent("sword", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return ModuleStoreRecoveryFixture(
            parent: parent,
            root: root,
            backupRoot: root.appendingPathComponent(
                ".module-transaction-\(UUID().uuidString).backup",
                isDirectory: true
            ),
            journal: ModuleStoreRecoveryJournal(rootURL: root, fileManager: .default)
        )
    }

    /** Writes one UTF-8 fixture file after creating its parent directory. */
    private func write(_ value: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(value.utf8).write(to: url)
    }

    /** Proves recovery removed both journal files and their now-empty container. */
    private func assertNoJournalResidue(in root: URL) throws {
        let journalDirectory = root.appendingPathComponent(".module-recovery")
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalDirectory.path))
    }
}

/** Isolated module-store crash-recovery fixture. */
private struct ModuleStoreRecoveryFixture {
    let parent: URL
    let root: URL
    let backupRoot: URL
    let journal: ModuleStoreRecoveryJournal
}

/** Injects one journal-file discard failure after rollback has become durable. */
private final class ModuleStoreJournalDiscardFaultFileManager: FileManager, @unchecked Sendable {
    /// Whether the next JSON journal removal should fail.
    private var shouldFailJournalRemoval = true

    /** Rejects only the first recovery-journal removal and delegates every other operation. */
    override func removeItem(at URL: URL) throws {
        if shouldFailJournalRemoval,
           URL.pathExtension.lowercased() == "json",
           URL.deletingLastPathComponent().lastPathComponent == ".module-recovery" {
            shouldFailJournalRemoval = false
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: URL)
    }
}
