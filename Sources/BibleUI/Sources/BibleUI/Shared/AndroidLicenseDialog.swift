import SwiftUI

/**
 Renders Android's Open Source License dialog from the bundled GPL text.

 Android reads its `raw/license` file into an app-owned dialog. This view reads the equivalent
 BibleUI resource, retains text selection for links and copying, and has no browser dependency.
 */
struct AndroidLicenseDialog: View {
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
        ZStack {
            Color.black.opacity(0.36)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 0) {
                Text(String(localized: "app_licence_title", defaultValue: "Open Source License"))
                    .font(.headline)
                    .padding()

                Divider()

                ScrollView {
                    Text(licenseText)
                        .font(.footnote.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding()
                }

                Divider()

                Button(String(localized: "ok", defaultValue: "OK"), action: onDismiss)
                    .padding()
            }
            .frame(maxWidth: 680, maxHeight: 720)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 16)
            .padding(24)
        }
        .accessibilityIdentifier("androidLicenseDialog")
    }
}
