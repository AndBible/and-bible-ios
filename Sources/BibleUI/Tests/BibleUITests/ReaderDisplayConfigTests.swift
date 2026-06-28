// ReaderDisplayConfigTests.swift -- Reader bridge display-config coverage

import XCTest
import BibleCore
@testable import BibleUI

/**
 Package-level tests for `BibleReaderDisplayConfig` bridge normalization.

 The suite exercises pure BibleUI payload construction with no app host, WebView, filesystem, or
 persistence side effects. Failures mean the Vue reader can receive values outside Android's
 supported text-display contract.
 */
final class ReaderDisplayConfigTests: XCTestCase {
    /**
     Protects Android Strong's-mode normalization for legacy stored values.

     Setup uses a stale raw mode outside Android's supported `0...2` range. The bridge payload must
     coerce that value to hidden links (`0`) because Android treats hidden links as the default, not
     as disabled Strong's data. A failure means old iOS settings can produce an unsupported Vue
     config and diverge from Android reader behavior.
     */
    func testNormalizesLegacyStrongsModeToAndroidHiddenLinks() {
        var settings = TextDisplaySettings()
        settings.strongsMode = 3

        let config = BibleReaderDisplayConfig(settings: settings, defaults: .appDefaults)

        XCTAssertEqual(config.strongsMode, StrongsMode.hiddenLinks.rawValue)
    }
}
