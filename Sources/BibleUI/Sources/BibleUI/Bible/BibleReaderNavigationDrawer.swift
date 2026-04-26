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
    case history
    case downloads
    case importExport
    case syncSettings
    case settings
    case help
    case sponsorDevelopment
    case needHelp
    case contribute
    case about
    case appLicense
    case tellFriend
    case rateApp
    case reportBug
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
                        title: localizedDrawerString("chooce_document", default: "Choose Document"),
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
                        title: String(localized: "my_notes"),
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
                        title: localizedDrawerString("history", default: "History"),
                        icon: .asset("DrawerHistory"),
                        identifier: "readerOpenHistoryAction",
                        action: .history
                    )
                }

                drawerSection(title: localizedDrawerString("administration", default: "Administration")) {
                    drawerRow(
                        title: localizedDrawerString("download", default: "Download Documents"),
                        icon: .asset("DrawerDownloads"),
                        identifier: "readerOpenDownloadsAction",
                        action: .downloads
                    )
                    drawerRow(
                        title: localizedDrawerString("backup_and_restore", default: "Backup & Restore"),
                        icon: .asset("DrawerBackupRestore"),
                        identifier: "readerOpenImportExportAction",
                        action: .importExport
                    )
                    drawerRow(
                        title: localizedDrawerString("cloud_sync_title", default: "Device synchronization"),
                        icon: .asset("DrawerSync"),
                        identifier: "readerOpenSyncSettingsAction",
                        action: .syncSettings
                    )
                    drawerRow(
                        title: "Application preferences",
                        icon: .asset("DrawerSettings"),
                        identifier: "readerOpenSettingsAction",
                        action: .settings
                    )
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
                        title: localizedDrawerString("questions_title", default: "Need Help"),
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
                        title: String(localized: "about"),
                        icon: .system("info.circle"),
                        identifier: "readerOpenAboutAction",
                        action: .about
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
