import Foundation
import SQLite3

/** Builds purpose-specific SQLite fixtures without weakening production read-only behavior. */
enum SQLiteDocumentTestDatabase {
    /**
     Creates a SQLite database by executing deterministic schema and data statements in order.

     - Parameters:
       - url: Destination beneath a test-owned temporary directory; no file may already exist.
       - statements: Complete SQL statements executed sequentially on one writable connection.
     - Side effects: Creates and closes one SQLite database file.
     - Throws: `SQLiteDocumentTestDatabaseError` when opening or executing any statement fails.
     - Note: Callers own removal of the containing temporary directory.
     */
    static func create(at url: URL, statements: [String]) throws {
        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE,
            nil
        )
        guard openResult == SQLITE_OK, let handle else {
            let message = handle
                .flatMap(sqlite3_errmsg)
                .map(String.init(cString:)) ?? "SQLite open failed with code \(openResult)"
            if let handle { sqlite3_close(handle) }
            throw SQLiteDocumentTestDatabaseError(statementIndex: nil, message: message)
        }
        defer { sqlite3_close(handle) }

        for (index, statement) in statements.enumerated() {
            var rawMessage: UnsafeMutablePointer<CChar>?
            let result = sqlite3_exec(handle, statement, nil, nil, &rawMessage)
            guard result == SQLITE_OK else {
                let message = rawMessage
                    .map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
                sqlite3_free(rawMessage)
                throw SQLiteDocumentTestDatabaseError(
                    statementIndex: index,
                    message: message
                )
            }
            sqlite3_free(rawMessage)
        }
    }
}

/** Captures which deterministic fixture statement SQLite rejected and why. */
struct SQLiteDocumentTestDatabaseError: Error, LocalizedError {
    /// Zero-based statement position, or `nil` when the database itself could not be opened.
    let statementIndex: Int?

    /// SQLite diagnostic copied before the writable fixture handle was closed.
    let message: String

    /// Human-readable fixture-construction error used by XCTest failure output.
    var errorDescription: String? {
        if let statementIndex {
            return "SQLite fixture statement \(statementIndex) failed: \(message)"
        }
        return "SQLite fixture open failed: \(message)"
    }
}
