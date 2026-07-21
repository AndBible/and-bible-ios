import Foundation
import XCTest
@testable import BibleCore
import SwordKit

/**
 Verifies generated Search readiness follows the installed source generation, not module initials.

 Each test uses production index creation and an isolated notification center/database. Temporary
 files are removed after the test, and no global module-store notification reaches other suites.
 */
final class SearchIndexReplacementTests: XCTestCase {
    /**
     Proves same-initials replacement invalidates both identity-aware and compatibility queries.

     Version two deliberately has different content and a different source fingerprint. Before the
     lifecycle signal it cannot claim version one's text or Strong's index through exact readiness.
     Posting the central module-store mutation invalidates even compatibility readiness across service
     reconstruction; rebuilding version two exposes only replacement text and lexical content.
     */
    func testSameInitialsReplacementRequiresExactGenerationBeforeServingResults() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-index-replacement-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let notificationCenter = NotificationCenter()
        let service = SearchIndexService(
            databasePath: databaseURL.path,
            notificationCenter: notificationCenter
        )
        let original = ReplacementSearchSource(
            moduleName: "KJV",
            version: "1.0",
            fingerprintDigit: "1",
            text: "legacyuniquetoken",
            strongToken: "H0430"
        )
        let replacement = ReplacementSearchSource(
            moduleName: "KJV",
            version: "2.0",
            fingerprintDigit: "2",
            text: "replacementuniquetoken",
            strongToken: "H0001"
        )

        try await service.createIndex(source: original)
        XCTAssertTrue(service.hasIndex(for: original.searchIndexSourceIdentity))
        XCTAssertTrue(service.hasStrongsIndex(for: original.searchIndexSourceIdentity))
        XCTAssertFalse(service.hasIndex(for: replacement.searchIndexSourceIdentity))
        XCTAssertFalse(service.hasStrongsIndex(for: replacement.searchIndexSourceIdentity))
        XCTAssertThrowsError(
            try service.search(
                query: "legacyuniquetoken",
                sourceIdentity: replacement.searchIndexSourceIdentity,
                wordMode: .allWords
            )
        )
        XCTAssertThrowsError(
            try service.searchStrongs(
                canonicalTokens: ["H0430"],
                sourceIdentity: replacement.searchIndexSourceIdentity
            )
        )

        SwordModuleStore.notifyModulesDidChange(center: notificationCenter)
        XCTAssertFalse(service.hasIndex(for: "KJV"))
        XCTAssertFalse(service.hasStrongsIndex(for: "KJV"))
        XCTAssertThrowsError(
            try service.search(query: "legacyuniquetoken", moduleName: "KJV", wordMode: .allWords)
        )
        XCTAssertThrowsError(
            try service.searchStrongs(canonicalTokens: ["H0430"], moduleName: "KJV")
        )
        let reopenedService = SearchIndexService(
            databasePath: databaseURL.path,
            notificationCenter: NotificationCenter()
        )
        XCTAssertFalse(
            reopenedService.hasIndex(for: "KJV"),
            "The invalidated store generation must survive service reconstruction."
        )

        try await service.createIndex(source: replacement)
        XCTAssertEqual(
            try service.search(
                query: "legacyuniquetoken",
                sourceIdentity: replacement.searchIndexSourceIdentity,
                wordMode: .allWords
            ).hits.count,
            0
        )
        XCTAssertEqual(
            try service.search(
                query: "replacementuniquetoken",
                sourceIdentity: replacement.searchIndexSourceIdentity,
                wordMode: .allWords
            ).hits.count,
            1
        )
        XCTAssertEqual(
            try service.searchStrongs(
                canonicalTokens: ["H0430"],
                sourceIdentity: replacement.searchIndexSourceIdentity
            ).hits.count,
            0
        )
        XCTAssertEqual(
            try service.searchStrongs(
                canonicalTokens: ["H0001"],
                sourceIdentity: replacement.searchIndexSourceIdentity
            ).hits.count,
            1
        )
    }
}

/**
 Deterministic one-verse source representing one installed module generation.

 The fixture supplies explicit version/fingerprint values plus generation-specific visible and lexical
 content. It intentionally omits filesystem discovery so the test can isolate service readiness and
 central lifecycle invalidation without weakening production indexing/query code.
 */
private final class ReplacementSearchSource: BibleSearchIndexSource {
    /// Exact module metadata, including the generation's declared version.
    let searchIndexModuleInfo: ModuleInfo

    /// Explicit content-generation identity independent of shared filesystem fixtures.
    let searchIndexSourceIdentity: SearchIndexSourceIdentity

    /// One emitted verse is the complete progress domain.
    let searchIndexProgressTotal = 1

    /// Generation-specific visible text used to detect stale rows.
    private let text: String

    /// Generation-specific Strong's token used to detect stale lexical rows.
    private let strongToken: String

    /**
     Creates one replacement generation with a deterministic valid SHA-256-shaped fingerprint.

     - Parameters:
       - moduleName: Shared initials used by both replacement generations.
       - version: Declared source version persisted with completion metadata.
       - fingerprintDigit: Hex-shaped digit repeated into the explicit 64-character fingerprint.
       - text: Generation-specific searchable text.
       - strongToken: Generation-specific canonical Strong's token.
     - Side effects: None.
     - Failure modes: Invalid non-hex digits are retained deliberately; test callers provide valid digits.
     */
    init(
        moduleName: String,
        version: String,
        fingerprintDigit: Character,
        text: String,
        strongToken: String
    ) {
        searchIndexModuleInfo = ModuleInfo(
            name: moduleName,
            description: moduleName,
            category: .bible,
            language: "en",
            moduleDriver: "RawText",
            version: version
        )
        searchIndexSourceIdentity = SearchIndexSourceIdentity(
            moduleName: moduleName,
            version: version,
            fingerprint: String(repeating: String(fingerprintDigit), count: 64)
        )
        self.text = text
        self.strongToken = strongToken
    }

    /**
     Emits the generation's one canonical verse without materializing additional state.

     - Parameter consume: Production index consumer invoked exactly once.
     - Side effects: Invokes the consumer with generation-specific visible and lexical content.
     - Throws: Propagates cancellation, analyzer, or SQLite errors from the consumer.
     */
    func forEachSearchIndexEntry(
        _ consume: (BibleSearchIndexEntry) throws -> Bool
    ) throws {
        _ = try consume(BibleSearchIndexEntry(
            displayKey: "Genesis 1:1",
            visibleText: text,
            sourceMarkup: "<w lemma=\"strong:\(strongToken)\">\(text)</w>",
            taggedText: "<w lemma=\"strong:\(strongToken)\">\(text)</w>",
            entryOrder: 0,
            sourcePosition: 1,
            osisBookId: "Gen",
            displayBook: "Genesis",
            chapter: 1,
            verse: 1
        ))
    }
}
