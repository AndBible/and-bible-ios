import Foundation
import XCTest
@testable import BibleView

/**
 Selects a bridge emission within the caller-supplied causal script boundary.

 Tests normally assert the first event produced by one action. Configuration assertions sometimes
 need the final state after that action emits more than one config. Keeping the choice explicit
 prevents a stale pre-action event from becoming the oracle merely because it was recorded first.
 */
enum BridgeEmissionSelection: Equatable {
    /// Select the first matching event in emission order.
    case first

    /// Select the last matching event in emission order.
    case last
}

/**
 Creates a Bible bridge that records JavaScript evaluations for BibleUI reader bridge tests.

 - Returns: A bridge plus a closure that exposes scripts in emission order for reader assertions.
 - Side effects: Installs `javaScriptEvaluationObserver` on the returned bridge.
 - Failure modes: none; callers validate expected emissions with XCTest assertions.
 */
func makeRecordingBridge() -> (BibleBridge, () -> [String]) {
    let bridge = BibleBridge()
    var evaluatedScripts: [String] = []
    bridge.javaScriptEvaluationObserver = { script in
        evaluatedScripts.append(script)
    }
    return (bridge, { evaluatedScripts })
}

/**
 Waits until the recording bridge observes one event produced after a caller-owned action boundary.

 The reader preparation pipeline publishes back to the main actor after source capture and JSON
 encoding finish on its worker queue. Tests use this passive observer instead of repeating the
 action or assuming publication is synchronous.

 - Parameters:
   - scripts: Recorder returned by `makeRecordingBridge`.
   - event: Vue event name that must appear.
   - boundary: Script count captured immediately before the action.
   - timeout: Maximum duration allowed for the worker and main-actor publication phases.
 - Returns: Every script recorded after `boundary` once the requested event is present.
 - Side effects: Suspends briefly between observations; it does not invoke the controller or bridge.
 - Failure modes: Throws `CancellationError` when the task is cancelled and records an XCTest
   failure when the event is not observed before the timeout.
 */
@MainActor
func awaitBridgeEmission(
    from scripts: @escaping () -> [String],
    event: String,
    after boundary: Int,
    timeout: Duration = .seconds(3),
    file: StaticString = #filePath,
    line: UInt = #line
) async throws -> [String] {
    let prefix = "bibleView.emit('\(event)', "
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    repeat {
        try Task.checkCancellation()
        let recorded = scripts()
        let bounded = boundary < recorded.count ? Array(recorded.dropFirst(boundary)) : []
        if bounded.contains(where: { $0.contains(prefix) }) {
            return bounded
        }
        await Task.yield()
        try await Task.sleep(for: .milliseconds(5))
    } while clock.now < deadline

    XCTFail("Expected a \(event) bridge emission after script \(boundary)", file: file, line: line)
    let recorded = scripts()
    return boundary < recorded.count ? Array(recorded.dropFirst(boundary)) : []
}

/**
 Waits for one caller-described reader condition without repeating the action under test.

 - Parameters:
   - description: Concrete state expected from the already-dispatched action.
   - timeout: Maximum duration allowed for asynchronous source work and main-owner publication.
   - condition: Main-owner observation that becomes true when the action has settled as expected.
 - Side effects: Suspends briefly between observations; never invokes production behavior.
 - Failure modes: Throws on task cancellation and records an XCTest failure at the caller when the
   condition remains false at the deadline.
 */
@MainActor
func awaitReaderCondition(
    _ description: String,
    timeout: Duration = .seconds(3),
    file: StaticString = #filePath,
    line: UInt = #line,
    condition: @escaping @MainActor () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    repeat {
        try Task.checkCancellation()
        if condition() { return }
        await Task.yield()
        try await Task.sleep(for: .milliseconds(5))
    } while clock.now < deadline
    XCTFail("Expected reader condition: \(description)", file: file, line: line)
}

/** Waits for one exact bridge script shape after a caller-owned causal boundary. */
@MainActor
func awaitBridgeScript(
    from scripts: @escaping () -> [String],
    after boundary: Int,
    description: String,
    timeout: Duration = .seconds(3),
    file: StaticString = #filePath,
    line: UInt = #line,
    matching predicate: @escaping (String) -> Bool
) async throws -> String? {
    var match: String?
    try await awaitReaderCondition(description, timeout: timeout, file: file, line: line) {
        let recorded = scripts()
        guard boundary < recorded.count else { return false }
        match = recorded.dropFirst(boundary).first(where: predicate)
        return match != nil
    }
    return match
}

/**
 Decodes a recorded `bibleView.emit` payload into a JSON value for BibleUI bridge assertions.

 - Parameters:
   - scripts: Recorded JavaScript evaluations from `makeRecordingBridge`.
   - event: Vue event name passed to `bibleView.emit`.
   - selection: First or last matching emission within the caller-supplied action slice.
   - file: XCTest source location used when reporting extraction or parse failures.
   - line: XCTest source location used when reporting extraction or parse failures.
 - Returns: The decoded JSON fragment emitted for the requested event.
 - Side effects: none.
 - Failure modes: Throws XCTest unwrap/JSON errors when the event is missing, the bridge wrapper is
   malformed, the payload is not UTF-8, or the payload is not valid JSON.
 */
func bridgeEmissionPayload(
    from scripts: [String],
    event: String,
    selection: BridgeEmissionSelection = .first,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> Any {
    let json = try bridgeEmissionPayloadJSON(
        from: scripts, event: event, selection: selection, file: file, line: line
    )
    let data = try XCTUnwrap(
        json.data(using: .utf8),
        "Expected UTF-8 JSON payload",
        file: file,
        line: line
    )
    return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
}

/**
 Decodes the latest reader `set_config` bridge payload into a JSON object.

 Reader configuration tests use this helper to assert the native-to-Vue configuration contract
 without depending on WebKit. The payload is extracted from the recorded JavaScript emissions and
 parsed as the same JSON object Vue receives.

 - Parameters:
   - scripts: Recorded JavaScript evaluations from `makeRecordingBridge`.
   - file: XCTest source location used when reporting extraction or parse failures.
   - line: XCTest source location used when reporting extraction or parse failures.
 - Returns: The decoded top-level `set_config` JSON object.
 - Side effects: none.
 - Failure modes: Throws XCTest unwrap/JSON errors when no emission exists, the wrapper is malformed,
   the payload is not UTF-8 JSON, or the payload is not an object.
 */
func setConfigPayload(
    from scripts: [String],
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> [String: Any] {
    let json = try bridgeEmissionPayloadJSON(
        from: scripts,
        event: "set_config",
        selection: .last,
        file: file,
        line: line
    )
    let data = try XCTUnwrap(
        json.data(using: .utf8),
        "Expected UTF-8 JSON payload",
        file: file,
        line: line
    )
    return try XCTUnwrap(
        JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any],
        "Expected object JSON payload",
        file: file,
        line: line
    )
}

/**
 Extracts one payload from either a standalone bridge emission or atomic replacement transaction.

 Production bridge emissions normally pass JSON, but this helper intentionally treats the payload as
 raw text before callers decide whether to parse it. Atomic replacements provide an event-specific
 marker; standalone emissions retain the legacy outer-wrapper suffix. Both suffix searches run
 backwards so marker-like user content cannot truncate the extracted contract.

 - Parameters:
   - scripts: Recorded JavaScript evaluations from `makeRecordingBridge`.
   - event: Vue event name passed to `bibleView.emit`.
   - file: XCTest source location used when reporting extraction failures.
   - line: XCTest source location used when reporting extraction failures.
 - Returns: Raw payload text between the emit prefix and its event-specific or outer suffix.
 - Side effects: none.
 - Failure modes: Throws XCTest unwrap errors when the event emission, prefix, or suffix is missing.
 */
func bridgeEmissionPayloadJSON(
    from scripts: [String],
    event: String,
    selection: BridgeEmissionSelection = .first,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> String {
    let prefix = "bibleView.emit('\(event)', "
    let matchingScripts = scripts.filter { $0.contains(prefix) }
    let script = try XCTUnwrap(
        selection == .first ? matchingScripts.first : matchingScripts.last,
        "Expected a \(event) bridge emission",
        file: file,
        line: line
    )
    let start = try XCTUnwrap(
        script.range(of: prefix)?.upperBound,
        "Expected \(event) payload prefix in script: \(script)",
        file: file,
        line: line
    )
    let transactionSuffix = "); /* bible-bridge-event-end:\(event) */"
    let end = try XCTUnwrap(
        script.range(
            of: transactionSuffix,
            options: .backwards,
            range: start..<script.endIndex
        )?.lowerBound
            ?? script.range(
                of: "); } catch",
                options: .backwards,
                range: start..<script.endIndex
            )?.lowerBound,
        "Expected \(event) payload suffix in script: \(script)",
        file: file,
        line: line
    )
    return String(script[start..<end])
}

/**
 Encodes a bridge DTO and decodes it back to a JSON dictionary for schema assertions.

 - Parameter value: Encodable bridge payload to inspect.
 - Returns: A string-keyed JSON object produced by the same `JSONEncoder` path used by bridge DTOs.
 - Side effects: none.
 - Failure modes: Throws encoding, decoding, or XCTest unwrap errors if the value does not produce
   a top-level JSON object.
 */
func bridgeJSONObject<T: Encodable>(_ value: T) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/**
 Asserts that a bridge JSON object exposes exactly the expected key set.

 The helper intentionally ignores ordering because JSON dictionaries are unordered, but it fails on
 both missing and extra keys so TypeScript/Vue bridge schema drift is visible in package tests.

 - Parameters:
   - object: JSON dictionary decoded from a bridge DTO.
   - expected: Required key names.
 - Side effects: Emits XCTest failures when the key set differs.
 - Failure modes: none beyond XCTest assertion reporting.
 */
func assertJSONKeys(_ object: [String: Any], _ expected: [String], file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(
        Set(object.keys),
        Set(expected),
        "Unexpected keys. Missing: \(Set(expected).subtracting(object.keys)); extra: \(Set(object.keys).subtracting(expected))",
        file: file,
        line: line
    )
}
