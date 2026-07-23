import SwiftUI

/**
 Renders Android's Open Source License dialog from the bundled GPL text.

 Android reads its `raw/license` file into an app-owned dialog. This view reads the equivalent
 BibleUI resource, retains text selection for links and copying, and has no browser dependency.
 */
struct AndroidLicenseDialog: View {
    /// Current appearance used by the globally managed Android dialog palette.
    @Environment(\.colorScheme) private var colorScheme

    let onDismiss: () -> Void

    /** Complete GPL text bundled with BibleUI, with a localized recovery message if it is absent. */
    private var licenseText: String {
        guard let url = Bundle.module.url(forResource: "LICENSE", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return String(
                localized: "app_licence_unavailable",
                defaultValue: "The Open Source License text is unavailable."
            )
        }
        return text
    }

    var body: some View {
        AndroidDialogWindow(
            colorScheme: colorScheme,
            accessibilityIdentifier: "androidLicenseDialog",
            onOutsideTap: onDismiss
        ) {
            AndroidDialogScaffold(
                title: String(localized: "app_licence_title", defaultValue: "Open Source License")
            ) {
                ScrollView {
                    Text(licenseText)
                        .font(.footnote.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 8)
                }
            } actions: {
                AndroidDialogTextAction(
                    title: String(localized: "ok", defaultValue: "OK"),
                    action: onDismiss
                )
            }
        }
    }
}
