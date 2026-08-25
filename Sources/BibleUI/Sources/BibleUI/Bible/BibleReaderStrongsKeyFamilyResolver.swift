// BibleReaderStrongsKeyFamilyResolver.swift — Android Strong's route and typed key families

import BibleCore
import Foundation

/**
 Classifies external Strong's routes and builds Android's exact typed dictionary-key candidates.

 Android examines the first raw UTF-16 unit: only uppercase `G` is Greek and every other/empty value
 routes to Hebrew. Candidate construction then preserves the raw, padded, padded-plus-carriage-return,
 and category families—including duplicate values and Android's malformed-input outputs.

 - Side effects: None.
 - Failure modes: Values outside Android's grammar remain deterministic malformed-family candidates;
 no iOS-only normalization or alias is introduced.
 */
enum BibleReaderStrongsKeyFamilyResolver {
    /**
     Returns Android's ordered typed candidates for one decoded external Strong's value.

     - Parameter strongsNumber: Untrimmed external link value.
     - Returns: Raw, padded, padded-carriage-return, and category families in Android order.
     - Side effects: None.
     - Failure modes: Malformed/empty input remains a deterministic malformed Hebrew-family result.
     */
    static func candidates(for strongsNumber: String) -> [AndroidStrongsKeyCandidate] {
        AndroidStrongsKeyResolution.candidates(
            for: strongsNumber,
            categoryPrefix: isHebrew(strongsNumber) ? "H" : "G"
        )
    }

    /**
     Returns candidate string values while preserving duplicate typed-family positions.

     - Parameter strongsNumber: Untrimmed external link value.
     - Returns: Candidate values in exact Android family order, including duplicates.
     - Side effects: None.
     - Failure modes: Delegates deterministic malformed-input handling to `candidates(for:)`.
     */
    static func values(for strongsNumber: String) -> [String] {
        candidates(for: strongsNumber).map(\.value)
    }

    /**
     Returns whether Android routes one raw external value to the Hebrew dictionary family.

     - Parameter strongsNumber: Untrimmed external Strong's value.
     - Returns: False only when the first UTF-16 code unit is uppercase `G` (`0x0047`).
     - Side effects: None.
     - Failure modes: Empty/malformed values classify as Hebrew.
     */
    static func isHebrew(_ strongsNumber: String) -> Bool {
        strongsNumber.utf16.first != 0x0047
    }
}
