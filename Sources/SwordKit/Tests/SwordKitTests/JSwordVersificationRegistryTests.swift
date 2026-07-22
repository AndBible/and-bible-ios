import XCTest
@testable import SwordKit

/**
 Contract tests for the single pinned JSword registry shared by module admission and BibleCore.

 These tests pin the Android dependency revision, exact system inventory, default behavior, and
 mapping-resource availability. They perform deterministic bundle reads and mutate no state.
 */
final class JSwordVersificationRegistryTests: XCTestCase {
    /**
     Verifies the bundled system inventory remains tied to the Android JSword revision.

     A failure means module admission and the higher-level mapper could disagree with the Android
     dependency or silently accept a malformed fixture.
     */
    func testRegistryExposesPinnedAndroidVersificationInventory() {
        XCTAssertEqual(
            JSwordVersificationRegistry.pinnedRevision,
            "0da7412d7716731f402c9002a0b92e4c00ef30eb"
        )
        XCTAssertEqual(
            JSwordVersificationRegistry.supportedNames,
            [
                "Calvin", "Catholic", "Catholic2", "DarbyFr", "German", "KJV", "KJVA", "LXX",
                "Leningrad", "Luther", "MT", "NRSV", "NRSVA", "Orthodox", "Segond", "Synodal",
                "SynodalProt", "Vulg",
            ]
        )
        XCTAssertEqual(JSwordVersificationRegistry.normalizedName(""), "KJV")
        XCTAssertEqual(JSwordVersificationRegistry.normalizedName("  KJVA  "), "KJVA")
        XCTAssertNil(JSwordVersificationRegistry.normalizedName("kjva"))
        XCTAssertFalse(JSwordVersificationRegistry.supports("NotAVersification"))
    }

    /**
     Verifies explicit Android mapping resources are available through the shared owner.

     Synodal has a checked-in mapping while KJV is identity-only. A failure means BibleCore cannot
     distinguish a valid identity system from a missing Android resource bundle.
     */
    func testRegistryLoadsExplicitMappingAndLeavesIdentitySystemsResourceFree() throws {
        let data = try XCTUnwrap(JSwordVersificationRegistry.mappingResourceData(for: "Synodal"))
        let contents = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(contents.contains("Ps.50.1=Ps.51.0"))
        XCTAssertNil(JSwordVersificationRegistry.mappingResourceData(for: "KJV"))
        XCTAssertNil(JSwordVersificationRegistry.mappingResourceData(for: "NotAVersification"))
        XCTAssertNotNil(JSwordVersificationRegistry.canonFixtureData())
    }

    /**
     Verifies module admission uses the shared Android registry and a renderable SWORD canon.

     The pinned registries are expected to stay aligned. Every category requires a registered Android
     driver and versification, while Bibles additionally require a libsword-renderable canon.
     */
    func testBibleAdmissionRequiresRegisteredRenderableVersification() {
        let swordSystems = Set(
            JSwordVersificationRegistry.supportedNames.filter(SwordVersification.supports)
        )
        XCTAssertEqual(swordSystems, JSwordVersificationRegistry.supportedNames)

        let supportedBible = ModuleInfo(
            name: "SUPPORTED",
            description: "Supported Bible",
            category: .bible,
            language: "en",
            moduleDriver: "RawText",
            aboutMetadata: ModuleAboutMetadata(versification: "KJVA")
        )
        let unsupportedBible = ModuleInfo(
            name: "UNSUPPORTED",
            description: "Unsupported Bible",
            category: .bible,
            language: "en",
            moduleDriver: "zText",
            aboutMetadata: ModuleAboutMetadata(versification: "NotAVersification")
        )
        let supportedDictionary = ModuleInfo(
            name: "SUPPORTED_DICTIONARY",
            description: "Supported Dictionary",
            category: .dictionary,
            language: "en",
            moduleDriver: "RawLD"
        )
        let unsupportedDictionary = ModuleInfo(
            name: "DICTIONARY",
            description: "Dictionary",
            category: .dictionary,
            language: "en",
            moduleDriver: "RawLD",
            aboutMetadata: ModuleAboutMetadata(versification: "NotAVersification")
        )
        let unknownDriver = ModuleInfo(
            name: "UNKNOWN_DRIVER",
            description: "Unknown Driver",
            category: .dictionary,
            language: "en",
            moduleDriver: "MadeUpDictionary"
        )
        let missingDriver = ModuleInfo(
            name: "MISSING_DRIVER",
            description: "Missing Driver",
            category: .dictionary,
            language: "en"
        )

        XCTAssertTrue(supportedBible.isSupported)
        XCTAssertFalse(unsupportedBible.isSupported)
        XCTAssertTrue(supportedDictionary.isSupported)
        XCTAssertFalse(unsupportedDictionary.isSupported)
        XCTAssertFalse(unknownDriver.isSupported)
        XCTAssertFalse(missingDriver.isSupported)
    }

    /**
     Verifies module admission recognizes every book driver registered by Android.

     - Setup: Builds one supported metadata row for each base JSword driver and each custom driver
       And Bible registers during application startup.
     - Expected result: Every row passes the shared driver and default-KJV versification gates.
     - Failure meaning: Fail-closed admission has accidentally hidden a valid SWORD, MyBible,
       MySword, EPUB, or e-Sword module family.
     - Side effects: Reads the bundled JSword and libsword versification registries.
     */
    func testModuleAdmissionRecognizesEveryAndroidRegisteredDriver() {
        let drivers: [(name: String, category: ModuleCategory)] = [
            ("RawText", .bible), ("zText", .bible), ("zText4", .bible),
            ("RawCom", .commentary), ("RawCom4", .commentary),
            ("zCom", .commentary), ("zCom4", .commentary),
            ("HREFCom", .commentary), ("RawFiles", .commentary),
            ("RawLD", .dictionary), ("RawLD4", .dictionary), ("zLD", .dictionary),
            ("RawGenBook", .generalBook),
            ("MyBibleBible", .bible), ("MyBibleCommentary", .commentary),
            ("MyBibleDictionary", .dictionary), ("MySwordBible", .bible),
            ("MySwordCommentary", .commentary), ("MySwordDictionary", .dictionary),
            ("EpubBook", .generalBook), ("ESwordBible", .bible),
        ]

        for driver in drivers {
            let module = ModuleInfo(
                name: driver.name.uppercased(),
                description: driver.name,
                category: driver.category,
                language: "en",
                moduleDriver: driver.name
            )

            XCTAssertTrue(module.isSupported, "Expected Android driver \(driver.name) to be supported")
        }
    }
}
