// AIBugReportMailComposer.swift -- Android-compatible addressed AI bug reports

import Foundation
import SwiftUI

#if os(iOS)
import MessageUI
#endif

/** Complete addressed email payload used by Android-compatible AI bug reports. */
struct AIBugReportMailPayload: Identifiable {
    /// Stable SwiftUI presentation identity.
    let id = UUID()
    /// Developer-team recipient copied from Android's `AiBugReport`.
    let recipient: String
    /// Android-compatible report subject.
    let subject: String
    /// Credential-free diagnostic body.
    let body: String
    /// Gzip-compressed raw conversation log.
    let attachmentData: Data
    /// Android attachment filename.
    let attachmentFilename: String
}

#if os(iOS)
/** System mail composer matching Android's addressed email intent and gzip attachment contract. */
struct AIBugReportMailComposer: UIViewControllerRepresentable {
    /// Whether this device has an account capable of sending the addressed report.
    static var canSendMail: Bool { MFMailComposeViewController.canSendMail() }

    /// Complete addressed message and attachment.
    let payload: AIBugReportMailPayload
    /// Called after the user sends, saves, cancels, or encounters a mail error.
    let onFinish: () -> Void

    /** Creates the delegate bridge that closes the SwiftUI presentation on every terminal result. */
    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    /**
     Creates and preconfigures Apple's mail composer.

     - Parameter context: SwiftUI representable context containing the delegate coordinator.
     - Returns: A composer addressed to Android's developer-team recipient with subject, body, and
       `application/gzip` attachment already populated.
     - Side effects: Configures a system mail controller but does not send until the user confirms.
     - Failure modes: Callers must check `canSendMail` before presentation; delivery errors are
       returned through the mail-composer delegate and close the presentation.
     */
    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients([payload.recipient])
        controller.setSubject(payload.subject)
        controller.setMessageBody(payload.body, isHTML: false)
        controller.addAttachmentData(
            payload.attachmentData,
            mimeType: "application/gzip",
            fileName: payload.attachmentFilename
        )
        return controller
    }

    /** Mail payloads are immutable for the lifetime of one system composer presentation. */
    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    /** Delegate bridge for every system mail-composer terminal result. */
    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        /// Parent dismissal callback.
        private let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        /** Dismisses the system composer after send, save, cancel, or failure. */
        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            controller.dismiss(animated: true, completion: onFinish)
        }
    }
}
#else
/** Non-iOS placeholder; Android-compatible addressed mail delivery is an iOS application feature. */
struct AIBugReportMailComposer: View {
    /// Mail delivery is unavailable outside the iOS app target.
    static var canSendMail: Bool { false }

    /// Retained only to keep the cross-platform view contract source-compatible.
    let payload: AIBugReportMailPayload
    /// Retained only to keep the cross-platform view contract source-compatible.
    let onFinish: () -> Void

    var body: some View { EmptyView() }
}
#endif
