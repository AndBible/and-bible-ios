// SwordJSwordPlainTextSourceFilter.swift -- Pinned JSword plain-source projection

import Foundation

/**
 Ports pinned JSword `PlainTextFilter` into the shared structural XML tree.

 Android treats missing and unknown `SourceType` values as plain text. It preserves every line,
 including empty interior/trailing lines, and inserts an OSIS `lb` between lines without appending
 one after the final line. Structural conversion prevents XML-looking source text from becoming
 markup while retaining Android's exact newline semantics.
 */
enum SwordJSwordPlainTextSourceFilter {
    /**
     Converts one decoded plain-source record to JSword-compatible OSIS children.

     - Parameter source: Exact backend-extracted source after native encoding conversion only.
     - Returns: XML-escaped text with one structural `lb` for each source LF except after the last
       line; an empty source returns empty output.
     - Side effects: Allocates bounded in-memory text and element nodes only.
     - Failure modes: None; every Swift string has a deterministic XML serialization.
     */
    static func convert(_ source: String) -> String {
        guard !source.isEmpty else { return "" }
        let lines = source.components(separatedBy: "\n")
        var output: [SwordXMLNode] = []
        output.reserveCapacity(lines.count * 2 - 1)
        for (index, line) in lines.enumerated() {
            output.append(.text(line))
            if index < lines.count - 1 {
                output.append(.element(name: "lb", attributes: [:]))
            }
        }
        return output.map { $0.serializedXML() }.joined()
    }
}
