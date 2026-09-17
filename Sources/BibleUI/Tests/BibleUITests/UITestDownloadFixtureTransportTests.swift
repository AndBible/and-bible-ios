import Foundation
import XCTest
@testable import BibleUI

final class UITestDownloadFixtureTransportTests: XCTestCase {
    /** The production binary accepts only an uncredentialed loopback endpoint with a run token. */
    func testDownloadFixtureEndpointRejectsExternalOrOpenLoopbackRoots() {
        XCTAssertEqual(
            UITestDownloadFixtureURLProtocol.validatedEndpoint(
                "http://127.0.0.1:48123/private-token"
            )?.absoluteString,
            "http://127.0.0.1:48123/private-token"
        )
        XCTAssertNil(UITestDownloadFixtureURLProtocol.validatedEndpoint("https://127.0.0.1:48123/token"))
        XCTAssertNil(UITestDownloadFixtureURLProtocol.validatedEndpoint("http://localhost:48123/token"))
        XCTAssertNil(UITestDownloadFixtureURLProtocol.validatedEndpoint("http://127.0.0.1:48123/"))
        XCTAssertNil(UITestDownloadFixtureURLProtocol.validatedEndpoint("http://127.0.0.1:48123"))
        XCTAssertNil(UITestDownloadFixtureURLProtocol.validatedEndpoint("http://user@127.0.0.1:48123/token"))
        XCTAssertNil(UITestDownloadFixtureURLProtocol.validatedEndpoint("http://127.0.0.1:48123/token?q=1"))
    }

    /** Only the synthetic repository host can be mapped under the host service's private token. */
    func testDownloadFixtureRelayPreservesPackagePathUnderPrivateEndpoint() throws {
        let endpoint = try XCTUnwrap(
            UITestDownloadFixtureURLProtocol.validatedEndpoint(
                "http://127.0.0.1:48123/private-token"
            )
        )
        XCTAssertEqual(
            UITestDownloadFixtureURLProtocol.relayURL(
                sourceURL: try XCTUnwrap(
                    URL(string: "https://uitest-download.invalid/catalog/packages/UITESTDLWARN.zip")
                ),
                endpoint: endpoint
            )?.absoluteString,
            "http://127.0.0.1:48123/private-token/catalog/packages/UITESTDLWARN.zip"
        )
        XCTAssertNil(
            UITestDownloadFixtureURLProtocol.relayURL(
                sourceURL: try XCTUnwrap(
                    URL(string: "https://crosswire.org/catalog/packages/KJV.zip")
                ),
                endpoint: endpoint
            )
        )
    }
}
