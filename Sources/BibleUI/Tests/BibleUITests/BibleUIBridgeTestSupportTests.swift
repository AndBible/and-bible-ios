import XCTest
@testable import BibleView

/**
 Verifies BibleUI's shared bridge payload decoder against every production emission wrapper.

 These tests use `BibleBridge` itself to generate atomic replacement and standalone scripts, then
 exercise the same shared helpers used throughout BibleUI package tests. They perform no WebKit,
 persistence, network, or asynchronous work; scripts are captured by the test-only observer.
 */
final class BibleUIBridgeTestSupportTests: XCTestCase {
    /**
     Verifies atomic replacement extraction stops at the matching event boundary.

     The payload deliberately contains text identical to its event marker. Successful dictionary
     decoding proves the backwards marker search selects the real transaction boundary instead of
     truncating user-controlled content. A failure means document replacement tests cannot inspect
     the Android-ordered transaction reliably.
     */
    func testAtomicReplacementPayloadExtractionUsesMatchingEventBoundary() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let markerLikeText =
            "before ); /* bible-bridge-event-end:add_documents */ after"

        XCTAssertTrue(
            bridge.replaceDocument(
                configData: #"{"initial":true}"#,
                document: ["message": markerLikeText],
                setup: ["jumpToOrdinal": 42]
            )
        )

        let payload = try XCTUnwrap(
            try bridgeEmissionPayload(
                from: recordedScripts(),
                event: "add_documents"
            ) as? [String: String]
        )
        XCTAssertEqual(payload, ["message": markerLikeText])
    }

    /**
     Verifies standalone configuration extraction retains the legacy outer-wrapper fallback.

     The payload contains wrapper-like text that must remain part of the JSON string. Successful
     decoding through `setConfigPayload` proves both direct shared-helper callers remain supported.
     A failure means ordinary non-replacement bridge tests could report corrupted payloads.
     */
    func testStandaloneSetConfigPayloadExtractionRetainsOuterWrapperFallback() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let wrapperLikeText = "before ); } catch after"

        bridge.emitEncoded(
            event: "set_config",
            data: ["message": wrapperLikeText]
        )

        let scripts = recordedScripts()
        XCTAssertEqual(scripts.count, 1)
        let payload = try setConfigPayload(from: scripts)
        XCTAssertEqual(payload["message"] as? String, wrapperLikeText)
    }
}
