// ProductFeedbackReportPreparation.swift -- consent-gated manual diagnostic report preparation

import Foundation
import BibleCore

#if os(iOS)
import UIKit
#endif

/**
 Evidence that can only be captured on the main actor: the live window image and device identity.

 The remaining collection work — log export, crash-diagnostic reads, and body formatting — is
 file and log-store bound, so it runs off the main actor to keep the reader responsive while the
 blocking collection dialog is visible.
 */
struct ProductFeedbackUIEvidence {
    /// Captured app-window screenshot, or `nil` when capture failed.
    let screenshot: AddressedMailAttachment?

    /// Truthful preparation note recorded when the screenshot could not be captured.
    let screenshotWarning: String?

    /// User-facing device model description resolved from live UI state.
    let deviceDescription: String
}

/** Builds an addressed, unsent manual diagnostic report before the consent prompt. */
enum ProductFeedbackReportPreparation {
    private static let screenshotByteLimit = 2 * 1_024 * 1_024

    /**
     Captures the evidence that requires live main-actor UI access.

     - Returns: Screenshot evidence or its warning, plus the device description for the report body.
     - Side effects: Renders the current key window when one is available.
     - Failure modes: Screenshot failure becomes a truthful preparation note; the report proceeds.
     */
    @MainActor
    static func captureUIEvidence() -> ProductFeedbackUIEvidence {
        #if os(iOS)
        let device = UIDevice.current
        let deviceDescription = "\(device.model) (\(device.userInterfaceIdiom == .pad ? "iPad" : "iPhone"))"
        if let screenshot = currentWindowScreenshot() {
            return ProductFeedbackUIEvidence(
                screenshot: .init(data: screenshot, filename: "current_window.jpg", mimeType: "image/jpeg"),
                screenshotWarning: nil,
                deviceDescription: deviceDescription
            )
        }
        return ProductFeedbackUIEvidence(
            screenshot: nil,
            screenshotWarning: String(
                localized: "bug_report_screenshot_unavailable",
                defaultValue: "Current app-window screenshot could not be captured."
            ),
            deviceDescription: deviceDescription
        )
        #else
        return ProductFeedbackUIEvidence(screenshot: nil, screenshotWarning: nil, deviceDescription: "Unavailable")
        #endif
    }

    /**
     Prepares the complete report from pre-captured UI evidence without touching the main actor.

     - Parameter uiEvidence: Screenshot and device identity captured on the main actor first.
     - Returns: A complete, pre-addressed payload the reader may present only after consent.
     - Side effects: Reads the process log store and any retained crash diagnostic.
     - Failure modes: Log capture failure becomes a truthful preparation note; remaining evidence
       is retained. Attachment order stays log, screenshot, then crash diagnostic.
     */
    nonisolated static func prepare(uiEvidence: ProductFeedbackUIEvidence) -> AddressedMailPayload {
        let metadata = AndBibleAppVersionMetadata.current()
        var attachments: [AddressedMailAttachment] = []
        var warnings: [String] = []
        #if os(iOS)
        switch ProductFeedbackLogExporter.capture() {
        case .attachment(let log): attachments.append(log)
        case .unavailable(let warning): warnings.append(warning)
        }
        if let screenshot = uiEvidence.screenshot {
            attachments.append(screenshot)
        } else if let screenshotWarning = uiEvidence.screenshotWarning {
            warnings.append(screenshotWarning)
        }
        if let recentCrash = RecentCrashDiagnosticStore.shared.recentAttachment() {
            attachments.append(recentCrash)
        }
        #endif
        return makePayload(
            metadata: metadata,
            attachments: attachments,
            warnings: warnings,
            deviceDescription: uiEvidence.deviceDescription
        )
    }

    /**
     Formats a prepared report from already-captured evidence.

     This pure seam keeps recipient, subject, truthful attachment listing, and preparation-warning
     behavior testable without UIKit, MetricKit, mail configuration, or an actual system handoff.
     */
    static func makePayload(
        metadata: AndBibleAppVersionMetadata,
        attachments: [AddressedMailAttachment],
        warnings: [String],
        deviceDescription: String
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
            body: diagnosticBody(
                metadata: metadata,
                attachmentDescription: attachmentDescription,
                deviceDescription: deviceDescription
            ) + notes,
            attachments: attachments
        )
    }

    /**
     Builds credential-free report metadata after evidence collection has completed.

     The device-info labels are intentionally unlocalized English literals, matching Android's
     `BugReport.createErrorText`, so the developer team can read every submitted report regardless
     of the sender's locale. User-facing headings above this block remain Android-localized.
     */
    private static func diagnosticBody(
        metadata: AndBibleAppVersionMetadata,
        attachmentDescription: String,
        deviceDescription: String
    ) -> String {
        let bundle = Bundle.main
        let processInfo = ProcessInfo.processInfo
        let unavailable = "Unavailable"
        let freeStorage = (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage.map(String.init) ?? unavailable
        return """
        \(String(localized: "report_bug_big_heading", defaultValue: "PLEASE WRITE YOUR FEEDBACK OR BUG REPORT ABOVE THIS LINE"))

        \(String(localized: "report_bug_heading1", defaultValue: "Instructions:"))
        \(String(localized: "report_bug_line_1", defaultValue: "Tell us briefly what did you do / what happened when issue took place."))

        \(attachmentDescription)

        \(String(localized: "report_bug_heading_4", defaultValue: "Device info:"))
        App id: \(bundle.bundleIdentifier ?? unavailable)
        Version: \(metadata.detailText)
        Operating system: \(processInfo.operatingSystemVersionString)
        Device: \(deviceDescription)
        Locale: \(Locale.current.identifier)
        Time zone: \(TimeZone.current.identifier)
        Physical memory bytes: \(processInfo.physicalMemory)
        Free storage bytes: \(freeStorage)
        """
    }

    #if os(iOS)
    /** Captures the key app window and progressively lowers resolution/quality to the 2 MiB ceiling. */
    @MainActor
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
