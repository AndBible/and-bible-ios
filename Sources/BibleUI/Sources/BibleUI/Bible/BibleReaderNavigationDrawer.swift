import SwiftUI

/// User actions emitted by the Android-style reader navigation drawer.
enum BibleReaderNavigationDrawerAction {
    case chooseDocument
    case search
    case speak
    case bookmarks
    case studyPads
    case myNotes
    case readingPlans
    case readingProgress
    case history
    case downloads
    case importExport
    case syncSettings
    case aiSettings
    case settings
    case help
    case sponsorDevelopment
    case needHelp
    case contribute
    case appLicense
    case tellFriend
    case rateApp
    case reportBug
}

/**
 Android's ordered Administration drawer rows.

 Case declaration order matches `main_bible_drawer_menu.xml` and directly drives SwiftUI rendering,
 allowing tests to protect placement without maintaining a second presentation-only list.
 */
enum BibleReaderAdministrationDrawerItem: CaseIterable, Hashable {
    case downloads
    case importExport
    case syncSettings
    case aiSettings
    case settings

    /// Android localization key used as the row title.
    var titleKey: String {
        switch self {
        case .downloads: return "download"
        case .importExport: return "backup_and_restore"
        case .syncSettings: return "cloud_sync_title"
        case .aiSettings: return "ai_settings"
        case .settings: return "application_preferences"
        }
    }

    /// English fallback used only when the Android key is unavailable.
    var defaultTitle: String {
        switch self {
        case .downloads: return "Download Documents"
        case .importExport: return "Backup & Restore"
        case .syncSettings: return "Device synchronization"
        case .aiSettings: return "AI Settings"
        case .settings: return "Application preferences"
        }
    }

    /// Bundled icon asset associated with the Android row.
    var iconAssetName: String {
        switch self {
        case .downloads: return "DrawerDownloads"
        case .importExport: return "DrawerBackupRestore"
        case .syncSettings: return "DrawerSync"
        case .aiSettings: return "SettingsIconRobot"
        case .settings: return "DrawerSettings"
        }
    }

    /// Accessibility identifier used by UI automation and reader action routing.
    var accessibilityIdentifier: String {
        switch self {
        case .downloads: return "readerOpenDownloadsAction"
        case .importExport: return "readerOpenImportExportAction"
        case .syncSettings: return "readerOpenSyncSettingsAction"
        case .aiSettings: return "readerOpenAISettingsAction"
        case .settings: return "readerOpenSettingsAction"
        }
    }

    /// Reader action emitted when the row is selected.
    var action: BibleReaderNavigationDrawerAction {
        switch self {
        case .downloads: return .downloads
        case .importExport: return .importExport
        case .syncSettings: return .syncSettings
        case .aiSettings: return .aiSettings
        case .settings: return .settings
        }
    }
}

/**
 Scrollable Android-style navigation drawer shown from the reader header.

 The drawer owns only presentation: grouping, row labels, icon chrome, and accessibility IDs.
 `BibleReaderView` remains responsible for interpreting actions and presenting follow-up UI.
 */
struct BibleReaderNavigationDrawer: View {
    let width: CGFloat
    let colorScheme: ColorScheme
    let versionText: String
    let onAction: (BibleReaderNavigationDrawerAction) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    headerIcon
                    Text(localizedDrawerString("app_name_medium", default: "Bible Study (AndBible)"))
                        .font(.system(size: 18, weight: .bold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .padding(.top, 24)
                .padding(.horizontal, 4)

                drawerSection {
                    drawerRow(
                        title: localizedDrawerString("choose_document", default: "Choose Document"),
                        icon: .asset("DrawerChooseDocument"),
                        identifier: "readerChooseDocumentAction",
                        action: .chooseDocument
                    )
                    drawerRow(
                        title: localizedDrawerString("search", default: "Find"),
                        icon: .asset("DrawerSearch"),
                        identifier: "readerOpenSearchAction",
                        action: .search
                    )
                    drawerRow(
                        title: localizedDrawerString("speak", default: "Speak"),
                        icon: .asset("DrawerSpeak"),
                        identifier: "readerOpenSpeakAction",
                        action: .speak
                    )
                    drawerRow(
                        title: localizedDrawerString("bookmarks", default: "Bookmarks"),
                        icon: .asset("DrawerBookmarks"),
                        identifier: "readerOpenBookmarksAction",
                        action: .bookmarks
                    )
                    drawerRow(
                        title: localizedDrawerString("studypads", default: "StudyPads"),
                        icon: .asset("DrawerStudyPads"),
                        identifier: "readerOpenStudyPadsAction",
                        action: .studyPads
                    )
                    drawerRow(
                        title: localizedDrawerString("my_documents_title", default: "My Documents"),
                        icon: .asset("DrawerDocuments"),
                        identifier: "readerOpenMyNotesAction",
                        action: .myNotes
                    )
                    drawerRow(
                        title: localizedDrawerString("rdg_plan_title", default: "Reading Plan"),
                        icon: .asset("DrawerReadingPlan"),
                        identifier: "readerOpenReadingPlansAction",
                        action: .readingPlans
                    )
                    drawerRow(
                        title: localizedDrawerString("reading_progress_title", default: "Read/Memory Progress"),
                        icon: .system("chart.bar"),
                        identifier: "readerOpenReadingProgressAction",
                        action: .readingProgress
                    )
                    drawerRow(
                        title: localizedDrawerString("history", default: "History"),
                        icon: .asset("DrawerHistory"),
                        identifier: "readerOpenHistoryAction",
                        action: .history
                    )
                }

                drawerSection(title: localizedDrawerString("administration", default: "Administration")) {
                    ForEach(BibleReaderAdministrationDrawerItem.allCases, id: \.self) { item in
                        drawerRow(
                            title: localizedDrawerString(item.titleKey, default: item.defaultTitle),
                            icon: .asset(item.iconAssetName),
                            identifier: item.accessibilityIdentifier,
                            action: item.action
                        )
                    }
                }

                drawerSection(title: localizedDrawerString("information", default: "Information")) {
                    drawerRow(
                        title: localizedDrawerString("help_and_tips", default: "Help & Tips"),
                        icon: .asset("DrawerHelp"),
                        identifier: "readerOpenHelpAction",
                        action: .help
                    )
                    drawerRow(
                        title: localizedDrawerString("buy_development", default: "Sponsor app development"),
                        icon: .asset("DrawerSponsorDevelopment"),
                        identifier: "readerSponsorDevelopmentAction",
                        action: .sponsorDevelopment
                    )
                    drawerRow(
                        title: localizedDrawerString("questions_title", default: "Questions?"),
                        icon: .system("questionmark.bubble"),
                        identifier: "readerNeedHelpAction",
                        action: .needHelp
                    )
                    drawerRow(
                        title: localizedDrawerString("how_to_contribute", default: "How to Contribute"),
                        icon: .system("figure.wave"),
                        identifier: "readerContributeAction",
                        action: .contribute
                    )
                    drawerRow(
                        title: localizedDrawerString("app_licence_title", default: "App Licence"),
                        icon: .system("doc.text"),
                        identifier: "readerOpenAppLicenseAction",
                        action: .appLicense
                    )
                }

                drawerSection(title: localizedDrawerString("contact", default: "Contact")) {
                    drawerRow(
                        title: localizedDrawerString("tell_friend_title", default: "Recommend to a friend"),
                        icon: .system("square.and.arrow.up"),
                        identifier: "readerTellFriendAction",
                        action: .tellFriend
                    )
                    drawerRow(
                        title: localizedDrawerString("rate_application", default: "Rate & Review"),
                        icon: .system("star"),
                        identifier: "readerRateAppAction",
                        action: .rateApp
                    )
                    drawerRow(
                        title: localizedDrawerString("send_bug_report_title", default: "Feedback / bug report"),
                        icon: .system("ladybug"),
                        identifier: "readerReportBugAction",
                        action: .reportBug
                    )
                }

                VStack(spacing: 10) {
                    Divider()
                    Text(versionText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
            .padding(.horizontal, 16)
        }
        .frame(width: width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(drawerBackground)
        .accessibilityIdentifier("readerNavigationDrawer")
    }

    @ViewBuilder
    private var headerIcon: some View {
        Image("DrawerLogo", bundle: .module)
            .renderingMode(.original)
            .interpolation(.high)
            .resizable()
            .scaledToFit()
            .frame(width: 52, height: 52)
    }

    private var drawerBackground: Color {
        #if os(iOS)
        return colorScheme == .dark
            ? Color(red: 48.0 / 255.0, green: 48.0 / 255.0, blue: 48.0 / 255.0)
            : Color(uiColor: .systemBackground)
        #elseif os(macOS)
        return Color(nsColor: .windowBackgroundColor)
        #endif
    }

    private func drawerSection<Content: View>(
        title: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            VStack(spacing: 0) {
                content()
            }
        }
    }

    private func drawerRow(
        title: String,
        icon: DrawerIcon,
        identifier: String,
        action: BibleReaderNavigationDrawerAction
    ) -> some View {
        Button {
            onAction(action)
        } label: {
            drawerRowLabel(title: title, icon: icon)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private func drawerRowLabel(title: String, icon: DrawerIcon) -> some View {
        HStack(spacing: 12) {
            drawerRowIcon(icon)
                .frame(width: 20, height: 20)
            Text(title)
                .foregroundStyle(.primary)
                .font(.system(size: 17, weight: .medium))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func drawerRowIcon(_ icon: DrawerIcon) -> some View {
        switch icon {
        case .system(let systemName):
            Image(systemName: systemName)
                .font(.body)
                .foregroundStyle(.secondary)
        case .asset(let assetName):
            Image(assetName, bundle: .module)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
        }
    }

    private func localizedDrawerString(_ key: String, default defaultValue: String) -> String {
        Bundle.main.localizedString(forKey: key, value: defaultValue, table: nil)
    }

    private enum DrawerIcon {
        case system(String)
        case asset(String)
    }
}
