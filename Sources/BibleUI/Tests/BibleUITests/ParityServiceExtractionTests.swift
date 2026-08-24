// ParityServiceExtractionTests.swift — characterization of extracted Android parity boundaries

import XCTest
@testable import BibleUI
@testable import BibleCore

/**
 Characterizes the pure dispatch/key contracts extracted from the large reader orchestrators.

 Tests use empty installed registries and literal Android synthetic identities, perform no disk or
 network access, and mutate no production state. Failures mean extraction changed an existing
 Android route/fallback decision or allowed wrapper and service behavior to diverge.
 */
final class ParityServiceExtractionTests: XCTestCase {
    /**
     Verifies saved auxiliary tokens retain Android's synthetic and fail-closed dispatch outcomes.

     - Setup: Creates an empty installed registry with deterministic unresolved-name canonicalization.
     - Expected result: Memorize/Multi remain synthetic, while missing dictionary/map tokens remain
       unresolved and never receive another category's fallback.
     - Failure meaning: Restore extraction changed category ownership or invented a readable owner.
     - Side effects: None.
     */
    func testRestoreDispatchPreservesSyntheticAndUnresolvedDecisions() {
        let resolver = BibleReaderInstalledModuleResolver(
            swordManager: nil,
            sqliteModules: []
        )
        let service = BibleReaderRestoreDispatchService(
            resolver: resolver,
            orderedCommentaryModules: [],
            canonicalSwordModuleName: { "canonical:\($0)" },
            localGeneralBookDocument: { _ in nil }
        )

        guard case .memorize = service.commentary(
            savedName: AndroidSpecialDocumentIdentity.memorizeDocumentInitials
        ) else {
            return XCTFail("Memorize must remain Android's synthetic commentary document")
        }
        guard case .multi = service.generalBook(
            savedName: AndroidSpecialDocumentIdentity.multiDocumentInitials
        ) else {
            return XCTFail("Multi must remain Android's synthetic general-book document")
        }
        guard case .unresolved(let dictionaryName) = service.dictionary(savedName: "MissingDict")
        else {
            return XCTFail("A missing dictionary must remain unresolved without fallback")
        }
        XCTAssertEqual(dictionaryName, "canonical:MissingDict")
        guard case .unresolved(let mapName) = service.map(savedName: "MissingMap") else {
            return XCTFail("A missing map must remain unresolved without fallback")
        }
        XCTAssertEqual(mapName, "canonical:MissingMap")
    }

    /**
     Verifies the retained builder API is a lossless facade over the extracted Android key service.

     - Setup: Exercises Greek, Hebrew, lowercase, numeric-only, and empty external values.
     - Expected result: Typed candidates, duplicate positions, and raw first-UTF16 routing match.
     - Failure meaning: Builder and backend selection can disagree about the dictionary key family.
     - Side effects: None.
     */
    func testStrongsBuilderFacadeMatchesExtractedKeyFamilyResolver() {
        for value in ["G123", "H7", "g42", "123", ""] {
            XCTAssertEqual(
                BibleReaderStrongsDocumentBuilder.strongsLookupKeyCandidates(for: value),
                BibleReaderStrongsKeyFamilyResolver.candidates(for: value)
            )
            XCTAssertEqual(
                BibleReaderStrongsDocumentBuilder.strongsLookupKeyOptions(for: value),
                BibleReaderStrongsKeyFamilyResolver.values(for: value)
            )
            XCTAssertEqual(
                BibleReaderStrongsDocumentBuilder.isHebrewStrongsNumber(value),
                BibleReaderStrongsKeyFamilyResolver.isHebrew(value)
            )
        }
    }
}
