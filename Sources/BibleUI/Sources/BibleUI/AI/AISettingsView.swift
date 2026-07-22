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
    /// Optional installed-module manager used to discover add-on prompt packs.
    private let swordManager: SwordManager?
    /// Device-only credential boundary forwarded to connection-management screens.
    private let credentialStore: AICredentialStore

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
    }

    public var body: some View {
        AISettingsContentView(
            swordManager: swordManager,
            credentialStore: credentialStore
        )
    }
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

    var body: some View {
        Group {
            switch AISettingsRootMode.resolve(providerCount: providerConfigurations.count) {
            case .setup:
                AISettingsSetupView(
                    swordManager: swordManager,
                    credentialStore: credentialStore
                )
            case .prompts:
                AIPromptManagementView(
                    swordManager: swordManager,
                    settingsRootCredentialStore: credentialStore
                )
            }
        }
        .navigationTitle(String(localized: "ai_settings", defaultValue: "AI Settings"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/** Android's unconfigured AI Settings state rendered with native iOS navigation. */
private struct AISettingsSetupView: View {
    /// Optional installed-module manager forwarded to Connection settings.
    let swordManager: SwordManager?
    /// Device-only credential boundary forwarded to provider setup.
    let credentialStore: AICredentialStore
    /// Android's app-owned AI Settings help dialog.
    @State private var activeDialog: AIConfigurationDialog?

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 18) {
                    Text(String(localized: "ai_setup_title", defaultValue: "Configure AI"))
                        .font(.title2.weight(.semibold))

                    Text(
                        String(
                            localized: "ai_setup_description",
                            defaultValue: "AndBible can use AI to translate Bible text, explain verses, create summaries, and more. To get started, configure a connection to an OpenAI-compatible API provider."
                        )
                    )
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)

                    NavigationLink {
                        AIConnectionSettingsView(
                            swordManager: swordManager,
                            credentialStore: credentialStore
                        )
                    } label: {
                        Text(
                            String(
                                localized: "ai_configure_button",
                                defaultValue: "Configure Connection"
                            )
                        )
                        .font(.headline)
                        .textCase(.uppercase)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(
                            Color.secondary.opacity(0.28),
                            in: RoundedRectangle(cornerRadius: 2, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("aiConfigureConnectionButton")
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        activeDialog = .information(
                            title: String(localized: "help", defaultValue: "Help"),
                            message: String(
                                localized: "help_ai_settings_text",
                                defaultValue: "AI Settings is where you manage your prompts and categories. From here you can create new prompts, organise them into categories, import/export prompts as CSV, install add-on prompt packs, and reach the AI connection settings."
                            )
                        )
                    } label: {
                        Label(
                            String(localized: "help", defaultValue: "Help"),
                            systemImage: "questionmark.circle"
                        )
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel(String(localized: "system_items1", defaultValue: "More"))
                .disabled(activeDialog != nil)
            }
        }
        .aiConfigurationDialog($activeDialog, credentialStore: credentialStore)
        .accessibilityIdentifier("aiSetupScreen")
    }
}
