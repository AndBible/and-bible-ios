// AndroidHelpDialog.swift -- Canonical app-owned Android Help dialog

import SwiftUI

/**
 Presents canonical `HelpView` content in the shared Android dialog window.

 Android's main Help command and filtered feature Help commands call the same content builder with
 different topic filters. This wrapper mirrors that contract while keeping presentation app-owned,
 palette-driven, and independent of iOS navigation or sheet chrome.

 Inputs: ordered topics, version-footer policy, and dismissal callback

 Output: one centered Android Help dialog with logo, scrollable content, and positive action

 Side effects: dismisses after an outside tap or explicit OK action and opens user-selected links

 Failure modes: none
 */
struct AndroidHelpDialog: View {
    /// Canonical topic subset to display.
    let topics: [AndroidHelpTopic]

    /// Optional Android feature-help message; mutually exclusive with topic content.
    let featureMessage: String?

    /// Exact Android feature manual destination.
    let featureDocumentationURL: URL?

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
        featureMessage = nil
        featureDocumentationURL = nil
        self.showsVersion = showsVersion
        self.onDismiss = onDismiss
    }

    /**
     Creates Android's feature-filtered Help dialog from the same shared surface and footer as the
     full Help catalog.

     - Parameters:
       - featureMessage: Localized feature explanation from Android resources.
       - documentationURL: Exact public manual URL corresponding to Android's `helpPath`.
       - onDismiss: Callback for outside-tap or positive-action dismissal.
     - Side effects: none until the user follows a link or dismisses.
     - Failure modes: a nil URL omits only the feature-specific manual link.
     */
    init(
        featureMessage: String,
        documentationURL: URL?,
        onDismiss: @escaping () -> Void
    ) {
        topics = []
        self.featureMessage = featureMessage
        featureDocumentationURL = documentationURL
        showsVersion = false
        self.onDismiss = onDismiss
    }

    var body: some View {
        AndroidDialogWindow(
            colorScheme: colorScheme,
            accessibilityIdentifier: "androidHelpDialog",
            onOutsideTap: onDismiss
        ) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image("DrawerLogo", bundle: .module)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 42, height: 42)
                    Text(String(localized: "help", defaultValue: "Help"))
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(AndroidDialogSurfacePalette.primaryText(for: colorScheme))
                }

                if let featureMessage {
                    HelpView(
                        featureMessage: featureMessage,
                        documentationURL: featureDocumentationURL,
                        showsVersion: showsVersion
                    )
                } else {
                    HelpView(topics: topics, showsVersion: showsVersion)
                }

                HStack {
                    Spacer()
                    Button(String(localized: "okay", defaultValue: "OK"), action: onDismiss)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AndroidDialogSurfacePalette.accent(for: colorScheme))
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("androidHelpDialogOKButton")
                }
            }
            .padding(24)
        }
    }
}
