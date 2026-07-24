// ShareSheet.swift — Cross-platform share sheet wrapper

import SwiftUI

/**
 Result emitted by the platform share surface after the user either completes or cancels sharing.

 The wrapper exposes a small platform-neutral contract instead of leaking UIKit or AppKit result
 types through SwiftUI callers. Backup and export flows can distinguish successful destination
 acceptance from simple dismissal, while plain text-share callers may ignore the result.

 Data dependencies:
 - `completed` comes from the platform share/copy completion signal
 - `activityIdentifier` names the selected activity when the platform reports one
 - `error` carries platform failures that occurred while completing the selected activity
 */
struct ShareSheetCompletion {
    /// Whether the user completed a share/copy destination rather than cancelling the surface.
    let completed: Bool

    /// Platform activity identifier when provided by the native share controller.
    let activityIdentifier: String?

    /// Platform error returned by the native share controller.
    let error: Error?
}

#if os(iOS)
/**
 Wraps `UIActivityViewController` for SwiftUI presentations on iOS.

 Data dependencies:
 - `items` supplies the activity items passed through to the system share sheet
 - `onCompletion` receives UIKit's completion result mapped into a platform-neutral value

 Side effects:
 - presents the system activity controller
 - invokes `onCompletion` after the selected activity completes, fails, or is cancelled
 */
struct ShareSheet: UIViewControllerRepresentable {
    /// Items to expose through the native share sheet.
    let items: [Any]

    /// Callback invoked with the native share result.
    let onCompletion: (ShareSheetCompletion) -> Void

    /**
     Creates an iOS share sheet wrapper.

     - Parameters:
       - items: Activity items passed to `UIActivityViewController`.
       - onCompletion: Callback for success, cancellation, or activity error results.
     - Side effects: none until SwiftUI asks the wrapper to create its UIKit controller.
     - Failure modes: Creation itself cannot fail; UIKit activity failures are reported later through
       `onCompletion`.
     */
    init(
        items: [Any],
        onCompletion: @escaping (ShareSheetCompletion) -> Void = { _ in }
    ) {
        self.items = items
        self.onCompletion = onCompletion
    }

    /**
     Creates the UIKit share-sheet controller.

     - Parameter context: SwiftUI context for the representable lifecycle.
     - Returns: Configured `UIActivityViewController` presenting the supplied share items.
     */
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let viewController = UIActivityViewController(activityItems: items, applicationActivities: nil)
        viewController.completionWithItemsHandler = { activityType, completed, _, error in
            onCompletion(
                ShareSheetCompletion(
                    completed: completed,
                    activityIdentifier: activityType?.rawValue,
                    error: error
                )
            )
        }
        return viewController
    }

    /**
     Updates the share-sheet controller after creation.

     - Parameters:
       - uiViewController: Previously created activity controller.
       - context: SwiftUI context for the representable lifecycle.
     - Note: The controller has no incremental update path after creation.
     */
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#elseif os(macOS)
/**
 Provides a simple SwiftUI share fallback on macOS.

 The macOS implementation does not currently bridge `NSSharingServicePicker`; instead it exposes
 the first share item as text and provides a copy-to-clipboard action.

 Data dependencies:
 - `items` provides the share payload, with the first string item used for display and clipboard
   copying
 - `onCompletion` receives a successful copy result when the user taps Copy to Clipboard

 Side effects:
 - tapping the copy button writes the first string item to the general pasteboard
 - tapping the copy button invokes `onCompletion` after the pasteboard write
 */
struct ShareSheet: View {
    /// Items supplied for sharing.
    let items: [Any]

    /// Callback invoked after the macOS fallback completes its copy action.
    let onCompletion: (ShareSheetCompletion) -> Void

    /**
     Creates the macOS fallback share view.

     - Parameters:
       - items: Values exposed by the fallback, with the first string displayed and copied.
       - onCompletion: Callback invoked after Copy to Clipboard succeeds.
     - Side effects: none until the user taps Copy to Clipboard.
     - Failure modes: The fallback does not currently surface pasteboard write errors.
     */
    init(
        items: [Any],
        onCompletion: @escaping (ShareSheetCompletion) -> Void = { _ in }
    ) {
        self.items = items
        self.onCompletion = onCompletion
    }

    /**
     Builds the macOS share fallback view.
     */
    var body: some View {
        VStack(spacing: 12) {
            Text(String(localized: "share", defaultValue: "Share"))
                .font(.headline)
            if let text = items.first as? String {
                Text(text)
                    .font(.body)
                    .padding()
                    .textSelection(.enabled)
            }
            Button(String(localized: "copy", defaultValue: "Copy")) {
                if let text = items.first as? String {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    onCompletion(
                        ShareSheetCompletion(
                            completed: true,
                            activityIdentifier: "copyToClipboard",
                            error: nil
                        )
                    )
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(minWidth: 300)
    }
}
#endif
