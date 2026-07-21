import CryptoKit
import XCTest
@testable import BibleCore
@testable import BibleUI

/**
 Verifies that the deterministic UI-test sync backend honors production reconciliation contracts.

 These tests exercise the same create-only capability required by real initial-backup and patch
 publication. Failures indicate the visible synchronization workflow can raise a test-only safety
 error even though the production backend supports the operation.
 */
final class UITestRemoteSyncAdapterTests: XCTestCase {
    /**
     Proves one durable patch is created and then recognized byte-for-byte by a fresh service user.

     The first reconciler creates through the process-session adapter used by Sync Settings. A new
     reconciler obtains that same app-session actor and must observe the previously published bytes,
     matching repeated construction of `RemoteSyncSynchronizationService` in the visible workflow.
     Temporary archive bytes are removed after the assertion.
     */
    func testRemotePatchReconciliationCreatesThenMatchesStoredBytes() async throws {
        let archiveData = Data("ui-test-durable-patch".utf8)
        let archiveURL = try makeTemporaryFile(data: archiveData)
        defer { try? FileManager.default.removeItem(at: archiveURL) }
        let firstAdapter = UITestRemoteSyncAdapter.appSession
        let parent = try await firstAdapter.createNewFolder(
            name: "device-\(UUID().uuidString)",
            parentID: nil
        )
        let archive = RemoteSyncDurablePatchArchive(
            fileName: "12.4.sqlite3.gz",
            fileURL: archiveURL,
            sha256: sha256Hex(archiveData),
            size: Int64(archiveData.count),
            parentID: parent.id,
            contentType: NextCloudSyncAdapter.gzipMimeType
        )
        let reconciler = RemoteSyncRemotePatchReconciler(adapter: firstAdapter)

        let firstResult = try await reconciler.reconcile(archive: archive)
        let createdFile: RemoteSyncFile
        switch firstResult {
        case let .created(file):
            createdFile = file
        case .matchedExisting:
            XCTFail("Expected the first reconciliation to create the absent patch")
            return
        }
        let storedBytes = try await firstAdapter.download(id: createdFile.id)
        XCTAssertEqual(storedBytes, archiveData)

        let secondAdapter = UITestRemoteSyncAdapter.appSession
        XCTAssertTrue(firstAdapter === secondAdapter)
        let retryReconciler = RemoteSyncRemotePatchReconciler(adapter: secondAdapter)
        let retryResult = try await retryReconciler.reconcile(archive: archive)
        XCTAssertEqual(retryResult, .matchedExisting(createdFile))
    }

    /**
     Proves a create-only collision preserves the first remote generation until explicit deletion.

     A second source uses the same parent and filename with different bytes. The adapter must report
     `.alreadyExists`, retain the first payload, expose it through listing and download, and remove it
     only when the production delete operation is requested. Temporary files are cleaned afterward.
     */
    func testConditionalUploadCollisionPreservesFirstBytesUntilDelete() async throws {
        let firstData = Data("first-generation".utf8)
        let secondData = Data("replacement-must-not-win".utf8)
        let firstURL = try makeTemporaryFile(data: firstData)
        let secondURL = try makeTemporaryFile(data: secondData)
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        let adapter = UITestRemoteSyncAdapter(bundleIdentifier: "org.andbible.ios.tests")
        let parent = try await adapter.createNewFolder(name: "device", parentID: nil)

        let firstResult = try await adapter.uploadIfAbsent(
            name: "12.4.sqlite3.gz",
            fileURL: firstURL,
            maximumByteCount: firstData.count,
            parentID: parent.id,
            contentType: NextCloudSyncAdapter.gzipMimeType
        )
        let createdFile: RemoteSyncFile
        switch firstResult {
        case let .created(file):
            createdFile = file
        case .alreadyExists:
            XCTFail("Expected an absent destination to be created")
            return
        }

        let collisionResult = try await adapter.uploadIfAbsent(
            name: createdFile.name,
            fileURL: secondURL,
            maximumByteCount: secondData.count,
            parentID: parent.id,
            contentType: NextCloudSyncAdapter.gzipMimeType
        )
        XCTAssertEqual(collisionResult, .alreadyExists)
        let retainedBytes = try await adapter.download(id: createdFile.id)
        XCTAssertEqual(retainedBytes, firstData)
        let listedFiles = try await adapter.listFiles(
            parentIDs: [parent.id],
            name: createdFile.name,
            mimeType: NextCloudSyncAdapter.gzipMimeType,
            modifiedAtLeast: nil
        )
        XCTAssertEqual(listedFiles, [createdFile])

        try await adapter.delete(id: createdFile.id)
        let filesAfterDelete = try await adapter.listFiles(
            parentIDs: [parent.id],
            name: createdFile.name,
            mimeType: NextCloudSyncAdapter.gzipMimeType,
            modifiedAtLeast: nil
        )
        XCTAssertTrue(filesAfterDelete.isEmpty)
    }

    /**
     Proves create-only occupancy uses remote location rather than a synthesized object identifier.

     Seeded category folders intentionally have opaque backend IDs that differ from the adapter's
     child-path synthesis. Uploading the same parent/name must preserve that seeded generation and
     report `.alreadyExists` without reading it as a distinct destination.
     */
    func testConditionalUploadTreatsOpaqueRemoteIDAtSameLocationAsOccupied() async throws {
        let bundleIdentifier = "org.andbible.ios.tests.opaque-(UUID().uuidString)"
        let adapter = UITestRemoteSyncAdapter(bundleIdentifier: bundleIdentifier)
        let folderName = RemoteSyncCategory.bookmarks.syncFolderName(
            bundleIdentifier: bundleIdentifier
        )
        let sourceURL = try makeTemporaryFile(data: Data("must-not-publish".utf8))
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let seededFiles = try await adapter.listFiles(
            parentIDs: nil,
            name: folderName,
            mimeType: NextCloudSyncAdapter.folderMimeType,
            modifiedAtLeast: nil
        )
        let seededFile = try XCTUnwrap(seededFiles.first)
        XCTAssertTrue(seededFile.id.hasPrefix("/uitest-existing-"))

        let result = try await adapter.uploadIfAbsent(
            name: folderName,
            fileURL: sourceURL,
            maximumByteCount: 64,
            parentID: "/",
            contentType: NextCloudSyncAdapter.folderMimeType
        )
        XCTAssertEqual(result, .alreadyExists)
        let remainingFiles = try await adapter.listFiles(
            parentIDs: nil,
            name: folderName,
            mimeType: NextCloudSyncAdapter.folderMimeType,
            modifiedAtLeast: nil
        )
        XCTAssertEqual(remainingFiles, [seededFile])
    }

    /**
     Verifies incremental listing excludes the cursor timestamp and includes strictly newer files.

     Production WebDAV and Android both implement `createdTime > cursor`; accepting equality here
     would let UI automation hide duplicate patch replay at a timestamp boundary.
     */
    func testIncrementalListingUsesStrictlyNewerTimestampBoundary() async throws {
        let payload = Data("cursor-boundary".utf8)
        let sourceURL = try makeTemporaryFile(data: payload)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let adapter = UITestRemoteSyncAdapter(bundleIdentifier: "org.andbible.ios.tests")
        let parent = try await adapter.createNewFolder(name: "cursor-(UUID().uuidString)", parentID: nil)
        let createdFile = try await adapter.upload(
            name: "12.4.sqlite3.gz",
            fileURL: sourceURL,
            parentID: parent.id,
            contentType: NextCloudSyncAdapter.gzipMimeType
        )
        let exactCursor = Date(timeIntervalSince1970: TimeInterval(createdFile.timestamp) / 1_000)
        let earlierCursor = Date(
            timeIntervalSince1970: TimeInterval(createdFile.timestamp - 1) / 1_000
        )

        let equalTimestampFiles = try await adapter.listFiles(
            parentIDs: [parent.id],
            name: createdFile.name,
            mimeType: createdFile.mimeType,
            modifiedAtLeast: exactCursor
        )
        XCTAssertTrue(equalTimestampFiles.isEmpty)
        let newerFiles = try await adapter.listFiles(
            parentIDs: [parent.id],
            name: createdFile.name,
            mimeType: createdFile.mimeType,
            modifiedAtLeast: earlierCursor
        )
        XCTAssertEqual(newerFiles, [createdFile])
    }

    /**
     Verifies an oversized conditional source fails before any remote object is published.

     The adapter delegates to BibleCore's no-follow bounded reader, so a source one byte above the
     declared ceiling must throw and leave the destination absent.
     */
    func testConditionalUploadRejectsOversizedSourceWithoutPublication() async throws {
        let payload = Data("oversized".utf8)
        let sourceURL = try makeTemporaryFile(data: payload)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let adapter = UITestRemoteSyncAdapter(bundleIdentifier: "org.andbible.ios.tests")
        let parent = try await adapter.createNewFolder(name: "oversized-(UUID().uuidString)", parentID: nil)

        do {
            _ = try await adapter.uploadIfAbsent(
                name: "oversized.sqlite3.gz",
                fileURL: sourceURL,
                maximumByteCount: payload.count - 1,
                parentID: parent.id,
                contentType: NextCloudSyncAdapter.gzipMimeType
            )
            XCTFail("Expected the oversized source to be rejected")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
        let publishedFiles = try await adapter.listFiles(
            parentIDs: [parent.id],
            name: "oversized.sqlite3.gz",
            mimeType: nil,
            modifiedAtLeast: nil
        )
        XCTAssertTrue(publishedFiles.isEmpty)
    }

    /**
     Verifies a symbolic-link source is rejected without publishing its target bytes.

     Temporary link and target paths are unique to this test and removed after the assertion.
     */
    func testConditionalUploadRejectsSymbolicLinkWithoutPublication() async throws {
        let targetURL = try makeTemporaryFile(data: Data("linked-payload".utf8))
        let linkURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ui-test-sync-adapter-link-(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
        defer {
            try? FileManager.default.removeItem(at: linkURL)
            try? FileManager.default.removeItem(at: targetURL)
        }
        let adapter = UITestRemoteSyncAdapter(bundleIdentifier: "org.andbible.ios.tests")
        let parent = try await adapter.createNewFolder(name: "symlink-(UUID().uuidString)", parentID: nil)

        do {
            _ = try await adapter.uploadIfAbsent(
                name: "linked.sqlite3.gz",
                fileURL: linkURL,
                maximumByteCount: 64,
                parentID: parent.id,
                contentType: NextCloudSyncAdapter.gzipMimeType
            )
            XCTFail("Expected the symbolic-link source to be rejected")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
        let publishedFiles = try await adapter.listFiles(
            parentIDs: [parent.id],
            name: "linked.sqlite3.gz",
            mimeType: nil,
            modifiedAtLeast: nil
        )
        XCTAssertTrue(publishedFiles.isEmpty)
    }

    /**
     Verifies a task cancelled before conditional upload cannot publish a destination.

     The child task cancels itself before crossing the adapter boundary, deterministically exercising
     the adapter's first cancellation checkpoint without scheduler timing assumptions.
     */
    func testConditionalUploadHonorsCancellationBeforePublication() async throws {
        let payload = Data("cancelled-payload".utf8)
        let sourceURL = try makeTemporaryFile(data: payload)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let adapter = UITestRemoteSyncAdapter(bundleIdentifier: "org.andbible.ios.tests")
        let parent = try await adapter.createNewFolder(name: "cancelled-(UUID().uuidString)", parentID: nil)

        let uploadTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await adapter.uploadIfAbsent(
                name: "cancelled.sqlite3.gz",
                fileURL: sourceURL,
                maximumByteCount: payload.count,
                parentID: parent.id,
                contentType: NextCloudSyncAdapter.gzipMimeType
            )
        }
        do {
            _ = try await uploadTask.value
            XCTFail("Expected cancellation before publication")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let publishedFiles = try await adapter.listFiles(
            parentIDs: [parent.id],
            name: "cancelled.sqlite3.gz",
            mimeType: nil,
            modifiedAtLeast: nil
        )
        XCTAssertTrue(publishedFiles.isEmpty)
    }

    /**
     Writes one unique temporary source file for create-only upload tests.

     - Parameter data: Exact bytes to persist.
     - Returns: File URL that remains valid until the caller removes it.
     - Side effects: Atomically creates one file in the process temporary directory.
     - Throws: Filesystem write failures.
     */
    private func makeTemporaryFile(data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ui-test-sync-adapter-\(UUID().uuidString).sqlite3.gz")
        try data.write(to: url, options: .atomic)
        return url
    }

    /**
     Encodes deterministic archive bytes as the lowercase digest expected by reconciliation.

     - Parameter data: Bytes whose identity should be recorded.
     - Returns: A 64-character lowercase SHA-256 hexadecimal string.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
