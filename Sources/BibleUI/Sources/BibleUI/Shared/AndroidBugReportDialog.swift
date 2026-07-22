import Foundation
import SwiftUI

/**
 Builds the app/device payload included in Android's manually initiated bug-report flow.

 The platform fields intentionally avoid user content and credentials. The returned plain text can
 be passed to iOS's system share surface, which is the equivalent of Android's email chooser.
 */
enum AndroidBugReportDiagnostic {
    /** Returns the manual-report subject and diagnostic body for the current app process. */
    static func manualReport(
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let metadata = AndBibleAppVersionMetadata.current(bundle: bundle)
        let appID = bundle.bundleIdentifier ?? "net.bible.androidactivity"
        let operatingSystem = processInfo.operatingSystemVersionString
        let memoryMegabytes = processInfo.physicalMemory / 1_048_576
        return """
        [\(metadata.marketingVersion) manual] Bug report for AndBible

        App id: \(appID)
        Version: \(metadata.detailText)
        Operating system: \(operatingSystem)
        Locale: \(locale.identifier)
        Time zone: \(timeZone.identifier)
        Physical memory Mb: \(memoryMegabytes)

        Please describe what happened, the expected result, and steps to reproduce it below.
        """
    }
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
