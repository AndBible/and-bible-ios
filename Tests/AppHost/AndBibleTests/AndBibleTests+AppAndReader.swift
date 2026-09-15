import XCTest
#if os(iOS)
import UIKit
#endif

extension AndBibleTests {
    #if os(iOS)
    /**
     Keeps app-host coverage for the live scene delegate bootstrap that package tests cannot exercise.

     The hosted application has already connected its UIWindowScene when this test executes. The
     test compares the connected session's retained configuration with the object UIKit actually
     installed and verifies that the SwiftUI delegate adaptor owns scene configuration. It avoids
     importing a second copy of the BibleUI package into the test bundle.
     */
    func testApplicationDelegateSceneConfigurationUsesWindowSceneDelegate() {
        guard let windowScene = UIApplication.shared.connectedScenes.compactMap({
            $0 as? UIWindowScene
        }).first else {
            return XCTFail("The hosted app must connect a UIWindowScene before app-host tests run.")
        }
        guard let liveSceneDelegate = windowScene.delegate else {
            return XCTFail("The connected UIWindowScene must have a live delegate.")
        }
        guard let applicationDelegate = UIApplication.shared.delegate else {
            return XCTFail("The SwiftUI app must install its UIApplicationDelegate adaptor.")
        }
        guard let expectedDelegateClass = windowScene.session.configuration.delegateClass else {
            return XCTFail("The connected session must retain its configured scene-delegate class.")
        }

        XCTAssertTrue(
            applicationDelegate.responds(
                to: NSSelectorFromString(
                    "application:configurationForConnectingSceneSession:options:"
                )
            ),
            "The SwiftUI application delegate adaptor must own scene configuration."
        )
        XCTAssertEqual(
            ObjectIdentifier(type(of: liveSceneDelegate)),
            ObjectIdentifier(expectedDelegateClass),
            "UIKit must install the exact scene-delegate class supplied by the app delegate."
        )
        XCTAssertTrue(
            liveSceneDelegate.responds(to: NSSelectorFromString("preferredWindowingControlStyleForScene:")),
            "The live scene delegate must expose the app's window-control customization hook."
        )
    }
    #endif
}
