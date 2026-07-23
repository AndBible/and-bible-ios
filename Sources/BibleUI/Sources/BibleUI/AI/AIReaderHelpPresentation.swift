// AIReaderHelpPresentation.swift -- Native reader help dialogs for bridge requests

import Foundation
import SwiftUI

/** Localized or bridge-supplied text displayed by a native reader help dialog. */
enum AIReaderHelpText: Equatable, Sendable {
    /// A localization key shared with Android.
    case localized(String)
    /// HTML supplied by the trusted bundled BibleView client.
    case html(String)

    /** Resolves display text without introducing an English-only fallback. */
    var localizedValue: String {
        switch self {
        case .localized(let key):
            return String(localized: String.LocalizationValue(key))
        case .html(let value):
            return value
        }
    }
}

/** One tappable link rendered as part of a native reader help dialog. */
struct AIReaderHelpLink: Equatable, Sendable {
    /// Android localization key used as the visible link label.
    let labelKey: String
    /// Allowlisted destination opened by the platform URL handler.
    let destination: URL
    /// Whether Android renders this link with italic emphasis.
    let isItalic: Bool
}

/** Complete semantic content for a reader help dialog. */
struct AIReaderHelpPresentation: Identifiable, Equatable, Sendable {
    /// Localized or explicit dialog title.
    let title: AIReaderHelpText
    /// Optional leading tutorial link.
    let tutorialLink: AIReaderHelpLink?
    /// Optional localized line rendered with Android's bold emphasis.
    let emphasizedTextKey: String?
    /// Main localized or HTML dialog body.
    let body: AIReaderHelpText
    /// Optional trailing documentation link.
    let documentationLink: AIReaderHelpLink?

    /// Stable identity used by SwiftUI item presentation.
    var id: String {
        [
            title.localizedValue,
            tutorialLink?.destination.absoluteString ?? "",
            emphasizedTextKey ?? "",
            body.localizedValue,
            documentationLink?.destination.absoluteString ?? "",
        ].joined(separator: "\u{1f}")
    }
}

/** Android-parity help contracts accepted from the bundled BibleView bridge. */
enum AIReaderHelpCatalog {
    /// Exact tutorial playlist used by Android's `helpBookmarks()` dialog.
    static let bookmarkTutorialURL = URL(
        string: "https://www.youtube.com/playlist?list=PLD-W_Iw-N2MlzNt0Zpna-QoTBpEpWSden"
    )

    /// Exact documentation destination used by Android's Memorize help scope.
    static let memorizeDocumentationURL = URL(
        string: "https://docs.andbible.org/en/latest/memorize.html"
    )

    /** Builds Android's localized Bookmarks and My Notes help dialog. */
    static func bookmarks() -> AIReaderHelpPresentation? {
        guard let bookmarkTutorialURL else { return nil }
        return AIReaderHelpPresentation(
            title: .localized("bookmarks_and_mynotes_title"),
            tutorialLink: AIReaderHelpLink(
                labelKey: "watch_tutorial_video",
                destination: bookmarkTutorialURL,
                isItalic: true
            ),
            emphasizedTextKey: "verse_tip",
            body: .localized("help_bookmarks_text"),
            documentationLink: nil
        )
    }

    /** Builds the only allowlisted scoped help request exposed by Android's bridge. */
    static func memorize() -> AIReaderHelpPresentation? {
        guard let memorizeDocumentationURL else { return nil }
        return AIReaderHelpPresentation(
            title: .localized("help"),
            tutorialLink: nil,
            emphasizedTextKey: nil,
            body: .localized("help_memorize_text"),
            documentationLink: AIReaderHelpLink(
                labelKey: "help_read_more_link",
                destination: memorizeDocumentationURL,
                isItalic: true
            )
        )
    }

    /** Wraps trusted generic BibleView help HTML in the same native presentation path. */
    static func generic(content: String, title: String?) -> AIReaderHelpPresentation {
        AIReaderHelpPresentation(
            title: title.map(AIReaderHelpText.html) ?? .localized("help"),
            tutorialLink: nil,
            emphasizedTextKey: nil,
            body: .html(content),
            documentationLink: nil
        )
    }
}

/** Native, scrollable reader dialog that preserves Android help emphasis and tappable links. */
struct AIReaderHelpDialog: View {
    /// Current appearance used by the globally managed Android dialog palette.
    @Environment(\.colorScheme) private var colorScheme

    /// Semantic help content selected by the bridge route.
    let presentation: AIReaderHelpPresentation

    /// Closes the app-owned Android-style dialog.
    let onDismiss: () -> Void

    /** Renders title, links, emphasis, and body in Android's vertical content order. */
    var body: some View {
        AndroidDialogWindow(
            colorScheme: colorScheme,
            accessibilityIdentifier: "androidAIReaderHelpDialog",
            onOutsideTap: onDismiss
        ) {
            AndroidDialogScaffold(title: presentation.title.localizedValue) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let tutorialLink = presentation.tutorialLink {
                            helpLink(tutorialLink)
                        }
                        if let emphasizedTextKey = presentation.emphasizedTextKey {
                            Text(String(localized: String.LocalizationValue(emphasizedTextKey)))
                                .bold()
                        }
                        helpText(presentation.body)
                        if let documentationLink = presentation.documentationLink {
                            helpLink(documentationLink)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 8)
            } actions: {
                AndroidDialogTextAction(
                    title: String(localized: "okay", defaultValue: "OK"),
                    action: onDismiss
                )
            }
        }
    }

    /** Renders one allowlisted URL with its shared localized label. */
    @ViewBuilder
    private func helpLink(_ link: AIReaderHelpLink) -> some View {
        let label = Text(String(localized: String.LocalizationValue(link.labelKey)))
        Link(destination: link.destination) {
            if link.isItalic {
                label.italic()
            } else {
                label
            }
        }
    }

    /** Renders localized content or trusted generic HTML using native attributed text. */
    @ViewBuilder
    private func helpText(_ text: AIReaderHelpText) -> some View {
        switch text {
        case .localized:
            Text(text.localizedValue)
        case .html(let html):
            if let attributed = attributedHTML(html) {
                Text(attributed)
            } else {
                Text(html)
            }
        }
    }

    /** Converts bundled BibleView help HTML to native attributed text with active links. */
    private func attributedHTML(_ html: String) -> AttributedString? {
        guard let data = html.data(using: .utf8),
              let value = try? NSAttributedString(
                  data: data,
                  options: [
                      .documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue,
                  ],
                  documentAttributes: nil
              ) else {
            return nil
        }
        return AttributedString(value)
    }
}
