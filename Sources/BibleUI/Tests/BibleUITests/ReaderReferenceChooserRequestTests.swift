import XCTest
@testable import BibleUI

/**
 Verifies one-shot lifecycle behavior for bridge-driven reader reference chooser requests.

 These tests use synchronous callbacks and no filesystem or network state. Failures mean a Vue
 deferred call can be completed twice or remain pending after cancellation or request replacement.
 */
final class ReaderReferenceChooserRequestTests: XCTestCase {
    /**
     Verifies a selected verse completes the request exactly once with JSword short-name text.

     The request receives two resolution attempts. The expected result is one callback containing
     Android's exact `Verse.name` for the first selection and no pending state afterward.
     */
    func testSelectedVerseCompletesPendingReferenceChooserExactlyOnce() {
        var results: [String?] = []
        var request = BibleReaderReferenceChooserRequest()
        let generation = request.replace { results.append($0) }

        request.resolve(for: generation, with: "Gen 1:1")
        request.resolve(for: generation, with: "Gen 1:2")

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0], "Gen 1:1")
        XCTAssertFalse(request.isPending)
    }

    /**
     Verifies replacing a chooser request cancels the superseded bridge call.

     The expected callbacks are `nil` for the first request and the selected exact verse for the
     replacement. Failure means a reentrant Vue request can orphan its predecessor.
     */
    func testReplacingReferenceChooserCancelsSupersededRequest() {
        var firstResults: [String?] = []
        var secondResults: [String?] = []
        var request = BibleReaderReferenceChooserRequest()
        _ = request.replace { firstResults.append($0) }

        let replacementGeneration = request.replace { secondResults.append($0) }
        request.resolve(for: replacementGeneration, with: "Joh 3:16")

        XCTAssertEqual(firstResults.count, 1)
        XCTAssertNil(firstResults[0])
        XCTAssertEqual(secondResults.count, 1)
        XCTAssertEqual(secondResults[0], "Joh 3:16")
        XCTAssertFalse(request.isPending)
    }

    /**
     Verifies cancellation terminates a pending chooser and is idempotent.

     The request is cancelled twice to model an explicit cancel followed by sheet `onDismiss`.
     Exactly one `nil` callback is expected.
     */
    func testReferenceChooserCancellationCompletesPendingRequestOnce() {
        var results: [String?] = []
        var request = BibleReaderReferenceChooserRequest()
        let generation = request.replace { results.append($0) }

        request.resolve(for: generation, with: nil)
        request.resolve(for: generation, with: nil)

        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results[0])
        XCTAssertFalse(request.isPending)
    }

    /**
     Verifies a disappearing superseded sheet cannot cancel its replacement request.

     The first generation is replaced, then models a delayed SwiftUI `onDisappear`. The stale
     resolution must report `false`, leave the second generation pending, and invoke no replacement
     callback until that generation resolves itself.
     */
    func testStaleDismissalDoesNotCancelReplacementReferenceChooser() {
        var firstResults: [String?] = []
        var secondResults: [String?] = []
        var request = BibleReaderReferenceChooserRequest()
        let staleGeneration = request.replace { firstResults.append($0) }
        let replacementGeneration = request.replace { secondResults.append($0) }

        XCTAssertFalse(request.resolve(for: staleGeneration, with: nil))
        XCTAssertEqual(request.generation, replacementGeneration)
        XCTAssertTrue(request.isPending)
        XCTAssertTrue(secondResults.isEmpty)

        XCTAssertTrue(request.resolve(for: replacementGeneration, with: "Joh 3:16"))
        XCTAssertEqual(firstResults.count, 1)
        XCTAssertNil(firstResults[0])
        XCTAssertEqual(secondResults, ["Joh 3:16"])
        XCTAssertFalse(request.isPending)
    }

    /**
     Verifies chooser output uses Android's exact JSword KJVA short `Verse.name` contract.

     JSword's `BibleNames.properties` defines `Gen.Short=Gen` and `John.Short=Joh`; Android toggles
     short book names before reading `Verse.name`. Invalid KJVA coordinates must fail closed.
     */
    func testResultFormatterReturnsExactJSwordShortVerseName() {
        XCTAssertEqual(
            BibleReaderReferenceChooserResultFormatter.verseName(
                osisBookId: "Gen",
                chapter: 1,
                verse: 1
            ),
            "Gen 1:1"
        )
        XCTAssertEqual(
            BibleReaderReferenceChooserResultFormatter.verseName(
                osisBookId: "John",
                chapter: 3,
                verse: 16
            ),
            "Joh 3:16"
        )
        XCTAssertNil(
            BibleReaderReferenceChooserResultFormatter.verseName(
                osisBookId: "John",
                chapter: 3,
                verse: 99
            )
        )
    }
}
