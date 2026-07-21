import XCTest
@testable import BibleCore

/**
 Product metadata contract tests for the standard and Calculator CloudKit stores.

 These tests keep the two product identifiers explicit at the contract boundary while production
 code consumes only the validated, build-owned Info.plist value.
 */
final class ProductCloudKitContainerIdentifierTests: XCTestCase {
    /**
     Verifies the standard product's processed metadata value resolves to its dedicated container.

     - Side effects: none.
     - Failure modes: Fails when the standard product contract changes or becomes malformed.
     */
    func testStandardProductMetadataResolvesDedicatedContainer() throws {
        let identifier = try ProductCloudKitContainerIdentifier(
            infoDictionary: [
                ProductCloudKitContainerIdentifier.infoPlistKey: "iCloud.org.andbible.ios",
            ]
        )

        XCTAssertEqual(identifier.value, "iCloud.org.andbible.ios")
    }

    /**
     Verifies the Calculator product's processed metadata value resolves to a separate container.

     - Side effects: none.
     - Failure modes: Fails when Calculator aliases the standard product's CloudKit store.
     */
    func testCalculatorProductMetadataResolvesDedicatedContainer() throws {
        let standard = try ProductCloudKitContainerIdentifier(
            infoDictionary: [
                ProductCloudKitContainerIdentifier.infoPlistKey: "iCloud.org.andbible.ios",
            ]
        )
        let calculator = try ProductCloudKitContainerIdentifier(
            infoDictionary: [
                ProductCloudKitContainerIdentifier.infoPlistKey: "iCloud.com.app.calculator.ios",
            ]
        )

        XCTAssertEqual(calculator.value, "iCloud.com.app.calculator.ios")
        XCTAssertNotEqual(calculator, standard)
    }

    /**
     Rejects missing, unresolved, and syntactically invalid product metadata.

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
