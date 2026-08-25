import XCTest
@testable import SwordKit

/**
 Verifies Java-exact string-set behavior at Android module identity boundaries.

 Tests use in-memory Unicode strings and perform no filesystem, SWORD, or persistence I/O. Failures
 mean a Swift collection can merge Android-distinct identities or retain exact duplicates.
 */
final class SwordJavaExactStringSetTests: XCTestCase {
    /**
     Verifies canonical spellings and case variants remain independent while exact duplicates dedupe.

     The fixture uses one NFC/NFD pair and one case pair. Failure means downstream selection state
     cannot represent every book retained by Java `HashSet<String>`.
     */
    func testPreservesJavaDistinctSpellingsAndDeduplicatesExactValues() {
        let composed = "Caf\u{00E9}"
        let decomposed = "Cafe\u{0301}"
        let values = SwordJavaExactStringSet([
            composed,
            decomposed,
            composed,
            "KJV",
            "kjv",
            "KJV",
        ])

        XCTAssertEqual(values.count, 4)
        XCTAssertTrue(values.contains(composed))
        XCTAssertTrue(values.contains(decomposed))
        XCTAssertTrue(values.contains("KJV"))
        XCTAssertTrue(values.contains("kjv"))
    }

    /**
     Verifies mutation and set algebra affect only exact UTF-16 identities.

     Failure means toggling or sanitizing one Android module can remove its canonically equivalent
     sibling or make order-sensitive state comparisons unstable.
     */
    func testMutationAndSetAlgebraUseExactUTF16Identity() {
        let composed = "Caf\u{00E9}"
        let decomposed = "Cafe\u{0301}"
        var values: SwordJavaExactStringSet = [composed, decomposed, "KJV"]

        XCTAssertTrue(values.remove(composed))
        XCTAssertFalse(values.contains(composed))
        XCTAssertTrue(values.contains(decomposed))
        XCTAssertTrue(values.insert(composed))
        XCTAssertFalse(values.insert(composed))
        XCTAssertEqual(
            values.intersection([decomposed, "KJV"]).values,
            SwordJavaExactStringSet([decomposed, "KJV"]).values
        )
        XCTAssertEqual(
            values.subtracting([composed]).values,
            SwordJavaExactStringSet([decomposed, "KJV"]).values
        )
        XCTAssertEqual(values, SwordJavaExactStringSet(["KJV", decomposed, composed]))

        values.formUnion(["kjv", decomposed])
        XCTAssertEqual(values.count, 4)
        values.removeAll()
        XCTAssertTrue(values.isEmpty)
    }
}
