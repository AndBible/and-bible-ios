import Foundation
import XCTest
@testable import BibleView

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
 Decodes a recorded `bibleView.emit` payload into a JSON value for BibleUI bridge assertions.

 - Parameters:
   - scripts: Recorded JavaScript evaluations from `makeRecordingBridge`.
   - event: Vue event name passed to `bibleView.emit`.
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
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> Any {
    let json = try bridgeEmissionPayloadJSON(from: scripts, event: event, file: file, line: line)
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
    let json = try bridgeEmissionPayloadJSON(from: scripts, event: "set_config", file: file, line: line)
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
 Extracts the payload argument from a recorded `try { void bibleView.emit(...) } catch` wrapper.

 Production bridge emissions normally pass JSON, but this helper intentionally treats the payload as
 raw text before callers decide whether to parse it. It finds the wrapper suffix with a backwards
 search so payload content that resembles `); } catch` does not truncate the extracted contract.

 - Parameters:
   - scripts: Recorded JavaScript evaluations from `makeRecordingBridge`.
   - event: Vue event name passed to `bibleView.emit`.
   - file: XCTest source location used when reporting extraction failures.
   - line: XCTest source location used when reporting extraction failures.
 - Returns: The raw payload text between the emit prefix and the outer bridge suffix.
 - Side effects: none.
 - Failure modes: Throws XCTest unwrap errors when the event emission, prefix, or suffix is missing.
 */
func bridgeEmissionPayloadJSON(
    from scripts: [String],
    event: String,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> String {
    let prefix = "bibleView.emit('\(event)', "
    let script = try XCTUnwrap(
        scripts.first { $0.contains(prefix) },
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
    let end = try XCTUnwrap(
        script.range(of: "); } catch", options: .backwards, range: start..<script.endIndex)?.lowerBound,
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
