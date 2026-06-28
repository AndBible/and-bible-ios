import XCTest
@testable import BibleView

#if os(iOS)
import UIKit

/**
 Package-lane coverage for iOS platform bootstrap values owned by `BibleWebView`.

 These tests validate the native wrapper's static platform contract without starting the app host or
 constructing a `WKWebView`, keeping renderer bootstrap behavior in the BibleView test target.
 */
final class BibleWebViewPlatformTests: XCTestCase {
    /**
     Verifies that UIKit idioms map to the CSS/JavaScript device classes consumed by the Vue reader.

     A failure means the shared web client may receive the wrong platform class and apply phone/iPad
     behavior inconsistently before the bridge sends reader content.
     */
    func testBibleWebViewMapsDeviceClassFromInterfaceIdiom() {
        XCTAssertEqual(BibleWebView.iosDeviceClass(for: .phone), "ios-phone")
        XCTAssertEqual(BibleWebView.iosDeviceClass(for: .pad), "ios-pad")
    }

    /**
     Verifies that the injected platform script exposes iOS and device-class globals to Vue startup.

     Setup:
     - generates the script from a deterministic device class
     - checks the bootstrap globals and root CSS classes the web bundle consumes

     Failure meaning:
     - the renderer can boot without the native iOS platform identity expected by shared Vue code.
     */
    func testBibleWebViewInjectsPlatformDeviceClassIntoUserScript() {
        let expectedDeviceClass = "ios-phone"
        let platformScript = BibleWebView.platformBootstrapScriptSource(deviceClass: expectedDeviceClass)

        XCTAssertTrue(platformScript.contains("window.__PLATFORM__ = 'ios';"))
        XCTAssertTrue(platformScript.contains("window.__IOS_DEVICE_CLASS__ = '\(expectedDeviceClass)';"))
        XCTAssertTrue(platformScript.contains("document.documentElement.classList.add('platform-ios');"))
        XCTAssertTrue(platformScript.contains("document.documentElement.classList.add('\(expectedDeviceClass)');"))
    }
}
#endif
