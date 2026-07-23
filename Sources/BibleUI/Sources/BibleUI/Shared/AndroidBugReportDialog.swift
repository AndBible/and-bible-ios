import Foundation
import SwiftUI

/**
 Renders Android's manual diagnostic-report confirmation before iOS system sharing.

 Android asks for consent after collecting report inputs and only then opens an email chooser. This
 dialog retains that explicit cancel/send boundary while the later share controller remains system
 owned.
 */
struct AndroidBugReportDialog: View {
    /// Current appearance used by the globally managed Android dialog palette.
    @Environment(\.colorScheme) private var colorScheme

    let onDismiss: () -> Void
    let onSendReport: () -> Void

    var body: some View {
        AndroidDialogWindow(
            colorScheme: colorScheme,
            accessibilityIdentifier: "androidBugReportDialog",
            onOutsideTap: onDismiss
        ) {
            AndroidDialogScaffold(
                title: String(
                    localized: "bug_report_email_title",
                    defaultValue: "Send bug report via email"
                )
            ) {
                Text(String(
                    localized: "bug_report_email_text",
                    defaultValue: "Next, please select your preferred email application (Gmail for example) to send the report to the developer team."
                ))
                .padding(.horizontal, 22)
                .padding(.vertical, 8)
            } actions: {
                AndroidDialogTextAction(
                    title: String(localized: "cancel", defaultValue: "Cancel"),
                    action: onDismiss
                )
                AndroidDialogTextAction(
                    title: String(localized: "send_bug_report_title", defaultValue: "Feedback / bug report"),
                    action: onSendReport
                )
            }
        }
    }
}

/** Blocks duplicate manual-report launches while evidence is collected before consent. */
struct AndroidBugReportPreparationDialog: View {
    /// Whether a previous ZIP creation failed; collection wording is retained for export retry.
    let isExportRetry: Bool

    var body: some View {
        AndroidIndeterminateProgressDialog(
            message: isExportRetry
                ? String(localized: "bug_report_export_preparing", defaultValue: "Preparing your report for export. Nothing has been sent.")
                : String(localized: "bug_report_collecting_evidence", defaultValue: "Collecting available diagnostic evidence. Nothing has been sent."),
            accessibilityIdentifier: "androidBugReportPreparationDialog"
        )
    }
}

/** Explains that a prepared report was not sent because no configured mail account is available. */
struct AndroidBugReportUnsentDialog: View {
    /// Current appearance used by the globally managed Android dialog palette.
    @Environment(\.colorScheme) private var colorScheme

    let onDismiss: () -> Void
    let onExport: () -> Void
    /// Explains a failed local ZIP attempt without implying any report was sent.
    let exportFailed: Bool

    var body: some View {
        AndroidDialogWindow(
            colorScheme: colorScheme,
            accessibilityIdentifier: "androidBugReportUnsentDialog",
            allowsOutsideDismissal: false,
            onOutsideTap: {}
        ) {
            AndroidDialogScaffold(
                title: String(localized: "bug_report_not_sent", defaultValue: "Bug report not sent")
            ) {
                Text(exportFailed
                    ? String(localized: "bug_report_export_failed", defaultValue: "The report could not be exported. No bug report has been sent.")
                    : String(localized: "bug_report_mail_unavailable", defaultValue: "Mail is not configured on this device. No bug report has been sent."))
                .padding(.horizontal, 22)
                .padding(.vertical, 8)
            } actions: {
                AndroidDialogTextAction(
                    title: String(localized: "cancel", defaultValue: "Cancel"),
                    action: onDismiss
                )
                AndroidDialogTextAction(
                    title: String(localized: "bug_report_export", defaultValue: "Export report"),
                    action: onExport
                )
            }
        }
    }
}
