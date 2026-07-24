import Foundation
import SwiftData
import XCTest
@testable import BibleCore

/** Android `STUDYPAD_EXPORT` manifest, projection, filename, and import-routing contract tests. */
final class AndroidStudyPadArchiveServiceTests: XCTestCase {
    /**
     Verifies an exported archive is structurally interchangeable with Android and contains only
     the selected Study Pad graph.

     Setup:
     - seeds selected and excluded labels, each with bookmark and text-entry content
     - gives the selected bookmarks an excluded primary label to exercise Android's repair step
     - exports with a deterministic producer build

     Expected result:
     - the manifest is the literal first member and carries all four Android fields
     - the filename follows Android sanitization
     - only the selected label, linked bookmarks/notes/junctions, and text survive
     - dangling primary labels and sync-log rows are absent

     Failure meaning:
     - iOS generated a superficially ZIP-shaped file that Android may misroute, reject, or import
       with unrelated user data.
     */
    func testExportMatchesAndroidManifestAndSelectedGraph() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let context = ModelContext(container)
        let selectedLabel = Label(name: "Alpha / Notes")
        let excludedLabel = Label(name: "Excluded")

        let selectedBible = BibleBookmark(
            kjvOrdinalStart: 4,
            kjvOrdinalEnd: 4,
            ordinalStart: 4,
            ordinalEnd: 4,
            v11n: "KJVA",
            bookInitials: "KJV",
            ordinalTrustMetadata: PersistedOrdinalTrustPolicy.androidImportMetadata(
                sourceVersification: "KJVA",
                sourceOrdinalStart: 4,
                sourceOrdinalEnd: 4,
                kjvaOrdinalStart: 4,
                kjvaOrdinalEnd: 4
            )
        )
        selectedBible.primaryLabelId = excludedLabel.id
        let selectedBibleNote = BibleBookmarkNotes(
            bookmarkId: selectedBible.id,
            notes: "selected Bible note",
            contentType: "HTML"
        )
        selectedBibleNote.bookmark = selectedBible
        selectedBible.notes = selectedBibleNote
        let selectedBibleLink = BibleBookmarkToLabel(orderNumber: 2, indentLevel: 1)
        selectedBibleLink.bookmark = selectedBible
        selectedBibleLink.label = selectedLabel
        selectedBible.bookmarkToLabels = [selectedBibleLink]

        let selectedGeneric = GenericBookmark(key: "entry", bookInitials: "DICT")
        selectedGeneric.primaryLabelId = excludedLabel.id
        let selectedGenericNote = GenericBookmarkNotes(
            bookmarkId: selectedGeneric.id,
            notes: "selected generic note",
            contentType: "MARKDOWN"
        )
        selectedGenericNote.bookmark = selectedGeneric
        selectedGeneric.notes = selectedGenericNote
        let selectedGenericLink = GenericBookmarkToLabel(orderNumber: 3, indentLevel: 0)
        selectedGenericLink.bookmark = selectedGeneric
        selectedGenericLink.label = selectedLabel
        selectedGeneric.bookmarkToLabels = [selectedGenericLink]

        let selectedEntry = StudyPadTextEntry(orderNumber: 4, indentLevel: 2, contentType: "HTML")
        selectedEntry.label = selectedLabel
        let selectedText = StudyPadTextEntryText(
            studyPadTextEntryId: selectedEntry.id,
            text: "selected Study Pad text"
        )
        selectedText.entry = selectedEntry
        selectedEntry.textEntry = selectedText

        let excludedGeneric = GenericBookmark(key: "excluded", bookInitials: "DICT")
        let excludedLink = GenericBookmarkToLabel(orderNumber: 1)
        excludedLink.bookmark = excludedGeneric
        excludedLink.label = excludedLabel
        excludedGeneric.bookmarkToLabels = [excludedLink]
        let excludedEntry = StudyPadTextEntry(orderNumber: 1)
        excludedEntry.label = excludedLabel
        let excludedText = StudyPadTextEntryText(
            studyPadTextEntryId: excludedEntry.id,
            text: "must not be exported"
        )
        excludedText.entry = excludedEntry
        excludedEntry.textEntry = excludedText

        selectedLabel.bibleBookmarkToLabels = [selectedBibleLink]
        selectedLabel.genericBookmarkToLabels = [selectedGenericLink]
        selectedLabel.studyPadEntries = [selectedEntry]
        excludedLabel.genericBookmarkToLabels = [excludedLink]
        excludedLabel.studyPadEntries = [excludedEntry]
        context.insert(selectedLabel)
        context.insert(excludedLabel)
        context.insert(selectedBible)
        context.insert(selectedBibleNote)
        context.insert(selectedBibleLink)
        context.insert(selectedGeneric)
        context.insert(selectedGenericNote)
        context.insert(selectedGenericLink)
        context.insert(selectedEntry)
        context.insert(selectedText)
        context.insert(excludedGeneric)
        context.insert(excludedLink)
        context.insert(excludedEntry)
        context.insert(excludedText)
        try context.save()

        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let service = AndroidStudyPadArchiveService(
            temporaryDirectory: scratch,
            producerVersion: 777
        )
        let export = try service.exportArchiveFile(labelIDs: [selectedLabel.id], modelContext: context)
        defer { service.cleanup(export) }

        XCTAssertEqual(export.fileName, "Alpha___Notes.abdb.zip")
        XCTAssertEqual(export.labelIDs, [selectedLabel.id])
        let entries = try ZipArchiveReader.fileEntries(inArchiveAt: export.fileURL)
        XCTAssertEqual(entries.map(\.name), [
            AndroidStudyPadArchiveService.manifestFileName,
            AndroidStudyPadArchiveService.bookmarksEntryName,
        ])
        let manifestData = try ZipArchiveReader.data(
            for: try XCTUnwrap(entries.first),
            inArchiveAt: export.fileURL,
            maximumByteCount: 1_024 * 1_024
        )
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        )
        XCTAssertEqual(manifest["backupType"] as? String, "STUDYPAD_EXPORT")
        XCTAssertEqual(manifest["contains"] as? [String], ["BOOKMARKS"])
        XCTAssertEqual(manifest["manifestVersion"] as? Int, 1)
        XCTAssertEqual(manifest["andBibleVersion"] as? Int, 777)

        let inspection = try service.inspectImport(at: export.fileURL)
        defer { service.cleanup(inspection) }
        XCTAssertEqual(
            inspection.summary,
            AndroidStudyPadArchiveSummary(
                labelCount: 1,
                bibleBookmarkCount: 1,
                genericBookmarkCount: 1,
                textEntryCount: 1
            )
        )
        let databaseURL = try XCTUnwrap(
            inspection.archive.sections.first(where: { $0.category == .bookmarks })?.databaseFileURL
        )
        let snapshot = try RemoteSyncBookmarkRestoreService().readSnapshot(from: databaseURL)
        XCTAssertEqual(snapshot.labels.map(\.id), [selectedLabel.id])
        XCTAssertEqual(snapshot.bibleBookmarks.map(\.id), [selectedBible.id])
        XCTAssertEqual(snapshot.bibleBookmarks.first?.notes, "selected Bible note")
        XCTAssertNil(snapshot.bibleBookmarks.first?.primaryLabelID)
        XCTAssertEqual(snapshot.genericBookmarks.map(\.id), [selectedGeneric.id])
        XCTAssertEqual(snapshot.genericBookmarks.first?.notes, "selected generic note")
        XCTAssertNil(snapshot.genericBookmarks.first?.primaryLabelID)
        XCTAssertEqual(snapshot.studyPadEntries.map(\.id), [selectedEntry.id])
        XCTAssertEqual(snapshot.studyPadEntries.first?.text, "selected Study Pad text")
        XCTAssertTrue(snapshot.logEntries.isEmpty)
    }

    /**
     Verifies Android's manifest-first specialized routing and strict non-null version fields.

     Setup:
     - creates a valid-shape archive whose Study Pad manifest is not first
     - creates a first-manifest generic DB backup
     - creates a first-manifest Study Pad archive with an explicit null manifest version

     Expected result:
     - each candidate is rejected before database staging or mutation with a specific routing error

     Failure meaning:
     - iOS accepts archives Android would route elsewhere or reject, making cross-platform behavior
       dependent on which platform performs the import.
     */
    func testImportRejectsNonAndroidSpecializedManifestRouting() throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let service = AndroidStudyPadArchiveService(temporaryDirectory: scratch)
        let databaseStub = Data("not reached".utf8)

        let manifestNotFirst = try writeArchive(
            entries: [
                .init(name: AndroidStudyPadArchiveService.bookmarksEntryName, data: databaseStub),
                .init(
                    name: AndroidStudyPadArchiveService.manifestFileName,
                    data: Data(
                        #"{"backupType":"STUDYPAD_EXPORT","contains":["BOOKMARKS"],"manifestVersion":1,"andBibleVersion":777}"#.utf8
                    )
                ),
            ],
            directory: scratch
        )
        XCTAssertThrowsError(try service.inspectImport(at: manifestNotFirst)) { error in
            XCTAssertEqual(error as? AndroidStudyPadArchiveError, .manifestNotFirst)
        }

        let genericBackup = try writeArchive(
            entries: [
                .init(
                    name: AndroidStudyPadArchiveService.manifestFileName,
                    data: Data(
                        #"{"backupType":"DB_BACKUP","contains":["BOOKMARKS"],"manifestVersion":1,"andBibleVersion":777}"#.utf8
                    )
                ),
                .init(name: AndroidStudyPadArchiveService.bookmarksEntryName, data: databaseStub),
            ],
            directory: scratch
        )
        XCTAssertThrowsError(try service.inspectImport(at: genericBackup)) { error in
            XCTAssertEqual(
                error as? AndroidStudyPadArchiveError,
                .unsupportedBackupType("DB_BACKUP")
            )
        }

        let explicitNullVersion = try writeArchive(
            entries: [
                .init(
                    name: AndroidStudyPadArchiveService.manifestFileName,
                    data: Data(
                        #"{"backupType":"STUDYPAD_EXPORT","contains":["BOOKMARKS"],"manifestVersion":null,"andBibleVersion":777}"#.utf8
                    )
                ),
                .init(name: AndroidStudyPadArchiveService.bookmarksEntryName, data: databaseStub),
            ],
            directory: scratch
        )
        XCTAssertThrowsError(try service.inspectImport(at: explicitNullVersion)) { error in
            guard case .invalidArchive = error as? AndroidStudyPadArchiveError else {
                return XCTFail("Expected invalidArchive, received \(error)")
            }
        }
    }

    /**
     Creates one isolated caller-owned scratch directory.

     - Returns: Empty temporary directory.
     - Side effects: Creates one directory below the process temporary root.
     - Failure modes: Rethrows filesystem creation failures.
     */
    private func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("study-pad-archive-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /** Writes one deterministic stored ZIP fixture in caller-supplied entry order. */
    private func writeArchive(
        entries: [ZipArchiveWriterEntry],
        directory: URL
    ) throws -> URL {
        let url = directory.appendingPathComponent("fixture-\(UUID().uuidString).abdb.zip")
        try ZipArchiveWriter.storedArchive(entries: entries).write(to: url, options: .atomic)
        return url
    }
}
