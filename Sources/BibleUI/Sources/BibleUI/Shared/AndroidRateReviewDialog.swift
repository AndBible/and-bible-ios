import SwiftUI

/**
 Renders Android's explanatory Rate & Review dialog before the platform review handoff.

 Android directs support, bug, document-maintainer, and contribution concerns through linked text
 before offering its store action. iOS keeps those actions app-owned here, then hands off only the
 final review request to the legitimate system controller.
 */
struct AndroidRateReviewDialog: View {
    /// Current appearance used by the globally managed Android dialog palette.
    @Environment(\.colorScheme) private var colorScheme

    let onDismiss: () -> Void
    let onProceed: () -> Void
    let onContactSupport: () -> Void
    let onReportBug: () -> Void
    let onContactMaintainers: () -> Void
    let onLearnToContribute: () -> Void

    var body: some View {
        AndroidDialogWindow(
            colorScheme: colorScheme,
            accessibilityIdentifier: "androidRateReviewDialog",
            onOutsideTap: onDismiss
        ) {
            AndroidDialogScaffold(
                title: String(localized: "rate_title", defaultValue: "Rating and reviewing app")
            ) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(String(
                            localized: "rate_message5",
                            defaultValue: "Positive and detailed reviews help AndBible Open Source Project a lot. Thank you!"
                        ))
                        Text(String(
                            localized: "rate_message6",
                            defaultValue: "Before reviewing negative review, please consider the following:"
                        ))

                        rateLink(
                            formatKey: "rate_message1",
                            fallback: "If you have a problem with app, please %@ or %@ instead.",
                            first: String(localized: "send_email", defaultValue: "send email"),
                            second: String(localized: "bug_report", defaultValue: "send a bug report")
                        )
                        HStack {
                            Button(String(localized: "send_email", defaultValue: "Send email"), action: onContactSupport)
                            Button(String(localized: "bug_report", defaultValue: "Send a bug report"), action: onReportBug)
                        }

                        rateLink(
                            formatKey: "rate_message2",
                            fallback: "If some text or Bible translation has an issue, %@.",
                            first: String(localized: "text_maintainers", defaultValue: "report it to maintainers")
                        )
                        Button(String(localized: "text_maintainers", defaultValue: "Contact maintainers"), action: onContactMaintainers)

                        Text(String.localizedStringWithFormat(
                            String(localized: "rate_message3", defaultValue: "If particular text is not available in the application, %@."),
                            String(localized: "how_to_help", defaultValue: "read how you can help")
                        ) + " " + String(
                            localized: "rate_message4",
                            defaultValue: "The developers of this app are not responsible for maintaining documents."
                        ))
                        Button(String(localized: "how_to_help", defaultValue: "How to help"), action: onLearnToContribute)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 8)
                }
            } actions: {
                AndroidDialogTextAction(
                    title: String(localized: "cancel", defaultValue: "Cancel"),
                    action: onDismiss
                )
                AndroidDialogTextAction(
                    title: String(localized: "proceed_google_play", defaultValue: "Proceed to App Store"),
                    action: onProceed
                )
            }
        }
    }

    /** Builds Android's localized two-action explanatory line. */
    private func rateLink(formatKey: String, fallback: String, first: String, second: String = "") -> some View {
        Text(String.localizedStringWithFormat(
            Bundle.main.localizedString(forKey: formatKey, value: fallback, table: nil),
            first,
            second
        ))
    }
}
