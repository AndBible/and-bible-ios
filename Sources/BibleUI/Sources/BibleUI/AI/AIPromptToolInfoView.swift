// AIPromptToolInfoView.swift -- Android Available tools destination

import BibleCore
import SwiftUI

/** Pure Android grouping and ordering rules for the Available tools destination. */
enum AIPromptToolInfoBehavior {
    /**
     Returns registered tool identities in Android's permission group and localized name order.

     - Parameter requiringPermission: `true` for write tools; `false` for read and structural tools.
     - Returns: Every matching `AgentTool`, sorted by Android's displayed name.
     - Side effects: Reads localized strings only.
     - Failure modes: None; the complete typed tool vocabulary is always available.
     */
    static func tools(requiringPermission: Bool) -> [AgentTool] {
        AgentTool.allCases
            .filter { ($0.access == .write) == requiringPermission }
            .sorted {
                AIPermissionPresentation.title(for: $0)
                    .localizedCompare(AIPermissionPresentation.title(for: $1)) == .orderedAscending
            }
    }
}

/**
 Pushed app-owned screen matching Android's `ToolInfoActivity`.

 The screen reads the complete typed tool catalog, separates tools by permission requirement, and
 displays Android's exact provider-facing descriptions. Its Help toolbar action opens the shared
 app-owned information dialog; the destination performs no persistence or credential access.
 */
struct AIPromptToolInfoView: View {
    /// Standalone dismissal fallback when the caller does not own an explicit route.
    @Environment(\.dismiss) private var dismiss
    /// Android's app-owned Tool Info help dialog.
    @State private var helpDialog: AIConfigurationDialog?
    /// Reader/workspace palette inherited from the prompt editor.
    let surfacePalette: ReaderThemeSurfacePalette
    /// Explicit Android Up command.
    let onBack: (() -> Void)?

    /** Creates the app-owned Tool Info activity without reading its immutable catalog. */
    init(
        surfacePalette: ReaderThemeSurfacePalette = .standard,
        onBack: (() -> Void)? = nil
    ) {
        self.surfacePalette = surfacePalette
        self.onBack = onBack
    }

    /// Read and structural tools that Android reports as not requiring permission.
    private var readTools: [AgentTool] {
        AIPromptToolInfoBehavior.tools(requiringPermission: false)
    }

    /// Write tools gated by Android's permission system.
    private var writeTools: [AgentTool] {
        AIPromptToolInfoBehavior.tools(requiringPermission: true)
    }

    var body: some View {
        AndroidActivityScreen(
            title: String(localized: "ai_available_tools", defaultValue: "Available tools"),
            accessibilityIdentifier: "aiPromptToolInfoTopAppBar",
            palette: surfacePalette,
            onBack: performBack
        ) {
            AndroidActivityTopAppBarActionButton(
                icon: .asset("ActivityHelp"),
                accessibilityLabel: String(localized: "help", defaultValue: "Help"),
                accessibilityIdentifier: "aiPromptToolInfoHelpButton",
                foregroundColor: surfacePalette.toolbarForegroundColor
            ) {
                helpDialog = .information(
                    title: String(localized: "help", defaultValue: "Help"),
                    message: String(
                        localized: "help_tool_info_text",
                        defaultValue: "AI tools are specialised functions the AI can call to read your data or make changes on your behalf. Read tools (verses, commentaries, dictionaries, bookmarks) never require permission. Write tools (creating bookmarks, notes, study pad entries) are gated by the permission system."
                    )
                )
            }
        } content: {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    toolSection(
                        title: String(localized: "ai_read_tools", defaultValue: "Read Tools"),
                        tools: readTools
                    )
                    toolSection(
                        title: String(localized: "ai_write_tools", defaultValue: "Write Tools"),
                        tools: writeTools
                    )
                }
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
        }
        .disabled(helpDialog != nil)
        .aiConfigurationDialog($helpDialog, credentialStore: .keychain())
        .accessibilityIdentifier("aiPromptToolInfoView")
    }

    /** Returns through the explicit prompt-editor owner or standalone environment fallback. */
    private func performBack() {
        if let onBack {
            onBack()
        } else {
            dismiss()
        }
    }

    /**
     Builds one Android read/write header followed by its ordered tool rows.

     - Parameters:
       - title: Localized Android section title.
       - tools: Tools already filtered and sorted for this section.
     - Returns: Unframed section content matching Android's scrolling linear layout.
     - Side effects: Reads immutable Android definition descriptions.
     - Failure modes: Catalog corruption is a programmer error enforced by the catalog itself.
     */
    @ViewBuilder
    private func toolSection(title: String, tools: [AgentTool]) -> some View {
        Text(title)
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(surfacePalette.foregroundColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 4)

        ForEach(tools, id: \.self) { tool in
            VStack(alignment: .leading, spacing: 2) {
                Text(AIPermissionPresentation.title(for: tool))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(surfacePalette.foregroundColor)
                Text(AndroidAgentToolDefinitionCatalog.definition(for: tool).description)
                    .font(.system(size: 14))
                    .foregroundStyle(surfacePalette.secondaryForegroundColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}
