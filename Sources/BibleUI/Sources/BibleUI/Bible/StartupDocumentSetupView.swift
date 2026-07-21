import Foundation
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/**
 Android-style startup document setup screen.

 Android renders first-download setup as a scrollable page with welcome text, format guidance, and
 full-width actions. This SwiftUI view mirrors that structure as a reader-stack destination instead
 of using iOS action-sheet chrome.

 - Inputs:
   - presentation: Ordered setup action contract resolved from startup state.
   - versionText: Optional application version detail shown at the bottom of the setup page.
   - action closures: Reader-owned routing hooks for each startup action.
 - Side effects: Invokes the supplied action closure when a button is tapped.
 - Failure modes: Missing optional version text is simply omitted.
 */
struct StartupDocumentSetupView: View {
    /// Presentation policy and action ordering for the current startup state.
    let presentation: StartupDocumentSetupPresentation

    /// Optional version text shown in the footer.
    let versionText: String?

    /// Starts Android Easy Start default downloads.
    let onEasyStart: () -> Void

    /// Opens the document download screen.
    let onDownloadDocuments: () -> Void

    /// Opens local document loading.
    let onLoadDocumentsFromFiles: () -> Void

    /// Opens database restore.
    let onRestoreDatabase: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                welcomeText

                if presentation.isEasyStartAvailable {
                    Text(
                        String(
                            localized: "easy_start_message",
                            defaultValue: "To easily get started, click below to automatically download recommended default documents. Recommended for first time users! You can change these settings later on."
                        )
                    )
                    .font(.body)
                    .foregroundStyle(.primary)
                }

                VStack(spacing: 10) {
                    ForEach(presentation.actions, id: \.self) { action in
                        startupActionButton(for: action)
                    }
                }

                Text(supportedFormatsText)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("startupDocumentSetupSupportedFormats")

                Spacer(minLength: 24)

                if let versionText {
                    Text(versionText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityIdentifier("startupDocumentSetupVersionText")
                }
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        #if os(iOS)
        .background(Color(uiColor: .systemBackground))
        #elseif os(macOS)
        .background(Color(nsColor: .windowBackgroundColor))
        #endif
        .navigationBarBackButtonHidden(true)
        .accessibilityIdentifier("startupDocumentSetupScreen")
    }

    /// Logo and app title matching Android's first-download header composition.
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "book.closed.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(String(localized: "app_name_long", defaultValue: "AndBible: Bible Study"))
                .font(.system(size: 28, weight: .semibold))
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
            .font(.body)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
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
        Button(action: handler(for: action)) {
            Text(title(for: action))
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .accessibilityIdentifier(accessibilityIdentifier(for: action))
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
