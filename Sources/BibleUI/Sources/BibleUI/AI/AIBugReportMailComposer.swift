// AIBugReportMailComposer.swift -- Android-compatible addressed AI bug reports

import Foundation
import SwiftUI

#if os(iOS)
import MessageUI
#endif

/** One immutable typed attachment for an addressed diagnostic report. */
struct AddressedMailAttachment: Equatable {
    /// Bounded and redacted bytes supplied by the report collector.
    let data: Data
    /// Truthful user-visible filename.
    let filename: String
    /// MIME type passed unchanged to the system composer.
    let mimeType: String
}

/** Explicit system-mail availability result; unavailable mail is never reported as sent. */
enum AddressedMailCapability: Equatable {
    /// A configured account can present the addressed system composer.
    case available
    /// The prepared report must remain unsent and be offered for export instead.
    case unavailable
}

/** Complete addressed email payload shared by AI and product diagnostic reports. */
struct AddressedMailPayload: Identifiable {
    /// Stable SwiftUI presentation identity.
    let id = UUID()
    /// Developer-team recipient copied from Android's `AiBugReport`.
    let recipient: String
    /// Android-compatible report subject.
    let subject: String
    /// Credential-free diagnostic body.
    let body: String
    /// Zero or more prepared artifacts in the order stated by the report body.
    let attachments: [AddressedMailAttachment]

    /**
     Creates an immutable addressed report for platform handoff.

     - Parameters:
       - recipient: Fully addressed diagnostic destination.
       - subject: Localized user-visible subject.
       - body: Localized, credential-free report body.
       - attachments: Prepared bounded artifacts with truthful MIME metadata.
     - Side effects: none.
     - Failure modes: Delivery is not attempted here; callers must handle capability and result.
     */
    init(recipient: String, subject: String, body: String, attachments: [AddressedMailAttachment]) {
        self.recipient = recipient
        self.subject = subject
        self.body = body
        self.attachments = attachments
    }
}

#if os(iOS)
/** System composer that populates every field of an already prepared addressed report. */
struct AddressedMailComposer: UIViewControllerRepresentable {
    /// Current capability used by callers to choose composer versus explicit unsent/export UI.
    static var capability: AddressedMailCapability {
        MFMailComposeViewController.canSendMail() ? .available : .unavailable
    }

    /// Complete addressed message and attachment.
    let payload: AddressedMailPayload
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
       all prepared attachments already populated with their truthful MIME type and filename.
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
        for attachment in payload.attachments {
            controller.addAttachmentData(
                attachment.data,
                mimeType: attachment.mimeType,
                fileName: attachment.filename
            )
        }
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
struct AddressedMailComposer: View {
    /// Mail delivery is unavailable outside the iOS app target.
    static var capability: AddressedMailCapability { .unavailable }

    /// Retained only to keep the cross-platform view contract source-compatible.
    let payload: AddressedMailPayload
    /// Retained only to keep the cross-platform view contract source-compatible.
    let onFinish: () -> Void

    var body: some View { EmptyView() }
}
#endif

/// Compatibility name retained until all AI report call sites migrate to the shared contract.
typealias AIBugReportMailPayload = AddressedMailPayload
/// Compatibility name retained until all AI report call sites migrate to the shared composer.
typealias AIBugReportMailComposer = AddressedMailComposer
