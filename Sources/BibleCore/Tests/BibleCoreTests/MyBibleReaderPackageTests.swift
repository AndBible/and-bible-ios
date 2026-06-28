import SQLite3
import XCTest
@testable import BibleCore

/**
 Package-level coverage for Android-compatible MyBible SQLite reader contracts.

 Downloads and repository tests own file installation mechanics, while BibleCore owns the reader
 that turns an installed `.SQLite3` payload into Bible text and metadata. This suite preserves the
 readability contract formerly asserted from app-host Downloads tests without depending on the app
 target or SwordKit install machinery.
 */
final class MyBibleReaderPackageTests: XCTestCase {
    /**
     Verifies the Android MyBible package payload used by repository installs remains readable.

     The repository package tests assert that normal and deflated MyBible installs publish this
     schema and metadata to disk. This test keeps the complementary BibleCore contract: once that
     payload exists, `MyBibleReader` must identify it as a Bible, expose its metadata, and return
     verse/chapter/book content through the same API used by reader windows.
     */
    func testMyBibleReaderReadsRepositoryInstallFixturePayload() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let databaseURL = tempDir.appendingPathComponent("finrk.SQLite3")
        try makeMyBibleReaderFixtureDatabase(at: databaseURL)

        let reader = try XCTUnwrap(MyBibleReader(filePath: databaseURL.path))

        XCTAssertTrue(reader.isBible)
        XCTAssertFalse(reader.isDictionary)
        XCTAssertEqual(reader.moduleDescription, "Finnish RK")
        XCTAssertEqual(reader.language, "fi")
        XCTAssertEqual(reader.getVerse(book: 10, chapter: 1, verse: 1), "Alussa loi Jumala")
        XCTAssertEqual(reader.getChapter(book: 10, chapter: 1).map(\.text), ["Alussa loi Jumala"])
        XCTAssertEqual(reader.books().first?.name, "Genesis")
    }

    private func makeMyBibleReaderFixtureDatabase(at databaseURL: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &db,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE,
            nil
        ) == SQLITE_OK else {
            throw MyBibleReaderFixtureError.openFailed
        }
        defer { sqlite3_close(db) }

        let sql = """
        CREATE TABLE info (name TEXT PRIMARY KEY, value TEXT);
        INSERT INTO info (name, value) VALUES ('description', 'Finnish RK');
        INSERT INTO info (name, value) VALUES ('language', 'fi');
        CREATE TABLE books (book_number INTEGER PRIMARY KEY, long_name TEXT, short_name TEXT);
        INSERT INTO books (book_number, long_name, short_name) VALUES (10, 'Genesis', 'Gen');
        CREATE TABLE verses (book_number INTEGER, chapter INTEGER, verse INTEGER, text TEXT);
        INSERT INTO verses (book_number, chapter, verse, text) VALUES (10, 1, 1, 'Alussa loi Jumala');
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw MyBibleReaderFixtureError.writeFailed
        }
    }
}

private enum MyBibleReaderFixtureError: Error {
    case openFailed
    case writeFailed
}
