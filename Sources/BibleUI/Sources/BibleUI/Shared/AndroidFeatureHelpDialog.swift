// AndroidFeatureHelpDialog.swift -- Typed Android showHelpDialog parity

import SwiftUI

/**
 Identifies every typed feature-help contract currently exposed by Android `CommonUtils.showHelpDialog`.

 Each case owns the exact Android string resource and documentation path. Callers select a semantic
 feature rather than rebuilding a title, message, or URL, preventing iOS-only copy and missing-link
 drift across AI, progress, document-sync, and reader help entry points.
 */
enum AndroidFeatureHelpTopic: String, CaseIterable, Equatable, Sendable {
    case aiSettings
    case aiConnection
    case aiProviders
    case aiModels
    case globalToolPermissions
    case promptEditor
    case toolInfo
    case aiDocumentFilter
    case readingProgress
    case documentSync
    case memorize

    /**
     Resolves Android's localized `titleResId` for the selected help route.

     - Returns: The shared Android Help title.
     - Side effects: reads the active application localization bundle.
     - Failure modes: missing resources use the exact Android English fallback.
     */
    var localizedTitle: String {
        String(localized: "help", defaultValue: "Help")
    }

    /**
     Returns Android's exact `messageResId` resource name for the selected route.

     - Returns: Stable Android localization key shared by rendering and bridge contracts.
     - Side effects: none.
     - Failure modes: none because every semantic topic has one compile-time resource.
     */
    var localizationKey: String {
        switch self {
        case .aiSettings: "help_ai_settings_text"
        case .aiConnection: "help_ai_connection_text"
        case .aiProviders: "help_ai_providers_text"
        case .aiModels: "help_ai_models_text"
        case .globalToolPermissions: "help_global_tool_permissions_text"
        case .promptEditor: "help_prompt_edit_text"
        case .toolInfo: "help_tool_info_text"
        case .aiDocumentFilter: "help_ai_document_filter_text"
        case .readingProgress: "help_reading_progress_text"
        case .documentSync: "help_document_sync_text"
        case .memorize: "help_memorize_text"
        }
    }

    /**
     Resolves Android's exact `messageResId` for the selected help route.

     - Returns: Localized feature explanation sourced from the matching Android resource.
     - Side effects: reads the active application localization bundle.
     - Failure modes: missing resources use the exact Android English fallback.
     */
    var localizedMessage: String {
        switch self {
        case .aiSettings:
            String(
                localized: "help_ai_settings_text",
                defaultValue: "AI Settings is where you manage your prompts and categories. From here you can create new prompts, organise them into categories, import/export prompts as CSV, install add-on prompt packs, and reach the AI connection settings."
            )
        case .aiConnection:
            String(
                localized: "help_ai_connection_text",
                defaultValue: "Configure your AI providers, models, permissions and other connection options here. Each provider needs its own API key. You can add multiple providers and select a default model."
            )
        case .aiProviders:
            String(
                localized: "help_ai_providers_text",
                defaultValue: "Manage AI providers (Google Gemini, OpenAI, Anthropic, etc.). Each provider needs its own API key. You can add multiple providers and assign different ones to specific prompts."
            )
        case .aiModels:
            String(
                localized: "help_ai_models_text",
                defaultValue: "Manage models for this provider. You can refresh the model list from the provider's API to pick up new releases, or add a model name manually if it is not in the fetched list."
            )
        case .globalToolPermissions:
            String(
                localized: "help_global_tool_permissions_text",
                defaultValue: "Configure permissions for individual AI tools. For each read tool, choose whether the AI may use it (Enabled or Disabled). For each write tool, choose Always allow, Always deny, or Ask (which falls back to the global permission mode set in AI Connection settings)."
            )
        case .promptEditor:
            String(
                localized: "help_prompt_edit_text",
                defaultValue: "Custom prompts let you create reusable AI instructions for your study. Set a name, description, template, the contexts where it should appear, and optionally a custom provider/model. Built-in prompts cannot be edited directly — use \"Copy to customize\" to create your own version."
            )
        case .toolInfo:
            String(
                localized: "help_tool_info_text",
                defaultValue: "AI tools are specialised functions the AI can call to read your data or make changes on your behalf. Read tools (verses, commentaries, dictionaries, bookmarks) never require permission. Write tools (creating bookmarks, notes, study pad entries) are gated by the permission system."
            )
        case .aiDocumentFilter:
            String(
                localized: "help_ai_document_filter_text",
                defaultValue: "Limit which Bibles, commentaries and other modules the AI agent can read. By default the AI sees all installed modules; filtering helps reduce noise and cost when you only want it to consider specific sources."
            )
        case .readingProgress:
            String(
                localized: "help_reading_progress_text",
                defaultValue: "Your Bible reading and memorization progress at a glance. Mark chapters as read manually with the \"Mark as read\" button, or enable automatic tracking. Memorize exercises also feed into this view."
            )
        case .documentSync:
            String(
                localized: "help_document_sync_text",
                defaultValue: "Document sync copies your installed Bibles, commentaries and other documents to the cloud and keeps them in sync across your devices. Use this view to see what is stored in the cloud, download or upload individual documents, remove documents, and control what syncs to this device."
            )
        case .memorize:
            String(
                localized: "help_memorize_text",
                defaultValue: "The Memorize view helps you learn passages by heart. Use Word Blur, Word Scramble, Word Type or Word Order to practise. Successful exercises automatically mark verses as memorized (this can be disabled)."
            )
        }
    }

    /**
     Resolves Android's exact `helpPath` against the shared documentation root.

     - Returns: Trusted HTTPS documentation destination for the selected feature.
     - Side effects: none.
     - Failure modes: none because every path and URL root is a compile-time Android constant.
     */
    var documentationURL: URL {
        let path: String
        switch self {
        case .aiSettings: path = "ai.html"
        case .aiConnection: path = "ai.html#getting-started"
        case .aiProviders: path = "ai.html#choosing-a-provider"
        case .aiModels: path = "ai.html#available-models"
        case .globalToolPermissions: path = "ai.html#setting-permissions"
        case .promptEditor: path = "ai.html#custom-prompts"
        case .toolInfo: path = "ai.html#ai-tools"
        case .aiDocumentFilter: path = "ai.html#available-data-and-documents"
        case .readingProgress: path = "reading_progress.html"
        case .documentSync: path = "document_sync.html"
        case .memorize: path = "memorize.html"
        }
        return URL(string: "https://docs.andbible.org/en/latest/\(path)")!
    }
}

/**
 Renders the content portion of Android's compact `CommonUtils.showHelpDialog`.

 Unlike Android's full catalog Help dialog, this contract contains no logo, tutorial catalog,
 full-documentation footer, or project-support footer: it shows one feature message, one manual link,
 and one positive action exactly as Android does.

 Inputs: typed Android feature-help topic and dismissal callback

 Output: intrinsic-height Android AlertDialog content ready for one `AndroidDialogWindow`

 Side effects: opens the trusted manual URL or invokes the dismissal callback

 Failure modes: none
 */
struct AndroidFeatureHelpDialogContent: View {
    /// Android feature whose resource and manual anchor should be displayed.
    let topic: AndroidFeatureHelpTopic

    /// Owner-controlled positive dismissal callback.
    let onDismiss: () -> Void

    var body: some View {
        AndroidDialogScaffold(title: topic.localizedTitle) {
            AndroidAdaptiveDialogScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(topic.localizedMessage)
                        .font(.system(size: 17))
                        .fixedSize(horizontal: false, vertical: true)

                    AndroidDialogLink(
                        String(
                            localized: "help_read_more_link",
                            defaultValue: "Read more in the manual"
                        ),
                        destination: topic.documentationURL,
                        isItalic: true
                    )
                    .font(.system(size: 17))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.vertical, 8)
            }
        } actions: {
            AndroidDialogTextAction(
                title: String(localized: "okay", defaultValue: "OK"),
                accessibilityIdentifier: "androidFeatureHelpOKButton",
                action: onDismiss
            )
        }
    }
}

/**
 Presents one typed feature-help contract in the shared app-owned Android dialog window.

 Inputs: typed Android help topic and owner dismissal callback

 Output: centered, outside-dismissible, intrinsic-height Android feature-help dialog

 Side effects: invokes `onDismiss` after an outside tap or OK action

 Failure modes: none
 */
struct AndroidFeatureHelpDialog: View {
    /// Android feature whose help contract is visible.
    let topic: AndroidFeatureHelpTopic

    /// Owner-controlled outside-tap and positive-action dismissal.
    let onDismiss: () -> Void

    /// Current application scheme consumed only by the global dialog palette.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        AndroidDialogWindow(
            colorScheme: colorScheme,
            accessibilityIdentifier: "androidFeatureHelpDialog",
            onOutsideTap: onDismiss
        ) {
            AndroidFeatureHelpDialogContent(topic: topic, onDismiss: onDismiss)
        }
    }
}
