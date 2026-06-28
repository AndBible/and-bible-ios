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
