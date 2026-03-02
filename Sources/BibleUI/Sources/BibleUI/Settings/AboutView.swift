// AboutView.swift — About screen with app info, credits, and links

import SwiftUI

/// Shows app version, credits, and links to project resources.
public struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // App icon and name
                VStack(spacing: 12) {
                    appIcon

                    Text("AndBible")
                        .font(.title.bold())

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
        .navigationTitle(String(localized: "about"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

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
