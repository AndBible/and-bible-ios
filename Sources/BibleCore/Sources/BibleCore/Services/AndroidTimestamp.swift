// AndroidTimestamp.swift -- Exact signed-millisecond persistence helpers

import Darwin
import Foundation

/** Fail-visible conversion errors at Date-backed compatibility boundaries. */
public enum AndroidTimestampError: Error, Equatable, Sendable {
    /// A `Date` cannot be represented as one finite signed-Int64 millisecond value.
    case unrepresentableDate
}

/**
 Preserves Android's signed-Int64 epoch-millisecond domain without floating-point clock reads.

 Persisted and wire values remain `Int64`. `Date` conversion is limited to presentation and legacy
 model compatibility; callers that round-trip remote values must retain the original integer.
 */
public enum AndroidTimestamp {
    /**
     Reads the realtime clock as exact whole milliseconds.

     - Returns: Signed Unix epoch milliseconds, saturating only if the platform clock exceeds Int64.
     - Side Effects: Reads `CLOCK_REALTIME`.
     - Failure modes: A platform clock-read failure returns zero; current Darwin `time_t` values fit.
     */
    public static func currentMilliseconds() -> Int64 {
        var value = timespec()
        guard clock_gettime(CLOCK_REALTIME, &value) == 0,
              let seconds = Int64(exactly: value.tv_sec) else {
            return 0
        }
        let (wholeMilliseconds, multiplyOverflow) = seconds.multipliedReportingOverflow(by: 1_000)
        guard !multiplyOverflow else {
            return seconds < 0 ? .min : .max
        }
        let fractionalMilliseconds = Int64(value.tv_nsec / 1_000_000)
        let (result, addOverflow) = wholeMilliseconds.addingReportingOverflow(
            fractionalMilliseconds
        )
        guard !addOverflow else {
            return seconds < 0 ? .min : .max
        }
        return result
    }

    /**
     Converts a local `Date` to milliseconds without a trapping integer cast.

     - Parameter date: Legacy Date-backed model value.
     - Returns: Nearest signed whole millisecond.
     - Side Effects: none.
     - Throws: `unrepresentableDate` for nonfinite or out-of-domain values.
     */
    public static func milliseconds(from date: Date) throws -> Int64 {
        let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded()
        guard milliseconds.isFinite, let value = Int64(exactly: milliseconds) else {
            throw AndroidTimestampError.unrepresentableDate
        }
        return value
    }

    /**
     Creates a presentation Date while callers retain the authoritative integer value separately.

     - Parameter milliseconds: Signed Android epoch milliseconds.
     - Returns: Foundation date approximation used by Date-backed UI/model compatibility.
     - Side Effects: none.
     - Failure modes: none; all Int64 inputs produce a finite `Date` on Darwin.
     */
    public static func date(from milliseconds: Int64) -> Date {
        let seconds = milliseconds / 1_000
        let remainder = milliseconds % 1_000
        return Date(
            timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(remainder) / 1_000
        )
    }

    /**
     Preserves the explicit Android-millisecond argument label used by existing persistence callers.

     - Parameter milliseconds: Signed Android epoch milliseconds.
     - Returns: Foundation date approximation produced by `date(from:)`.
     - Side Effects: none.
     - Failure modes: none; all `Int64` inputs produce a finite `Date` on Darwin.
     */
    public static func date(fromMilliseconds milliseconds: Int64) -> Date {
        date(from: milliseconds)
    }
}
