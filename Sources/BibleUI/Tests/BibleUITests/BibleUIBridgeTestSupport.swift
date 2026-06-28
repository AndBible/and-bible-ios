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
