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
            warnings.append(String(
                localized: "bug_report_screenshot_unavailable",
                defaultValue: "Current app-window screenshot could not be captured."
            ))
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
        let attachmentEvidence = attachments.isEmpty
            ? String(
                localized: "bug_report_no_attachments",
                defaultValue: "No diagnostic attachments were available."
            )
            : attachments.map(\.filename).joined(separator: ", ")
                + "\n"
                + String(
                    localized: "bug_report_attachment_line_1",
                    defaultValue: "Having these files attached helps app developers a lot in fixing the reported bug."
                )
        let attachmentDescription = String(
            localized: "report_bug_heading_3",
            defaultValue: "Attachments:"
        ) + "\n" + attachmentEvidence
        let notes = warnings.isEmpty
            ? ""
            : "\n\n"
                + String(localized: "bug_report_preparation_notes", defaultValue: "Preparation notes:")
                + "\n"
                + warnings.map { "- \($0)" }.joined(separator: "\n")
        let subject = String(
            format: String(
                localized: "report_bug_email_subject_3",
                defaultValue: "[%1$@] Bug report for %2$@ %3$@"
            ),
            "\(metadata.buildNumber) \(ProductFeedbackContract.manualReportSource)",
            "AndBible",
            metadata.marketingVersion
        )
        return AddressedMailPayload(
            recipient: ProductFeedbackContract.diagnosticRecipient,
            subject: subject,
            body: diagnosticBody(metadata: metadata, attachmentDescription: attachmentDescription) + notes,
            attachments: attachments
        )
    }

    /** Builds credential-free report metadata after evidence collection has completed. */
    private static func diagnosticBody(metadata: AndBibleAppVersionMetadata, attachmentDescription: String) -> String {
        let bundle = Bundle.main
        let processInfo = ProcessInfo.processInfo
        let unavailable = String(localized: "bug_report_unavailable", defaultValue: "Unavailable")
        let freeStorage = (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage.map(String.init) ?? unavailable
        #if os(iOS)
        let device = UIDevice.current
        let deviceDescription = "\(device.model) (\(device.userInterfaceIdiom == .pad ? "iPad" : "iPhone"))"
        #else
        let deviceDescription = unavailable
        #endif
        return """
        \(String(localized: "report_bug_big_heading", defaultValue: "PLEASE WRITE YOUR FEEDBACK OR BUG REPORT ABOVE THIS LINE"))

        \(String(localized: "report_bug_heading1", defaultValue: "Instructions:"))
        \(String(localized: "report_bug_line_1", defaultValue: "Tell us briefly what did you do / what happened when issue took place."))

        \(attachmentDescription)

        \(String(localized: "report_bug_heading_4", defaultValue: "Device info:"))
        \(String(localized: "bug_report_app_id", defaultValue: "App id:")) \(bundle.bundleIdentifier ?? unavailable)
        \(String(localized: "bug_report_version", defaultValue: "Version:")) \(metadata.detailText)
        \(String(localized: "bug_report_operating_system", defaultValue: "Operating system:")) \(processInfo.operatingSystemVersionString)
        \(String(localized: "bug_report_device", defaultValue: "Device:")) \(deviceDescription)
        \(String(localized: "bug_report_locale", defaultValue: "Locale:")) \(Locale.current.identifier)
        \(String(localized: "bug_report_time_zone", defaultValue: "Time zone:")) \(TimeZone.current.identifier)
        \(String(localized: "bug_report_physical_memory", defaultValue: "Physical memory bytes:")) \(processInfo.physicalMemory)
        \(String(localized: "bug_report_free_storage", defaultValue: "Free storage bytes:")) \(freeStorage)
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
