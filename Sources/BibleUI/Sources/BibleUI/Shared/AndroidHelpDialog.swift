// AndroidHelpDialog.swift -- Canonical app-owned Android Help dialog

import SwiftUI

/**
 Renders Android `CommonUtils.showHelp` through the shared AlertDialog content hierarchy.

 Android uses `AlertDialog.Builder.setTitle`, `setIcon`, `setMessage`, and `setPositiveButton` for
 both full and topic-filtered Help. Keeping that composition in one content view prevents feature
 callers from rebuilding title chrome, message spacing, or action placement.

 Inputs: ordered Help topics, version-footer policy, and owner dismissal callback

 Output: intrinsic-height AlertDialog title, adaptive message, and positive action regions

 Side effects: opens selected Help links or invokes `onDismiss`

 Failure modes: none
 */
struct AndroidFullHelpDialogContent: View {
    /// Canonical topic subset displayed in Android order.
    let topics: [AndroidHelpTopic]

    /// Whether Android's optional version footer is included.
    let showsVersion: Bool

    /// Owner-controlled positive-action dismissal.
    let onDismiss: () -> Void

    var body: some View {
        AndroidDialogScaffold(
            title: String(localized: "help", defaultValue: "Help"),
            titleIcon: Image("DrawerLogo", bundle: .module)
        ) {
            HelpView(topics: topics, showsVersion: showsVersion)
                .padding(.horizontal, 22)
                .padding(.vertical, 8)
        } actions: {
            AndroidDialogTextAction(
                title: String(localized: "okay", defaultValue: "OK"),
                accessibilityIdentifier: "androidHelpDialogOKButton",
                action: onDismiss
            )
        }
    }
}

/**
 Presents canonical `HelpView` content in the shared Android dialog window.

 Android's main Help command and filtered feature Help commands call the same content builder with
 different topic filters. This wrapper mirrors that contract while keeping presentation app-owned,
 palette-driven, and independent of iOS navigation or sheet chrome.

 Inputs: ordered topics, version-footer policy, and dismissal callback

 Output: one centered Android AlertDialog with its title icon, adaptive message, and positive action

 Side effects: dismisses after an outside tap or explicit OK action and opens user-selected links

 Failure modes: none
 */
struct AndroidHelpDialog: View {
    /// Canonical topic subset to display.
    let topics: [AndroidHelpTopic]

    /// Whether the Android version footer is shown.
    let showsVersion: Bool

    /// Owner dismissal callback.
    let onDismiss: () -> Void

    /// Active scheme used by shared dialog colors.
    @Environment(\.colorScheme) private var colorScheme

    /**
     Creates an Android Help dialog.

     - Parameters:
       - topics: Ordered topic subset; defaults to Android's complete Help catalog.
       - showsVersion: Version-footer policy; defaults to Android main Help behavior.
       - onDismiss: Callback for outside-tap or positive-action dismissal.
     - Side effects: none until a user action occurs.
     - Failure modes: none.
     */
    init(
        topics: [AndroidHelpTopic] = AndroidHelpTopic.allCases,
        showsVersion: Bool = true,
        onDismiss: @escaping () -> Void
    ) {
        self.topics = topics
        self.showsVersion = showsVersion
        self.onDismiss = onDismiss
    }

    var body: some View {
        AndroidDialogWindow(
            colorScheme: colorScheme,
            accessibilityIdentifier: "androidHelpDialog",
            onOutsideTap: onDismiss
        ) {
            AndroidFullHelpDialogContent(
                topics: topics,
                showsVersion: showsVersion,
                onDismiss: onDismiss
            )
        }
    }
}
