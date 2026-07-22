// RemoteSyncIntegrityContracts.swift -- Shared ordering, clock, and process-gate invariants

import Foundation

/** Typed failure for a value that cannot be represented by Android's signed 32-bit wire type. */
enum RemoteSyncWireIntegerError: Error, Equatable {
    /// The named source value lies outside `Int32.min...Int32.max`.
    case outOfRange(field: String, value: String)
}

/** Exact Android wire-integer conversion shared by SQLite backup and patch writers. */
enum RemoteSyncWireInteger {
    /**
     Converts one binary integer without truncation or a Swift runtime trap.

     - Parameters:
       - value: Source integer to encode in an Android `INTEGER` or SQLite byte-count argument.
       - field: Stable contract name included in a typed failure.
     - Returns: The exactly represented signed 32-bit value.
     - Side effects: none.
     - Throws: `RemoteSyncWireIntegerError.outOfRange` when `value` does not fit `Int32`.
     */
    static func int32<Value: BinaryInteger>(
        exactly value: Value,
        field: String
    ) throws -> Int32 {
        guard let converted = Int32(exactly: value) else {
            throw RemoteSyncWireIntegerError.outOfRange(
                field: field,
                value: String(describing: value)
            )
        }
        return converted
    }
}

/**
 Errors raised when remote sync cannot allocate another value in Android's signed 64-bit domains.

 Callers must surface these failures instead of wrapping to a negative timestamp or patch number,
 because either wrap would make a newer local mutation permanently lose conflict resolution.
 */
public enum RemoteSyncLogicalSequenceError: Error, Equatable {
    /// No millisecond value remains above every supplied high-water mark and the current clock.
    case timestampExhausted

    /// No positive patch number remains above the accepted local and discovered remote marks.
    case patchNumberExhausted
}

/**
 Allocates signed 64-bit logical values without arithmetic overflow.

 The timestamp contract deliberately advances beyond wall time as well as every accepted or pending
 high-water mark. This preserves Android's last-writer-wins semantics when the device clock moves
 backwards and ensures edits made while an upload is in flight remain newer than that upload.
 */
enum RemoteSyncLogicalSequence {
    /**
     Returns a logical mutation timestamp strictly greater than all supplied marks and wall time.

     - Parameters:
       - now: Current wall-clock time in milliseconds.
       - highWatermarks: Accepted, pending, or stored mutation timestamps that must be exceeded.
     - Returns: The smallest signed 64-bit value greater than every input.
     - Side Effects: none.
     - Throws: `RemoteSyncLogicalSequenceError.timestampExhausted` when the maximum input is
       `Int64.max`.
     */
    static func nextTimestamp(now: Int64, highWatermarks: [Int64]) throws -> Int64 {
        let highWatermark = highWatermarks.reduce(now, max)
        guard highWatermark < Int64.max else {
            throw RemoteSyncLogicalSequenceError.timestampExhausted
        }
        return highWatermark + 1
    }

    /**
     Returns the next positive Android patch number without wrapping signed 64-bit storage.

     - Parameter highWatermarks: Accepted local and discovered remote patch numbers.
     - Returns: One greater than the largest nonnegative mark, or one when no mark exists.
     - Side Effects: none.
     - Throws: `RemoteSyncLogicalSequenceError.patchNumberExhausted` when the maximum mark is
       `Int64.max`.
     */
    static func nextPatchNumber(after highWatermarks: [Int64]) throws -> Int64 {
        let highWatermark = highWatermarks.reduce(Int64(0), max)
        guard highWatermark < Int64.max else {
            throw RemoteSyncLogicalSequenceError.patchNumberExhausted
        }
        return highWatermark + 1
    }
}

/**
 Defines Android's strict timestamp conflict rule plus deterministic local iteration order.

 Android patch SQL replaces an existing log entry only when the candidate `lastUpdated` is strictly
 greater. Equal timestamps never win. A wider sort key remains useful only to make independent local
 collection iteration deterministic; it does not confer conflict precedence.
 */
enum RemoteSyncLogEntryConflictOrder {
    /**
     Reports whether a candidate mutation must replace the currently accepted mutation.

     - Parameters:
       - candidate: Incoming or newly journaled operation.
       - current: Existing operation for the same logical entity.
     - Returns: `true` only when Android's incoming timestamp is strictly greater.
     - Side Effects: none.
     - Failure modes: This comparison cannot fail.
     */
    static func isNewer(_ candidate: RemoteSyncLogEntry, than current: RemoteSyncLogEntry) -> Bool {
        candidate.lastUpdated > current.lastUpdated
    }

    /**
     Sorts operations from oldest/lowest precedence to newest/highest precedence.

     - Parameters:
       - lhs: First operation.
       - rhs: Second operation.
     - Returns: `true` when `lhs` precedes `rhs` in the deterministic total order.
     - Side Effects: none.
     - Failure modes: This comparison cannot fail.
     */
    static func precedes(_ lhs: RemoteSyncLogEntry, _ rhs: RemoteSyncLogEntry) -> Bool {
        sortKey(lhs) < sortKey(rhs)
    }

    /** Stable comparable projection for one log operation. */
    private static func sortKey(_ entry: RemoteSyncLogEntry) -> RemoteSyncLogEntrySortKey {
        RemoteSyncLogEntrySortKey(
            lastUpdated: entry.lastUpdated,
            sourceDevice: entry.sourceDevice,
            operationRank: entry.type == .delete ? 1 : 0,
            tableName: entry.tableName,
            entityID1: canonicalValue(entry.entityID1),
            entityID2: canonicalValue(entry.entityID2)
        )
    }

    /** Stable text projection that preserves SQLite storage kind and payload. */
    private static func canonicalValue(_ value: RemoteSyncSQLiteValue) -> String {
        switch value.kind {
        case .null:
            return "n:"
        case .integer:
            return "i:\(value.integerValue ?? 0)"
        case .real:
            return "r:\(value.realValue?.bitPattern ?? 0)"
        case .text:
            return "t:\(value.textValue ?? "")"
        case .blob:
            return "b:\(value.blobBase64Value ?? "")"
        }
    }
}

/** Comparable storage for the deterministic log-entry order. */
private struct RemoteSyncLogEntrySortKey: Comparable {
    let lastUpdated: Int64
    let sourceDevice: String
    let operationRank: Int
    let tableName: String
    let entityID1: String
    let entityID2: String

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.lastUpdated != rhs.lastUpdated { return lhs.lastUpdated < rhs.lastUpdated }
        if lhs.sourceDevice != rhs.sourceDevice { return lhs.sourceDevice < rhs.sourceDevice }
        if lhs.operationRank != rhs.operationRank { return lhs.operationRank < rhs.operationRank }
        if lhs.tableName != rhs.tableName { return lhs.tableName < rhs.tableName }
        if lhs.entityID1 != rhs.entityID1 { return lhs.entityID1 < rhs.entityID1 }
        return lhs.entityID2 < rhs.entityID2
    }
}

/**
 Serializes every remote-sync bootstrap and synchronization entry point within the process.

 Separate lifecycle and settings services may exist concurrently, but Android uses one process-wide
 mutex. This actor supplies the same contract. Waiting-task cancellation removes and resumes the
 waiter, while cancellation of the active operation releases the permit through `defer`.
 */
actor RemoteSyncProcessSynchronizationGate {
    /// Shared process-wide synchronization gate.
    static let shared = RemoteSyncProcessSynchronizationGate()

    /** One suspended permit request. */
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var isHeld = false
    private var waiters: [Waiter] = []

    /**
     Executes one operation while holding the process-wide remote-sync permit.

     - Parameter operation: Asynchronous bootstrap, reset, or synchronization operation.
     - Returns: The operation's return value.
     - Side Effects: Suspends behind an active operation and releases the permit on every exit path.
     - Throws: `CancellationError` when cancelled while waiting, or rethrows the operation's error.
     */
    func withPermit<Value>(_ operation: () async throws -> Value) async throws -> Value {
        try await acquire()
        defer { release() }
        return try await operation()
    }

    /** Acquires the permit immediately or enqueues one cancellation-aware waiter. */
    private func acquire() async throws {
        try Task.checkCancellation()
        guard isHeld else {
            isHeld = true
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters.append(Waiter(id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    /** Transfers the held permit to the first non-cancelled waiter, or marks it available. */
    private func release() {
        guard !waiters.isEmpty else {
            isHeld = false
            return
        }
        let waiter = waiters.removeFirst()
        waiter.continuation.resume()
    }

    /** Removes and resumes one cancelled waiter without disturbing the active permit owner. */
    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}
