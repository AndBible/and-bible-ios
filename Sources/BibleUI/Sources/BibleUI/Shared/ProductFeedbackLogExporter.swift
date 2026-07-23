// ProductFeedbackLogExporter.swift -- bounded current-process log capture and redaction

import Foundation

/**
 Removes credential-shaped values from one application-log message before it becomes report data.

 This platform-neutral helper is kept separate from OSLog access so the privacy contract is tested
on every supported package platform rather than only on an iOS simulator.
 */
enum ProductFeedbackLogRedactor {
    /**
     Redacts common authorization, cookie, API-key, and URL-credential shapes before retention.

     - Parameter message: One log message, which may contain user-controlled server text.
     - Returns: The same message with credential-shaped values replaced by `[REDACTED]`.
     - Side effects: none.
     - Note: Patterns run in a fixed order so redacting one secret cannot expose another later.
     */
    static func redact(_ message: String) -> String {
        let patterns: [(String, String)] = [
            ("(?i)(authorization\\s*[:=]\\s*)([^\\s,;]+)", "$1[REDACTED]"),
            ("(?i)(bearer\\s+)([^\\s,;]+)", "$1[REDACTED]"),
            ("(?i)((?:api[_-]?key|token|secret|password)\\s*[:=]\\s*)([^\\s,;]+)", "$1[REDACTED]"),
            ("(?i)(cookie\\s*[:=]\\s*)([^\\r\\n]+)", "$1[REDACTED]"),
            ("(?i)(https?://[^:/\\s]+:)([^@\\s]+)(@)", "$1[REDACTED]$3"),
            ("(?i)([?&](?:token|api[_-]?key|secret|password)=)([^&#\\s]+)", "$1[REDACTED]")
        ]
        return patterns.reduce(message) { value, rule in
            guard let expression = try? NSRegularExpression(pattern: rule.0) else { return value }
            let range = NSRange(value.startIndex..., in: value)
            return expression.stringByReplacingMatches(in: value, range: range, withTemplate: rule.1)
        }
    }
}

#if os(iOS)
import OSLog

/** Captures a bounded redacted current-process unified-log attachment for a manual report. */
enum ProductFeedbackLogExporter {
    /// Upper bound for one log message before UTF-8 encoding and incremental archive accumulation.
    static let maximumLineCharacterCount = 128 * 1_024
    static let maximumExpandedByteCount = 4 * 1_024 * 1_024

    /** Typed capture outcome keeps partial-report warnings distinct from thrown delivery failures. */
    enum CaptureOutcome {
        case attachment(AddressedMailAttachment)
        case unavailable(String)
    }

    /**
     Collects recent current-process log entries and redacts credential-shaped values before attachment.

     - Returns: A text attachment on success or an explanatory warning when OSLog access is unavailable.
     - Side effects: Reads the current-process unified log only; no log is uploaded or persisted.
     - Note: The bounded buffer is assembled incrementally so a noisy process cannot allocate an
       unbounded report.
     */
    static func capture() -> CaptureOutcome {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let entries = try store.getEntries(at: store.position(timeIntervalSinceEnd: -3_600))
            var output = Data()
            let truncationMarker = Data("[truncated after 4 MiB]\n".utf8)
            for case let entry as OSLogEntryLog in entries {
                let line = ProductFeedbackLogRedactor.redact(String(entry.composedMessage.prefix(maximumLineCharacterCount))) + "\n"
                let data = Data(line.utf8)
                guard output.count + data.count <= maximumExpandedByteCount else {
                    let remaining = maximumExpandedByteCount - output.count
                    output.append(truncationMarker.prefix(remaining))
                    break
                }
                output.append(data)
            }
            guard !output.isEmpty else {
                return .unavailable(String(
                    localized: "bug_report_log_empty",
                    defaultValue: "Current-process application log contained no exportable entries."
                ))
            }
            return .attachment(.init(data: output, filename: "current_application_log.txt", mimeType: "text/plain"))
        } catch {
            return .unavailable(String(
                localized: "bug_report_log_unavailable",
                defaultValue: "Current-process application log could not be captured."
            ))
        }
    }

}
#endif
