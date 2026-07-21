import XCTest
@testable import BibleCore

/**
 App metadata contract tests for AndBible's CloudKit store.

 Production code consumes one validated Info.plist value for SwiftData and account-status checks.
 */
final class ProductCloudKitContainerIdentifierTests: XCTestCase {
    /**
     Verifies the processed app metadata resolves to AndBible's CloudKit container.

     - Side effects: none.
     - Failure modes: Fails when the app contract changes or becomes malformed.
     */
    func testAppMetadataResolvesCloudKitContainer() throws {
        let identifier = try ProductCloudKitContainerIdentifier(
            infoDictionary: [
                ProductCloudKitContainerIdentifier.infoPlistKey: "iCloud.org.andbible.ios",
            ]
        )

        XCTAssertEqual(identifier.value, "iCloud.org.andbible.ios")
    }

    /**
     Rejects missing, unresolved, and syntactically invalid app metadata.

     - Side effects: none.
     - Failure modes: Fails if an invalid build substitution can reach CloudKit at runtime.
     */
    func testRejectsMissingOrUnresolvedMetadata() {
        XCTAssertThrowsError(try ProductCloudKitContainerIdentifier(infoDictionary: nil))
        XCTAssertThrowsError(try ProductCloudKitContainerIdentifier("$(CLOUDKIT_CONTAINER)"))
        XCTAssertThrowsError(try ProductCloudKitContainerIdentifier("org.andbible.ios"))
        XCTAssertThrowsError(try ProductCloudKitContainerIdentifier("iCloud.org.and bible"))
    }
}
