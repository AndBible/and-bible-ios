/**
 Hashable Java `String.equals` identity over the exact UTF-16 code-unit sequence.

 Swift `String` equality deliberately treats canonically equivalent Unicode spellings as equal,
 while Java `String.equals`, `HashMap`, and `HashSet` compare the stored UTF-16 `char` sequence.
 Installed-book registries and persisted Android fields use this value whenever normalization or
 locale-sensitive comparison would merge identities that Java keeps distinct.

 The identity retains no original `String`; callers that serialize or display a value keep that
 string alongside this key. Construction and equality are deterministic for a supplied UTF-16
 sequence. Swift supplies process-local `Hashable` seeding, while equal identities always hash
 equally within that process. Construction has no side effects and cannot fail for a valid string.
 */
public struct SwordJavaExactStringIdentity: Hashable, Sendable {
    /// Exact unsigned Java `char` sequence, exposed for Java-compatible ordering and serialization.
    public let utf16CodeUnits: [UInt16]

    /**
     Creates an exact Java string key without normalization, trimming, or case folding.

     - Parameter value: Swift string whose current UTF-16 representation defines the Java identity.
     - Side effects: None.
     - Failure modes: None; every Swift string exposes a valid UTF-16 view.
     */
    public init(_ value: String) {
        utf16CodeUnits = Array(value.utf16)
    }
}

/**
 Hashable Android 37 `String.equalsIgnoreCase` identity over Java UTF-16 `char` units.

 Android compares equal-length strings one UTF-16 unit at a time, applying non-expanding
 `Character.toUpperCase(char)` and lowercase fallback. Supplementary case pairs therefore remain
 distinct because each surrogate unit is unchanged. The backing mappings come from SwordKit's
 generated Android 37 ICU 78.3 resource rather than host Foundation Unicode behavior.
 */
public struct SwordJavaStringIdentity: Hashable, Sendable {
    /// Android lowercase-of-uppercase representative for each original Java `char`.
    private let foldedUTF16: [UInt16]

    /**
     Creates a stable Android case-insensitive identity for one exact Swift string.

     - Parameter value: Installed initials, full name, or other Java string identity.
     - Side effects: Loads and validates SwordKit's generated character table on first use.
     - Failure modes: Traps when the target resource is missing/corrupt because falling back to a
       host Unicode version could merge or authorize the wrong installed module.
     */
    public init(_ value: String) {
        precondition(
            SwordJavaTextCompatibility.bundledCharacterRowCount
                == SwordJavaTextCompatibility.expectedBundledCharacterRowCount,
            "Missing pinned Android 37 Java character compatibility table"
        )
        foldedUTF16 = value.utf16.map(SwordJavaTextCompatibility.equalsIgnoreCaseFold)
    }

    /**
     Compares two strings with Java `String.equals` UTF-16 identity semantics.

     - Parameters:
       - lhs: First exact Java string identity.
       - rhs: Second exact Java string identity.
     - Returns: True only when both strings contain the same UTF-16 code units; unlike Swift
       `String ==`, canonically equivalent composed and decomposed spellings remain distinct.
     - Side effects: None.
     - Failure modes: None; Swift strings expose a valid UTF-16 view for exact comparison.
     */
    public static func equals(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.elementsEqual(rhs.utf16)
    }

    /**
     Compares two strings with Android 37 `String.equalsIgnoreCase` semantics.

     - Parameters:
       - lhs: First exact UTF-16 string.
       - rhs: Second exact UTF-16 string.
     - Returns: True only for equal-length per-`char` Android case matches.
     - Side effects: Loads the bundled compatibility table on first use.
     - Failure modes: Traps for a missing/corrupt generated resource through identity creation.
     */
    public static func equalsIgnoreCase(_ lhs: String, _ rhs: String) -> Bool {
        SwordJavaStringIdentity(lhs) == SwordJavaStringIdentity(rhs)
    }

    /**
     Compares two strings with Java's non-locale `String.compareToIgnoreCase` ordering.

     - Parameters:
       - lhs: First Java UTF-16 string.
       - rhs: Second Java UTF-16 string.
     - Returns: Negative, zero, or positive according to the first differing Android-folded Java
       `char`, then UTF-16 length.
     - Side effects: Loads the bundled Android compatibility table on first use.
     - Failure modes: Traps for a missing/corrupt generated resource through identity creation.
     */
    public static func compareIgnoreCase(_ lhs: String, _ rhs: String) -> Int {
        let left = SwordJavaStringIdentity(lhs).foldedUTF16
        let right = SwordJavaStringIdentity(rhs).foldedUTF16
        for (leftUnit, rightUnit) in zip(left, right) where leftUnit != rightUnit {
            return Int(leftUnit) - Int(rightUnit)
        }
        return left.count - right.count
    }

    /**
     Removes edge characters with Java `String.trim()` UTF-16 semantics.

     - Parameter value: Exact generated-config or Java boundary string.
     - Returns: The substring after removing leading/trailing code units `<= U+0020`; NBSP and all
       higher Unicode whitespace remain unchanged.
     - Side effects: None.
     - Failure modes: None; valid Swift strings round-trip through their UTF-16 representation.
     */
    public static func trim(_ value: String) -> String {
        let units = Array(value.utf16)
        var start = 0
        var end = units.count
        while start < end, units[start] <= 0x20 { start += 1 }
        while end > start, units[end - 1] <= 0x20 { end -= 1 }
        return String(decoding: units[start..<end], as: UTF16.self)
    }
}
