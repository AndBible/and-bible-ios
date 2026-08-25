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
 Set-like collection whose membership follows Java `String.equals` over exact UTF-16 code units.

 Swift `Set<String>` merges canonically equivalent Unicode spellings, while Android/Kotlin module
 selections use Java strings and keep those spellings independent. This value preserves the first
 raw spelling for each exact identity, stores values in deterministic unsigned UTF-16 order, and
 exposes only Java-exact membership and set algebra.

 Inputs are Swift strings at Android module, document, or persisted-setting identity boundaries.
 Iteration and `values` return deterministic raw strings without normalization. Mutating operations
 affect only this in-memory value and perform no I/O. Construction and set operations cannot fail.
 */
public struct SwordJavaExactStringSet: Equatable, Sendable, ExpressibleByArrayLiteral, Sequence {
    /// Exact raw values sorted lexicographically by unsigned Java UTF-16 code units.
    private var storage: [String]

    /**
     Creates an empty Java-exact string set.

     - Side effects: None.
     - Failure modes: None.
     */
    public init() {
        storage = []
    }

    /**
     Creates a Java-exact string set from a sequence, retaining one value per UTF-16 identity.

     - Parameter values: Raw strings whose exact UTF-16 identities should be retained.
     - Side effects: None.
     - Failure modes: None; duplicate exact identities are omitted after their first occurrence.
     */
    public init<S: Sequence>(_ values: S) where S.Element == String {
        var seen = Set<SwordJavaExactStringIdentity>()
        storage = values.filter {
            seen.insert(SwordJavaExactStringIdentity($0)).inserted
        }.sorted(by: Self.javaUTF16Precedes)
    }

    /**
     Creates a Java-exact set from an array literal.

     - Parameter elements: Raw literal values to de-duplicate by exact UTF-16 identity.
     - Side effects: None.
     - Failure modes: None.
     */
    public init(arrayLiteral elements: String...) {
        self.init(elements)
    }

    /**
     Number of exact Java string identities in the set.

     - Returns: Count after exact UTF-16 duplicate removal.
     - Side effects: None.
     - Failure modes: None.
     */
    public var count: Int { storage.count }

    /**
     Whether the set contains no exact Java string identities.

     - Returns: `true` when `count` is zero.
     - Side effects: None.
     - Failure modes: None.
     */
    public var isEmpty: Bool { storage.isEmpty }

    /**
     Deterministically ordered raw values for persistence, display, or boundary adaptation.

     - Returns: Retained spellings in unsigned Java UTF-16 order.
     - Side effects: None.
     - Failure modes: None.
     */
    public var values: [String] { storage }

    /**
     Returns whether the set contains one exact Java UTF-16 string identity.

     - Parameter value: Raw string identity to test without normalization or case folding.
     - Returns: `true` only when every UTF-16 code unit matches a stored value.
     - Side effects: None.
     - Failure modes: None.
     */
    public func contains(_ value: String) -> Bool {
        let identity = SwordJavaExactStringIdentity(value)
        return storage.contains { SwordJavaExactStringIdentity($0) == identity }
    }

    /**
     Inserts one exact Java string identity.

     - Parameter value: Raw string to retain when its exact UTF-16 identity is absent.
     - Returns: `true` when the set changed, otherwise `false` for an exact duplicate.
     - Side effects: Mutates only this in-memory value and restores deterministic ordering.
     - Failure modes: None.
     */
    @discardableResult
    public mutating func insert(_ value: String) -> Bool {
        guard !contains(value) else { return false }
        storage.append(value)
        storage.sort(by: Self.javaUTF16Precedes)
        return true
    }

    /**
     Removes one exact Java string identity.

     - Parameter value: Raw string whose exact UTF-16 identity should be removed.
     - Returns: `true` when a value was removed, otherwise `false`.
     - Side effects: Mutates only this in-memory value.
     - Failure modes: None.
     */
    @discardableResult
    public mutating func remove(_ value: String) -> Bool {
        let identity = SwordJavaExactStringIdentity(value)
        guard let index = storage.firstIndex(where: {
            SwordJavaExactStringIdentity($0) == identity
        }) else { return false }
        storage.remove(at: index)
        return true
    }

    /**
     Removes every exact identity from this set.

     - Side effects: Clears only this in-memory value.
     - Failure modes: None.
     */
    public mutating func removeAll() {
        storage.removeAll()
    }

    /**
     Adds every exact identity in a raw string sequence.

     - Parameter values: Raw strings to union into the receiver.
     - Side effects: Mutates only this in-memory value.
     - Failure modes: None; exact duplicates are ignored.
     */
    public mutating func formUnion<S: Sequence>(_ values: S) where S.Element == String {
        for value in values {
            insert(value)
        }
    }

    /**
     Returns exact identities shared with another Java-exact string set.

     - Parameter other: Set providing the permitted exact identities.
     - Returns: Deterministically ordered Java-exact intersection.
     - Side effects: None.
     - Failure modes: None.
     */
    public func intersection(_ other: SwordJavaExactStringSet) -> SwordJavaExactStringSet {
        SwordJavaExactStringSet(storage.filter(other.contains))
    }

    /**
     Returns this set after removing exact identities present in a raw sequence.

     - Parameter values: Raw strings whose exact identities should be removed.
     - Returns: Deterministically ordered Java-exact difference.
     - Side effects: None.
     - Failure modes: None.
     */
    public func subtracting<S: Sequence>(_ values: S) -> SwordJavaExactStringSet
    where S.Element == String {
        let removed = SwordJavaExactStringSet(values)
        return SwordJavaExactStringSet(storage.filter { !removed.contains($0) })
    }

    /**
     Iterates raw strings in deterministic unsigned Java UTF-16 order.

     - Returns: Iterator over the retained raw values.
     - Side effects: None.
     - Failure modes: None.
     */
    public func makeIterator() -> IndexingIterator<[String]> {
        storage.makeIterator()
    }

    /**
     Compares two collections as Java-exact sets.

     - Parameters:
       - lhs: First exact-identity collection.
       - rhs: Second exact-identity collection.
     - Returns: `true` only when both contain the same exact UTF-16 identities.
     - Side effects: None.
     - Failure modes: None.
     */
    public static func == (
        lhs: SwordJavaExactStringSet,
        rhs: SwordJavaExactStringSet
    ) -> Bool {
        lhs.storage.count == rhs.storage.count
            && zip(lhs.storage, rhs.storage).allSatisfy {
                SwordJavaExactStringIdentity($0.0) == SwordJavaExactStringIdentity($0.1)
            }
    }

    /**
     Orders two raw strings lexicographically by unsigned Java UTF-16 code units.

     - Parameters:
       - lhs: First raw Java string.
       - rhs: Second raw Java string.
     - Returns: `true` when `lhs` precedes `rhs` by Java UTF-16 code-unit order.
     - Side effects: None.
     - Failure modes: None.
     */
    private static func javaUTF16Precedes(_ lhs: String, _ rhs: String) -> Bool {
        SwordJavaExactStringIdentity(lhs).utf16CodeUnits.lexicographicallyPrecedes(
            SwordJavaExactStringIdentity(rhs).utf16CodeUnits
        )
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
