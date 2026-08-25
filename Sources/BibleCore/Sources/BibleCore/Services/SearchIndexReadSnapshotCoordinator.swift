// SearchIndexReadSnapshotCoordinator.swift — operation-owned committed Search reads

import Foundation
import SQLite3

/**
 Owns one committed WAL read snapshot and its module/store authorization lifetime.

 Search uses a service-owned writer connection, but queries must open independent read-only
 connections so they never observe that writer's uncommitted replacement transaction. This
 coordinator centralizes read admission, BEGIN/COMMIT/ROLLBACK, epoch replay, and handle closure.

 - Side effects: Opens and closes one read-only SQLite connection and one deferred transaction.
 - Failure modes: Scheduled module mutations, store invalidation, database/open/transaction errors,
 body errors, and an epoch change all throw without publishing a partial result.
 */
struct SearchIndexReadSnapshotCoordinator {
    /// Generated Search database path shared with the writer.
    let databasePath: String

    /// Whether service initialization currently owns a usable writer/database lifecycle.
    let writerIsAvailable: Bool

    /// Exact per-module scheduled/creating state used for Android read gating.
    let moduleMutationState: SearchIndexModuleMutationState

    /// Monotonic module-store invalidation state replayed before and after the snapshot.
    let invalidationState: SearchIndexInvalidationEpochState

    /**
     Runs one logical readiness or query operation against a committed snapshot.

     - Parameters:
       - moduleName: Exact generated-index owner whose mutation state gates admission.
       - operation: Caller-facing diagnostic operation for typed SQLite errors.
       - body: Complete metadata/result read using only the supplied snapshot connection.
     - Returns: Value produced by `body` after the final epoch validation and commit.
     - Side effects: Opens a read-only handle, begins/commits a deferred transaction, and closes it.
     - Failure modes: Unavailable/mutating sources, invalidation overlap, SQLite errors, and body
       errors throw; an active transaction is rolled back before handle closure.
     */
    func read<Result>(
        for moduleName: String,
        operation: String,
        _ body: (OpaquePointer) throws -> Result
    ) throws -> Result {
        guard !moduleMutationState.isMutating(moduleName),
              let readEpoch = invalidationState.captureReadEpoch() else {
            throw SearchIndexError.indexUnavailable(moduleName: moduleName)
        }
        let database = try openReadDatabase(operation: operation)
        defer { sqlite3_close(database) }
        var transactionIsOpen = false
        try execute(
            db: database,
            sql: "BEGIN DEFERRED TRANSACTION",
            operation: "starting read snapshot for \(moduleName)"
        )
        transactionIsOpen = true
        do {
            let result = try body(database)
            guard invalidationState.isCurrent(readEpoch) else {
                throw SearchIndexError.indexUnavailable(moduleName: moduleName)
            }
            try execute(
                db: database,
                sql: "COMMIT",
                operation: "committing read snapshot for \(moduleName)"
            )
            transactionIsOpen = false
            guard invalidationState.isCurrent(readEpoch) else {
                throw SearchIndexError.indexUnavailable(moduleName: moduleName)
            }
            return result
        } catch {
            if transactionIsOpen {
                sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            }
            throw error
        }
    }

    /**
     Opens one operation-owned read-only SQLite connection.

     - Parameter operation: Caller-facing diagnostic operation.
     - Returns: Independent serialized SQLite handle; `read` always closes it.
     - Side effects: Opens the generated Search database read-only.
     - Throws: Database-unavailable or typed SQLite open failure.
     */
    private func openReadDatabase(operation: String) throws -> OpaquePointer {
        guard writerIsAvailable else {
            throw SearchIndexError.databaseUnavailable(operation: operation)
        }
        var handle: OpaquePointer?
        let openCode = sqlite3_open_v2(
            databasePath,
            &handle,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openCode == SQLITE_OK, let handle else {
            let message = handle.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:))
                ?? "SQLite error \(openCode)"
            if let handle { sqlite3_close(handle) }
            throw SearchIndexError.sqlite(
                operation: "opening a read snapshot for \(operation)",
                code: openCode,
                message: message
            )
        }
        return handle
    }

    /**
     Executes one read-transaction boundary and translates SQLite failures.

     - Parameters:
       - db: Operation-owned read connection.
       - sql: Trusted deferred-BEGIN or COMMIT statement.
       - operation: Diagnostic operation attached to failure.
     - Side effects: Advances the read connection's transaction state.
     - Throws: Typed SQLite error unless SQLite returns `SQLITE_OK`.
     */
    private func execute(
        db: OpaquePointer?,
        sql: String,
        operation: String
    ) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw SearchIndexError.sqlite(
                operation: operation,
                code: sqlite3_errcode(db),
                message: sqlite3_errmsg(db).map(String.init(cString:)) ?? "Unknown SQLite error"
            )
        }
    }
}
