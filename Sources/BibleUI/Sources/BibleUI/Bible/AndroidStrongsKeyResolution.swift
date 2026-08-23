import Foundation

/**
 Identifies one behaviorally distinct `LinkControl.KeyType` Strong's lookup family.

 The enum order is Android's retry order and the value is cached per installed book after a hit.
 Families therefore remain distinct even when they generate the same dictionary key string.

 - Side effects: None; cases are immutable lookup identities.
 - Failure modes: None; malformed external keys are represented by candidates, not new cases.
 */
enum AndroidStrongsKeyFamily: Equatable {
    /// The decoded external key exactly as Android receives it.
    case key

    /// The significant numeric identity left-padded to five characters.
    case zeroPaddedKey

    /// The five-character key followed by the carriage return used by zLD modules.
    case zeroPaddedKeyWithCarriageReturn

    /// The language category (`G` or `H`) followed by the unpadded significant digits.
    case category
}

/**
 Couples one exact backend key string to the Android family that generated it.

 Inputs are produced only by `AndroidStrongsKeyResolution`; consumers preserve array order and may
 cache `family` after the backend accepts `value`. Equality includes both fields, so duplicate key
 strings under different families are never collapsed.

 - Side effects: None; instances are immutable values.
 - Failure modes: None; even empty and literal-null malformed-family values are representable.
 */
struct AndroidStrongsKeyCandidate: Equatable {
    /// Typed Android family retained even when another family produces the same string.
    let family: AndroidStrongsKeyFamily

    /// Exact key string passed to the installed dictionary backend.
    let value: String
}

/**
 Parses external Strong's keys into Android's exact four typed lookup candidates.

 Android's `LinkControl.getStrongsKey` accepts an optional uppercase `G`/`H`, greedily consumes
 leading zeroes, permits decoration after the digits, and retains duplicate values under different
 typed families for preferred-family caching. No libsword-only aliases are added because they could
 turn an Android miss into iOS content or select a different dictionary record.

 - Side effects: Candidate construction evaluates one deterministic regular expression; it does
   not read module content or mutate preferred-family history.
 - Failure modes: Malformed keys preserve Android's literal four-family nil-base outputs instead
   of being rejected or receiving iOS-only aliases.
 */
enum AndroidStrongsKeyResolution {
    /**
     Retains the significant digit capture from Android's anchored Strong's expression.

     - Inputs: A regex match whose optional prefix and greedy zero group have already been removed.
     - Outputs: Exact remaining ASCII digits, including one final zero for all-zero inputs.
     - Side effects: None.
     - Failure modes: Construction occurs only after a complete valid capture.
     */
    private struct Components {
        /// Digits left after Android's greedy leading-zero capture.
        let significantDigits: String
    }

    /**
     Builds Android's raw, five-digit, five-digit-plus-CR, and category candidates.

     - Parameters:
       - strongsNumber: Decoded external Strong's key before normalization.
       - categoryPrefix: `G` or `H` selected by Android's raw first-character URI rule.
     - Returns: Four typed candidates in Android enum order, with duplicate values retained.
     - Side effects: None.
     - Failure modes: Values outside Android's anchored grammar retain Android's four-family null-
       base outputs: raw, empty, carriage return, and category plus literal `null`.
     */
    static func candidates(
        for strongsNumber: String,
        categoryPrefix: String
    ) -> [AndroidStrongsKeyCandidate] {
        let rawCandidate = AndroidStrongsKeyCandidate(family: .key, value: strongsNumber)
        guard let components = components(from: strongsNumber) else {
            return [
                rawCandidate,
                AndroidStrongsKeyCandidate(family: .zeroPaddedKey, value: ""),
                AndroidStrongsKeyCandidate(
                    family: .zeroPaddedKeyWithCarriageReturn,
                    value: "\r"
                ),
                AndroidStrongsKeyCandidate(
                    family: .category,
                    value: categoryPrefix + "null"
                ),
            ]
        }

        let significantDigits = components.significantDigits
        let zeroPadded = significantDigits.count < 5
            ? String(repeating: "0", count: 5 - significantDigits.count) + significantDigits
            : significantDigits
        var candidates = [rawCandidate]
        candidates.append(
            AndroidStrongsKeyCandidate(family: .zeroPaddedKey, value: zeroPadded)
        )
        candidates.append(
            AndroidStrongsKeyCandidate(
                family: .zeroPaddedKeyWithCarriageReturn,
                value: zeroPadded + "\r"
            )
        )
        candidates.append(
            AndroidStrongsKeyCandidate(
                family: .category,
                value: categoryPrefix + significantDigits
            )
        )
        return candidates
    }

    /**
     Parses the significant digits accepted by Android's anchored regular expression.

     - Parameter strongsNumber: Decoded raw Strong's key; trailing content is permitted.
     - Returns: Significant digits, or `nil` unless the key begins with an optional uppercase
       `G`/`H` followed by at least one ASCII digit.
     - Side effects: Compiles and evaluates one deterministic regular expression.
     - Failure modes: Invalid UTF-16 ranges fail closed with `nil`.
     */
    private static func components(from strongsNumber: String) -> Components? {
        guard let regex = try? NSRegularExpression(
            pattern: #"^[GH]?(0*)([0-9]+).*"#
        ),
              let match = regex.firstMatch(
                in: strongsNumber,
                range: NSRange(strongsNumber.startIndex..., in: strongsNumber)
              ),
              let significantRange = Range(match.range(at: 2), in: strongsNumber) else {
            return nil
        }
        return Components(significantDigits: String(strongsNumber[significantRange]))
    }
}

/**
 Stores Android's last accepted Strong's key family for each canonical module initials value.

 Production builders share `shared` so history survives route-local builder recreation, matching
 application-scoped Android `LinkControl`. Focused tests can inject a new instance to avoid ordering
 dependence. A lock makes reads and accepted-family updates atomic across reader panes.

 - Side effects: Reads and updates lock-protected in-memory preference state.
 - Failure modes: Missing history preserves Android enum order; empty initials remain a valid,
   deterministic cache key rather than causing lookup failure.
 */
final class AndroidStrongsKeyPreferenceCache: @unchecked Sendable {
    /// Application-lifetime cache used by production installed-book builders.
    static let shared = AndroidStrongsKeyPreferenceCache()

    /// Serializes access to `preferredFamilyByModuleInitials`.
    private let lock = NSLock()

    /// Last exact family accepted by each case-sensitive canonical module initials value.
    private var preferredFamilyByModuleInitials: [String: AndroidStrongsKeyFamily] = [:]

    /**
     Creates an empty per-module preferred-family cache.

     - Side effects: Allocates private lock-protected mutable state.
     - Failure modes: None; production uses `shared`, while tests inject isolated instances.
     */
    init() {}

    /**
     Moves one module's remembered family before Android's remaining default families.

     - Parameters:
       - candidates: Four typed candidates in Android enum order.
       - moduleInitials: Canonical installed module initials used by Android as the cache key.
     - Returns: Preferred-family candidates first, followed by every other family in original order;
       duplicate string values remain present under their distinct families.
     - Side effects: Reads lock-protected in-memory preference state.
     - Failure modes: Missing history returns `candidates` unchanged.
     */
    func orderedCandidates(
        _ candidates: [AndroidStrongsKeyCandidate],
        moduleInitials: String
    ) -> [AndroidStrongsKeyCandidate] {
        lock.lock()
        let preferred = preferredFamilyByModuleInitials[moduleInitials]
        lock.unlock()
        guard let preferred else { return candidates }
        return candidates.filter { $0.family == preferred }
            + candidates.filter { $0.family != preferred }
    }

    /**
     Records the family of an accepted exact dictionary lookup.

     - Parameters:
       - family: Typed Android family that produced accepted content.
       - moduleInitials: Canonical installed module initials.
     - Side effects: Atomically replaces one in-memory cache entry.
     - Failure modes: None; empty initials remain a deterministic dictionary key.
     */
    func record(
        _ family: AndroidStrongsKeyFamily,
        moduleInitials: String
    ) {
        lock.lock()
        preferredFamilyByModuleInitials[moduleInitials] = family
        lock.unlock()
    }
}
