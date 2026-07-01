import SwiftData
import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import BibleView
#if os(iOS)
import UIKit
#endif

extension AndBibleTests {
    #if os(iOS)
    /**
     Keeps app-host coverage for the scene delegate bootstrap that package tests cannot exercise.

     `AndBibleApplicationDelegate.sceneConfiguration` is the remaining `+AppAndReader` test that
     depends on the app target rather than BibleUI package logic. A failure here means app launch
     would stop installing `AndBibleWindowSceneDelegate`, breaking the iPadOS windowing-control
     policy wiring even though the package-level policy tests still pass.
     */
    func testApplicationDelegateSceneConfigurationUsesWindowSceneDelegate() {
        let configuration = AndBibleApplicationDelegate.sceneConfiguration(
            sessionRole: UISceneSession.Role.windowApplication
        )

        XCTAssertEqual(
            ObjectIdentifier(configuration.delegateClass!),
            ObjectIdentifier(AndBibleWindowSceneDelegate.self)
        )
        XCTAssertNil(configuration.name)
    }
    #endif

    /**
     Verifies local memorization progress can write Android's KJVA-global rows directly.

     Android stores memorized verses and memorization targets as KJV-normalized ordinals without a
     module identity. This app-host regression test keeps that storage contract visible to the
     locally runnable unit-test scheme: inserts must accept an empty `bookInitials` global range,
     return Android-style delta arrays, and remain readable from any module initials.

     Failure means new iOS memorization writes still depend on an iOS-only module-specific storage
     key instead of the Android progress domain used by backup/restore and the shared Vue client.
     */
    func testMemorizationProgressStoreWritesKJVGlobalRangesAndDeltas() throws {
        let settingsStore = try makeMemorizeParitySettingsStore()
        let store = MemorizationProgressStore(settingsStore: settingsStore)

        let addDelta = store.addMemorizationTarget(bookInitials: "", startOrdinal: 4, endOrdinal: 5)
        XCTAssertEqual(addDelta.addedTargets, [4, 5])
        XCTAssertEqual(addDelta.removedTargets, [])
        XCTAssertEqual(store.targetOrdinals(bookInitials: "KJV", startOrdinal: 4, endOrdinal: 5), [4, 5])
        XCTAssertEqual(store.targetOrdinals(bookInitials: "FinRK", startOrdinal: 4, endOrdinal: 5), [4, 5])

        let noOpDelta = store.addMemorizationTargetIfNeeded(bookInitials: "", startOrdinal: 4, endOrdinal: 5)
        XCTAssertTrue(noOpDelta.isEmpty)

        let markDelta = store.markAsMemorized(bookInitials: "", startOrdinal: 4, endOrdinal: 4)
        XCTAssertEqual(markDelta.addedMemorized, [4])
        XCTAssertEqual(store.memorizedOrdinals(bookInitials: "ESV", startOrdinal: 4, endOrdinal: 4), [4])

        let removeDelta = store.removeMemorizationTarget(bookInitials: "", startOrdinal: 5, endOrdinal: 5)
        XCTAssertEqual(removeDelta.removedTargets, [5])
        XCTAssertEqual(store.targetOrdinals(bookInitials: "KJV", startOrdinal: 4, endOrdinal: 5), [4])

        let unmarkDelta = store.unmarkMemorized(bookInitials: "", startOrdinal: 4, endOrdinal: 4)
        XCTAssertEqual(unmarkDelta.removedMemorized, [4])
        XCTAssertEqual(store.memorizedOrdinals(bookInitials: "KJV", startOrdinal: 4, endOrdinal: 4), [])
    }

    /**
     Verifies bridge memorization mutations use Android's storage and event contracts.

     The shared Vue client expects native `markAsMemorized`, `addMemorizationTarget`,
     `removeMemorizationTarget`, and `unmarkMemorized` calls to emit
     `update_memorization_data` deltas in the current rendered ordinal domain while persistence is
     normalized to Android KJVA ordinals. This test uses the no-module reader fallback so it runs in
     the app-host scheme without a SWORD fixture: rendered ordinals 1 and 2 are Genesis 1:1-2, while
     KJVA storage ordinals are 4 and 5.

     Failure means the bridge can persist native state without updating the open Vue document, or
     can continue writing iOS-only module-specific memorization rows.
     */
    func testMemorizationBridgePersistsKJVAGlobalRowsAndEmitsRenderedDeltas() throws {
        let (bridge, recordedScripts) = makeMemorizeParityRecordingBridge()
        let controller = BibleReaderController(bridge: bridge)
        controller.settingsStore = try makeMemorizeParitySettingsStore()
        let store = try XCTUnwrap(controller.memorizationProgressStore)

        XCTAssertEqual(
            bridge.dispatchMessage(method: "addMemorizationTarget", args: ["KJV", 1, 2]),
            .handled
        )
        XCTAssertEqual(
            store.snapshot().targetRanges,
            [MemorizationProgressRange(bookInitials: "", startOrdinal: 4, endOrdinal: 5)]
        )
        XCTAssertEqual(
            try memorizationParityPayloads(from: recordedScripts()).last?["addedTargets"] as? [Int],
            [1, 2]
        )

        XCTAssertEqual(
            bridge.dispatchMessage(method: "markAsMemorized", args: ["KJV", 1, 1]),
            .handled
        )
        XCTAssertEqual(
            store.snapshot().memorizedRanges,
            [MemorizationProgressRange(bookInitials: "", startOrdinal: 4, endOrdinal: 4)]
        )
        XCTAssertEqual(
            try memorizationParityPayloads(from: recordedScripts()).last?["addedMemorized"] as? [Int],
            [1]
        )

        XCTAssertEqual(
            bridge.dispatchMessage(method: "removeMemorizationTarget", args: ["KJV", 2, 2]),
            .handled
        )
        XCTAssertEqual(store.snapshot().targetRanges, [
            MemorizationProgressRange(bookInitials: "", startOrdinal: 4, endOrdinal: 4),
        ])
        XCTAssertEqual(
            try memorizationParityPayloads(from: recordedScripts()).last?["removedTargets"] as? [Int],
            [2]
        )

        XCTAssertEqual(
            bridge.dispatchMessage(method: "unmarkMemorized", args: ["KJV", 1, 1]),
            .handled
        )
        XCTAssertTrue(store.snapshot().memorizedRanges.isEmpty)
        XCTAssertEqual(
            try memorizationParityPayloads(from: recordedScripts()).last?["removedMemorized"] as? [Int],
            [1]
        )
    }

    /**
     Verifies Memorize document payloads reuse saved page-manager state.

     Android stores the full Vue state blob on `PageManager.jsState` through `saveState`, then passes
     that same state into the next Memorize fake document. This regression keeps iOS from
     synthesizing a fresh blur-mode-only state that loses the user's selected memorization mode or
     sibling document state keys.

     Failure means opening Memorize on iOS resets the shared Vue document state instead of restoring
     the Android `pageManager.jsState` contract.
     */
    func testMemorizeDocumentUsesSavedPageManagerState() throws {
        let (bridge, recordedScripts) = makeMemorizeParityRecordingBridge()
        let controller = BibleReaderController(bridge: bridge)
        controller.settingsStore = try makeMemorizeParitySettingsStore()

        let window = Window()
        let pageManager = PageManager(id: window.id)
        pageManager.jsState = #"{"memorize":{"mode":"scramble","modeConfig":{"memorizeWordVisibility":"hidden","customLevel":7}},"otherDocument":{"selectedTab":"lexicon"}}"#
        window.pageManager = pageManager
        controller.activeWindow = window
        controller.bridgeDidSetClientReady(bridge)

        let baselineScriptCount = recordedScripts().count
        XCTAssertEqual(bridge.dispatchMessage(method: "memorize", args: ["KJV", 1, 1]), .handled)

        let memorizeScripts = Array(recordedScripts().dropFirst(baselineScriptCount))
        let document = try XCTUnwrap(
            memorizeParityBridgeEmissionPayload(from: memorizeScripts, event: "add_documents") as? [String: Any]
        )
        let state = try XCTUnwrap(document["state"] as? [String: Any])
        let memorizeState = try XCTUnwrap(state["memorize"] as? [String: Any])
        XCTAssertEqual(memorizeState["mode"] as? String, "scramble")
        XCTAssertEqual(
            (memorizeState["modeConfig"] as? [String: Any])?["memorizeWordVisibility"] as? String,
            "hidden"
        )
        XCTAssertEqual(
            (state["otherDocument"] as? [String: Any])?["selectedTab"] as? String,
            "lexicon"
        )
    }
}

/**
 Creates an in-memory settings store for app-host memorization parity tests.

 - Returns: `SettingsStore` backed by a transient SwiftData container.
 - Side effects: Allocates an in-memory model container for the duration of the test.
 - Failure modes: Throws if SwiftData cannot create the transient settings schema.
 */
private func makeMemorizeParitySettingsStore() throws -> SettingsStore {
    let schema = Schema([Setting.self])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [configuration])
    return SettingsStore(modelContext: ModelContext(container))
}

/**
 Creates a recording bridge for app-host memorization parity tests.

 - Returns: A bridge plus ordered JavaScript evaluations emitted by native bridge code.
 - Side effects: Installs a JavaScript evaluation observer on the returned bridge.
 - Failure modes: None.
 */
private func makeMemorizeParityRecordingBridge() -> (BibleBridge, () -> [String]) {
    let bridge = BibleBridge()
    var scripts: [String] = []
    bridge.javaScriptEvaluationObserver = { scripts.append($0) }
    return (bridge, { scripts })
}

/**
 Decodes every recorded `update_memorization_data` bridge payload.

 - Parameter scripts: JavaScript snippets recorded from `BibleBridge.emit`.
 - Returns: Payload dictionaries in emission order.
 - Side effects: None.
 - Failure modes: Throws XCTest unwrap or JSON errors when an emission wrapper is malformed.
 */
private func memorizationParityPayloads(from scripts: [String]) throws -> [[String: Any]] {
    try scripts
        .filter { $0.contains("bibleView.emit('update_memorization_data'") }
        .map { script in
            let prefix = "bibleView.emit('update_memorization_data', "
            let start = try XCTUnwrap(script.range(of: prefix)?.upperBound)
            let end = try XCTUnwrap(
                script.range(of: "); } catch", options: .backwards, range: start..<script.endIndex)?.lowerBound
            )
            let json = String(script[start..<end])
            let data = try XCTUnwrap(json.data(using: .utf8))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
}

/**
 Decodes a recorded `bibleView.emit` payload for app-host memorization parity tests.

 - Parameters:
   - scripts: JavaScript snippets recorded from `BibleBridge.emit`.
   - event: Event name passed to `bibleView.emit`.
 - Returns: Decoded JSON payload for the first matching event.
 - Side effects: None.
 - Failure modes: Throws XCTest unwrap or JSON errors when the emission wrapper is malformed.
 */
private func memorizeParityBridgeEmissionPayload(from scripts: [String], event: String) throws -> Any {
    let json = try memorizeParityBridgeEmissionPayloadJSON(from: scripts, event: event)
    let data = try XCTUnwrap(json.data(using: .utf8))
    return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
}

private func memorizeParityBridgeEmissionPayloadJSON(from scripts: [String], event: String) throws -> String {
    let prefix = "bibleView.emit('\(event)', "
    let script = try XCTUnwrap(scripts.first { $0.contains(prefix) })
    let start = try XCTUnwrap(script.range(of: prefix)?.upperBound)
    let end = try XCTUnwrap(
        script.range(of: "); } catch", options: .backwards, range: start..<script.endIndex)?.lowerBound
    )
    return String(script[start..<end])
}
