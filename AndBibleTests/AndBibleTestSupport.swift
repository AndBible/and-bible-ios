import XCTest
import AVFoundation
@testable import BibleCore
import CLibSword
@testable import SwordKit
import SwiftData
import SQLite3
@testable import BibleUI
@testable import BibleView
import struct SwiftUI.Binding
import enum SwiftUI.ColorScheme
import struct SwiftUI.EdgeInsets
import struct SwiftUI.EmptyView
#if os(iOS)
import UIKit
import WebKit
import struct SwiftUI.Color
#endif

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class FakeSpeechSynthesizer: SpeechSynthesizing {
    weak var delegate: AVSpeechSynthesizerDelegate?

    private(set) var spokenUtterances: [AVSpeechUtterance] = []
    private(set) var stopBoundaries: [AVSpeechBoundary] = []
    private(set) var pauseBoundaries: [AVSpeechBoundary] = []
    private(set) var continueCount = 0

    func speak(_ utterance: AVSpeechUtterance) {
        spokenUtterances.append(utterance)
    }

    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        stopBoundaries.append(boundary)
        return true
    }

    func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        pauseBoundaries.append(boundary)
        return true
    }

    func continueSpeaking() -> Bool {
        continueCount += 1
        return true
    }
}

extension AndBibleTests {
    #if os(iOS)
    func makeRecordingBridge() -> (BibleBridge, () -> [String]) {
        let bridge = BibleBridge()
        var evaluatedScripts: [String] = []
        bridge.javaScriptEvaluationObserver = { script in
            evaluatedScripts.append(script)
        }
        return (bridge, { evaluatedScripts })
    }

    func setConfigPayload(
        from scripts: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        let script = try XCTUnwrap(
            scripts.first { $0.contains("bibleView.emit('set_config'") },
            "Expected a set_config bridge emission",
            file: file,
            line: line
        )
        let prefix = "bibleView.emit('set_config', "
        let start = try XCTUnwrap(
            script.range(of: prefix)?.upperBound,
            "Expected set_config payload prefix in script: \(script)",
            file: file,
            line: line
        )
        let end = try XCTUnwrap(
            script.range(of: "); } catch", range: start..<script.endIndex)?.lowerBound,
            "Expected set_config payload suffix in script: \(script)",
            file: file,
            line: line
        )
        let json = String(script[start..<end])
        let data = try XCTUnwrap(
            json.data(using: .utf8),
            "Expected UTF-8 JSON payload",
            file: file,
            line: line
        )
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(
            object as? [String: Any],
            "Expected set_config payload to be a JSON object",
            file: file,
            line: line
        )
    }
    #endif
    func bridgeJSONObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try bridgeEncoder.encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    func assertJSONKeys(
        _ object: [String: Any],
        _ expectedKeys: Set<String>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(Set(object.keys), expectedKeys, file: file, line: line)
    }

    var malformedCallIdRequests: [(method: String, args: [Any])] {
        [
            ("requestMoreToBeginning", []),
            ("requestMoreToBeginning", ["41"]),
            ("requestMoreToEnd", []),
            ("requestMoreToEnd", ["42"]),
            ("refChooserDialog", []),
            ("refChooserDialog", ["43"]),
            ("parseRef", [44]),
            ("parseRef", ["Genesis 1:1", 44]),
            ("getMyDocumentPageRawContent", [45, "MYDOC"]),
            ("getMyDocumentPageRawContent", ["MYDOC", "intro", 45]),
        ]
    }

    var malformedBridgeMessages: [(method: String, args: [Any])] {
        [
            ("jsLog", ["WARN"]),
            ("toast", []),
            ("reportModalState", []),
            ("reportInputFocus", []),
            ("setLimitAmbiguousModalSize", []),
            ("selectionChanged", []),
            ("setEditing", []),
            ("saveState", []),
            ("onKeyDown", []),
            ("scrolledToOrdinal", ["main"]),
            ("scrolledToOrdinal", ["main", 1, "true"]),
            ("addBookmark", ["KJV", 1, 1]),
            ("addGenericBookmark", ["KJV", "Gen.1.1", 1, 1]),
            ("removeBookmark", []),
            ("removeGenericBookmark", []),
            ("saveBookmarkNote", []),
            ("saveBookmarkNote", ["bookmark-id", 7]),
            ("saveGenericBookmarkNote", []),
            ("saveGenericBookmarkNote", ["bookmark-id", 7]),
            ("assignLabels", []),
            ("genericAssignLabels", []),
            ("toggleBookmarkLabel", ["bookmark-id"]),
            ("toggleGenericBookmarkLabel", ["bookmark-id"]),
            ("removeBookmarkLabel", ["bookmark-id"]),
            ("removeGenericBookmarkLabel", ["bookmark-id"]),
            ("setAsPrimaryLabel", ["bookmark-id"]),
            ("setAsPrimaryLabelGeneric", ["bookmark-id"]),
            ("setBookmarkWholeVerse", ["bookmark-id"]),
            ("setGenericBookmarkWholeVerse", ["bookmark-id"]),
            ("setBookmarkCustomIcon", []),
            ("setBookmarkCustomIcon", ["bookmark-id", 7]),
            ("setGenericBookmarkCustomIcon", []),
            ("setGenericBookmarkCustomIcon", ["bookmark-id", 7]),
            ("shareVerse", ["KJV", 1]),
            ("copyVerse", ["KJV", 1]),
            ("copyMyDocumentContent", ["MYDOC"]),
            ("shareMyDocumentContent", ["MYDOC"]),
            ("saveMyDocumentPageContent", ["MYDOC", "page-id"]),
            ("saveMyDocumentPageContent", ["MYDOC", "page-id", "content", 7]),
            ("reloadMyDocumentPage", []),
            ("regenerateMyDocumentPage", []),
            ("deleteMyDocumentPage", []),
            ("shareBookmarkVerse", [["id": "bookmark-id"]]),
            ("compare", ["KJV", 1]),
            ("speak", ["KJV", "KJV", 1]),
            ("speakGeneric", ["KJV", "Gen.1.1", 1]),
            ("speakMemorizationLoop", ["KJV", "KJV", 1]),
            ("memorize", ["KJV", 1]),
            ("markAsMemorized", ["KJV", 1]),
            ("addMemorizationTarget", ["KJV", 1]),
            ("removeMemorizationTarget", ["KJV", 1]),
            ("unmarkMemorized", ["KJV", 1]),
            ("recordChapterRead", ["KJV", 1, 1]),
            ("recordChapterRead", ["KJV", 1, 1, 7]),
            ("markChapterRead", ["KJV", 1, 1]),
            ("markChapterRead", ["KJV", 1, 1, 7]),
            ("openChapterReadHistory", ["KJV", 1]),
            ("openChapterReadHistory", ["KJV", 1, "1"]),
            ("openReadingProgress", []),
            ("openReadingProgress", ["1"]),
            ("openReadingProgressSettings", [1]),
            ("setReadingProgressSettings", []),
            ("setReadingProgressSettings", [["autoMarkMemorized": true]]),
            ("unmarkChapterRead", ["KJV", 1]),
            ("unmarkChapterRead", ["KJV", 1, "1"]),
            ("addParagraphBreakBookmark", ["KJV", 1]),
            ("addGenericParagraphBreakBookmark", ["KJV", "Gen.1.1", 1]),
            ("openStudyPad", ["label-id"]),
            ("openMyNotes", ["KJV"]),
            ("deleteStudyPadEntry", []),
            ("createNewStudyPadEntry", ["label-id", "journal"]),
            ("setStudyPadCursor", ["label-id"]),
            ("updateOrderNumber", ["label-id"]),
            ("updateStudyPadTextEntry", []),
            ("updateStudyPadTextEntryText", ["entry-id"]),
            ("updateBookmarkToLabel", []),
            ("updateGenericBookmarkToLabel", []),
            ("setBookmarkEditAction", ["bookmark-id"]),
            ("openExternalLink", []),
            ("openEpubLink", ["module", "key"]),
            ("toggleCompareDocument", []),
            ("helpDialog", []),
            ("helpDialog", ["content", 7]),
            ("shareHtml", []),
        ]
    }

    func makeTemporaryBundledSwordPath() throws -> String {
        let fm = FileManager.default
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bundledSwordURL = sourceRoot
            .appendingPathComponent("AndBible", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("sword", isDirectory: true)
        XCTAssertTrue(
            fm.fileExists(atPath: bundledSwordURL.path),
            "Expected repo-bundled sword resources at \(bundledSwordURL.path)"
        )

        let tempRoot = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sword", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try copyDirectoryContents(from: bundledSwordURL, to: tempRoot)

        temporarySwordModulePaths.append(tempRoot.path)
        return tempRoot.path
    }

    func copyDirectoryContents(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]) {
            let target = destination.appendingPathComponent(item.lastPathComponent, isDirectory: true)
            let values = try item.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                try copyDirectoryContents(from: item, to: target)
            } else {
                try fm.copyItem(at: item, to: target)
            }
        }
    }

    func makeMockedURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    func makeInMemorySettingsStore() throws -> SettingsStore {
        SettingsStore(modelContext: ModelContext(try makeInMemorySettingsContainer()))
    }

    func makeInMemorySettingsContainer() throws -> ModelContainer {
        let schema = Schema([Setting.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    func makeLifecycleSyncReport(for category: RemoteSyncCategory) -> RemoteSyncCategorySynchronizationReport {
        RemoteSyncCategorySynchronizationReport(
            category: category,
            bootstrapState: RemoteSyncBootstrapState(
                syncFolderID: "/sync/\(category.rawValue)",
                deviceFolderID: "/sync/\(category.rawValue)/device",
                secretFileName: "device-known-ios"
            ),
            initialRestoreReport: nil,
            patchReplayReport: nil,
            patchUploadReport: nil,
            discoveredPatchCount: 0,
            lastPatchWritten: nil,
            lastSynchronized: 1_000
        )
    }

    func requestBodyData(for request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var data = Data()
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read < 0 {
                return nil
            }
            if read == 0 {
                break
            }
            data.append(buffer, count: read)
        }
        return data
    }

    static let sampleWebDAVMultiStatusXML = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:multistatus xmlns:d="DAV:">
      <d:response>
        <d:href>/remote.php/dav/files/alice/sync/</d:href>
        <d:propstat>
          <d:prop>
            <d:displayname>sync</d:displayname>
            <d:resourcetype><d:collection /></d:resourcetype>
            <d:getlastmodified>Wed, 26 Feb 2026 12:00:00 GMT</d:getlastmodified>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/remote.php/dav/files/alice/sync/1.1.sqlite3.gz</d:href>
        <d:propstat>
          <d:prop>
            <d:displayname>1.1.sqlite3.gz</d:displayname>
            <d:getcontentlength>12345</d:getcontentlength>
            <d:getcontenttype>application/gzip</d:getcontenttype>
            <d:getlastmodified>Wed, 26 Feb 2026 12:01:00 GMT</d:getlastmodified>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
    </d:multistatus>
    """

    static func webDAVMultiStatusXML(folderPath: String, fileName: String) -> String {
        let normalizedFolderPath = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
        let folderDisplayName = normalizedFolderPath
            .split(separator: "/")
            .last
            .map(String.init) ?? ""
        return [
            #"<?xml version="1.0" encoding="utf-8"?>"#,
            #"<d:multistatus xmlns:d="DAV:">"#,
            #"  <d:response>"#,
            "    <d:href>\(normalizedFolderPath)</d:href>",
            #"    <d:propstat>"#,
            #"      <d:prop>"#,
            "        <d:displayname>\(folderDisplayName)</d:displayname>",
            #"        <d:resourcetype><d:collection /></d:resourcetype>"#,
            #"        <d:getlastmodified>Wed, 26 Feb 2026 12:00:00 GMT</d:getlastmodified>"#,
            #"      </d:prop>"#,
            #"      <d:status>HTTP/1.1 200 OK</d:status>"#,
            #"    </d:propstat>"#,
            #"  </d:response>"#,
            #"  <d:response>"#,
            "    <d:href>\(normalizedFolderPath)\(fileName)</d:href>",
            #"    <d:propstat>"#,
            #"      <d:prop>"#,
            "        <d:displayname>\(fileName)</d:displayname>",
            #"        <d:getcontentlength>12345</d:getcontentlength>"#,
            #"        <d:getcontenttype>application/gzip</d:getcontenttype>"#,
            #"        <d:getlastmodified>Wed, 26 Feb 2026 12:01:00 GMT</d:getlastmodified>"#,
            #"      </d:prop>"#,
            #"      <d:status>HTTP/1.1 200 OK</d:status>"#,
            #"    </d:propstat>"#,
            #"  </d:response>"#,
            #"</d:multistatus>"#,
        ].joined(separator: "\n")
    }

    struct AndroidReadingPlanRow {
        let id: UUID
        let planCode: String
        let startDate: Date
        let currentDay: Int
    }

    struct AndroidReadingPlanStatusRow {
        let id: UUID
        let planCode: String
        let dayNumber: Int
        let readingStatusJSON: String
    }

    struct AndroidLogEntryRow {
        let tableName: String
        let entityID1: RemoteSyncSQLiteValue
        let entityID2: RemoteSyncSQLiteValue
        let type: RemoteSyncLogEntryType
        let lastUpdated: Int64
        let sourceDevice: String
    }

    struct AndroidLabelRow {
        let id: UUID
        let name: String
        let colour: Int
        let markerStyle: Bool
        let markerStyleWholeVerse: Bool
        let underlineStyle: Bool
        let underlineStyleWholeVerse: Bool
        let hideStyle: Bool
        let hideStyleWholeVerse: Bool
        let favourite: Bool
        let type: String?
        let customIcon: String?

        init(
            id: UUID,
            name: String,
            colour: Int = Label.defaultColor,
            markerStyle: Bool = false,
            markerStyleWholeVerse: Bool = false,
            underlineStyle: Bool = false,
            underlineStyleWholeVerse: Bool = true,
            hideStyle: Bool = false,
            hideStyleWholeVerse: Bool = false,
            favourite: Bool = false,
            type: String? = nil,
            customIcon: String? = nil
        ) {
            self.id = id
            self.name = name
            self.colour = colour
            self.markerStyle = markerStyle
            self.markerStyleWholeVerse = markerStyleWholeVerse
            self.underlineStyle = underlineStyle
            self.underlineStyleWholeVerse = underlineStyleWholeVerse
            self.hideStyle = hideStyle
            self.hideStyleWholeVerse = hideStyleWholeVerse
            self.favourite = favourite
            self.type = type
            self.customIcon = customIcon
        }
    }

    struct AndroidBibleBookmarkRow {
        let id: UUID
        let kjvOrdinalStart: Int
        let kjvOrdinalEnd: Int
        let ordinalStart: Int
        let ordinalEnd: Int
        let v11n: String
        let playbackSettingsJSON: String?
        let createdAt: Date
        let book: String?
        let startOffset: Int?
        let endOffset: Int?
        let primaryLabelID: UUID?
        let lastUpdatedOn: Date
        let wholeVerse: Bool
        let type: String?
        let customIcon: String?
        let editActionMode: String?
        let editActionContent: String?

        init(
            id: UUID,
            kjvOrdinalStart: Int,
            kjvOrdinalEnd: Int,
            ordinalStart: Int,
            ordinalEnd: Int,
            v11n: String = "KJVA",
            playbackSettingsJSON: String? = nil,
            createdAt: Date,
            book: String? = nil,
            startOffset: Int? = nil,
            endOffset: Int? = nil,
            primaryLabelID: UUID? = nil,
            lastUpdatedOn: Date,
            wholeVerse: Bool = true,
            type: String? = nil,
            customIcon: String? = nil,
            editActionMode: String? = nil,
            editActionContent: String? = nil
        ) {
            self.id = id
            self.kjvOrdinalStart = kjvOrdinalStart
            self.kjvOrdinalEnd = kjvOrdinalEnd
            self.ordinalStart = ordinalStart
            self.ordinalEnd = ordinalEnd
            self.v11n = v11n
            self.playbackSettingsJSON = playbackSettingsJSON
            self.createdAt = createdAt
            self.book = book
            self.startOffset = startOffset
            self.endOffset = endOffset
            self.primaryLabelID = primaryLabelID
            self.lastUpdatedOn = lastUpdatedOn
            self.wholeVerse = wholeVerse
            self.type = type
            self.customIcon = customIcon
            self.editActionMode = editActionMode
            self.editActionContent = editActionContent
        }
    }

    struct AndroidGenericBookmarkRow {
        let id: UUID
        let key: String
        let createdAt: Date
        let bookInitials: String
        let ordinalStart: Int
        let ordinalEnd: Int
        let startOffset: Int?
        let endOffset: Int?
        let primaryLabelID: UUID?
        let lastUpdatedOn: Date
        let wholeVerse: Bool
        let playbackSettingsJSON: String?
        let customIcon: String?
        let editActionMode: String?
        let editActionContent: String?

        init(
            id: UUID,
            key: String,
            createdAt: Date,
            bookInitials: String,
            ordinalStart: Int,
            ordinalEnd: Int,
            startOffset: Int? = nil,
            endOffset: Int? = nil,
            primaryLabelID: UUID? = nil,
            lastUpdatedOn: Date,
            wholeVerse: Bool = true,
            playbackSettingsJSON: String? = nil,
            customIcon: String? = nil,
            editActionMode: String? = nil,
            editActionContent: String? = nil
        ) {
            self.id = id
            self.key = key
            self.createdAt = createdAt
            self.bookInitials = bookInitials
            self.ordinalStart = ordinalStart
            self.ordinalEnd = ordinalEnd
            self.startOffset = startOffset
            self.endOffset = endOffset
            self.primaryLabelID = primaryLabelID
            self.lastUpdatedOn = lastUpdatedOn
            self.wholeVerse = wholeVerse
            self.playbackSettingsJSON = playbackSettingsJSON
            self.customIcon = customIcon
            self.editActionMode = editActionMode
            self.editActionContent = editActionContent
        }
    }

    struct AndroidBookmarkNoteRow {
        let bookmarkID: UUID
        let notes: String
    }

    struct AndroidBookmarkLabelLinkRow {
        let bookmarkID: UUID
        let labelID: UUID
        let orderNumber: Int
        let indentLevel: Int
        let expandContent: Bool
    }

    struct AndroidStudyPadEntryRow {
        let id: UUID
        let labelID: UUID
        let orderNumber: Int
        let indentLevel: Int
    }

    struct AndroidStudyPadTextRow {
        let entryID: UUID
        let text: String
    }

    func makeReadingPlanRestoreModelContainer() throws -> ModelContainer {
        let schema = Schema([
            ReadingPlan.self,
            ReadingPlanDay.self,
            Setting.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    func makeBookmarkRestoreModelContainer() throws -> ModelContainer {
        let schema = Schema([
            BibleBookmark.self,
            BibleBookmarkNotes.self,
            BibleBookmarkToLabel.self,
            GenericBookmark.self,
            GenericBookmarkNotes.self,
            GenericBookmarkToLabel.self,
            Label.self,
            StudyPadTextEntry.self,
            StudyPadTextEntryText.self,
            Setting.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    func makeAndroidReadingPlansDatabase(
        plans: [AndroidReadingPlanRow],
        statuses: [AndroidReadingPlanStatusRow],
        logEntries: [AndroidLogEntryRow] = []
    ) throws -> URL {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("android-readingplans-\(UUID().uuidString).sqlite3")

        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK, let db else {
            XCTFail("Failed to open temporary Android reading plan database")
            throw RemoteSyncReadingPlanRestoreError.invalidSQLiteDatabase
        }
        defer { sqlite3_close(db) }

        XCTAssertEqual(
            sqlite3_exec(
                db,
                """
                CREATE TABLE ReadingPlan (
                    planCode TEXT NOT NULL,
                    planStartDate INTEGER NOT NULL,
                    planCurrentDay INTEGER NOT NULL DEFAULT 1,
                    id BLOB NOT NULL PRIMARY KEY
                );
                CREATE TABLE ReadingPlanStatus (
                    planCode TEXT NOT NULL,
                    planDay INTEGER NOT NULL,
                    readingStatus TEXT NOT NULL,
                    id BLOB NOT NULL PRIMARY KEY
                );
                CREATE TABLE LogEntry (
                    tableName TEXT NOT NULL,
                    entityId1 BLOB,
                    entityId2 BLOB,
                    type TEXT NOT NULL,
                    lastUpdated INTEGER NOT NULL,
                    sourceDevice TEXT NOT NULL
                );
                """,
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )

        for plan in plans {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO ReadingPlan (planCode, planStartDate, planCurrentDay, id) VALUES (?, ?, ?, ?)",
                    -1,
                    &statement,
                    nil
                ),
                SQLITE_OK
            )

            sqlite3_bind_text(statement, 1, plan.planCode, -1, sqliteTransient)
            sqlite3_bind_int64(statement, 2, Int64(plan.startDate.timeIntervalSince1970 * 1000))
            sqlite3_bind_int(statement, 3, Int32(plan.currentDay))
            let blob = uuidBlob(plan.id)
            _ = blob.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, 4, bytes.baseAddress, Int32(blob.count), sqliteTransient)
            }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        for status in statuses {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO ReadingPlanStatus (planCode, planDay, readingStatus, id) VALUES (?, ?, ?, ?)",
                    -1,
                    &statement,
                    nil
                ),
                SQLITE_OK
            )

            sqlite3_bind_text(statement, 1, status.planCode, -1, sqliteTransient)
            sqlite3_bind_int(statement, 2, Int32(status.dayNumber))
            sqlite3_bind_text(statement, 3, status.readingStatusJSON, -1, sqliteTransient)
            let blob = uuidBlob(status.id)
            _ = blob.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, 4, bytes.baseAddress, Int32(blob.count), sqliteTransient)
            }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        for entry in logEntries {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO LogEntry (tableName, entityId1, entityId2, type, lastUpdated, sourceDevice) VALUES (?, ?, ?, ?, ?, ?)",
                    -1,
                    &statement,
                    nil
                ),
                SQLITE_OK
            )

            sqlite3_bind_text(statement, 1, entry.tableName, -1, sqliteTransient)
            bindSQLiteValue(entry.entityID1, to: statement, index: 2)
            bindSQLiteValue(entry.entityID2, to: statement, index: 3)
            sqlite3_bind_text(statement, 4, entry.type.rawValue, -1, sqliteTransient)
            sqlite3_bind_int64(statement, 5, entry.lastUpdated)
            sqlite3_bind_text(statement, 6, entry.sourceDevice, -1, sqliteTransient)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        return databaseURL
    }

    /**
     Builds one staged patch-archive fixture for reading-plan replay tests.

     - Parameters:
       - patchDatabaseURL: Local SQLite database containing Android patch rows.
       - sourceDevice: Android source-device name owning the patch stream.
       - patchNumber: Monotonic patch number within the source-device stream.
       - fileTimestamp: Remote millisecond timestamp that should be recorded on the staged archive.
     - Returns: Staged patch archive pointing at a temporary gzip file.
     - Side effects:
       - reads the supplied SQLite database
       - writes one temporary gzip archive beneath the process temporary directory
     - Failure modes:
       - rethrows filesystem read and write errors
       - rethrows gzip-compression failures from `RemoteSyncArchiveStagingService`
     */
    func makeReadingPlanPatchArchive(
        patchDatabaseURL: URL,
        sourceDevice: String,
        patchNumber: Int64,
        fileTimestamp: Int64
    ) throws -> RemoteSyncStagedPatchArchive {
        let archiveData = try RemoteSyncArchiveStagingService.gzip(Data(contentsOf: patchDatabaseURL))
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("android-readingplans-patch-\(UUID().uuidString).sqlite3.gz")
        try archiveData.write(to: archiveURL, options: .atomic)

        return RemoteSyncStagedPatchArchive(
            patch: RemoteSyncDiscoveredPatch(
                sourceDevice: sourceDevice,
                patchNumber: patchNumber,
                schemaVersion: 1,
                file: RemoteSyncFile(
                    id: "/org.andbible.ios-sync-readingplans/\(sourceDevice)/\(patchNumber).sqlite3.gz",
                    name: "\(patchNumber).sqlite3.gz",
                    size: Int64(archiveData.count),
                    timestamp: fileTimestamp,
                    parentID: "/org.andbible.ios-sync-readingplans/\(sourceDevice)",
                    mimeType: "application/gzip"
                )
            ),
            archiveFileURL: archiveURL
        )
    }

    /**
     Creates one staged bookmark patch archive from a temporary SQLite database fixture.

     - Parameters:
       - patchDatabaseURL: Local SQLite database containing Android bookmark patch rows.
       - sourceDevice: Android source-device name owning the patch stream.
       - patchNumber: Monotonic patch number within the source-device stream.
       - fileTimestamp: Remote millisecond timestamp that should be recorded on the staged archive.
     - Returns: Staged patch archive pointing at a temporary gzip file.
     - Side effects:
       - reads the supplied SQLite database
       - writes one temporary gzip archive beneath the process temporary directory
     - Failure modes:
       - rethrows filesystem read and write errors
       - rethrows gzip-compression failures from `RemoteSyncArchiveStagingService`
     */
    func makeBookmarkPatchArchive(
        patchDatabaseURL: URL,
        sourceDevice: String,
        patchNumber: Int64,
        fileTimestamp: Int64
    ) throws -> RemoteSyncStagedPatchArchive {
        let archiveData = try RemoteSyncArchiveStagingService.gzip(Data(contentsOf: patchDatabaseURL))
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("android-bookmarks-patch-\(UUID().uuidString).sqlite3.gz")
        try archiveData.write(to: archiveURL, options: .atomic)

        return RemoteSyncStagedPatchArchive(
            patch: RemoteSyncDiscoveredPatch(
                sourceDevice: sourceDevice,
                patchNumber: patchNumber,
                schemaVersion: 1,
                file: RemoteSyncFile(
                    id: "/org.andbible.ios-sync-bookmarks/\(sourceDevice)/\(patchNumber).sqlite3.gz",
                    name: "\(patchNumber).sqlite3.gz",
                    size: Int64(archiveData.count),
                    timestamp: fileTimestamp,
                    parentID: "/org.andbible.ios-sync-bookmarks/\(sourceDevice)",
                    mimeType: "application/gzip"
                )
            ),
            archiveFileURL: archiveURL
        )
    }

    func makeAndroidBookmarksDatabase(
        labels: [AndroidLabelRow],
        bibleBookmarks: [AndroidBibleBookmarkRow] = [],
        bibleNotes: [AndroidBookmarkNoteRow] = [],
        bibleLinks: [AndroidBookmarkLabelLinkRow] = [],
        genericBookmarks: [AndroidGenericBookmarkRow] = [],
        genericNotes: [AndroidBookmarkNoteRow] = [],
        genericLinks: [AndroidBookmarkLabelLinkRow] = [],
        studyPadEntries: [AndroidStudyPadEntryRow] = [],
        studyPadTexts: [AndroidStudyPadTextRow] = [],
        logEntries: [AndroidLogEntryRow] = []
    ) throws -> URL {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("android-bookmarks-\(UUID().uuidString).sqlite3")

        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK, let db else {
            XCTFail("Failed to open temporary Android bookmark database")
            throw RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase
        }
        defer { sqlite3_close(db) }

        XCTAssertEqual(
            sqlite3_exec(
                db,
                """
                CREATE TABLE Label (
                    id BLOB NOT NULL PRIMARY KEY,
                    name TEXT NOT NULL,
                    color INTEGER NOT NULL DEFAULT 0,
                    markerStyle INTEGER NOT NULL DEFAULT 0,
                    markerStyleWholeVerse INTEGER NOT NULL DEFAULT 0,
                    underlineStyle INTEGER NOT NULL DEFAULT 0,
                    underlineStyleWholeVerse INTEGER NOT NULL DEFAULT 0,
                    hideStyle INTEGER NOT NULL DEFAULT 0,
                    hideStyleWholeVerse INTEGER NOT NULL DEFAULT 0,
                    favourite INTEGER NOT NULL DEFAULT 0,
                    type TEXT DEFAULT NULL,
                    customIcon TEXT DEFAULT NULL
                );
                CREATE TABLE BibleBookmark (
                    kjvOrdinalStart INTEGER NOT NULL,
                    kjvOrdinalEnd INTEGER NOT NULL,
                    ordinalStart INTEGER NOT NULL,
                    ordinalEnd INTEGER NOT NULL,
                    v11n TEXT NOT NULL,
                    playbackSettings TEXT DEFAULT NULL,
                    id BLOB NOT NULL PRIMARY KEY,
                    createdAt INTEGER NOT NULL,
                    book TEXT DEFAULT NULL,
                    startOffset INTEGER DEFAULT NULL,
                    endOffset INTEGER DEFAULT NULL,
                    primaryLabelId BLOB DEFAULT NULL,
                    lastUpdatedOn INTEGER NOT NULL DEFAULT 0,
                    wholeVerse INTEGER NOT NULL DEFAULT 0,
                    type TEXT DEFAULT NULL,
                    customIcon TEXT DEFAULT NULL,
                    editAction_mode TEXT DEFAULT NULL,
                    editAction_content TEXT DEFAULT NULL
                );
                CREATE TABLE BibleBookmarkNotes (
                    bookmarkId BLOB NOT NULL PRIMARY KEY,
                    notes TEXT NOT NULL
                );
                CREATE TABLE BibleBookmarkToLabel (
                    bookmarkId BLOB NOT NULL,
                    labelId BLOB NOT NULL,
                    orderNumber INTEGER NOT NULL DEFAULT -1,
                    indentLevel INTEGER NOT NULL DEFAULT 0,
                    expandContent INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (bookmarkId, labelId)
                );
                CREATE TABLE GenericBookmark (
                    id BLOB NOT NULL PRIMARY KEY,
                    `key` TEXT NOT NULL,
                    createdAt INTEGER NOT NULL,
                    bookInitials TEXT NOT NULL DEFAULT '',
                    ordinalStart INTEGER NOT NULL,
                    ordinalEnd INTEGER NOT NULL,
                    startOffset INTEGER DEFAULT NULL,
                    endOffset INTEGER DEFAULT NULL,
                    primaryLabelId BLOB DEFAULT NULL,
                    lastUpdatedOn INTEGER NOT NULL DEFAULT 0,
                    wholeVerse INTEGER NOT NULL DEFAULT 0,
                    playbackSettings TEXT DEFAULT NULL,
                    customIcon TEXT DEFAULT NULL,
                    editAction_mode TEXT DEFAULT NULL,
                    editAction_content TEXT DEFAULT NULL
                );
                CREATE TABLE GenericBookmarkNotes (
                    bookmarkId BLOB NOT NULL PRIMARY KEY,
                    notes TEXT NOT NULL
                );
                CREATE TABLE GenericBookmarkToLabel (
                    bookmarkId BLOB NOT NULL,
                    labelId BLOB NOT NULL,
                    orderNumber INTEGER NOT NULL DEFAULT -1,
                    indentLevel INTEGER NOT NULL DEFAULT 0,
                    expandContent INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (bookmarkId, labelId)
                );
                CREATE TABLE StudyPadTextEntry (
                    id BLOB NOT NULL PRIMARY KEY,
                    labelId BLOB NOT NULL,
                    orderNumber INTEGER NOT NULL,
                    indentLevel INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE StudyPadTextEntryText (
                    studyPadTextEntryId BLOB NOT NULL PRIMARY KEY,
                    text TEXT NOT NULL
                );
                CREATE TABLE LogEntry (
                    tableName TEXT NOT NULL,
                    entityId1 BLOB NOT NULL,
                    entityId2 BLOB,
                    type TEXT NOT NULL,
                    lastUpdated INTEGER NOT NULL,
                    sourceDevice TEXT NOT NULL,
                    PRIMARY KEY (tableName, entityId1, entityId2)
                );
                """,
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )

        for label in labels {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO Label (id, name, color, markerStyle, markerStyleWholeVerse, underlineStyle, underlineStyleWholeVerse, hideStyle, hideStyleWholeVerse, favourite, type, customIcon) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    -1,
                    &statement,
                    nil
                ),
                SQLITE_OK
            )
            bindUUIDBlob(label.id, to: statement, index: 1)
            sqlite3_bind_text(statement, 2, label.name, -1, sqliteTransient)
            sqlite3_bind_int(statement, 3, Int32(label.colour))
            sqlite3_bind_int(statement, 4, label.markerStyle ? 1 : 0)
            sqlite3_bind_int(statement, 5, label.markerStyleWholeVerse ? 1 : 0)
            sqlite3_bind_int(statement, 6, label.underlineStyle ? 1 : 0)
            sqlite3_bind_int(statement, 7, label.underlineStyleWholeVerse ? 1 : 0)
            sqlite3_bind_int(statement, 8, label.hideStyle ? 1 : 0)
            sqlite3_bind_int(statement, 9, label.hideStyleWholeVerse ? 1 : 0)
            sqlite3_bind_int(statement, 10, label.favourite ? 1 : 0)
            bindOptionalText(label.type, to: statement, index: 11)
            bindOptionalText(label.customIcon, to: statement, index: 12)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        for bookmark in bibleBookmarks {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO BibleBookmark (kjvOrdinalStart, kjvOrdinalEnd, ordinalStart, ordinalEnd, v11n, playbackSettings, id, createdAt, book, startOffset, endOffset, primaryLabelId, lastUpdatedOn, wholeVerse, type, customIcon, editAction_mode, editAction_content) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    -1,
                    &statement,
                    nil
                ),
                SQLITE_OK
            )
            sqlite3_bind_int(statement, 1, Int32(bookmark.kjvOrdinalStart))
            sqlite3_bind_int(statement, 2, Int32(bookmark.kjvOrdinalEnd))
            sqlite3_bind_int(statement, 3, Int32(bookmark.ordinalStart))
            sqlite3_bind_int(statement, 4, Int32(bookmark.ordinalEnd))
            sqlite3_bind_text(statement, 5, bookmark.v11n, -1, sqliteTransient)
            bindOptionalText(bookmark.playbackSettingsJSON, to: statement, index: 6)
            bindUUIDBlob(bookmark.id, to: statement, index: 7)
            sqlite3_bind_int64(statement, 8, Int64(bookmark.createdAt.timeIntervalSince1970 * 1000))
            bindOptionalText(bookmark.book, to: statement, index: 9)
            bindOptionalInt(bookmark.startOffset, to: statement, index: 10)
            bindOptionalInt(bookmark.endOffset, to: statement, index: 11)
            bindOptionalUUIDBlob(bookmark.primaryLabelID, to: statement, index: 12)
            sqlite3_bind_int64(statement, 13, Int64(bookmark.lastUpdatedOn.timeIntervalSince1970 * 1000))
            sqlite3_bind_int(statement, 14, bookmark.wholeVerse ? 1 : 0)
            bindOptionalText(bookmark.type, to: statement, index: 15)
            bindOptionalText(bookmark.customIcon, to: statement, index: 16)
            bindOptionalText(bookmark.editActionMode, to: statement, index: 17)
            bindOptionalText(bookmark.editActionContent, to: statement, index: 18)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        for note in bibleNotes {
            try insertBookmarkNote(note, tableName: "BibleBookmarkNotes", db: db)
        }

        for link in bibleLinks {
            try insertBookmarkLabelLink(link, tableName: "BibleBookmarkToLabel", db: db)
        }

        for bookmark in genericBookmarks {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO GenericBookmark (id, `key`, createdAt, bookInitials, ordinalStart, ordinalEnd, startOffset, endOffset, primaryLabelId, lastUpdatedOn, wholeVerse, playbackSettings, customIcon, editAction_mode, editAction_content) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    -1,
                    &statement,
                    nil
                ),
                SQLITE_OK
            )
            bindUUIDBlob(bookmark.id, to: statement, index: 1)
            sqlite3_bind_text(statement, 2, bookmark.key, -1, sqliteTransient)
            sqlite3_bind_int64(statement, 3, Int64(bookmark.createdAt.timeIntervalSince1970 * 1000))
            sqlite3_bind_text(statement, 4, bookmark.bookInitials, -1, sqliteTransient)
            sqlite3_bind_int(statement, 5, Int32(bookmark.ordinalStart))
            sqlite3_bind_int(statement, 6, Int32(bookmark.ordinalEnd))
            bindOptionalInt(bookmark.startOffset, to: statement, index: 7)
            bindOptionalInt(bookmark.endOffset, to: statement, index: 8)
            bindOptionalUUIDBlob(bookmark.primaryLabelID, to: statement, index: 9)
            sqlite3_bind_int64(statement, 10, Int64(bookmark.lastUpdatedOn.timeIntervalSince1970 * 1000))
            sqlite3_bind_int(statement, 11, bookmark.wholeVerse ? 1 : 0)
            bindOptionalText(bookmark.playbackSettingsJSON, to: statement, index: 12)
            bindOptionalText(bookmark.customIcon, to: statement, index: 13)
            bindOptionalText(bookmark.editActionMode, to: statement, index: 14)
            bindOptionalText(bookmark.editActionContent, to: statement, index: 15)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        for note in genericNotes {
            try insertBookmarkNote(note, tableName: "GenericBookmarkNotes", db: db)
        }

        for link in genericLinks {
            try insertBookmarkLabelLink(link, tableName: "GenericBookmarkToLabel", db: db)
        }

        for entry in studyPadEntries {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO StudyPadTextEntry (id, labelId, orderNumber, indentLevel) VALUES (?, ?, ?, ?)",
                    -1,
                    &statement,
                    nil
                ),
                SQLITE_OK
            )
            bindUUIDBlob(entry.id, to: statement, index: 1)
            bindUUIDBlob(entry.labelID, to: statement, index: 2)
            sqlite3_bind_int(statement, 3, Int32(entry.orderNumber))
            sqlite3_bind_int(statement, 4, Int32(entry.indentLevel))
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        for text in studyPadTexts {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO StudyPadTextEntryText (studyPadTextEntryId, text) VALUES (?, ?)",
                    -1,
                    &statement,
                    nil
                ),
                SQLITE_OK
            )
            bindUUIDBlob(text.entryID, to: statement, index: 1)
            sqlite3_bind_text(statement, 2, text.text, -1, sqliteTransient)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        for entry in logEntries {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO LogEntry (tableName, entityId1, entityId2, type, lastUpdated, sourceDevice) VALUES (?, ?, ?, ?, ?, ?)",
                    -1,
                    &statement,
                    nil
                ),
                SQLITE_OK
            )
            sqlite3_bind_text(statement, 1, entry.tableName, -1, sqliteTransient)
            bindSQLiteValue(entry.entityID1, to: statement, index: 2)
            bindSQLiteValue(entry.entityID2, to: statement, index: 3)
            sqlite3_bind_text(statement, 4, entry.type.rawValue, -1, sqliteTransient)
            sqlite3_bind_int64(statement, 5, entry.lastUpdated)
            sqlite3_bind_text(statement, 6, entry.sourceDevice, -1, sqliteTransient)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        return databaseURL
    }

    func insertBookmarkNote(_ note: AndroidBookmarkNoteRow, tableName: String, db: OpaquePointer) throws {
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                db,
                "INSERT INTO \(tableName) (bookmarkId, notes) VALUES (?, ?)",
                -1,
                &statement,
                nil
            ),
            SQLITE_OK
        )
        bindUUIDBlob(note.bookmarkID, to: statement, index: 1)
        sqlite3_bind_text(statement, 2, note.notes, -1, sqliteTransient)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        sqlite3_finalize(statement)
    }

    func insertBookmarkLabelLink(_ link: AndroidBookmarkLabelLinkRow, tableName: String, db: OpaquePointer) throws {
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                db,
                "INSERT INTO \(tableName) (bookmarkId, labelId, orderNumber, indentLevel, expandContent) VALUES (?, ?, ?, ?, ?)",
                -1,
                &statement,
                nil
            ),
            SQLITE_OK
        )
        bindUUIDBlob(link.bookmarkID, to: statement, index: 1)
        bindUUIDBlob(link.labelID, to: statement, index: 2)
        sqlite3_bind_int(statement, 3, Int32(link.orderNumber))
        sqlite3_bind_int(statement, 4, Int32(link.indentLevel))
        sqlite3_bind_int(statement, 5, link.expandContent ? 1 : 0)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        sqlite3_finalize(statement)
    }

    func bindUUIDBlob(_ uuid: UUID, to statement: OpaquePointer?, index: Int32) {
        let blob = uuidBlob(uuid)
        _ = blob.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(blob.count), sqliteTransient)
        }
    }

    func bindOptionalUUIDBlob(_ uuid: UUID?, to statement: OpaquePointer?, index: Int32) {
        guard let uuid else {
            sqlite3_bind_null(statement, index)
            return
        }
        bindUUIDBlob(uuid, to: statement, index: index)
    }

    func bindOptionalText(_ value: String?, to statement: OpaquePointer?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    func bindOptionalInt(_ value: Int?, to statement: OpaquePointer?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int(statement, index, Int32(value))
    }

    /**
     Binds one typed Android SQLite scalar into a fixture statement.

     - Parameters:
       - value: Typed scalar payload that should be bound into SQLite.
       - statement: SQLite statement receiving the bound parameter.
       - index: One-based parameter index.
     - Side effects:
       - mutates the bound SQLite statement parameter state
     - Failure modes: This helper cannot fail.
     */
    func bindSQLiteValue(_ value: RemoteSyncSQLiteValue, to statement: OpaquePointer?, index: Int32) {
        switch value.kind {
        case .null:
            sqlite3_bind_null(statement, index)
        case .integer:
            sqlite3_bind_int64(statement, index, value.integerValue ?? 0)
        case .real:
            sqlite3_bind_double(statement, index, value.realValue ?? 0)
        case .text:
            sqlite3_bind_text(statement, index, value.textValue ?? "", -1, sqliteTransient)
        case .blob:
            let data = value.blobData ?? Data()
            _ = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(data.count), sqliteTransient)
            }
        }
    }

    func uuidBlob(_ uuid: UUID) -> Data {
        let hex = uuid.uuidString.replacingOccurrences(of: "-", with: "")
        var bytes = Data()
        bytes.reserveCapacity(16)

        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            let byteString = hex[index..<nextIndex]
            bytes.append(UInt8(byteString, radix: 16)!)
            index = nextIndex
        }
        return bytes
    }
}

final class InMemorySecretStore: SecretStoring {
    var secrets: [String: String] = [:]

    func secret(forKey key: String) -> String? {
        secrets[key]
    }

    func setSecret(_ value: String, forKey key: String) throws {
        secrets[key] = value
    }

    func removeSecret(forKey key: String) throws {
        secrets.removeValue(forKey: key)
    }
}

final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            fatalError("MockURLProtocol.requestHandler must be set before use")
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    var entries: [RequestLogEntry] = []

    func append(method: String, path: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(RequestLogEntry(method: method, path: path))
    }

    func snapshot() -> [RequestLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

struct RequestLogEntry: Equatable {
    let method: String
    let path: String
}

actor MockRemoteSyncAdapter: RemoteSyncAdapting {
    var fallbackListFilesResult: [RemoteSyncFile] = []
    var listFilesResultsQueue: [[RemoteSyncFile]] = []
    var createFolderResults: [RemoteSyncFile] = []
    var uploadResults: [RemoteSyncFile] = []
    var downloadDataByID: [String: Data] = [:]
    var knownResponses: [String: Bool] = [:]
    var makeKnownResponse = "device-known-default"
    var events: [MockRemoteSyncAdapterEvent] = []
    var uploadedFiles: [MockRemoteSyncUploadedFile] = []

    func setListFilesResult(_ result: [RemoteSyncFile]) {
        fallbackListFilesResult = result
    }

    func enqueueListFilesResult(_ result: [RemoteSyncFile]) {
        listFilesResultsQueue.append(result)
    }

    func enqueueCreateFolderResult(_ result: RemoteSyncFile) {
        createFolderResults.append(result)
    }

    func enqueueUploadResult(_ result: RemoteSyncFile) {
        uploadResults.append(result)
    }

    func setDownloadData(_ data: Data, forID id: String) {
        downloadDataByID[id] = data
    }

    func setKnownResponse(_ value: Bool, forSyncFolderID syncFolderID: String, secretFileName: String) {
        knownResponses["\(syncFolderID)|\(secretFileName)"] = value
    }

    func setMakeKnownResponse(_ value: String) {
        makeKnownResponse = value
    }

    func eventsSnapshot() -> [MockRemoteSyncAdapterEvent] {
        events
    }

    func uploadedFilesSnapshot() -> [MockRemoteSyncUploadedFile] {
        uploadedFiles
    }

    func listFiles(
        parentIDs: [String]?,
        name: String?,
        mimeType: String?,
        modifiedAtLeast: Date?
    ) async throws -> [RemoteSyncFile] {
        events.append(
            .listFiles(
                parentIDs: parentIDs,
                name: name,
                mimeType: mimeType,
                modifiedAtLeast: modifiedAtLeast
            )
        )
        if !listFilesResultsQueue.isEmpty {
            return listFilesResultsQueue.removeFirst()
        }
        return fallbackListFilesResult
    }

    func createNewFolder(name: String, parentID: String?) async throws -> RemoteSyncFile {
        events.append(.createFolder(name: name, parentID: parentID))
        if !createFolderResults.isEmpty {
            return createFolderResults.removeFirst()
        }
        return RemoteSyncFile(
            id: [parentID, name].compactMap { $0 }.joined(separator: "/"),
            name: name,
            size: 0,
            timestamp: 0,
            parentID: parentID ?? "/",
            mimeType: NextCloudSyncAdapter.folderMimeType
        )
    }

    func download(id: String) async throws -> Data {
        events.append(.download(id: id))
        return downloadDataByID[id] ?? Data()
    }

    func upload(
        name: String,
        fileURL: URL,
        parentID: String,
        contentType: String
    ) async throws -> RemoteSyncFile {
        events.append(.upload(name: name, parentID: parentID, contentType: contentType))
        let data = try Data(contentsOf: fileURL)
        uploadedFiles.append(
            MockRemoteSyncUploadedFile(
                name: name,
                parentID: parentID,
                contentType: contentType,
                data: data
            )
        )
        if !uploadResults.isEmpty {
            let result = uploadResults.removeFirst()
            return RemoteSyncFile(
                id: result.id,
                name: result.name,
                size: Int64(data.count),
                timestamp: result.timestamp,
                parentID: result.parentID,
                mimeType: result.mimeType
            )
        }
        return RemoteSyncFile(
            id: [parentID, name].joined(separator: "/"),
            name: name,
            size: Int64(data.count),
            timestamp: 0,
            parentID: parentID,
            mimeType: contentType
        )
    }

    func delete(id: String) async throws {
        events.append(.delete(id: id))
    }

    func isSyncFolderKnown(syncFolderID: String, secretFileName: String) async throws -> Bool {
        events.append(.isSyncFolderKnown(syncFolderID: syncFolderID, secretFileName: secretFileName))
        return knownResponses["\(syncFolderID)|\(secretFileName)"] ?? false
    }

    func makeSyncFolderKnown(syncFolderID: String, deviceIdentifier: String) async throws -> String {
        events.append(.makeKnown(syncFolderID: syncFolderID, deviceIdentifier: deviceIdentifier))
        return makeKnownResponse
    }
}

enum MockRemoteSyncAdapterEvent: Equatable {
    case listFiles(parentIDs: [String]?, name: String?, mimeType: String?, modifiedAtLeast: Date?)
    case createFolder(name: String, parentID: String?)
    case download(id: String)
    case upload(name: String, parentID: String, contentType: String)
    case delete(id: String)
    case isSyncFolderKnown(syncFolderID: String, secretFileName: String)
    case makeKnown(syncFolderID: String, deviceIdentifier: String)
}

struct MockRemoteSyncUploadedFile: Equatable {
    let name: String
    let parentID: String
    let contentType: String
    let data: Data
}

/**
 Test double for `RemoteSyncCategorySynchronizing`.

 The lifecycle runner only needs category synchronization plus the auto-create branch, so this fake
 records both call paths and returns preloaded outcomes without touching WebDAV transport.
 */
@MainActor
final class MockRemoteSyncLifecycleSynchronizer: RemoteSyncCategorySynchronizing {
    /// Preloaded outcomes returned from `synchronize(_:modelContext:settingsStore:)`.
    var synchronizeResults: [RemoteSyncCategory: RemoteSyncSynchronizationOutcome] = [:]

    /// Preloaded reports returned from `adoptRemoteFolderAndSynchronize(...)`.
    var adoptResults: [RemoteSyncCategory: RemoteSyncCategorySynchronizationReport] = [:]

    /// Preloaded reports returned from `createRemoteFolderAndSynchronize(...)`.
    var createResults: [RemoteSyncCategory: RemoteSyncCategorySynchronizationReport] = [:]

    /// Categories passed through the main synchronization entry point.
    private(set) var synchronizeCalls: [RemoteSyncCategory] = []

    /// Categories passed through the adopt-existing-folder recovery path.
    private(set) var adoptCalls: [RemoteSyncCategory] = []

    /// Categories passed through the auto-create recovery path.
    private(set) var createCalls: [RemoteSyncCategory] = []

    /**
     Returns the preloaded outcome for a category and records the call.

     - Parameters:
       - category: Logical sync category requested by the lifecycle runner.
       - modelContext: Unused test context supplied by the caller.
       - settingsStore: Unused test settings store supplied by the caller.
     - Returns: Preloaded synchronization outcome for the category.
     - Side Effects: Appends the category to `synchronizeCalls`.
     - Failure modes: Missing preloaded outcomes trap the test with `XCTFail`-style precondition semantics.
     */
    func synchronize(
        _ category: RemoteSyncCategory,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) async throws -> RemoteSyncSynchronizationOutcome {
        synchronizeCalls.append(category)
        guard let result = synchronizeResults[category] else {
            preconditionFailure("Missing synchronize result for \(category)")
        }
        return result
    }

    /**
     Returns the preloaded adopt-existing-folder report for a category and records the call.

     - Parameters:
       - category: Logical sync category requested by the lifecycle runner.
       - remoteFolderID: Existing remote folder identifier chosen by the user.
       - modelContext: Unused test context supplied by the caller.
       - settingsStore: Unused test settings store supplied by the caller.
     - Returns: Preloaded synchronization report for the category.
     - Side Effects: Appends the category to `adoptCalls`.
     - Failure modes: Missing preloaded reports trap the test with `XCTFail`-style precondition semantics.
     */
    func adoptRemoteFolderAndSynchronize(
        for category: RemoteSyncCategory,
        remoteFolderID: String,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) async throws -> RemoteSyncCategorySynchronizationReport {
        adoptCalls.append(category)
        guard let result = adoptResults[category] else {
            preconditionFailure("Missing adopt result for \(category)")
        }
        return result
    }

    /**
     Returns the preloaded auto-create report for a category and records the call.

     - Parameters:
       - category: Logical sync category requested by the lifecycle runner.
       - replacingRemoteFolderID: Optional folder identifier that would be deleted first in production.
       - modelContext: Unused test context supplied by the caller.
       - settingsStore: Unused test settings store supplied by the caller.
     - Returns: Preloaded synchronization report for the category.
     - Side Effects: Appends the category to `createCalls`.
     - Failure modes: Missing preloaded reports trap the test with `XCTFail`-style precondition semantics.
     */
    func createRemoteFolderAndSynchronize(
        for category: RemoteSyncCategory,
        replacingRemoteFolderID: String?,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) async throws -> RemoteSyncCategorySynchronizationReport {
        createCalls.append(category)
        guard let result = createResults[category] else {
            preconditionFailure("Missing create result for \(category)")
        }
        return result
    }
}

#if os(iOS)
/**
 In-memory scheduler double for `RemoteSyncBackgroundRefreshCoordinator` tests.

 The fake captures registrations, submitted requests, and cancellations so tests can verify the
 coordinator's scheduling policy without talking to `BGTaskScheduler`.
 */
final class FakeRemoteSyncBackgroundRefreshScheduler: RemoteSyncBackgroundRefreshScheduling {
    /// Identifier most recently registered with the fake scheduler.
    private(set) var registeredIdentifier: String?

    /// Launch handler installed by the coordinator under test.
    var launchHandler: ((any RemoteSyncBackgroundRefreshTaskHandling) -> Void)?

    /// Requests submitted through the fake scheduler.
    private(set) var submittedRequests: [RemoteSyncBackgroundRefreshRequest] = []

    /// Identifiers cancelled through the fake scheduler.
    private(set) var cancelledIdentifiers: [String] = []

    /**
     Captures the registration request and stores the launch handler.

     - Parameters:
       - identifier: Stable task identifier supplied by the coordinator.
       - launchHandler: Handler invoked by tests to simulate a launched task.
     - Returns: `true` so registration succeeds in tests.
     - Side effects: Stores the identifier and launch handler for later assertions.
     - Failure modes: This helper cannot fail.
     */
    func register(
        forTaskWithIdentifier identifier: String,
        launchHandler: @escaping (any RemoteSyncBackgroundRefreshTaskHandling) -> Void
    ) -> Bool {
        registeredIdentifier = identifier
        self.launchHandler = launchHandler
        return true
    }

    /**
     Records one submitted background refresh request.

     - Parameter request: Request supplied by the coordinator.
     - Side effects: Appends the request to `submittedRequests`.
     - Failure modes: This helper cannot fail.
     */
    func submit(_ request: RemoteSyncBackgroundRefreshRequest) throws {
        submittedRequests.append(request)
    }

    /**
     Records one cancellation request.

     - Parameter identifier: Stable task identifier cancelled by the coordinator.
     - Side effects: Appends the identifier to `cancelledIdentifiers`.
     - Failure modes: This helper cannot fail.
     */
    func cancel(taskRequestWithIdentifier identifier: String) {
        cancelledIdentifiers.append(identifier)
    }
}

/**
 In-memory task double for background-refresh coordinator tests.

 Tests use this handle to observe completion state and manually trigger the expiration callback.
 */
final class FakeRemoteSyncBackgroundRefreshTask: RemoteSyncBackgroundRefreshTaskHandling {
    /// Callback fired when the coordinator installs an expiration handler.
    var onExpirationHandlerSet: (() -> Void)?

    /// Callback fired when the coordinator completes the task.
    var onCompletion: ((Bool) -> Void)?

    /// Completion statuses recorded for this fake task.
    private(set) var completions: [Bool] = []

    /// Expiration handler installed by the coordinator.
    var expirationHandler: (() -> Void)? {
        didSet {
            if expirationHandler != nil {
                onExpirationHandlerSet?()
            }
        }
    }

    /**
     Records one task completion result.

     - Parameter success: Completion status supplied by the coordinator.
     - Side effects:
       - appends the status to `completions`
       - invokes `onCompletion`
     - Failure modes: This helper cannot fail.
     */
    func setTaskCompleted(success: Bool) {
        completions.append(success)
        onCompletion?(success)
    }
}
#endif

func gunzipTestData(_ data: Data) throws -> Data {
    try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Data in
        guard let baseAddress = ptr.baseAddress else {
            throw RemoteSyncArchiveStagingError.decompressionFailed
        }

        var outputLength: UInt = 0
        guard let output = gunzip_data(
            baseAddress.assumingMemoryBound(to: UInt8.self),
            UInt(data.count),
            &outputLength
        ) else {
            throw RemoteSyncArchiveStagingError.decompressionFailed
        }

        defer { gunzip_free(output) }
        return Data(bytes: output, count: Int(outputLength))
    }
}

func makeTemporarySQLiteDatabase(userVersion: Int) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "remote-sync-test-\(UUID().uuidString).sqlite3"
    )

    var database: OpaquePointer?
    guard sqlite3_open_v2(
        url.path,
        &database,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
        nil
    ) == SQLITE_OK,
    let database else {
        if let database {
            sqlite3_close(database)
        }
        throw NSError(domain: "AndBibleTests.SQLite", code: 1)
    }
    defer { sqlite3_close(database) }

    guard sqlite3_exec(database, "PRAGMA user_version = \(userVersion);", nil, nil, nil) == SQLITE_OK else {
        throw NSError(domain: "AndBibleTests.SQLite", code: 2)
    }
    guard sqlite3_exec(database, "CREATE TABLE IF NOT EXISTS sample (id INTEGER PRIMARY KEY, value TEXT);", nil, nil, nil) == SQLITE_OK else {
        throw NSError(domain: "AndBibleTests.SQLite", code: 3)
    }
    guard sqlite3_exec(database, "INSERT INTO sample (value) VALUES ('fixture');", nil, nil, nil) == SQLITE_OK else {
        throw NSError(domain: "AndBibleTests.SQLite", code: 4)
    }

    return url
}

func readSQLiteUserVersion(at url: URL) throws -> Int {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          let database else {
        if let database {
            sqlite3_close(database)
        }
        throw NSError(domain: "AndBibleTests.SQLite", code: 5)
    }
    defer { sqlite3_close(database) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK,
          let statement else {
        if let statement {
            sqlite3_finalize(statement)
        }
        throw NSError(domain: "AndBibleTests.SQLite", code: 6)
    }
    defer { sqlite3_finalize(statement) }

    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw NSError(domain: "AndBibleTests.SQLite", code: 7)
    }
    return Int(sqlite3_column_int(statement, 0))
}

func makeWorkspaceModelContainer() throws -> ModelContainer {
    let schema = Schema([
        Setting.self,
        Workspace.self,
        Window.self,
        PageManager.self,
        HistoryItem.self,
    ])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [configuration])
}

func makeMyDocumentModelContainer() throws -> ModelContainer {
    let schema = Schema([
        MyDocument.self,
        MyDocumentPage.self,
        MyDocumentPageContent.self,
        AiPageCacheEntry.self,
    ])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [configuration])
}

func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected async expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
