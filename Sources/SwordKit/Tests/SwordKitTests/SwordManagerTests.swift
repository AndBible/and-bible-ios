// SwordManagerTests.swift — Tests for SwordKit

import XCTest
@testable import SwordKit

final class SwordManagerTests: XCTestCase {
    func testDefaultModulePath() {
        let path = SwordManager.defaultModulePath()
        XCTAssertTrue(path.contains("sword"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testModuleInfoCreation() {
        let info = ModuleInfo(
            name: "KJV",
            description: "King James Version",
            category: .bible,
            language: "en",
            version: "2.3",
            features: [.strongsNumbers, .redLetterWords]
        )
        XCTAssertEqual(info.name, "KJV")
        XCTAssertEqual(info.id, "KJV")
        XCTAssertEqual(info.category, .bible)
        XCTAssertTrue(info.features.contains(.strongsNumbers))
        XCTAssertFalse(info.features.contains(.morphology))
        XCTAssertFalse(info.isEncrypted)
        XCTAssertTrue(info.isUnlocked)
    }

    func testModuleCategoryInit() {
        XCTAssertEqual(ModuleCategory(typeString: "Biblical Texts"), .bible)
        XCTAssertEqual(ModuleCategory(typeString: "Commentaries"), .commentary)
        XCTAssertEqual(ModuleCategory(typeString: "Unknown Type"), .unknown)
    }

    func testSearchOptionsDefaults() {
        let opts = SearchOptions(query: "love")
        XCTAssertEqual(opts.searchType, .multiWord)
        XCTAssertTrue(opts.caseInsensitive)
        XCTAssertNil(opts.scope)
    }

    func testSearchResultIdentity() {
        let r = SearchResult(key: "Gen 1:1", moduleName: "KJV")
        XCTAssertEqual(r.id, "KJV:Gen 1:1")
    }
}
