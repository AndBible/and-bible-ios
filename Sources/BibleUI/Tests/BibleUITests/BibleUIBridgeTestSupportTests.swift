import XCTest
@testable import BibleUI
@testable import BibleView

/**
 Verifies BibleUI's shared bridge payload decoder against every production emission wrapper.

 These tests use `BibleBridge` itself to generate atomic replacement and standalone scripts, then
 exercise the same shared helpers used throughout BibleUI package tests. They perform no WebKit,
 persistence, network, or asynchronous work; scripts are captured by the test-only observer.
 */
final class BibleUIBridgeTestSupportTests: XCTestCase {
    /**
     Verifies the add-on reload event retains all Android consumer inventories and exact spellings.

     - Setup: Emits a typed payload containing NFC/NFD font owners plus feature/style owners.
     - Expected result: Vue receives all three arrays in supplied order without canonical folding.
     - Side effects: Records one in-memory bridge JavaScript evaluation.
     - Failure meaning: Font reload can erase sibling add-on inventories or collapse exact owners.
     */
    func testAddonReloadPayloadPreservesCompleteExactInventory() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let composed = "FÓNT"
        let decomposed = "FO\u{301}NT"
        bridge.emitEncoded(
            event: "reload_addons",
            data: BibleReaderAddonReloadPayload(
                fontModuleNames: [composed, decomposed],
                featureModuleNames: ["RefParser"],
                styleModuleNames: ["StylePack"]
            )
        )

        let payload = try XCTUnwrap(
            try bridgeEmissionPayload(
                from: recordedScripts(),
                event: "reload_addons"
            ) as? [String: Any]
        )
        XCTAssertEqual(payload["fontModuleNames"] as? [String], [composed, decomposed])
        XCTAssertEqual(payload["featureModuleNames"] as? [String], ["RefParser"])
        XCTAssertEqual(payload["styleModuleNames"] as? [String], ["StylePack"])
    }

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

    /**
     Verifies configuration assertions select the final emission inside one explicit action boundary.

     Setup records an earlier unrelated config, captures the action boundary, and then emits two
     causal configuration states. The shared config helper must return the final causal state while
     the general event helper retains its documented first-emission behavior. A failure means tests
     can either assert stale setup state or silently reinterpret every multi-emission event as latest.
     */
    func testSetConfigPayloadUsesLatestEmissionInsideCallerActionBoundary() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        bridge.emitEncoded(event: "set_config", data: ["phase": "setup"])
        let actionBoundary = recordedScripts().count

        bridge.emitEncoded(event: "set_config", data: ["phase": "intermediate"])
        bridge.emitEncoded(event: "set_config", data: ["phase": "committed"])

        let actionScripts = Array(recordedScripts().dropFirst(actionBoundary))
        let firstPayload = try XCTUnwrap(
            try bridgeEmissionPayload(from: actionScripts, event: "set_config") as? [String: String]
        )
        let finalPayload = try setConfigPayload(from: actionScripts)

        XCTAssertEqual(firstPayload, ["phase": "intermediate"])
        XCTAssertEqual(finalPayload["phase"] as? String, "committed")
        XCTAssertNotEqual(finalPayload["phase"] as? String, "setup")
    }
}
