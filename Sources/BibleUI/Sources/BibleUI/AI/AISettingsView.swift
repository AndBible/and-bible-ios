// AISettingsView.swift -- Android-parity AI settings entry point

import BibleCore
import SwiftData
import SwiftUI
import SwordKit

/**
 Shared app-owned entry point for Android-compatible AI settings.

 The route mirrors Android's `AiSettingsActivity`: an installation without providers sees a
 focused configuration prompt, while any saved provider changes the root to prompt management.
 Execution readiness remains a separate concern and does not decide which screen is visible.

 The view reads provider rows from the surrounding SwiftData container. Navigation actions push
 app-owned destinations in the existing navigation stack; this view does not present sheets.
 */
public struct AISettingsView: View {
    /// Pops the reader-owned AI Settings activity for standalone callers.
    @Environment(\.dismiss) private var dismiss

    /// Optional installed-module manager used to discover add-on prompt packs.
    private let swordManager: SwordManager?
    /// Device-only credential boundary forwarded to connection-management screens.
    private let credentialStore: AICredentialStore
    /// Reader/workspace palette shared by every nested AI activity.
    private let surfacePalette: ReaderThemeSurfacePalette
    /// Explicit reader-owner Back command, or nil for the environment dismissal fallback.
    private let onBack: (() -> Void)?

    /// Nested Android activity currently replacing the AI Settings root.
    @State private var activityRoute: AISettingsActivityRoute?

    /**
     Creates the shared AI settings route.

     - Parameters:
       - swordManager: Optional installed-module source for read-only prompt packs.
       - credentialStore: Device-only Keychain facade used by provider setup screens.
     - Side effects: None until a destination reads or mutates its settings.
     - Failure modes: Persistence and credential failures are surfaced by the owning destination.
     */
    public init(
        swordManager: SwordManager? = nil,
        credentialStore: AICredentialStore = .keychain()
    ) {
        self.swordManager = swordManager
        self.credentialStore = credentialStore
        surfacePalette = .standard
        onBack = nil
    }

    /**
     Creates the reader-owned AI Settings activity with the active workspace/window palette.

     - Parameters:
       - swordManager: Installed-module source for add-on prompts and document access.
       - credentialStore: Device-only provider credential boundary.
       - surfacePalette: Palette resolved by the owning reader destination.
       - onBack: Explicit command returning to the reader.
     - Side effects: none until a child command is selected.
     - Failure modes: nested persistence failures remain owned by their activity.
     */
    init(
        swordManager: SwordManager?,
        credentialStore: AICredentialStore = .keychain(),
        surfacePalette: ReaderThemeSurfacePalette,
        onBack: @escaping () -> Void
    ) {
        self.swordManager = swordManager
        self.credentialStore = credentialStore
        self.surfacePalette = surfacePalette
        self.onBack = onBack
    }

    public var body: some View {
        Group {
            switch activityRoute {
            case .connection:
                AIConnectionSettingsView(
                    swordManager: swordManager,
                    credentialStore: credentialStore,
                    surfacePalette: surfacePalette,
                    onBack: { activityRoute = nil }
                )
            case .promptEditor(let promptID):
                AIPromptEditorView(
                    promptID: promptID,
                    swordManager: swordManager,
                    surfacePalette: surfacePalette,
                    onBack: { activityRoute = nil },
                    onChanged: {}
                )
            case nil:
                AISettingsContentView(
                    swordManager: swordManager,
                    credentialStore: credentialStore,
                    surfacePalette: surfacePalette,
                    onBack: performRootBack,
                    onOpenConnection: { activityRoute = .connection },
                    onOpenPrompt: { activityRoute = .promptEditor($0) }
                )
            }
        }
    }

    /** Returns from AI Settings through its explicit reader owner or environment fallback. */
    private func performRootBack() {
        if let onBack {
            onBack()
        } else {
            dismiss()
        }
    }
}

/** App-owned nested activities reachable from the AI Settings root. */
private enum AISettingsActivityRoute: Equatable {
    case connection
    case promptEditor(UUID?)
}

/** Android's provider-count-driven top-level AI settings states. */
enum AISettingsRootMode: Equatable {
    /// No provider exists, so the route shows the centered Configure AI state.
    case setup
    /// At least one provider exists, so the route becomes prompt management.
    case prompts

    /**
     Resolves the visible root state from persisted provider count.

     - Parameter providerCount: Number of provider configuration rows; negative values are treated
       as empty defensively.
     - Returns: `.setup` only when no provider exists, matching Android's `llmConfigured` contract.
     - Side effects: None. The result is deterministic for the supplied count.
     */
    static func resolve(providerCount: Int) -> Self {
        providerCount > 0 ? .prompts : .setup
    }
}

/** Provider-observing content that switches the shared route without replacing navigation state. */
private struct AISettingsContentView: View {
    /// Live provider rows; SwiftData updates the root after setup or provider deletion.
    @Query private var providerConfigurations: [LLMProviderConfig]

    /// Optional installed-module manager used by prompt and permission destinations.
    let swordManager: SwordManager?
    /// Device-only credential boundary used by connection destinations.
    let credentialStore: AICredentialStore
    /// Reader/workspace colors shared by both configured and setup roots.
    let surfacePalette: ReaderThemeSurfacePalette
    /// Explicit Android Up command.
    let onBack: () -> Void
    /// Opens Connection settings inside the same app-owned activity host.
    let onOpenConnection: () -> Void
    /// Opens a new or existing prompt editor inside the same activity host.
    let onOpenPrompt: (UUID?) -> Void

    var body: some View {
        Group {
            switch AISettingsRootMode.resolve(providerCount: providerConfigurations.count) {
            case .setup:
                AISettingsSetupView(
                    credentialStore: credentialStore,
                    surfacePalette: surfacePalette,
                    onBack: onBack,
                    onOpenConnection: onOpenConnection
                )
            case .prompts:
                AIPromptManagementView(
                    swordManager: swordManager,
                    settingsRootCredentialStore: credentialStore,
                    surfacePalette: surfacePalette,
                    onBack: onBack,
                    onOpenConnection: onOpenConnection,
                    onOpenPrompt: onOpenPrompt
                )
            }
        }
    }
}

/** Android's unconfigured AI Settings state rendered as a full app-owned activity. */
private struct AISettingsSetupView: View {
    /// Device-only credential boundary forwarded to provider setup.
    let credentialStore: AICredentialStore
    /// Reader/workspace palette selected by the activity owner.
    let surfacePalette: ReaderThemeSurfacePalette
    /// Explicit Android Up command.
    let onBack: () -> Void
    /// Replaces this setup root with Connection settings.
    let onOpenConnection: () -> Void
    /// Android's app-owned AI Settings help dialog.
    @State private var activeDialog: AIConfigurationDialog?
    /// Whether Android's toolbar overflow popup is visible.
    @State private var showsOverflowMenu = false
    /// Current appearance used by the shared popup surface.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        AndroidActivityScreen(
            title: String(localized: "ai_settings", defaultValue: "AI Settings"),
            accessibilityIdentifier: "aiSettingsTopAppBar",
            palette: surfacePalette,
            onBack: onBack
        ) {
            AndroidActivityTopAppBarActionButton(
                icon: .asset("ToolbarOverflow"),
                accessibilityLabel: String(localized: "system_items1", defaultValue: "More"),
                accessibilityIdentifier: "aiSettingsOverflowButton",
                foregroundColor: surfacePalette.toolbarForegroundColor
            ) {
                showsOverflowMenu.toggle()
            }
            .androidPopupMenuAnchor(id: "aiSettingsOverflowAnchor")
        } content: {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 18) {
                        Text(String(localized: "ai_setup_title", defaultValue: "Configure AI"))
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(surfacePalette.foregroundColor)

                        Text(
                            String(
                                localized: "ai_setup_description",
                                defaultValue: "AndBible can use AI to translate Bible text, explain verses, create summaries, and more. To get started, configure a connection to an OpenAI-compatible API provider."
                            )
                        )
                        .foregroundStyle(surfacePalette.secondaryForegroundColor)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)

                        AndroidRaisedTextButton(
                            title: String(
                                localized: "ai_configure_button",
                                defaultValue: "Configure Connection"
                            ),
                            foregroundColor: surfacePalette.foregroundColor,
                            backgroundColor: surfacePalette.secondaryForegroundColor.opacity(0.28),
                            accessibilityIdentifier: "aiConfigureConnectionButton",
                            action: onOpenConnection
                        )
                        .frame(maxWidth: 320)
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: geometry.size.height)
                }
            }
        }
        .androidAccessibilityIdentityMarker(
            label: String(localized: "ai_settings", defaultValue: "AI Settings"),
            accessibilityIdentifier: "aiSetupScreen",
            surfaceColor: surfacePalette.backgroundColor
        )
        .disabled(activeDialog != nil)
        .androidAnchoredPopupMenu(
            anchorID: "aiSettingsOverflowAnchor",
            isPresented: $showsOverflowMenu,
            menuWidth: 220,
            estimatedMenuHeight: 52,
            accessibilityIdentifier: "aiSettingsOverflowMenu"
        ) {
            AndroidPopupMenuSurface(
                colorScheme: colorScheme,
                accessibilityIdentifier: "aiSettingsOverflowMenu",
                backgroundColor: surfacePalette.backgroundColor,
                primaryTextColor: surfacePalette.foregroundColor,
                secondaryTextColor: surfacePalette.secondaryForegroundColor,
                accentColor: surfacePalette.controlAccentColor
            ) {
                AndroidPopupMenuRow(
                    title: String(localized: "help", defaultValue: "Help"),
                    icon: .asset("DrawerHelp"),
                    accessibilityIdentifier: "aiSettingsHelpMenuItem"
                ) {
                    showsOverflowMenu = false
                    activeDialog = .information(
                        title: String(localized: "help", defaultValue: "Help"),
                        message: String(
                            localized: "help_ai_settings_text",
                            defaultValue: "AI Settings is where you manage your prompts and categories. From here you can create new prompts, organise them into categories, import/export prompts as CSV, install add-on prompt packs, and reach the AI connection settings."
                        )
                    )
                }
            }
        }
        .aiConfigurationDialog($activeDialog, credentialStore: credentialStore)
    }
}
