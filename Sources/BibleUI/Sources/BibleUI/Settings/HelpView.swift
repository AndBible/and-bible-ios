// HelpView.swift — Help & Tips screen with quick-start sections

import SwiftUI

/**
 Displays the built-in help and tips content mirrored from Android's quick-start guidance.

 The screen is a read-only collection of localized help sections covering navigation, selection,
 bookmarks, StudyPads, search, workspaces, and discrete-mode affordances.

 Data dependencies:
 - localized string resources provide the section titles and body copy
 - `Bundle.main` provides the footer version string when available
 */
struct HelpView: View {
    /**
     Builds the stacked help sections and optional version footer.
     */
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

                Text(AndBibleAppVersionMetadata.current().helpFooterText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding()
        }
        .navigationTitle(String(localized: "help_tips"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /**
     Builds one help section with a localized title and explanatory body text.

     - Parameters:
       - title: Section heading displayed in headline styling.
       - body: Localized explanatory copy shown beneath the heading.
     - Returns: A vertical stack containing the formatted help section.
     */
    private func helpSection(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(body)
                .foregroundStyle(.secondary)
        }
    }
}
