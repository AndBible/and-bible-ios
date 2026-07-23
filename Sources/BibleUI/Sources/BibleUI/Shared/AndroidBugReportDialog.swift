import Foundation
import SwiftUI

/**
 Renders Android's manual diagnostic-report confirmation before iOS system sharing.

 Android asks for consent after collecting report inputs and only then opens an email chooser. This
 dialog retains that explicit cancel/send boundary while the later share controller remains system
 owned.
 */
struct AndroidBugReportDialog: View {
    let onDismiss: () -> Void
    let onSendReport: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.36)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            VStack(alignment: .leading, spacing: 16) {
                Text(String(
                    localized: "bug_report_email_title",
                    defaultValue: "Send bug report via email"
                ))
                    .font(.headline)
                Text(String(
                    localized: "bug_report_email_text",
                    defaultValue: "Next, please select your preferred email application (Gmail for example) to send the report to the developer team."
                ))
                    .foregroundStyle(.secondary)
                HStack {
                    Button(String(localized: "cancel", defaultValue: "Cancel"), action: onDismiss)
                    Spacer()
                    Button(String(localized: "send_bug_report_title", defaultValue: "Feedback / bug report"), action: onSendReport)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .frame(maxWidth: 480)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 16)
            .padding(24)
        }
        .accessibilityIdentifier("androidBugReportDialog")
    }
}

/** Blocks duplicate manual-report launches while evidence is collected before consent. */
struct AndroidBugReportPreparationDialog: View {
    /// Whether a previous ZIP creation failed; collection wording is retained for export retry.
    let isExportRetry: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.36).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                Text(String(
                    localized: "send_bug_report_title",
                    defaultValue: "Feedback / bug report"
                ))
                    .font(.headline)
                Text(isExportRetry
                    ? String(localized: "bug_report_export_preparing", defaultValue: "Preparing your report for export. Nothing has been sent.")
                    : String(localized: "bug_report_collecting_evidence", defaultValue: "Collecting available diagnostic evidence. Nothing has been sent."))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: 360)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(24)
        }
        .accessibilityIdentifier("androidBugReportPreparationDialog")
    }
}

/** Explains that a prepared report was not sent because no configured mail account is available. */
struct AndroidBugReportUnsentDialog: View {
    let onDismiss: () -> Void
    let onExport: () -> Void
    /// Explains a failed local ZIP attempt without implying any report was sent.
    let exportFailed: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.36).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                Text(String(localized: "bug_report_not_sent", defaultValue: "Bug report not sent")).font(.headline)
                Text(exportFailed
                    ? String(localized: "bug_report_export_failed", defaultValue: "The report could not be exported. No bug report has been sent.")
                    : String(localized: "bug_report_mail_unavailable", defaultValue: "Mail is not configured on this device. No bug report has been sent."))
                    .foregroundStyle(.secondary)
                HStack {
                    Button(String(localized: "cancel", defaultValue: "Cancel"), action: onDismiss)
                    Spacer()
                    Button(String(localized: "bug_report_export", defaultValue: "Export report"), action: onExport)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .frame(maxWidth: 480)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(24)
        }
        .accessibilityIdentifier("androidBugReportUnsentDialog")
    }
}
