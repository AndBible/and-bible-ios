import XCTest
@testable import BibleView

/**
 Creates a Bible bridge that records JavaScript evaluations for BibleView bridge tests.

 - Returns: A bridge plus a closure that exposes scripts in emission order for payload assertions.
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
 Extracts one payload from either a standalone bridge emission or atomic replacement transaction.

 Production bridge emissions normally pass JSON, but this helper intentionally treats the payload as
 raw text before callers decide whether to parse it. Atomic replacements provide an event-specific
 marker; standalone emissions retain the legacy outer-wrapper suffix.

 - Parameters:
   - scripts: Recorded JavaScript evaluations from `makeRecordingBridge`.
   - event: Vue event name passed to `bibleView.emit`.
   - file: XCTest source location used when reporting extraction failures.
   - line: XCTest source location used when reporting extraction failures.
 - Returns: Raw payload text between the emit prefix and its event-specific/outer suffix.
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
    let transactionSuffix = "); /* bible-bridge-event-end:\(event) */"
    let end = try XCTUnwrap(
        script.range(of: transactionSuffix, range: start..<script.endIndex)?.lowerBound
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
