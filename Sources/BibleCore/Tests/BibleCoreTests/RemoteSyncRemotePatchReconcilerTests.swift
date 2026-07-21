import CryptoKit
import XCTest
@testable import BibleCore

/**
 Verifies create-only remote patch publication and exact-byte reconciliation contracts.

 The suite supplies durable archive files and deterministic in-memory remote responses. Failures mean
 a retry could overwrite an existing Android-compatible patch, accept bytes from another generation,
 or advance after an ambiguous transport race. Temporary archives are removed by each test.
 */
final class RemoteSyncRemotePatchReconcilerTests: XCTestCase {
    /**
     Proves an absent patch is created once through the narrow conditional capability.

     The adapter returns an empty exact-name listing and records any forbidden base-protocol upload.
     Success requires the conditional uploader to receive the validated durable bytes and the base
     upload count to remain zero.
     */
    func testAbsentRemotePatchIsCreatedWithVerifiedDurableBytes() async throws {
        let archiveData = Data("durable-patch".utf8)
        let archive = try makeDurableArchive(data: archiveData)
        defer { try? FileManager.default.removeItem(at: archive.fileURL) }
        let createdFile = remotePatchFile(id: "/device/12.4.sqlite3.gz", size: Int64(archiveData.count))
        let adapter = RemotePatchReconciliationAdapter(listingResponses: [[]])
        let uploader = RemotePatchConditionalUploader(outcomes: [.created(createdFile)])
        let reconciler = RemoteSyncRemotePatchReconciler(
            adapter: adapter,
            conditionalUploader: uploader
        )

        let result = try await reconciler.reconcile(archive: archive)

        XCTAssertEqual(result, .created(createdFile))
        let uploads = await uploader.recordedUploads()
        XCTAssertEqual(uploads.count, 1)
        XCTAssertEqual(uploads[0].name, archive.fileName)
        XCTAssertEqual(uploads[0].data, archiveData)
        XCTAssertEqual(uploads[0].maximumByteCount, archiveData.count)
        XCTAssertEqual(uploads[0].parentID, archive.parentID)
        let unconditionalUploadCount = await adapter.unconditionalUploadCount()
        XCTAssertEqual(unconditionalUploadCount, 0)
    }

    /**
     Proves a byte-identical existing patch is accepted without any upload request.

     The listed candidate is downloaded and checked against the durable size, SHA-256, and bytes.
     A failure indicates retries no longer recognize a previously committed generation exactly.
     */
    func testExactExistingRemotePatchIsAcceptedWithoutUpload() async throws {
        let archiveData = Data("already-remote".utf8)
        let archive = try makeDurableArchive(data: archiveData)
        defer { try? FileManager.default.removeItem(at: archive.fileURL) }
        let existingFile = remotePatchFile(id: "/device/12.4.sqlite3.gz", size: Int64(archiveData.count))
        let adapter = RemotePatchReconciliationAdapter(
            listingResponses: [[existingFile]],
            downloads: [existingFile.id: archiveData]
        )
        let uploader = RemotePatchConditionalUploader(outcomes: [.alreadyExists])
        let reconciler = RemoteSyncRemotePatchReconciler(
            adapter: adapter,
            conditionalUploader: uploader
        )

        let result = try await reconciler.reconcile(archive: archive)

        XCTAssertEqual(result, .matchedExisting(existingFile))
        let downloadedIDs = await adapter.downloadedIDs()
        let conditionalUploadCount = await uploader.recordedUploads().count
        let unconditionalUploadCount = await adapter.unconditionalUploadCount()
        XCTAssertEqual(downloadedIDs, [existingFile.id])
        XCTAssertEqual(conditionalUploadCount, 0)
        XCTAssertEqual(unconditionalUploadCount, 0)
    }

    /**
     Proves a missing local outbox file does not block acceptance of manifest-matching remote bytes.

     The archive descriptor retains the durable size and SHA-256 after its file is removed. Success
     requires the remote download alone to satisfy that manifest and no upload capability to be used.
     A failure would strand a generation after remote commit followed by local archive loss.
     */
    func testMissingLocalArchiveAcceptsManifestMatchingRemotePatch() async throws {
        let archiveData = Data("remote-survived-local-loss".utf8)
        let archive = try makeDurableArchive(data: archiveData)
        try FileManager.default.removeItem(at: archive.fileURL)
        let existingFile = remotePatchFile(id: "/device/12.4.sqlite3.gz", size: Int64(archiveData.count))
        let adapter = RemotePatchReconciliationAdapter(
            listingResponses: [[existingFile]],
            downloads: [existingFile.id: archiveData]
        )
        let reconciler = RemoteSyncRemotePatchReconciler(adapter: adapter)

        let result = try await reconciler.reconcile(archive: archive)

        XCTAssertEqual(result, .matchedExisting(existingFile))
        let unconditionalUploadCount = await adapter.unconditionalUploadCount()
        XCTAssertEqual(unconditionalUploadCount, 0)
    }

    /**
     Proves a missing local archive cannot authorize creation when the remote destination is absent.

     The adapter returns no exact-name candidate and a conditional uploader is available. Reconciliation
     must report missing source bytes before any create request, preserving fail-closed behavior after
     local outbox loss.
     */
    func testMissingLocalArchiveAndAbsentRemotePatchFailsClosed() async throws {
        let archiveData = Data("lost-before-upload".utf8)
        let archive = try makeDurableArchive(data: archiveData)
        try FileManager.default.removeItem(at: archive.fileURL)
        let adapter = RemotePatchReconciliationAdapter(listingResponses: [[]])
        let uploader = RemotePatchConditionalUploader(outcomes: [.alreadyExists])
        let reconciler = RemoteSyncRemotePatchReconciler(
            adapter: adapter,
            conditionalUploader: uploader
        )

        do {
            _ = try await reconciler.reconcile(archive: archive)
            XCTFail("Expected absent local and remote patch bytes to fail closed")
        } catch {
            XCTAssertEqual(
                error as? RemoteSyncRemotePatchReconciliationError,
                .localArchiveMissing
            )
        }
        let conditionalUploadCount = await uploader.recordedUploads().count
        let listCallCount = await adapter.listCallCount()
        let unconditionalUploadCount = await adapter.unconditionalUploadCount()
        XCTAssertEqual(conditionalUploadCount, 0)
        XCTAssertEqual(listCallCount, 1)
        XCTAssertEqual(unconditionalUploadCount, 0)
    }

    /**
     Proves one matching candidate cannot conceal another same-name candidate with conflicting bytes.

     Both candidates are downloaded in deterministic identifier order. Reconciliation must fail closed
     after detecting inconsistency and must not attempt either conditional or unconditional upload.
     */
    func testMultipleSameNameRemoteCandidatesFailWhenAnyBytesConflict() async throws {
        let archiveData = Data("expected-generation".utf8)
        let archive = try makeDurableArchive(data: archiveData)
        defer { try? FileManager.default.removeItem(at: archive.fileURL) }
        let matchingFile = remotePatchFile(id: "/device/a/12.4.sqlite3.gz", size: Int64(archiveData.count))
        let conflictingData = Data("conflicting-generation".utf8)
        let conflictingFile = remotePatchFile(
            id: "/device/b/12.4.sqlite3.gz",
            size: Int64(conflictingData.count)
        )
        let adapter = RemotePatchReconciliationAdapter(
            listingResponses: [[conflictingFile, matchingFile]],
            downloads: [
                matchingFile.id: archiveData,
                conflictingFile.id: conflictingData,
            ]
        )
        let uploader = RemotePatchConditionalUploader(outcomes: [.alreadyExists])
        let reconciler = RemoteSyncRemotePatchReconciler(
            adapter: adapter,
            conditionalUploader: uploader
        )

        do {
            _ = try await reconciler.reconcile(archive: archive)
            XCTFail("Expected inconsistent same-name candidates to fail closed")
        } catch {
            XCTAssertEqual(
                error as? RemoteSyncRemotePatchReconciliationError,
                .conflictingRemotePatch(archive.fileName)
            )
        }
        let downloadedIDs = await adapter.downloadedIDs()
        let conditionalUploadCount = await uploader.recordedUploads().count
        let unconditionalUploadCount = await adapter.unconditionalUploadCount()
        XCTAssertEqual(downloadedIDs, [matchingFile.id, conflictingFile.id])
        XCTAssertEqual(conditionalUploadCount, 0)
        XCTAssertEqual(unconditionalUploadCount, 0)
    }

    /**
     Proves a conditional-create precondition race is reconciled from a fresh remote listing.

     The first listing is absent, the conditional uploader reports an occupied destination, and the
     second listing exposes the winner with exact bytes. Success requires two listings and one verified
     download, with no unconditional overwrite.
     */
    func testPreconditionRaceRelistsAndAcceptsWinningRemoteBytes() async throws {
        let archiveData = Data("race-winner".utf8)
        let archive = try makeDurableArchive(data: archiveData)
        defer { try? FileManager.default.removeItem(at: archive.fileURL) }
        let winningFile = remotePatchFile(id: "/device/12.4.sqlite3.gz", size: Int64(archiveData.count))
        let adapter = RemotePatchReconciliationAdapter(
            listingResponses: [[], [winningFile]],
            downloads: [winningFile.id: archiveData]
        )
        let uploader = RemotePatchConditionalUploader(outcomes: [.alreadyExists])
        let reconciler = RemoteSyncRemotePatchReconciler(
            adapter: adapter,
            conditionalUploader: uploader
        )

        let result = try await reconciler.reconcile(archive: archive)

        XCTAssertEqual(result, .matchedExisting(winningFile))
        let listCallCount = await adapter.listCallCount()
        let downloadedIDs = await adapter.downloadedIDs()
        let conditionalUploadCount = await uploader.recordedUploads().count
        let unconditionalUploadCount = await adapter.unconditionalUploadCount()
        XCTAssertEqual(listCallCount, 2)
        XCTAssertEqual(downloadedIDs, [winningFile.id])
        XCTAssertEqual(conditionalUploadCount, 1)
        XCTAssertEqual(unconditionalUploadCount, 0)
    }

    /**
     Proves remote listing transport failures propagate without being mistaken for absence.

     Treating this failure as an empty listing would authorize an unsafe create. The test therefore
     requires the original transport error and zero upload attempts.
     */
    func testRemoteListingTransportFailurePropagatesWithoutUpload() async throws {
        let archiveData = Data("transport-failure".utf8)
        let archive = try makeDurableArchive(data: archiveData)
        defer { try? FileManager.default.removeItem(at: archive.fileURL) }
        let adapter = RemotePatchReconciliationAdapter(failsListing: true)
        let uploader = RemotePatchConditionalUploader(outcomes: [.alreadyExists])
        let reconciler = RemoteSyncRemotePatchReconciler(
            adapter: adapter,
            conditionalUploader: uploader
        )

        do {
            _ = try await reconciler.reconcile(archive: archive)
            XCTFail("Expected the listing transport failure to propagate")
        } catch {
            XCTAssertEqual(error as? RemotePatchReconciliationTestFailure, .listingTransportFailure)
        }
        let conditionalUploadCount = await uploader.recordedUploads().count
        let unconditionalUploadCount = await adapter.unconditionalUploadCount()
        XCTAssertEqual(conditionalUploadCount, 0)
        XCTAssertEqual(unconditionalUploadCount, 0)
    }

    /**
     Proves an absent destination fails closed when the backend lacks create-only capability.

     The base adapter still implements unconditional upload for compatibility, but reconciliation must
     not call it. A failure indicates a backend without preconditions could overwrite an existing patch
     between list and upload.
     */
    func testAbsentRemotePatchWithoutConditionalCapabilityFailsClosed() async throws {
        let archiveData = Data("requires-precondition".utf8)
        let archive = try makeDurableArchive(data: archiveData)
        defer { try? FileManager.default.removeItem(at: archive.fileURL) }
        let adapter = RemotePatchReconciliationAdapter(listingResponses: [[]])
        let reconciler = RemoteSyncRemotePatchReconciler(adapter: adapter)

        do {
            _ = try await reconciler.reconcile(archive: archive)
            XCTFail("Expected an absent create-only capability to fail closed")
        } catch {
            XCTAssertEqual(
                error as? RemoteSyncRemotePatchReconciliationError,
                .conditionalUploadUnavailable(archive.fileName)
            )
        }
        let unconditionalUploadCount = await adapter.unconditionalUploadCount()
        XCTAssertEqual(unconditionalUploadCount, 0)
    }

    /**
     Writes one uniquely named durable archive and derives its immutable reconciliation metadata.

     - Parameter data: Exact archive bytes to persist for the test.
     - Returns: Descriptor whose URL exists until the calling test removes it.
     - Side effects: Atomically writes one file under the process temporary directory.
     - Throws: Filesystem write failures.
     */
    private func makeDurableArchive(data: Data) throws -> RemoteSyncDurablePatchArchive {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-patch-reconciliation-\(UUID().uuidString).sqlite3.gz")
        try data.write(to: fileURL, options: .atomic)
        return RemoteSyncDurablePatchArchive(
            fileName: "12.4.sqlite3.gz",
            fileURL: fileURL,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            size: Int64(data.count),
            parentID: "/device",
            contentType: NextCloudSyncAdapter.gzipMimeType
        )
    }

    /**
     Builds deterministic remote metadata for one patch candidate.

     - Parameters:
       - id: Backend identifier for download ordering and lookup.
       - size: Advertised remote size; downloaded bytes remain the integrity authority.
     - Returns: Android-shaped gzip patch metadata.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func remotePatchFile(id: String, size: Int64) -> RemoteSyncFile {
        RemoteSyncFile(
            id: id,
            name: "12.4.sqlite3.gz",
            size: size,
            timestamp: 1_750_000_000_000,
            parentID: "/device",
            mimeType: NextCloudSyncAdapter.gzipMimeType
        )
    }
}

/**
 Verifies Nextcloud's narrow conditional-upload capability at the HTTP transport boundary.

 The intercepted WebDAV request proves the adapter sends the create-only precondition and reports an
 occupied destination distinctly. The process-global URL protocol handler is reset after each test.
 */
final class RemoteSyncConditionalUploadTransportTests: XCTestCase {
    /**
     Clears the shared URL protocol callback after each transport assertion.

     - Side effects: Removes the process-global mocked request handler.
     - Failure modes: none.
     */
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    /**
     Proves Nextcloud uses WebDAV's create-only precondition and maps HTTP 412 to `.alreadyExists`.

     The handler inspects method, path, headers, and exact body bytes. A failure means reconciliation
     could overwrite an occupied Android-compatible patch or lose the race distinction.
     */
    func testNextCloudConditionalUploadUsesCreateOnlyHeaderAndReportsExistingDestination() async throws {
        let patchData = Data("conditional-patch".utf8)
        let patchURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "conditional-patch-\(UUID().uuidString).sqlite3.gz"
        )
        try patchData.write(to: patchURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: patchURL) }
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/remote.php/dav/files/alice/device/12.4.sqlite3.gz")
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "*")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), NextCloudSyncAdapter.gzipMimeType)
            XCTAssertEqual(requestBodyData(for: request), patchData)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 412,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        let adapter = try NextCloudSyncAdapter(
            configuration: WebDAVSyncConfiguration(
                serverURL: "https://example.com",
                username: "alice",
                folderPath: nil
            ),
            password: "secret",
            session: makeMockedURLSession()
        )

        let result = try await adapter.uploadIfAbsent(
            name: "12.4.sqlite3.gz",
            fileURL: patchURL,
            maximumByteCount: patchData.count,
            parentID: "/device",
            contentType: NextCloudSyncAdapter.gzipMimeType
        )

        XCTAssertEqual(result, .alreadyExists)
    }
}

/**
 Deterministic base remote adapter for exact-name listing, downloads, and overwrite detection.

 It intentionally does not conform to the conditional-upload protocol, which lets tests prove the
 reconciler fails closed without changing shared production mocks. Actor isolation makes recorded
 request order deterministic across async calls.
 */
private actor RemotePatchReconciliationAdapter: RemoteSyncAdapting {
    private var listingResponses: [[RemoteSyncFile]]
    private let downloads: [String: Data]
    private let failsListing: Bool
    private var recordedDownloadedIDs: [String] = []
    private var recordedListCallCount = 0
    private var recordedUnconditionalUploadCount = 0

    /**
     Creates a remote adapter with ordered listing responses and downloaded payloads.

     - Parameters:
       - listingResponses: Values returned by successive exact-name listing calls.
       - downloads: Payload bytes keyed by candidate identifier.
       - failsListing: Whether every listing call throws the transport sentinel.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    init(
        listingResponses: [[RemoteSyncFile]] = [],
        downloads: [String: Data] = [:],
        failsListing: Bool = false
    ) {
        self.listingResponses = listingResponses
        self.downloads = downloads
        self.failsListing = failsListing
    }

    /** Returns the next listing or the configured transport failure, recording one call. */
    func listFiles(
        parentIDs: [String]?,
        name: String?,
        mimeType: String?,
        modifiedAtLeast: Date?
    ) async throws -> [RemoteSyncFile] {
        recordedListCallCount += 1
        if failsListing {
            throw RemotePatchReconciliationTestFailure.listingTransportFailure
        }
        guard !listingResponses.isEmpty else {
            return []
        }
        return listingResponses.removeFirst()
    }

    /** Throws because reconciliation never creates folders. */
    func createNewFolder(name: String, parentID: String?) async throws -> RemoteSyncFile {
        throw RemotePatchReconciliationTestFailure.unexpectedCall
    }

    /** Returns configured bytes for a candidate and records deterministic download order. */
    func download(id: String) async throws -> Data {
        recordedDownloadedIDs.append(id)
        guard let data = downloads[id] else {
            throw RemotePatchReconciliationTestFailure.missingDownload(id)
        }
        return data
    }

    /** Records and rejects any forbidden unconditional upload. */
    func upload(
        name: String,
        fileURL: URL,
        parentID: String,
        contentType: String
    ) async throws -> RemoteSyncFile {
        recordedUnconditionalUploadCount += 1
        throw RemotePatchReconciliationTestFailure.unexpectedCall
    }

    /** Throws because reconciliation never deletes remote resources. */
    func delete(id: String) async throws {
        throw RemotePatchReconciliationTestFailure.unexpectedCall
    }

    /** Throws because reconciliation never checks folder ownership markers. */
    func isSyncFolderKnown(syncFolderID: String, secretFileName: String) async throws -> Bool {
        throw RemotePatchReconciliationTestFailure.unexpectedCall
    }

    /** Throws because reconciliation never creates folder ownership markers. */
    func makeSyncFolderKnown(syncFolderID: String, deviceIdentifier: String) async throws -> String {
        throw RemotePatchReconciliationTestFailure.unexpectedCall
    }

    /** Returns exact candidate identifiers downloaded so far. */
    func downloadedIDs() -> [String] {
        recordedDownloadedIDs
    }

    /** Returns the number of exact-name listing calls made so far. */
    func listCallCount() -> Int {
        recordedListCallCount
    }

    /** Returns the number of forbidden base-protocol upload calls. */
    func unconditionalUploadCount() -> Int {
        recordedUnconditionalUploadCount
    }
}

/**
 Deterministic create-only uploader that records immutable bytes and returns ordered outcomes.

 The actor models atomic backend results only; listing and downloading remain owned by the separate
 base adapter, matching the production capability boundary.
 */
private actor RemotePatchConditionalUploader: RemoteSyncConditionalFileUploading {
    private var outcomes: [RemoteSyncConditionalUploadResult]
    private var uploads: [RecordedRemotePatchConditionalUpload] = []

    /**
     Creates an uploader with one result per expected conditional request.

     - Parameter outcomes: Ordered atomic-create results.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    init(outcomes: [RemoteSyncConditionalUploadResult]) {
        self.outcomes = outcomes
    }

    /** Reads the bounded test file, records exact request bytes, and returns the next result. */
    func uploadIfAbsent(
        name: String,
        fileURL: URL,
        maximumByteCount: Int,
        parentID: String,
        contentType: String
    ) async throws -> RemoteSyncConditionalUploadResult {
        let data = try RemoteSyncBoundedFileIO.readRegularFile(
            at: fileURL,
            maximumByteCount: maximumByteCount
        )
        uploads.append(
            RecordedRemotePatchConditionalUpload(
                name: name,
                data: data,
                maximumByteCount: maximumByteCount,
                parentID: parentID,
                contentType: contentType
            )
        )
        guard !outcomes.isEmpty else {
            throw RemotePatchReconciliationTestFailure.unexpectedCall
        }
        return outcomes.removeFirst()
    }

    /** Returns all conditional create requests recorded so far. */
    func recordedUploads() -> [RecordedRemotePatchConditionalUpload] {
        uploads
    }
}

/** Exact immutable arguments recorded for one conditional remote patch create. */
private struct RecordedRemotePatchConditionalUpload: Sendable, Equatable {
    let name: String
    let data: Data
    let maximumByteCount: Int
    let parentID: String
    let contentType: String
}

/** Sentinel failures used to distinguish transport propagation from reconciliation policy errors. */
private enum RemotePatchReconciliationTestFailure: Error, Equatable {
    case listingTransportFailure
    case missingDownload(String)
    case unexpectedCall
}
