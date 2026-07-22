// ProductFeedbackReportPreparation.swift -- consent-gated manual diagnostic report preparation

import Foundation
import BibleCore

#if os(iOS)
import UIKit
#endif

/** Builds an addressed, unsent manual diagnostic report before the consent prompt. */
@MainActor
enum ProductFeedbackReportPreparation {
    private static let screenshotByteLimit = 2 * 1_024 * 1_024

    /**
     Prepares available app and device evidence without uploading or sending it.

     - Returns: A complete, pre-addressed payload the reader may present only after consent.
     - Side effects: Captures the current app window when available.
     - Failure modes: Screenshot failure becomes a truthful preparation note; remaining evidence is retained.
     */
    static func prepare() -> AddressedMailPayload {
        let metadata = AndBibleAppVersionMetadata.current()
        var attachments: [AddressedMailAttachment] = []
        var warnings: [String] = []
        #if os(iOS)
        switch ProductFeedbackLogExporter.capture() {
        case .attachment(let log): attachments.append(log)
        case .unavailable(let warning): warnings.append(warning)
        }
        if let screenshot = currentWindowScreenshot() {
            attachments.append(.init(data: screenshot, filename: "current_window.jpg", mimeType: "image/jpeg"))
        } else {
            warnings.append("Current app-window screenshot could not be captured.")
        }
        if let recentCrash = RecentCrashDiagnosticStore.shared.recentAttachment() {
            attachments.append(recentCrash)
        }
        #endif
        return makePayload(metadata: metadata, attachments: attachments, warnings: warnings)
    }

    /**
     Formats a prepared report from already-captured evidence.

     This pure seam keeps recipient, subject, truthful attachment listing, and preparation-warning
     behavior testable without UIKit, MetricKit, mail configuration, or an actual system handoff.
     */
    static func makePayload(
        metadata: AndBibleAppVersionMetadata,
        attachments: [AddressedMailAttachment],
        warnings: [String]
    ) -> AddressedMailPayload {
        let attachmentDescription = attachments.isEmpty
            ? String(localized: "bug_report_no_attachments", defaultValue: "No diagnostic attachments were available.")
            : String(
                format: String(localized: "bug_report_attached_evidence", defaultValue: "Attached diagnostic evidence: %@"),
                attachments.map(\.filename).joined(separator: ", ")
            )
        let notes = warnings.isEmpty ? "" : "\n\n" + String(localized: "bug_report_preparation_notes", defaultValue: "Preparation notes:") + "\n" + warnings.map { "- \($0)" }.joined(separator: "\n")
        return AddressedMailPayload(
            recipient: ProductFeedbackContract.diagnosticRecipient,
            subject: "[\(metadata.buildNumber) \(ProductFeedbackContract.manualReportSource)] Bug report for AndBible \(metadata.marketingVersion)",
            body: diagnosticBody(metadata: metadata, attachmentDescription: attachmentDescription) + notes,
            attachments: attachments
        )
    }

    /** Builds credential-free report metadata after evidence collection has completed. */
    private static func diagnosticBody(metadata: AndBibleAppVersionMetadata, attachmentDescription: String) -> String {
        let bundle = Bundle.main
        let processInfo = ProcessInfo.processInfo
        let freeStorage = (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage.map(String.init) ?? "Unavailable"
        #if os(iOS)
        let device = UIDevice.current
        let deviceDescription = "\(device.model) (\(device.userInterfaceIdiom == .pad ? "iPad" : "iPhone"))"
        #else
        let deviceDescription = "Unavailable"
        #endif
        return """
        \(String(localized: "bug_report_app_id", defaultValue: "App id:")) \(bundle.bundleIdentifier ?? String(localized: "bug_report_unavailable", defaultValue: "Unavailable"))
        \(String(localized: "bug_report_version", defaultValue: "Version:")) \(metadata.detailText)
        \(String(localized: "bug_report_operating_system", defaultValue: "Operating system:")) \(processInfo.operatingSystemVersionString)
        \(String(localized: "bug_report_device", defaultValue: "Device:")) \(deviceDescription)
        \(String(localized: "bug_report_locale", defaultValue: "Locale:")) \(Locale.current.identifier)
        \(String(localized: "bug_report_time_zone", defaultValue: "Time zone:")) \(TimeZone.current.identifier)
        \(String(localized: "bug_report_physical_memory", defaultValue: "Physical memory bytes:")) \(processInfo.physicalMemory)
        \(String(localized: "bug_report_free_storage", defaultValue: "Free storage bytes:")) \(freeStorage)

        \(attachmentDescription)

        \(String(localized: "bug_report_reproduction_prompt", defaultValue: "Please describe what happened, the expected result, and steps to reproduce it below."))
        """
    }

    #if os(iOS)
    /** Captures the key app window and progressively lowers resolution/quality to the 2 MiB ceiling. */
    private static func currentWindowScreenshot() -> Data? {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow), window.bounds.width > 0, window.bounds.height > 0 else { return nil }
        let sourceSize = window.bounds.size
        for scale in stride(from: CGFloat(1), through: 0.25, by: -0.25) {
            let targetSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
            let image = UIGraphicsImageRenderer(size: targetSize).image { _ in window.drawHierarchy(in: CGRect(origin: .zero, size: targetSize), afterScreenUpdates: true) }
            for quality in stride(from: CGFloat(0.8), through: 0.3, by: -0.1) {
                if let data = image.jpegData(compressionQuality: quality), data.count <= screenshotByteLimit { return data }
            }
        }
        return nil
    }
    #endif
}
