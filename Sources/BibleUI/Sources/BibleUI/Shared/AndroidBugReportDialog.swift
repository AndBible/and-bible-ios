import Foundation
import SwiftUI

/** Reader-owned manual-report state that prevents duplicate collection and premature mail handoff. */
enum ManualBugReportState {
    /// No report is being prepared or presented.
    case idle
    /// Evidence is being collected before consent.
    case collecting
    /// A prepared, unsent report is awaiting an explicit user decision.
    case awaitingConsent(AddressedMailPayload)
    /// The system mail composer owns the prepared report presentation.
    case presentingMail
    /// Mail is unavailable; the report has not been sent.
    case mailUnavailable
}

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
                Text(String(localized: "bug_report_email_title", defaultValue: "Send bug report?"))
                    .font(.headline)
                Text(String(
                    localized: "bug_report_email_text",
                    defaultValue: "Send an app and device diagnostic report to help investigate this issue?"
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
    var body: some View {
        ZStack {
            Color.black.opacity(0.36).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                Text(String(localized: "send_bug_report_title", defaultValue: "Preparing bug report"))
                    .font(.headline)
                Text("Collecting available diagnostic evidence. Nothing has been sent.")
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

    var body: some View {
        ZStack {
            Color.black.opacity(0.36).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                Text("Bug report not sent").font(.headline)
                Text("Mail is not configured on this device. No bug report has been sent.")
                    .foregroundStyle(.secondary)
                Button(String(localized: "ok", defaultValue: "OK"), action: onDismiss)
                    .buttonStyle(.borderedProminent)
            }
            .padding()
            .frame(maxWidth: 480)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(24)
        }
        .accessibilityIdentifier("androidBugReportUnsentDialog")
    }
}
