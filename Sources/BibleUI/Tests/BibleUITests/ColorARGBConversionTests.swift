import XCTest
@testable import BibleUI
import struct SwiftUI.Color

/**
 Package-level coverage for BibleUI signed ARGB color conversion helpers.

 These tests protect the color-settings bridge between SwiftUI `Color` values and the Android/Vue
 signed ARGB integers stored by text-display and workspace color settings. They belong to BibleUI
 because the helpers live with `ColorSettingsView` and do not require app delegate or simulator app
 bootstrap behavior.
 */
final class ColorARGBConversionTests: XCTestCase {
    /**
     Verifies transient picker component values are sanitized before byte conversion.

     UIKit color editing can briefly produce out-of-range, NaN, or infinite component values while a
     user edits a hex field. A failure means color settings can trap or serialize invalid bytes
     during intermediate picker states instead of clamping to Android-compatible ARGB bytes.
     */
    func testColorARGBByteClampsIntermediatePickerComponents() {
        XCTAssertEqual(Color.clampedARGBByte(-0.25), 0)
        XCTAssertEqual(Color.clampedARGBByte(0.5), 128)
        XCTAssertEqual(Color.clampedARGBByte(1.2), 255)
        XCTAssertEqual(Color.clampedARGBByte(.nan), 0)
        XCTAssertEqual(Color.clampedARGBByte(.infinity), 0)
    }

    /**
     Verifies signed ARGB serialization clamps out-of-range SwiftUI color components.

     Android and the Vue reader use signed ARGB integers for persisted colors. A failure means
     `Color.argbInt` can drift from that shared format when SwiftUI/UIColor reports non-normalized
     components, breaking persisted color parity.
     */
    func testColorARGBIntClampsOutOfRangeComponents() {
        let color = Color(.sRGB, red: -0.25, green: 0.5, blue: 1.2, opacity: 1.0)

        XCTAssertEqual(color.argbInt, Int(Int32(bitPattern: 0xFF0080FF)))
    }
}
