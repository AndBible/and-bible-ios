import XCTest
@testable import BibleCore

/** Verifies the Android persistence identity domain independently of any filtered module catalog. */
final class JSwordBibleBookTests: XCTestCase {
    /** Includes introductions and extended-canon books whose positions differ from KJVA table order. */
    func testAndroidPersistedBookIdentitiesAcrossCanons() {
        let androidIdentities: [(String, Int)] = [
            ("Intro.Bible", 0), ("Gen", 2), ("Esth", 18), ("Ps", 20),
            ("Matt", 42), ("Tob", 69), ("3Macc", 81), ("Ps151", 86),
            ("EsthGr", 126),
        ]
        for (osisID, ordinal) in androidIdentities {
            XCTAssertEqual(JSwordBibleBook.ordinal(forOSIS: osisID), ordinal, osisID)
            XCTAssertEqual(JSwordBibleBook.osisID(forOrdinal: ordinal), osisID)
        }
    }

    /** SWORD's wisdom-book alias resolves to the same identity without accepting arbitrary names. */
    func testAliasAndInvalidSavedIdentities() {
        XCTAssertEqual(JSwordBibleBook.ordinal(forOSIS: "WisSol"), 72)
        XCTAssertEqual(JSwordBibleBook.osisID(forOrdinal: 72), "Wis")
        XCTAssertNil(JSwordBibleBook.ordinal(forOSIS: "UnknownBook"))
        XCTAssertNil(JSwordBibleBook.osisID(forOrdinal: -1))
        XCTAssertNil(JSwordBibleBook.osisID(forOrdinal: 127))
    }

    /** Resolves only explicitly canonical PageManager identities without guessing a source list. */
    func testPageManagerCanonicalBibleIdentityFailsClosedForLegacyAndUnknownEncodings() throws {
        let pageManager = PageManager()
        pageManager.bibleBibleBook = try XCTUnwrap(JSwordBibleBook.ordinal(forOSIS: "Ps"))
        pageManager.bibleBookEncoding = PageManager.jswordBibleBookEncoding

        XCTAssertEqual(pageManager.canonicalBibleOSISBookID, "Ps")

        pageManager.bibleBibleBook = try XCTUnwrap(JSwordBibleBook.ordinal(forOSIS: "Tob"))
        XCTAssertEqual(pageManager.canonicalBibleOSISBookID, "Tob")

        pageManager.bibleBookEncoding = nil
        XCTAssertNil(pageManager.canonicalBibleOSISBookID)

        pageManager.bibleBookEncoding = "futureEncoding"
        XCTAssertNil(pageManager.canonicalBibleOSISBookID)

        pageManager.bibleBookEncoding = PageManager.jswordBibleBookEncoding
        pageManager.bibleBibleBook = 127
        XCTAssertNil(pageManager.canonicalBibleOSISBookID)

        pageManager.bibleBibleBook = nil
        XCTAssertNil(pageManager.canonicalBibleOSISBookID)
    }
}
