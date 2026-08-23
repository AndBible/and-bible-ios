import Foundation
import SwordKit

/**
 Resolves one external key with pinned JSword `SwordGenBook.getKey` semantics.

 Callers provide libsword's physical TreeKey traversal and receive distinct leaf-name/full-path
 identity for the selected entry. Exact, casefold, prefix, and substring tiers are preserved;
 ambiguous non-exact winners use deterministic source order because Android HashMap order is not a
 portable app contract.

 - Side effects: Loads the pinned Java case-fold table for case-insensitive tiers.
 - Failure modes: Empty or unmatched key maps return nil from `resolve`.
 */
enum AndroidJSwordGenBookKeyResolution {
    /**
     Captures the three key identities exposed after selecting one TreeKey.

     `sourceKey` reloads libsword, `keyName` is Android `Key.name`, and `osisRef` is both JSword
     `osisID` and `osisRef`. Keeping them separate prevents nested paths from flattening in Vue.

     - Side effects: None; values are immutable.
     - Failure modes: None; root keys may legitimately produce empty leaf/path values.
     */
    struct Resolution: Equatable {
        /// Exact path returned by libsword key enumeration and accepted by `rawOSISFragment`.
        let sourceKey: String

        /// TreeKey leaf name exposed as Android `Key.name`.
        let keyName: String

        /// Full TreeKey path exposed as both `Key.osisID` and `Key.osisRef`.
        let osisRef: String

        /// Selected TreeKey plus every descendant, matching `TreeKey.getCardinality()`.
        let subtreeCardinality: Int
    }

    /**
     Models one distinct JSword local-map key during TreeKey activation.

     The OSIS reference is HashMap identity; a later duplicate replaces `sourceKey` without moving
     the first entry position, matching Java Map replacement behavior used by deterministic tiers.

     - Side effects: `sourceKey` may be replaced while building the local in-memory projection.
     - Failure modes: None; empty root OSIS references remain valid entries.
     */
    private struct Entry {
        /// Full JSword TreeKey OSIS reference used as the HashMap key.
        let osisRef: String

        /// Exact libsword path stored as the HashMap value.
        var sourceKey: String

    }

    /**
     Resolves a Strong's or morphology candidate through pinned `SwordGenBook.getKey` tiers.

     JSword constructs a default Java `HashMap` from every global TreeKey OSIS reference. Lookup
     first performs exact `Map.get`, then scans `keySet()` for whole-key equals-ignore-case, a
     case-sensitive prefix, and a case-sensitive substring. Android does not define which equal-tier
     match wins because `HashMap.keySet()` order varies by runtime. iOS uses physical tree preorder
     only for that Android-undefined tie while preserving the exact four lookup tiers.

     - Parameters:
       - candidate: Single typed Strong's family or raw Robinson code.
       - sourceKeys: Exact full paths from `SwordModule.loadAllKeys()` in insertion/traversal order.
     - Returns: Selected full-path/leaf identity, or `nil` when no tier matches.
     - Side effects: None.
     - Failure modes: Empty maps and unmatched candidates return `nil`; ambiguous matches within one
       non-exact tier use source preorder because Android exposes no portable winner contract.
     */
    static func resolve(
        candidate: String,
        sourceKeys: [String]
    ) -> Resolution? {
        let entries = distinctEntries(from: sourceKeys)
        guard !entries.isEmpty else { return nil }

        if let exact = entries.first(where: { javaStringEquals($0.osisRef, candidate) }) {
            return resolution(from: exact, entries: entries)
        }

        if let caseInsensitive = entries.first(where: {
            SwordJavaStringIdentity.equalsIgnoreCase($0.osisRef, candidate)
        }) {
            return resolution(from: caseInsensitive, entries: entries)
        }
        if let prefix = entries.first(where: {
            javaStringHasPrefix($0.osisRef, candidate)
        }) {
            return resolution(from: prefix, entries: entries)
        }
        if let substring = entries.first(where: {
            javaStringContains($0.osisRef, candidate)
        }) {
            return resolution(from: substring, entries: entries)
        }
        return nil
    }

    /**
     Projects libsword paths into JSword OSIS-reference map entries.

     - Parameter sourceKeys: Tree traversal paths, commonly prefixed by libsword's root slash.
     - Returns: Distinct Java map keys with replacement values and stable first insertion indices.
     - Side effects: None.
     - Failure modes: Empty root-only paths remain legal map keys, matching TreeKey metadata.
     */
    private static func distinctEntries(from sourceKeys: [String]) -> [Entry] {
        var entries: [Entry] = []
        for sourceKey in sourceKeys {
            let osisRef = sourceKey.utf16.first == 0x002F
                ? String(sourceKey.dropFirst())
                : sourceKey
            if let index = entries.firstIndex(where: { javaStringEquals($0.osisRef, osisRef) }) {
                entries[index].sourceKey = sourceKey
            } else {
                entries.append(Entry(
                    osisRef: osisRef,
                    sourceKey: sourceKey
                ))
            }
        }
        return entries
    }

    /**
     Builds Android's distinct leaf-name/full-path identity from one selected map entry.

     - Parameters:
       - entry: Selected local-map entry containing full OSIS path and libsword reload path.
       - entries: Distinct activated TreeKeys used to count the selected node's subtree.
     - Returns: A resolution whose name is the final path segment, whose OSIS identity is full, and
       whose cardinality includes the selected TreeKey plus every descendant.
     - Side effects: None.
     - Failure modes: None; an empty/root path yields an empty leaf name exactly like TreeKey.
     */
    private static func resolution(from entry: Entry, entries: [Entry]) -> Resolution {
        let keyName = entry.osisRef.split(separator: "/", omittingEmptySubsequences: false).last
            .map(String.init) ?? entry.osisRef
        let descendantPrefix = entry.osisRef.isEmpty ? "" : entry.osisRef + "/"
        let subtreeCardinality = entries.reduce(into: 0) { count, candidate in
            if javaStringEquals(candidate.osisRef, entry.osisRef)
                || (!descendantPrefix.isEmpty
                    && javaStringHasPrefix(candidate.osisRef, descendantPrefix))
                || entry.osisRef.isEmpty {
                count += 1
            }
        }
        return Resolution(
            sourceKey: entry.sourceKey,
            keyName: keyName,
            osisRef: entry.osisRef,
            subtreeCardinality: subtreeCardinality
        )
    }

    /**
     Compares Java `String.equals` identity without Swift normalization.

     - Parameters: `lhs` and `rhs` are exact candidate/map-key strings.
     - Returns: True only when every UTF-16 code unit matches.
     - Side effects: None.
     - Failure modes: None.
     */
    private static func javaStringEquals(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.elementsEqual(rhs.utf16)
    }

    /**
     Applies Java `String.startsWith` over UTF-16 code units.

     - Parameters: `value` is the full map key and `prefix` is the external lookup candidate.
     - Returns: True when the exact candidate units occupy the start of the map key.
     - Side effects: None.
     - Failure modes: Oversized prefixes return false; an empty prefix returns true.
     */
    private static func javaStringHasPrefix(_ value: String, _ prefix: String) -> Bool {
        let valueUnits = Array(value.utf16)
        let prefixUnits = Array(prefix.utf16)
        guard prefixUnits.count <= valueUnits.count else { return false }
        return valueUnits.prefix(prefixUnits.count).elementsEqual(prefixUnits)
    }

    /**
     Applies Java `String.contains` over exact UTF-16 code-unit sequences.

     - Parameters: `value` is the full map key and `substring` is the external candidate.
     - Returns: True for an exact contiguous match; Java's empty substring is always present.
     - Side effects: None.
     - Failure modes: Oversized nonempty candidates return false without indexing.
     */
    private static func javaStringContains(_ value: String, _ substring: String) -> Bool {
        let valueUnits = Array(value.utf16)
        let substringUnits = Array(substring.utf16)
        guard !substringUnits.isEmpty else { return true }
        guard substringUnits.count <= valueUnits.count else { return false }
        for start in 0...(valueUnits.count - substringUnits.count) {
            if valueUnits[start..<(start + substringUnits.count)].elementsEqual(substringUnits) {
                return true
            }
        }
        return false
    }
}
