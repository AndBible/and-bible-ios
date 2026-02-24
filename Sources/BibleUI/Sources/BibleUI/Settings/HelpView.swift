// HelpView.swift — Help & Tips screen with quick-start sections

import SwiftUI

/// Displays help sections matching Android's CommonUtils.showHelp().
struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                helpSection(
                    title: String(localized: "help_navigation"),
                    body: String(localized: "help_navigation_body")
                )
                helpSection(
                    title: String(localized: "help_selection"),
                    body: String(localized: "help_selection_body")
                )
                helpSection(
                    title: String(localized: "help_pinning"),
                    body: String(localized: "help_pinning_body")
                )
                helpSection(
                    title: String(localized: "help_bookmarks"),
                    body: String(localized: "help_bookmarks_body")
                )
                helpSection(
                    title: String(localized: "help_studypads"),
                    body: String(localized: "help_studypads_body")
                )
                helpSection(
                    title: String(localized: "help_search"),
                    body: String(localized: "help_search_body")
                )
                helpSection(
                    title: String(localized: "help_workspaces"),
                    body: String(localized: "help_workspaces_body")
                )
                helpSection(
                    title: String(localized: "help_hidden"),
                    body: String(localized: "help_hidden_body")
                )

                Divider()

                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                    Text("AndBible v\(version)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding()
        }
        .navigationTitle(String(localized: "help_tips"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func helpSection(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(body)
                .foregroundStyle(.secondary)
        }
    }
}
