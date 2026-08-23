import Foundation
import SwordKit

/**
 Reproduces the pinned JSword `RawLDBackend.search` contract for reader dictionaries.

 libsword and JSword can position the same RawLD module differently for case-insensitive and
 Strong's-padded requests. JSword derives Strong's padding from the first binary-search midpoint,
 not from the eventual hit. The reader therefore resolves against the exact source-index key order
 before asking libsword to read the selected stored record. This preserves Android's typed-family
 cache without accepting an unrelated libsword nearest-key result.

 - Side effects: Evaluates cached regular expressions and pinned Java string transforms; it does
   not move a SWORD cursor or mutate the physical index.
 - Failure modes: Empty, corrupt, undecodable, or unsupported physical-index shapes fail closed.
   A no-progress guard intentionally returns a miss for corrupt shapes that can hang pinned JSword.
 */
enum AndroidJSwordRawLDKeyResolution {
    /**
     Captures every installed-book input used by pinned RawLD key normalization.

     Initials, category, and feature flags come from the actual globally selected book; boolean
     fields are parsed from its config. The value is immutable for one lookup so binary-search
     normalization cannot observe mixed metadata.

     - Side effects: None.
     - Failure modes: Callers project JSword defaults before construction: missing
       `CaseSensitiveKeys` is false, while missing `StrongsPadding` is true.
     */
    struct Configuration {
        /// Canonical installed-book initials used by JSword's `naslex` suffix exception.
        let moduleInitials: String

        /// Actual installed-book category; daily devotions do not case-fold search keys.
        let category: ModuleCategory

        /// Actual installed-book features that enable Strong's external-key normalization.
        let features: ModuleFeatures

        /// Parsed `CaseSensitiveKeys=true` flag from the module configuration.
        let caseSensitiveKeys: Bool

        /// Parsed `StrongsPadding=true` flag from the module configuration.
        let strongsPadding: Bool
    }

    /** Anchored JSword Strong's grammar, including its optional lowercase NASB decoration. */
    private static let strongsPattern = try! NSRegularExpression(
        pattern: #"^([GH])([0-9]+)((!)?([a-z])?)$"#
    )

    /** JSword's already-internal daily-devotion key grammar. */
    private static let devotionPattern = try! NSRegularExpression(pattern: #"^[0-9][0-9]\.[0-9][0-9]$"#)

    /**
     Retains exact captures from JSword's anchored Strong's grammar.

     Prefix/digits determine numeric formatting; suffix/separator preserve the pinned `naslex`
     exception and no-padding stripping quirk without normalizing the original spelling.

     - Side effects: None; instances are immutable.
     - Failure modes: Nonmatching or overflowing inputs are rejected before this value is used.
     */
    private struct StrongsComponents {
        /// Initial uppercase Greek/Hebrew prefix.
        let prefix: String

        /// Complete ASCII numeric group, including any leading zeroes.
        let digits: String

        /// Optional trailing lowercase letter.
        let suffix: String?

        /// Whether the suffix was preceded by JSword's optional exclamation mark.
        let hasSuffixSeparator: Bool
    }

    /**
     Identifies the exact physical RawLD-family record selected by JSword search.

     - Side effects: None; values are immutable.
     - Failure modes: Construction occurs only after a nonzero slot supplies a decoded key.
     */
    struct Resolution: Equatable {
        /// Zero-based source-index position, retained to avoid a second ambiguous key search.
        let index: Int

        /// Exact stored DataEntry key used by Android fragment identity and typed-family caching.
        let storedKey: String
    }

    /**
     Resolves the exact RawLD key selected by pinned JSword's binary search.

     JSword searches indices `1..<count`, using index zero only as an after-search special case for
     dictionary title records. It normalizes the supplied key exactly once, using the first midpoint
     entry as `external2internal`'s Strong's-padding pattern. A case-sensitive miss then performs a
     raw exact linear scan. Zero-size midpoint slots move one index toward the longer side before
     comparison, exactly as pinned JSword does; valid empty-body entries remain positive-size slots.

     - Parameters:
       - requestedKey: The single typed Strong's family or raw Robinson key sent to `Book.getKey`.
       - storedSlots: Physical RawLD-family slots in source order, including duplicates and
         zero-size placeholders.
       - configuration: Actual selected-book category, features, initials, and config flags.
     - Returns: Exact physical index and stored key selected by JSword, or `nil` for a search miss.
     - Side effects: Applies deterministic regular-expression and locale-US string transforms.
     - Failure modes: Empty lists, malformed daily-devotion requests, Strong's integer overflow,
       repeated-zero cycles, and midpoint moves that make no search-bound progress fail closed. The
       no-progress guard is an intentional safety-only divergence: pinned Android can loop forever
       on corrupt shapes such as `[valid index zero, zero-size index one]`; iOS returns a miss.
     */
    static func resolve(
        requestedKey: String,
        storedSlots: [SwordRawDictionaryIndexSlot],
        configuration: Configuration
    ) -> Resolution? {
        guard !storedSlots.isEmpty else { return nil }

        var low = 0
        var high = storedSlots.count
        var suppliedKey: String?

        while high - low > 1 {
            let previousLow = low
            let previousHigh = high
            var midpoint = (low + high) >> 1
            var visitedZeroIndices: Set<Int> = []
            while storedSlots.indices.contains(midpoint), storedSlots[midpoint].size == 0 {
                guard visitedZeroIndices.insert(midpoint).inserted else { return nil }
                midpoint += high - midpoint > midpoint - low ? 1 : -1
                guard midpoint >= low, midpoint <= high else { return nil }
            }
            guard storedSlots.indices.contains(midpoint),
                  let storedKey = storedSlots[midpoint].key else {
                return nil
            }
            let entryKey = normalizeForSearch(
                storedKey,
                configuration: configuration
            )
            if suppliedKey == nil {
                guard let internalRequestedKey = externalToInternal(
                    requestedKey,
                    storedPattern: entryKey,
                    configuration: configuration
                ) else {
                    return nil
                }
                suppliedKey = normalizeForSearch(
                    internalRequestedKey,
                    configuration: configuration
                )
            }
            guard let suppliedKey else { return nil }
            let comparison = javaStringCompare(entryKey, suppliedKey)
            if comparison < 0 {
                low = midpoint
            } else if comparison > 0 {
                high = midpoint
            } else {
                return Resolution(index: midpoint, storedKey: storedKey)
            }
            guard low != previousLow || high != previousHigh else { return nil }
        }

        let firstStoredKey = storedSlots[0].key ?? ""
        let firstEntryKey = normalizeForSearch(
            firstStoredKey,
            configuration: configuration
        )
        if suppliedKey == nil {
            guard let internalRequestedKey = externalToInternal(
                requestedKey,
                storedPattern: firstEntryKey,
                configuration: configuration
            ) else {
                return nil
            }
            suppliedKey = normalizeForSearch(
                internalRequestedKey,
                configuration: configuration
            )
        }
        if let suppliedKey, javaStringCompare(firstEntryKey, suppliedKey) == 0 {
            return Resolution(index: 0, storedKey: firstStoredKey)
        }

        if configuration.caseSensitiveKeys {
            for slot in storedSlots {
                let storedKey = slot.key ?? ""
                if javaStringEquals(storedKey, requestedKey) {
                    return Resolution(index: slot.index, storedKey: storedKey)
                }
            }
        }
        return nil
    }

    /**
     Parses JSword boolean config values with Java `String.equalsIgnoreCase` semantics.

     - Parameter value: Optional raw SWORD config entry.
     - Returns: `true` only for a case-insensitive exact spelling of `true`.
     - Side effects: Loads SwordKit's pinned Android Java-string identity table.
     - Failure modes: Missing, padded, or non-boolean values return `false`, matching JSword.
     */
    static func javaBoolean(_ value: String?) -> Bool {
        guard let value else { return false }
        return SwordJavaStringIdentity.equalsIgnoreCase(value, "true")
    }

    /**
     Applies pinned `RawLDBackend.normalizeForSearch` behavior.

     - Parameters:
       - value: Stored or externally normalized key.
       - configuration: Actual book category and case-sensitivity flag.
     - Returns: Original text for case-sensitive/daily-devotion books; otherwise Locale.US
       uppercase, as JSword uses for RawLD binary search.
     - Side effects: None.
     - Failure modes: None for reader Strong's and Robinson ASCII keys; Foundation performs the
       same locale-US full-string case mapping for any non-ASCII book key that reaches this route.
     */
    private static func normalizeForSearch(
        _ value: String,
        configuration: Configuration
    ) -> String {
        guard !configuration.caseSensitiveKeys,
              configuration.category != .dailyDevotion else {
            return value
        }
        return value.uppercased(with: Locale(identifier: "en_US"))
    }

    /**
     Applies pinned `RawLDBackend.external2internal` behavior relevant to dictionary routes.

     - Parameters:
       - requestedKey: External candidate supplied by Android `LinkControl`.
       - storedPattern: Search-normalized RawLD key used by JSword to infer Strong's padding style.
       - configuration: Actual selected-book metadata and config flags.
     - Returns: JSword's internal search key, or `nil` when the request cannot be interpreted.
     - Side effects: None.
     - Failure modes: Non-internal daily-devotion display dates fail closed because Strong's and
       Robinson routes never supply localized calendar labels; overflowing Strong's numbers also
       fail as Java `Integer.parseInt` does.
     */
    private static func externalToInternal(
        _ requestedKey: String,
        storedPattern: String,
        configuration: Configuration
    ) -> String? {
        guard !requestedKey.isEmpty else { return requestedKey }
        if configuration.category == .dailyDevotion {
            return exactMatch(devotionPattern, in: requestedKey) == nil ? nil : requestedKey
        }

        let hasGreekDefinitions = configuration.features.contains(.greekDef)
        let hasHebrewDefinitions = configuration.features.contains(.hebrewDef)
        guard hasGreekDefinitions || hasHebrewDefinitions,
              let components = strongsComponents(from: requestedKey) else {
            return requestedKey
        }

        if configuration.strongsPadding {
            guard let number = Int32(components.digits) else { return nil }
            let suffix = components.suffix
            let keepsSuffix = suffix != nil
                && SwordJavaStringIdentity.equalsIgnoreCase(
                    configuration.moduleInitials,
                    "naslex"
                )
            if hasGreekDefinitions && hasHebrewDefinitions {
                return components.prefix
                    + zeroPadded(number, minimumDigits: 4)
                    + (keepsSuffix ? suffix! : "")
            }

            if let storedComponents = strongsComponents(from: storedPattern) {
                let minimumDigits = storedComponents.digits.count == 4 ? 4 : 5
                return components.prefix
                    + zeroPadded(number, minimumDigits: minimumDigits)
                    + (keepsSuffix ? suffix! : "")
            }
            return zeroPadded(number, minimumDigits: 5)
        }

        // Pinned JSword constructs an unpadded buffer but never returns it. Its only observable
        // mutation is stripping a trailing lowercase letter (and optional `!`) when digit 1 is 0.
        guard requestedKey.utf16.dropFirst().first == 0x0030 else { return requestedKey }
        guard Int32(components.digits) != nil else { return nil }
        guard components.suffix != nil else { return requestedKey }
        let suffixLength = components.hasSuffixSeparator ? 2 : 1
        return String(requestedKey.dropLast(suffixLength))
    }

    /**
     Extracts JSword Strong's regex groups without normalizing their spelling.

     - Parameter value: Candidate or stored-pattern key.
     - Returns: Prefix, digits, suffix, and separator state for an exact grammar match.
     - Side effects: Evaluates the cached regular expression.
     - Failure modes: Invalid UTF-16 ranges or nonmatching keys return `nil`.
     */
    private static func strongsComponents(from value: String) -> StrongsComponents? {
        guard let match = exactMatch(strongsPattern, in: value),
              let prefixRange = Range(match.range(at: 1), in: value),
              let digitsRange = Range(match.range(at: 2), in: value) else {
            return nil
        }
        let suffix: String?
        if match.range(at: 5).location != NSNotFound,
           let suffixRange = Range(match.range(at: 5), in: value) {
            suffix = String(value[suffixRange])
        } else {
            suffix = nil
        }
        return StrongsComponents(
            prefix: String(value[prefixRange]),
            digits: String(value[digitsRange]),
            suffix: suffix,
            hasSuffixSeparator: match.range(at: 4).location != NSNotFound
        )
    }

    /**
     Evaluates one cached JSword grammar against the entire Swift string range.

     - Parameters:
       - regex: Anchored expression representing one pinned JSword key grammar.
       - value: Candidate or stored key inspected without normalization.
     - Returns: The first complete match, or nil when grammar/UTF-16 conversion fails.
     - Side effects: None.
     - Failure modes: Invalid ranges and nonmatches return nil.
     */
    private static func exactMatch(
        _ regex: NSRegularExpression,
        in value: String
    ) -> NSTextCheckingResult? {
        regex.firstMatch(
            in: value,
            range: NSRange(value.startIndex..., in: value)
        )
    }

    /**
     Formats one parsed Java integer with DecimalFormat's minimum-zero behavior.

     - Parameters:
       - number: Nonnegative Strong's integer already accepted by Java-compatible parsing.
       - minimumDigits: Minimum decimal width inferred from module feature/pattern state.
     - Returns: Decimal digits left-padded with ASCII zeroes to at least the requested width.
     - Side effects: None.
     - Failure modes: None; values wider than the minimum remain unchanged.
     */
    private static func zeroPadded(_ number: Int32, minimumDigits: Int) -> String {
        let digits = String(number)
        return String(repeating: "0", count: max(0, minimumDigits - digits.count)) + digits
    }

    /**
     Compares Java `String.equals` values by exact UTF-16 code units.

     - Parameters: `lhs` and `rhs` are raw stored/requested key strings.
     - Returns: True only for exact code-unit identity.
     - Side effects: None.
     - Failure modes: None.
     */
    private static func javaStringEquals(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.elementsEqual(rhs.utf16)
    }

    /**
     Implements Java `String.compareTo` over unsigned UTF-16 code units.

     - Parameters: `lhs` and `rhs` are normalized binary-search keys.
     - Returns: Negative, zero, or positive at the first differing unit, then by unit count.
     - Side effects: None.
     - Failure modes: None.
     */
    private static func javaStringCompare(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs.utf16)
        let right = Array(rhs.utf16)
        for (leftUnit, rightUnit) in zip(left, right) where leftUnit != rightUnit {
            return Int(leftUnit) - Int(rightUnit)
        }
        return left.count - right.count
    }
}
