// AboutView.swift — About screen with app info, credits, and links

import SwiftUI

/**
 Shows application identity, credits, and external project-resource links.

 The screen is a lightweight informational destination from settings. It resolves version metadata
 from the main bundle, renders the platform-specific app icon, and exposes project links such as
 the website, source repository, privacy policy, and license.

 Data dependencies:
 - `Bundle.main` provides app-version and build metadata
 - platform APIs provide the current app icon and browser handoff for external links

 Side effects:
 - tapping a link row opens the corresponding external URL through the host platform
 */
public struct AboutView: View {
    /// Dismiss action inherited from the surrounding navigation presentation.
    @Environment(\.dismiss) private var dismiss

    /// Human-readable marketing version shown beneath the app title.
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    /// Internal build number shown alongside the marketing version.
    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    /**
     Creates the about screen with bundle-backed metadata lookup.

     - Note: The view reads its version data lazily from `Bundle.main`.
     */
    public init() {}

    /**
     Builds the about screen content, including version metadata, credits, and external links.
     */
    public var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // App icon and name
                VStack(spacing: 12) {
                    appIcon

                    Text("AndBible")
                        .font(.title.bold())
                        .accessibilityIdentifier("aboutAppTitle")

                    Text(String(localized: "version \(appVersion) (\(buildNumber))"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 20)

                // Credits
                VStack(spacing: 8) {
                    Text(String(localized: "about_description"))
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)

                    Text(String(localized: "about_sword_credit"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal)

                Divider()

                // Links
                VStack(spacing: 0) {
                    linkRow(
                        title: String(localized: "about_website"),
                        icon: "globe",
                        url: "https://andbible.org"
                    )
                    Divider().padding(.leading, 44)
                    linkRow(
                        title: String(localized: "about_source_code"),
                        icon: "chevron.left.forwardslash.chevron.right",
                        url: "https://github.com/AndBible/and-bible"
                    )
                    Divider().padding(.leading, 44)
                    linkRow(
                        title: String(localized: "about_privacy_policy"),
                        icon: "hand.raised",
                        url: "https://andbible.org/privacy"
                    )
                    Divider().padding(.leading, 44)
                    linkRow(
                        title: String(localized: "about_license"),
                        icon: "doc.text",
                        url: "https://www.gnu.org/licenses/gpl-3.0.html"
                    )
                }

                Spacer(minLength: 40)
            }
        }
        .accessibilityIdentifier("aboutScreen")
        .navigationTitle(String(localized: "about"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /**
     Builds the current platform app-icon view used at the top of the about screen.
     */
    @ViewBuilder
    private var appIcon: some View {
        #if os(iOS)
        if let uiImage = UIImage(named: "AppIcon") {
            Image(uiImage: uiImage)
                .resizable()
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 18))
        } else {
            Image(systemName: "book.fill")
                .font(.system(size: 60))
                .foregroundStyle(.tint)
        }
        #elseif os(macOS)
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .frame(width: 80, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 18))
        #endif
    }

    /**
     Builds one tappable resource row that opens an external URL.

     - Parameters:
       - title: Localized row title shown to the user.
       - icon: SF Symbol name used for the row icon.
       - url: Absolute URL string to open when the row is tapped.
     - Returns: A plain button row that opens the resolved external URL when valid.

     Side effects:
     - opens the provided URL through `UIApplication` on iOS or `NSWorkspace` on macOS

     Failure modes:
     - returns without side effects if `url` cannot be parsed into a valid `URL`
     */
    private func linkRow(title: String, icon: String, url: String) -> some View {
        Button {
            guard let link = URL(string: url) else { return }
            #if os(iOS)
            UIApplication.shared.open(link)
            #elseif os(macOS)
            NSWorkspace.shared.open(link)
            #endif
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .frame(width: 24)
                    .foregroundStyle(.tint)
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }
}
