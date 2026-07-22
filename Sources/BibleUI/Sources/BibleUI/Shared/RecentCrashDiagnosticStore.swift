// RecentCrashDiagnosticStore.swift -- bounded retention for user-initiated diagnostic reports

#if os(iOS)
import Foundation
import MetricKit

/**
 Retains the newest MetricKit crash diagnostic for a later user-initiated bug report.

 MetricKit delivery does not send anything to AndBible. This store receives Apple's local callback,
 retains only crash diagnostics for 24 hours, and exposes them only while a user prepares a report.
 */
final class RecentCrashDiagnosticStore: NSObject, MXMetricManagerSubscriber {
    static let shared = RecentCrashDiagnosticStore()

    private let queue = DispatchQueue(label: "net.andbible.recent-crash-diagnostic")
    private let maximumAge: TimeInterval = 24 * 60 * 60
    private let maximumBytes = 2 * 1_024 * 1_024

    private override init() { super.init() }

    /** Registers the retained singleton before MetricKit delivers any previous-session diagnostics. */
    func start() {
        MXMetricManager.shared.add(self)
    }

    /** Persists only the most recent payload that actually contains a crash diagnostic. */
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        queue.async { [weak self] in
            guard let self,
                  let payload = payloads
                    .filter({ !($0.crashDiagnostics?.isEmpty ?? true) })
                    .max(by: { $0.timeStampEnd < $1.timeStampEnd })
            else { return }
            self.persist(payload)
        }
    }

    /**
     Returns the unmodified bounded MetricKit crash JSON when it remains within Android's 24-hour window.

     - Returns: A truthful attachment or `nil` when no fresh crash diagnostic exists.
     - Side effects: Deletes expired or corrupt data.
     - Failure modes: File and decode failures return `nil`; no error is treated as a sent report.
     */
    func recentAttachment(now: Date = Date()) -> AddressedMailAttachment? {
        queue.sync {
            guard let data = try? Data(contentsOf: storageURL),
                  let envelope = try? JSONDecoder().decode(StoredCrashDiagnostic.self, from: data),
                  now.timeIntervalSince(envelope.occurrence) <= maximumAge,
                  now >= envelope.occurrence
            else {
                try? FileManager.default.removeItem(at: storageURL)
                return nil
            }
            return AddressedMailAttachment(
                data: envelope.payload,
                filename: "recent_crash_diagnostic.json",
                mimeType: "application/json"
            )
        }
    }

    private func persist(_ payload: MXDiagnosticPayload) {
        let representation = payload.dictionaryRepresentation()
        guard let crashes = representation["crashDiagnostics"],
              JSONSerialization.isValidJSONObject(crashes),
              let crashJSON = try? JSONSerialization.data(withJSONObject: crashes, options: [.sortedKeys]),
              crashJSON.count <= maximumBytes
        else { return }
        let envelope = StoredCrashDiagnostic(occurrence: payload.timeStampEnd, payload: crashJSON)
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        try? FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storageURL, options: .atomic)
    }

    private var storageURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AndBible", isDirectory: true)
        return directory.appendingPathComponent("recent-crash-diagnostic.json")
    }
}

/** On-disk envelope separates retention timing from the JSON MetricKit attachment. */
private struct StoredCrashDiagnostic: Codable {
    let occurrence: Date
    let payload: Data
}
#endif
