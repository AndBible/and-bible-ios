import Foundation
import XCTest
@testable import BibleCore

/**
 Selection-core contract tests for the Android bookmark book-name resolver.

 These tests drive `AndroidBookmarkSwordBookNameResolver` through a deterministic fake gateway so
 the candidate iteration, versification matching, and all cross-versification fallback stages are
 executed without installed SWORD modules. Only the thin SwordKit gateway remains
 integration-tested elsewhere.
 */
final class AndroidBookmarkBookNameResolverTests: XCTestCase {
    /**
     Verifies unresolvable versification-matched candidates are skipped, not fatal.

     Round-1 review of issue #356 found the resolver committed to the first versification-matched
     module even when libsword could not open it (custom-driver or MyBible projections) or when a
     content-sparse module lacked the resolved book. The expected result is that later candidates
     with the same versification still resolve. A failure means one unloadable module silently
     disables restore normalization for the whole inventory.
     */
    func testResolverSkipsUnresolvableVersificationMatchedCandidates() {
        let gateway = FakeResolverGateway(
            modules: [
                (name: "AMP", versification: ""),
                (name: "KJV", versification: "KJV"),
            ],
            resolutions: [
                FakeResolverGateway.Key(module: "KJV", ordinal: 4):
                    AndroidBookmarkResolvedBook(name: "Genesis", testament: 1)
            ]
        )
        let resolver = AndroidBookmarkSwordBookNameResolver(gateway: gateway)

        XCTAssertEqual(
            resolver.displayBookName(v11nName: "KJV", ordinal: 4, kjvOrdinal: 4),
            "Genesis",
            "An unloadable first candidate must not block resolution through later candidates."
        )
    }

    /**
     Verifies KJVA bookmarks resolve through a KJVA-versified module using the KJVA ordinal.

     Android's default bookmark versification is KJVA, so restored rows frequently carry KJVA
     ordinals. The expected result is stage-two resolution through an installed KJVA module when
     the primary versification match is empty. A failure means KJVA rows only resolve via the
     Old-Testament-restricted KJV fallback.
     */
    func testResolverUsesKJVAModuleForKJVABookmarks() {
        let gateway = FakeResolverGateway(
            modules: [(name: "KJVA-MOD", versification: "KJVA")],
            resolutions: [
                FakeResolverGateway.Key(module: "KJVA-MOD", ordinal: 30031):
                    AndroidBookmarkResolvedBook(name: "Matthew", testament: 2)
            ]
        )
        let resolver = AndroidBookmarkSwordBookNameResolver(gateway: gateway)

        XCTAssertEqual(
            resolver.displayBookName(v11nName: "KJVA", ordinal: 30031, kjvOrdinal: 30031),
            "Matthew",
            "KJVA rows must resolve directly through a KJVA-versified module."
        )
    }

    /**
     Verifies the Old-Testament-restricted KJV fallback for KJVA ordinals.

     KJV and KJVA intro-inclusive ordinals are identical from Genesis through Malachi, so a KJVA
     Old Testament ordinal may resolve through a KJV module — but only when the resolved book is
     Old Testament. The expected result accepts Genesis and rejects a same-ordinal New Testament
     resolution, which would indicate the ordinal lies in the diverged post-apocrypha range.
     A failure means either stock-install KJVA OT rows stay unresolved or unsound cross-space
     resolutions leak through.
     */
    func testResolverAppliesOldTestamentGateToKJVFallback() {
        let gateway = FakeResolverGateway(
            modules: [(name: "KJV", versification: "KJV")],
            resolutions: [
                FakeResolverGateway.Key(module: "KJV", ordinal: 4):
                    AndroidBookmarkResolvedBook(name: "Genesis", testament: 1),
                FakeResolverGateway.Key(module: "KJV", ordinal: 25000):
                    AndroidBookmarkResolvedBook(name: "Luke", testament: 2),
            ]
        )
        let resolver = AndroidBookmarkSwordBookNameResolver(gateway: gateway)

        XCTAssertEqual(
            resolver.displayBookName(v11nName: "KJVA", ordinal: 4, kjvOrdinal: 4),
            "Genesis",
            "KJVA Old Testament ordinals must resolve through KJV modules."
        )
        XCTAssertNil(
            resolver.displayBookName(v11nName: "KJVA", ordinal: 25000, kjvOrdinal: 25000),
            "KJVA apocrypha-range ordinals must not accept New Testament KJV resolutions."
        )
    }

    /**
     Verifies the apocrypha-offset New Testament fallback for KJVA ordinals.

     KJVA inserts 14 apocrypha books (5,913 intro-inclusive ordinals per SWORD's canon tables)
     before the New Testament, so a KJVA New Testament ordinal equals the KJV ordinal plus that
     span. The expected result shifts a KJVA Matthew 1:1 ordinal (30,031) to the KJV ordinal
     (24,118) and accepts only a New Testament resolution. A failure means the dominant Android
     bookmark shape — New Testament rows in KJVA — stays `Unknown` on stock KJV-only installs.
     */
    func testResolverShiftsKJVANewTestamentOrdinalsOntoKJVModules() {
        let gateway = FakeResolverGateway(
            modules: [(name: "KJV", versification: "KJV")],
            resolutions: [
                FakeResolverGateway.Key(module: "KJV", ordinal: 24118):
                    AndroidBookmarkResolvedBook(name: "Matthew", testament: 2)
            ]
        )
        let resolver = AndroidBookmarkSwordBookNameResolver(gateway: gateway)

        XCTAssertEqual(
            resolver.displayBookName(v11nName: "KJVA", ordinal: 30031, kjvOrdinal: 30031),
            "Matthew",
            "KJVA New Testament ordinals must shift by the apocrypha span onto KJV modules."
        )
        XCTAssertEqual(
            gateway.resolveCalls.last,
            FakeResolverGateway.Key(module: "KJV", ordinal: 24118),
            "The shifted ordinal must equal the KJVA ordinal minus the apocrypha span."
        )
    }

    /**
     Verifies ordinals below the KJVA New Testament section never enter the shifted fallback.

     The shifted stage is only versification-sound for ordinals at or beyond the KJVA New
     Testament start (30,028). The expected result is `nil` for an apocrypha-range ordinal when
     no direct or Old-Testament-gated resolution exists. A failure means apocrypha bookmarks
     would map onto arbitrary early-Bible books.
     */
    func testResolverNeverShiftsOrdinalsBelowNewTestamentStart() {
        let gateway = FakeResolverGateway(
            modules: [(name: "KJV", versification: "KJV")],
            resolutions: [:]
        )
        let resolver = AndroidBookmarkSwordBookNameResolver(gateway: gateway)

        XCTAssertNil(
            resolver.displayBookName(v11nName: "Luther", ordinal: 100, kjvOrdinal: 27000),
            "Apocrypha-range KJVA ordinals must not be shifted into KJV space."
        )
        XCTAssertFalse(
            gateway.resolveCalls.contains(FakeResolverGateway.Key(module: "KJV", ordinal: 27000 - 5913)),
            "No shifted resolution may be attempted below the KJVA New Testament start."
        )
    }

    /**
     Verifies initials classification covers Bibles and commentaries.

     Android's `book` column holds any `AbstractPassageBook`, including commentaries, so both
     categories must classify as installed initials. A failure leaves commentary-bound bookmark
     rows permanently un-normalized despite the module being installed.
     */
    func testResolverClassifiesBibleAndCommentaryInitials() {
        let gateway = FakeResolverGateway(
            modules: [(name: "KJV", versification: "KJV")],
            resolutions: [:],
            passageInitials: ["KJV", "TSK"]
        )
        let resolver = AndroidBookmarkSwordBookNameResolver(gateway: gateway)

        XCTAssertTrue(resolver.isInstalledBibleInitials("KJV"))
        XCTAssertTrue(resolver.isInstalledBibleInitials("TSK"))
        XCTAssertFalse(resolver.isInstalledBibleInitials("ESV2011"))
    }
}

/**
 Deterministic gateway double recording resolution attempts for selection-core tests.

 Side effects:
 - records every `resolve` call key in `resolveCalls`

 Failure modes:
 - returns `nil` for resolution keys missing from the fixture map, matching real gateway misses
 */
private final class FakeResolverGateway: AndroidBookmarkResolverGateway {
    /// One recorded module/ordinal resolution attempt.
    struct Key: Hashable {
        /// Module initials the resolver attempted.
        let module: String

        /// Ordinal the resolver attempted.
        let ordinal: Int
    }

    private let modules: [(name: String, versification: String)]
    private let resolutions: [Key: AndroidBookmarkResolvedBook]
    private let fixedPassageInitials: Set<String>

    /// Every resolution attempt in call order.
    private(set) var resolveCalls: [Key] = []

    /**
     Creates the fake gateway.

     - Parameters:
       - modules: Installed Bible descriptors returned by `bibleModules()`.
       - resolutions: Successful resolutions keyed by module and ordinal.
       - passageInitials: Initials set returned by `passageInitials()`; defaults to module names.
     - Side effects: none.
     - Failure modes: none.
     */
    init(
        modules: [(name: String, versification: String)],
        resolutions: [Key: AndroidBookmarkResolvedBook],
        passageInitials: Set<String>? = nil
    ) {
        self.modules = modules
        self.resolutions = resolutions
        self.fixedPassageInitials = passageInitials ?? Set(modules.map(\.name))
    }

    /**
     Lists the fixture's installed Bible descriptors.

     - Returns: The configured module list.
     - Side effects: none.
     - Failure modes: none.
     */
    func bibleModules() -> [(name: String, versification: String)] {
        modules
    }

    /**
     Lists the fixture's passage-module initials.

     - Returns: The configured initials set.
     - Side effects: none.
     - Failure modes: none.
     */
    func passageInitials() -> Set<String> {
        fixedPassageInitials
    }

    /**
     Resolves one ordinal from the fixture map, recording the attempt.

     - Parameters:
       - moduleName: Module initials the resolver attempted.
       - ordinal: Ordinal the resolver attempted.
     - Returns: The fixture resolution, or `nil` when unmapped.
     - Side effects: appends the attempt to `resolveCalls`.
     - Failure modes: none.
     */
    func resolve(moduleName: String, ordinal: Int) -> AndroidBookmarkResolvedBook? {
        let key = Key(module: moduleName, ordinal: ordinal)
        resolveCalls.append(key)
        return resolutions[key]
    }
}
