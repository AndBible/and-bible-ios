import Foundation
import SwiftUI

/**
 Android-style startup document setup screen.

 Android renders first-download setup as a scrollable page with welcome text, format guidance, and
 full-width actions. This SwiftUI view mirrors that structure as a reader-stack destination instead
 of using iOS action-sheet chrome.

 - Inputs:
   - presentation: Ordered setup action contract resolved from startup state.
   - versionText: Optional application version detail shown at the bottom of the setup page.
   - surfacePalette: Reader/workspace palette inherited by the full-screen startup destination.
   - action closures: Reader-owned routing hooks for each startup action.
 - Side effects: Invokes the supplied action closure when a button is tapped.
 - Failure modes: Missing optional version text is simply omitted.
 */
struct StartupDocumentSetupView: View {
    /// Current appearance used by Android's globally managed link accent.
    @Environment(\.colorScheme) private var colorScheme

    /// Host-platform URL handoff used by Android's two startup auto-link rows.
    @Environment(\.openURL) private var openURL

    /// Presentation policy and action ordering for the current startup state.
    let presentation: StartupDocumentSetupPresentation

    /// Optional version text shown in the footer.
    let versionText: String?

    /// Reader/workspace-owned palette used by the complete startup activity.
    let surfacePalette: ReaderThemeSurfacePalette

    /// Starts Android Easy Start default downloads.
    let onEasyStart: () -> Void

    /// Opens the document download screen.
    let onDownloadDocuments: () -> Void

    /// Opens local document loading.
    let onLoadDocumentsFromFiles: () -> Void

    /// Opens database restore.
    let onRestoreDatabase: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    welcomeText

                    if presentation.actions.contains(.easyStart) {
                        Text(
                            String(
                                localized: "easy_start_message",
                                defaultValue: "To easily get started, click below to automatically download recommended default documents. Recommended for first time users! You can change these settings later on."
                            )
                        )
                        .font(.system(size: 16))
                        .foregroundStyle(surfacePalette.secondaryForegroundColor)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(5)

                        startupActionButton(for: .easyStart)
                    }

                    if presentation.actions.contains(.downloadDocuments) {
                        startupActionButton(for: .downloadDocuments)
                    }

                    if presentation.actions.contains(.restoreDatabase) {
                        startupActionButton(for: .restoreDatabase)
                    }

                    if presentation.actions.contains(.loadDocumentsFromFiles) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(title(for: .loadDocumentsFromFiles))
                                .font(.system(size: 16, weight: .bold))

                            Text(supportedFormatsText)
                                .font(.system(size: 16))
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("startupDocumentSetupSupportedFormats")
                        }
                        .foregroundStyle(surfacePalette.secondaryForegroundColor)
                        .padding(.top, 10)
                        .padding(5)

                        startupActionButton(for: .loadDocumentsFromFiles)
                    }

                    VStack(spacing: 4) {
                        startupLink(
                            title: "https://andbible.org",
                            urlString: "https://andbible.org",
                            accessibilityIdentifier: "startupDocumentSetupHomepageLink"
                        )
                        startupLink(
                            title: "https://github.com/AndBible/and-bible",
                            urlString: "https://github.com/AndBible/and-bible",
                            accessibilityIdentifier: "startupDocumentSetupGitHubLink"
                        )
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)

                    Spacer(minLength: 14)

                    if let versionText {
                        Text(versionText)
                            .font(.system(size: 12))
                            .foregroundStyle(surfacePalette.secondaryForegroundColor)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(5)
                            .accessibilityIdentifier("startupDocumentSetupVersionText")
                    }
                }
                .padding(15)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(surfacePalette.foregroundColor)
            .background(surfacePalette.backgroundColor.ignoresSafeArea())

            AndroidActivityAccessibilityMarker(
                label: String(localized: "app_name_long", defaultValue: "AndBible: Bible Study"),
                accessibilityIdentifier: "startupDocumentSetupScreen",
                surfaceColor: surfacePalette.backgroundColor
            )
        }
        .navigationBarBackButtonHidden(true)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    /// Logo and app title matching Android's first-download header composition.
    private var header: some View {
        HStack(spacing: 12) {
            Image("DrawerLogo", bundle: .module)
                .interpolation(.high)
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)

            Text(String(localized: "app_name_long", defaultValue: "AndBible: Bible Study"))
                .font(.system(size: 20))
                .foregroundStyle(surfacePalette.secondaryForegroundColor)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    /// Welcome message for the current startup reason.
    private var welcomeText: some View {
        Text(welcomeMessage)
            .font(.system(size: 16))
            .foregroundStyle(surfacePalette.secondaryForegroundColor)
            .fixedSize(horizontal: false, vertical: true)
            .padding(5)
            .accessibilityIdentifier("startupDocumentSetupWelcomeText")
    }

    /// Localized welcome message matching Android's no-Bible copy when setup is required.
    private var welcomeMessage: String {
        String(
            format: String(
                localized: "welcome_message",
                defaultValue: "Thank you for downloading %@. There are currently no Bibles or documents installed. To continue, please install at least 1 document by downloading from the internet, or by loading from a zip file document."
            ),
            String(localized: "app_name_long", defaultValue: "AndBible: Bible Study")
        )
    }

    /// Supported-file text copied from Android's first-download page.
    private var supportedFormatsText: String {
        let appName = String(localized: "app_name_andbible", defaultValue: "AndBible")
        let zip = String(
            format: String(
                localized: "format_zip",
                defaultValue: "Zip file containing Sword module(s), or documents backup file (*.abmd) created by %@"
            ),
            appName
        )
        let formats = [
            zip,
            String(localized: "format_mybible", defaultValue: "MyBible documents (*.SQLite3)"),
            String(localized: "format_mysword", defaultValue: "MySword documents (*.mybible)"),
            String(localized: "format_epub", defaultValue: "EPUB documents (*.epub)")
        ].joined(separator: ", ")
        return String(
            format: String(
                localized: "supported_formats",
                defaultValue: "Supported formats for loading documents from a file: %@"
            ),
            formats
        )
    }

    /**
     Renders a full-width Android startup action button.

     - Parameter action: Startup setup action to render.
     - Returns: A button with stable accessibility metadata and Android-like full-width sizing.
     */
    @ViewBuilder
    private func startupActionButton(for action: StartupDocumentSetupPresentation.Action) -> some View {
        AndroidRaisedTextButton(
            title: title(for: action),
            foregroundColor: surfacePalette.foregroundColor,
            backgroundColor: surfacePalette.controlFillColor,
            accessibilityIdentifier: accessibilityIdentifier(for: action),
            action: handler(for: action)
        )
    }

    /**
     Builds one Android startup auto-link row using the application-managed accent color.

     Inputs:
     - visible link text copied from Android's untranslated startup resource
     - absolute URL string and stable accessibility identity supplied by the startup activity

     Output: one centered, underlined app-owned link row

     Side effects: a successful tap hands the validated URL to the host operating system

     Failure modes: an invalid URL string is ignored without changing startup navigation state
     */
    private func startupLink(
        title: String,
        urlString: String,
        accessibilityIdentifier: String
    ) -> some View {
        Button {
            guard let url = URL(string: urlString) else { return }
            openURL(url)
        } label: {
            Text(title)
                .font(.system(size: 16))
                .foregroundStyle(AndroidDialogSurfacePalette.accent(for: colorScheme))
                .underline()
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(5)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    /// Human-readable title for a startup action.
    private func title(for action: StartupDocumentSetupPresentation.Action) -> String {
        switch action {
        case .easyStart:
            String(localized: "easy_start_title", defaultValue: "Easy start")
        case .downloadDocuments:
            String(localized: "download", defaultValue: "Download Documents")
        case .loadDocumentsFromFiles:
            String(localized: "install_zip", defaultValue: "Load Documents From Files")
        case .restoreDatabase:
            String(localized: "restore_database", defaultValue: "Restore Database File")
        }
    }

    /// Action closure for a startup setup action.
    private func handler(for action: StartupDocumentSetupPresentation.Action) -> () -> Void {
        switch action {
        case .easyStart:
            onEasyStart
        case .downloadDocuments:
            onDownloadDocuments
        case .loadDocumentsFromFiles:
            onLoadDocumentsFromFiles
        case .restoreDatabase:
            onRestoreDatabase
        }
    }

    /// Stable UI-test identifier for a startup action.
    private func accessibilityIdentifier(for action: StartupDocumentSetupPresentation.Action) -> String {
        switch action {
        case .easyStart:
            "startupSetupAction.easyStart"
        case .downloadDocuments:
            "startupSetupAction.downloadDocuments"
        case .loadDocumentsFromFiles:
            "startupSetupAction.loadDocumentsFromFiles"
        case .restoreDatabase:
            "startupSetupAction.restoreDatabase"
        }
    }
}
