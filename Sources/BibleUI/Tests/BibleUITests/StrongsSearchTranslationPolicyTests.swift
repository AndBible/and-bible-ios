import XCTest
@testable import BibleUI
@testable import SwordKit

/**
 Tests Android's Strong's Find All translation eligibility, fallback, and execution ordering.

 Fixtures are metadata-only `ModuleInfo` values, so the suite performs no SWORD or filesystem I/O.
 Failures indicate Find All can search a non-Strong's Bible, choose the wrong fallback document, or
 reorder a remembered Strong's selection.
 */
final class StrongsSearchTranslationPolicyTests: XCTestCase {
    /**
     Verifies Find All removes plain Bibles and prefers an indexed Strong's fallback when the active
     Bible cannot provide Strong's numbers.

     The installed order intentionally places an unindexed Strong's Bible before an indexed one.
     Android's `defaultBibleWithStrongs` must select the indexed candidate without admitting the
     active plain Bible.
     */
    func testFindAllFiltersPlainBiblesAndPrefersIndexedStrongsFallback() {
        let plain = module(named: "PLAIN")
        let unindexed = module(named: "FIRST", hasStrongs: true)
        let indexed = module(named: "INDEXED", hasStrongs: true)
        let candidates = SearchTranslationSelectionPolicy.candidateModules(
            from: [plain, unindexed, indexed],
            isStrongsFindAll: true
        )

        XCTAssertEqual(candidates.map(\.name), ["FIRST", "INDEXED"])
        XCTAssertEqual(
            SearchTranslationSelectionPolicy.fallbackModuleName(
                currentModuleName: "PLAIN",
                candidateModules: candidates,
                isStrongsFindAll: true,
                isIndexed: { $0 == "INDEXED" }
            ),
            "INDEXED"
        )
    }

    /**
     Verifies Android keeps the active Bible when it is Strong's-capable, even if another eligible
     module already has an index.

     A failure would make Find All switch translations unexpectedly instead of following
     `LinkControl.showAllOccurrences`.
     */
    func testFindAllKeepsCurrentStrongsBibleBeforeIndexedFallback() {
        let current = module(named: "CURRENT", hasStrongs: true)
        let indexed = module(named: "INDEXED", hasStrongs: true)

        XCTAssertEqual(
            SearchTranslationSelectionPolicy.fallbackModuleName(
                currentModuleName: "CURRENT",
                candidateModules: [current, indexed],
                isStrongsFindAll: true,
                isIndexed: { $0 == "INDEXED" }
            ),
            "CURRENT"
        )
    }

    /**
     Verifies remembered Strong's module order remains authoritative and ineligible names cannot be
     reintroduced from either persistence or picker membership.

     The selected module missing from remembered order is appended by Android abbreviation order.
     A failure means relaunch can change the primary Find All result document or query a plain Bible.
     */
    func testFindAllExecutionOrderPreservesRememberedEligibleSelection() {
        let candidates = [
            module(named: "KJV", hasStrongs: true),
            module(named: "ASV", hasStrongs: true),
            module(named: "WEB", hasStrongs: true),
        ]

        XCTAssertEqual(
            SearchTranslationSelectionPolicy.strongsOrderedSelection(
                selectedModuleNames: ["KJV", "ASV", "WEB", "PLAIN"],
                rememberedOrder: ["WEB", "KJV", "PLAIN", "WEB"],
                candidateModules: candidates
            ),
            ["WEB", "KJV", "ASV"]
        )
    }

    /**
     Creates metadata for one deterministic Bible candidate.

     - Parameters:
       - name: SWORD initials used by selection contracts.
       - hasStrongs: Whether the module advertises Android's `STRONGS_NUMBERS` feature.
     - Returns: Bible metadata with no persistence or module-loading side effects.
     - Failure modes: None; support-driver validation is outside this pure selection policy.
     */
    private func module(named name: String, hasStrongs: Bool = false) -> ModuleInfo {
        ModuleInfo(
            name: name,
            description: name,
            category: .bible,
            language: "en",
            features: hasStrongs ? [.strongsNumbers] : []
        )
    }
}
