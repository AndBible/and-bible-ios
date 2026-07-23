// HelpView.swift -- Canonical Android Help & Tips content

import SwiftUI

/**
 Identifies the canonical help topics and links defined by Android `CommonUtils.showHelp`.

 The enum is the shared semantic owner for the full reader Help dialog and feature-filtered dialogs
 such as Study Pads. Localized text remains in Android-aligned string resources; URLs mirror the
 Android playlists and documentation paths.
 */
enum AndroidHelpTopic: CaseIterable, Hashable {
    case navigation
    case contextMenus
    case windowPinning
    case bookmarks
    case studyPads
    case search
    case workspaces
    case hiddenShortcuts

    /// Localized Android section title.
    var localizedTitle: String {
        switch self {
        case .navigation:
            String(localized: "help_nav_title", defaultValue: "Navigation")
        case .contextMenus:
            String(localized: "help_contextmenus_title", defaultValue: "Context Menus")
        case .windowPinning:
            String(localized: "help_window_pinning_title", defaultValue: "Window pinning")
        case .bookmarks:
            String(localized: "help_bookmarks_title", defaultValue: "Bookmarks & My Notes")
        case .studyPads:
            String(localized: "studypads", defaultValue: "Study Pads")
        case .search:
            String(localized: "help_search_title", defaultValue: "Search")
        case .workspaces:
            String(localized: "help_workspaces_title", defaultValue: "Workspaces")
        case .hiddenShortcuts:
            String(localized: "help_hidden_features_title", defaultValue: "Hidden shortcuts")
        }
    }

    /// Localized Android section body.
    var localizedBody: String {
        switch self {
        case .navigation:
            String(localized: "help_nav_text")
        case .contextMenus:
            String(localized: "help_contextmenus_text")
        case .windowPinning:
            String(localized: "help_window_pinning_text")
        case .bookmarks:
            String(localized: "help_bookmarks_text")
        case .studyPads:
            String(localized: "help_studypads_text")
        case .search:
            String(localized: "help_search_text2")
        case .workspaces:
            String(localized: "help_workspaces_text")
        case .hiddenShortcuts:
            String(localized: "help_hidden_features_text")
        }
    }

    /// Android tutorial playlist for topics that expose one.
    var tutorialURL: URL? {
        switch self {
        case .windowPinning, .workspaces:
            URL(string: "https://www.youtube.com/playlist?list=PLD-W_Iw-N2Mmiq_X6G-vDhoAIq9sDnrIQ")
        case .bookmarks:
            URL(string: "https://www.youtube.com/playlist?list=PLD-W_Iw-N2MlzNt0Zpna-QoTBpEpWSden")
        case .studyPads:
            URL(string: "https://www.youtube.com/playlist?list=PLD-W_Iw-N2MkMiGz7cjGASOYjElr1Q76m")
        case .navigation, .contextMenus, .search, .hiddenShortcuts:
            nil
        }
    }

    /// Android documentation page for topics that expose one.
    var documentationURL: URL? {
        let path: String?
        switch self {
        case .navigation: path = "navigation.html"
        case .windowPinning: path = "windows.html"
        case .bookmarks: path = "bookmarks.html"
        case .studyPads: path = "study_pads.html"
        case .search: path = "search.html"
        case .workspaces: path = "workspaces.html"
        case .contextMenus, .hiddenShortcuts: path = nil
        }
        return path.flatMap { URL(string: "https://docs.andbible.org/en/latest/\($0)") }
    }
}

/**
 Displays the canonical content portion of Android's Help dialog.

 The view is presentation-neutral: an app-owned dialog or full route supplies outer chrome, while
 this content owns topic order, localized copy, tutorial/manual links, project support, and optional
 version text. Filtered feature help and complete reader help therefore cannot drift into parallel
 content implementations.

 Inputs:
 - ordered Android help topics
 - whether Android's version footer is included

 Output: scrollable, AppCompat-palette help content

 Side effects: opens explicit tutorial, documentation, and support links after user taps

 Failure modes: topics whose canonical Android URL is absent simply omit that link
 */
struct HelpView: View {
    /// Android help topics rendered in caller-supplied order.
    let topics: [AndroidHelpTopic]

    /// Whether to include Android's version footer.
    let showsVersion: Bool

    /// Active scheme used by the shared AppCompat dialog palette.
    @Environment(\.colorScheme) private var colorScheme

    /**
     Creates canonical Android help content.

     - Parameters:
       - topics: Ordered subset of `AndroidHelpTopic`; defaults to Android's complete catalog.
       - showsVersion: Whether the footer is present; Android's main Help passes true and filtered
         feature help passes false.
     - Side effects: none until a link is tapped.
     - Failure modes: none.
     */
    init(topics: [AndroidHelpTopic] = AndroidHelpTopic.allCases, showsVersion: Bool = true) {
        self.topics = topics
        self.showsVersion = showsVersion
    }

    var body: some View {
        AndroidAdaptiveDialogScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(topics, id: \.self) { topic in
                    helpSection(topic)
                }

                AndroidDialogLink(
                    String(localized: "help_full_documentation_link", defaultValue: "Browse the full documentation"),
                    destination: URL(string: "https://docs.andbible.org/en/latest/")!
                )
                .font(.system(size: 17))

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    AndBibleIconView(name: "DrawerSponsorDevelopment", size: 20)
                        .foregroundStyle(AndroidDialogSurfacePalette.secondaryText(for: colorScheme))
                        .accessibilityHidden(true)
                    Text(String(localized: "buy_development2", defaultValue: "Support project") + ":")
                        .fontWeight(.semibold)
                    AndroidDialogLink(
                        String(localized: "buy_development", defaultValue: "Sponsor app development"),
                        destination: URL(string: "https://shop.andbible.org")!
                    )
                }
                .font(.system(size: 17))

                if showsVersion {
                    Text(AndBibleAppVersionMetadata.current().helpFooterText)
                        .font(.footnote.italic())
                        .foregroundStyle(AndroidDialogSurfacePalette.secondaryText(for: colorScheme))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .foregroundStyle(AndroidDialogSurfacePalette.primaryText(for: colorScheme))
        .tint(AndroidDialogSurfacePalette.accent(for: colorScheme))
    }

    /**
     Builds one Android help topic and its optional tutorial/manual links.

     - Parameter topic: Canonical topic whose localized copy and links should render.
     - Returns: One vertically stacked help section.
     - Side effects: none until a link is tapped.
     - Failure modes: Missing optional URLs omit only their corresponding link.
     */
    private func helpSection(_ topic: AndroidHelpTopic) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(topic.localizedTitle)
                .font(.system(size: 18, weight: .bold))

            Text(topic.localizedBody)
                .font(.system(size: 17))
                .fixedSize(horizontal: false, vertical: true)

            if topic.tutorialURL != nil || topic.documentationURL != nil {
                VStack(alignment: .leading, spacing: 5) {
                    if let tutorialURL = topic.tutorialURL {
                        AndroidDialogLink(
                            "• " + String(localized: "watch_tutorial_video", defaultValue: "Watch tutorial video (English)"),
                            destination: tutorialURL,
                            isItalic: true
                        )
                    }
                    if let documentationURL = topic.documentationURL {
                        AndroidDialogLink(
                            "• " + String(localized: "help_read_more_link", defaultValue: "Read more in the manual"),
                            destination: documentationURL,
                            isItalic: true
                        )
                    }
                }
                .font(.system(size: 17))
                .padding(.top, 5)
            }
        }
    }
}
