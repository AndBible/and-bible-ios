// MyDocumentActivityItemSource.swift -- Native subject/body sharing for My Documents

#if os(iOS)
import BibleCore
import UIKit
import UniformTypeIdentifiers

/**
 Supplies My Documents text to `UIActivityViewController` without concatenating the page title.

 Android sends raw content through `Intent.EXTRA_TEXT` and the title through `EXTRA_SUBJECT`.
 `UIActivityItemSource` is UIKit's equivalent contract: activity destinations receive the raw body
 as their item and may independently request the subject.
 */
final class MyDocumentActivityItemSource: NSObject, UIActivityItemSource {
    private let payload: MyDocumentSharePayload

    init(payload: MyDocumentSharePayload) {
        self.payload = payload
    }

    func activityViewControllerPlaceholderItem(
        _ activityViewController: UIActivityViewController
    ) -> Any {
        payload.body
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        payload.body
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        subjectForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        payload.subject ?? ""
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        UTType.plainText.identifier
    }
}
#endif
