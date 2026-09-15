import UIKit
import XCTest
@testable import BibleUI

@MainActor
final class AndroidDialogTextInputTests: XCTestCase {
    /** A window-attached unlock field focuses and selects its exact prefilled value once. */
    func testWindowAttachmentFocusesAndSelectsPrefilledUnlockKey() throws {
        let root = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.rootViewController = root
        window.makeKeyAndVisible()

        let field = AndroidDialogSelectAllTextField(frame: CGRect(x: 20, y: 20, width: 240, height: 44))
        field.text = "persisted-key"
        field.selectAllOnFirstWindowAttachment = true
        root.view.addSubview(field)

        XCTAssertTrue(field.isFirstResponder)
        let selection = try XCTUnwrap(field.selectedTextRange)
        XCTAssertEqual(field.offset(from: field.beginningOfDocument, to: selection.start), 0)
        XCTAssertEqual(
            field.offset(from: field.beginningOfDocument, to: selection.end),
            "persisted-key".utf16.count
        )

        field.selectedTextRange = field.textRange(from: field.endOfDocument, to: field.endOfDocument)
        field.removeFromSuperview()
        root.view.addSubview(field)
        let reattachedSelection = try XCTUnwrap(field.selectedTextRange)
        XCTAssertEqual(
            field.offset(from: field.beginningOfDocument, to: reattachedSelection.start),
            "persisted-key".utf16.count
        )
        window.isHidden = true
    }
}
