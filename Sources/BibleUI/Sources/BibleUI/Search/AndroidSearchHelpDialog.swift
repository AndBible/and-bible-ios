// AndroidSearchHelpDialog.swift -- Shared Android search-syntax AlertDialog content

import Foundation
import SwiftUI

/** Search-engine documentation linked by Android's two search criteria activities. */
enum AndroidSearchHelpDocumentation {
    /// Bible/module Search uses Android's pinned Apache Lucene syntax link.
    case lucene

    /// EPUB Search uses Android's pinned SQLite FTS5 syntax link.
    case sqliteFTS5

    /// Exact localized Android resource label for the selected documentation.
    var localizedTitle: String {
        switch self {
        case .lucene:
            return String(
                localized: "help_apache_lucene",
                defaultValue: "Apache Lucene query syntax"
            )
        case .sqliteFTS5:
            return String(
                localized: "help_fts5",
                defaultValue: "FTS5 Full-text Query Syntax"
            )
        }
    }

    /// Exact URL used by the corresponding Android activity.
    var urlString: String {
        switch self {
        case .lucene:
            return "https://lucene.apache.org/core/2_9_4/queryparsersyntax.html"
        case .sqliteFTS5:
            return "https://www.sqlite.org/fts5.html#full_text_query_syntax"
        }
    }
}

/**
 Presents the exact feature help shared by Android Search and EPUB Search.

 Neither activity opens the application's general Help catalog. Both show the current activity
 title, app logo, special-query syntax summary, and their engine-specific documentation link in one
 AlertDialog. This view reuses the shared dialog window/scaffold and global AppCompat palette while
 preserving the distinct Lucene and FTS5 destinations from Android source.

 Inputs: current localized activity title, engine documentation contract, stable identifier prefix,
 and dismissal callback

 Output: one centered, app-owned Search help dialog

 Side effects: outside/OK dismisses through `onDismiss`; the documentation link opens through the
 platform URL environment

 Failure modes: if the OS cannot open the HTTPS link, the dialog remains visible and no Search
 state changes
 */
struct AndroidSearchHelpDialog: View {
    /// Current Android Search activity title, including the primary document abbreviation.
    let title: String

    /// Android source-specific query syntax destination.
    let documentation: AndroidSearchHelpDocumentation

    /// Stable prefix allowing Search and EPUB Search dialogs to coexist in UI automation.
    let accessibilityPrefix: String

    /// Owner-controlled dismissal callback.
    let onDismiss: () -> Void

    /// Active appearance used exclusively by the shared dialog palette.
    @Environment(\.colorScheme) private var colorScheme

    /**
     Creates one shared Android search-syntax dialog.

     - Parameters:
       - title: Current localized activity title.
       - documentation: Exact Android documentation destination; defaults to module Search Lucene.
       - accessibilityPrefix: Stable automation prefix; defaults to module Search.
       - onDismiss: Owner-controlled outside-tap and OK command.
     - Side effects: None until the user dismisses or follows the link.
     - Failure modes: None during initialization.
     */
    init(
        title: String,
        documentation: AndroidSearchHelpDocumentation = .lucene,
        accessibilityPrefix: String = "search",
        onDismiss: @escaping () -> Void
    ) {
        self.title = title
        self.documentation = documentation
        self.accessibilityPrefix = accessibilityPrefix
        self.onDismiss = onDismiss
    }

    var body: some View {
        AndroidDialogWindow(
            colorScheme: colorScheme,
            accessibilityIdentifier: "\(accessibilityPrefix)HelpDialog",
            onOutsideTap: onDismiss
        ) {
            AndroidDialogScaffold(title: title) {
                AndroidAdaptiveDialogScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top, spacing: 14) {
                            Image("DrawerLogo", bundle: .module)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 42, height: 42)
                                .accessibilityHidden(true)

                            Text(String(
                                localized: "help_search_text2",
                                defaultValue: "Search text can include special characters like *, AND, OR, NOT"
                            ))
                            .font(.system(size: 16))
                            .fixedSize(horizontal: false, vertical: true)
                        }

                        Text(searchDetailsText)
                            .font(.system(size: 16))
                            .foregroundStyle(AndroidDialogSurfacePalette.primaryText(for: colorScheme))
                            .tint(AndroidDialogSurfacePalette.accent(for: colorScheme))
                            .accessibilityIdentifier("\(accessibilityPrefix)HelpDocumentationLink")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 12)
                }
            } actions: {
                AndroidDialogTextAction(
                    title: String(localized: "okay", defaultValue: "OK"),
                    accessibilityIdentifier: "\(accessibilityPrefix)HelpOKButton",
                    action: onDismiss
                )
            }
        }
    }

    /**
     Substitutes Android's localized `%s` link variable without losing its locale-specific position.

     - Returns: A Markdown-backed attributed sentence whose selected engine label is clickable.
     - Side effects: none; URL opening occurs only after the rendered link is tapped.
     - Failure modes: Markdown parsing failure falls back to the same localized sentence as plain
       text, retaining content even if link interaction is unavailable.
     */
    private var searchDetailsText: AttributedString {
        let linkLabel = documentation.localizedTitle
        let linkedLabel = "[\(linkLabel)](\(documentation.urlString))"
        let format = String(
            localized: "help_search_details",
            defaultValue: "Please see %@ for more details."
        )
        let markdown = String(format: format, locale: .current, linkedLabel)
        return (try? AttributedString(markdown: markdown)) ?? AttributedString(
            String(format: format, locale: .current, linkLabel)
        )
    }
}
