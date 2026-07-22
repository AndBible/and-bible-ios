// AIModelsView.swift -- Android-parity configured-model management

import BibleCore
import SwiftData
import SwiftUI

/**
 Pushed full-screen model catalog matching Android's provider-independent Models activity.

 SwiftData queries supply provider names, configured models, global default identity, and cumulative
 usage. Add, edit, and delete actions remain app-owned dialog overlays on this screen.
 */
struct AIModelsView: View {
    /// Current appearance supplied to Android's app-owned overflow popup surface.
    @Environment(\.colorScheme) private var colorScheme

    /// Live providers supply row ownership labels and add-model destinations.
    @Query private var providerConfigurations: [LLMProviderConfig]
    /// Live models populate Android's global model list.
    @Query private var configuredModels: [LLMConfiguredModel]
    /// Singleton settings query supplies the default badge without mutating during rendering.
    @Query private var globalSettingsRows: [GlobalAISettings]
    /// Per-device usage rows are summed for Android's cumulative model cost.
    @Query private var usageRecords: [LLMUsageRecord]

    /// Active app-owned provider chooser, model editor, or deletion confirmation.
    @State private var dialog: AIModelDialog?
    /// Shared app-owned information dialog used by Android's Models Help action.
    @State private var configurationDialog: AIConfigurationDialog?
    /// Whether Android's app-owned toolbar overflow popup is visible.
    @State private var showsOverflowMenu = false

    /// Providers in Android's persisted display order.
    private var providers: [LLMProviderConfig] {
        providerConfigurations.sorted { lhs, rhs in
            if lhs.orderNumber != rhs.orderNumber { return lhs.orderNumber < rhs.orderNumber }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    /// Models in Android's default-first then persisted display order.
    private var models: [LLMConfiguredModel] {
        configuredModels.sorted { lhs, rhs in
            let lhsIsDefault = lhs.id == defaultModelID
            let rhsIsDefault = rhs.id == defaultModelID
            if lhsIsDefault != rhsIsDefault { return lhsIsDefault }
            if lhs.orderNumber != rhs.orderNumber { return lhs.orderNumber < rhs.orderNumber }
            return lhs.modelId.localizedCaseInsensitiveCompare(rhs.modelId) == .orderedAscending
        }
    }

    /// Current global default identity, or `nil` after an explicit edit clear.
    private var defaultModelID: UUID? {
        globalSettingsRows.first?.defaultModelId
    }

    /// Whether an Android dialog or popup currently owns all screen interaction.
    private var isModalPresented: Bool {
        dialog != nil || configurationDialog != nil || showsOverflowMenu
    }

    var body: some View {
        ZStack {
            List {
                ForEach(models) { model in
                    Button {
                        dialog = .editor(
                            providerID: model.providerConfigId,
                            modelID: model.id
                        )
                    } label: {
                        modelRow(
                            AIModelListRowPresentation(
                                modelID: model.modelId,
                                providerName: providerName(for: model.providerConfigId),
                                inputPricePerMillion: model.inputPricePerMillion,
                                outputPricePerMillion: model.outputPricePerMillion,
                                cumulativeCost: cumulativeCost(for: model.id),
                                isDefault: model.id == defaultModelID
                            )
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("aiModelRow_\(model.id.uuidString)")
                }
            }
            .listStyle(.plain)
            .accessibilityHidden(isModalPresented)
            .disabled(isModalPresented)

            if showsOverflowMenu {
                overflowDismissLayer
                overflowMenu
            }

            if dialog != nil {
                AIModelDialogOverlay(
                    dialog: $dialog,
                    providers: providers,
                    onChanged: {}
                )
            }
        }
        .accessibilityIdentifier("aiModelsScreen")
        .navigationTitle(String(localized: "ai_models_category", defaultValue: "Models"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationBarBackButtonHidden(isModalPresented)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: addModel) {
                    Image(systemName: "plus")
                }
                .disabled(providers.isEmpty || isModalPresented)
                .accessibilityLabel(String(localized: "add_model", defaultValue: "Add model"))
                .accessibilityIdentifier("aiAddModelButton")

                Button {
                    showsOverflowMenu.toggle()
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel(String(localized: "system_items1", defaultValue: "More"))
                .accessibilityIdentifier("aiModelsOverflowButton")
                .disabled(isModalPresented)
            }
        }
        .aiConfigurationDialog($configurationDialog, credentialStore: .keychain())
    }

    /** Builds one dense Android-style configured-model row without nested navigation. */
    private func modelRow(_ presentation: AIModelListRowPresentation) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "cpu")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if presentation.isDefault {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel(
                                String(
                                    localized: "model_set_default",
                                    defaultValue: "Set as default model"
                                )
                            )
                    }

                    Text(presentation.modelID)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    if presentation.isSupported {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .accessibilityLabel(
                                String(localized: "model_supported_badge", defaultValue: "✓ Supported")
                            )
                    }
                }

                Text(presentation.providerModelAndPricingSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let cumulativeCostText = presentation.cumulativeCostText {
                    Text(cumulativeCostText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    /** Opens Android's provider chooser, or skips it when exactly one provider exists. */
    private func addModel() {
        showsOverflowMenu = false
        dialog = AIModelDialog.addDestination(providerIDs: providers.map(\.id))
    }

    /// Full-screen clear hit target that dismisses Android's overflow popup without a system menu.
    private var overflowDismissLayer: some View {
        Color.black.opacity(0.001)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { showsOverflowMenu = false }
            .zIndex(9)
            .accessibilityHidden(true)
    }

    /// Android's one-row Models overflow menu, anchored below the trailing app-bar action.
    private var overflowMenu: some View {
        AndroidPopupMenuSurface(
            colorScheme: colorScheme,
            accessibilityIdentifier: "aiModelsOverflowMenu"
        ) {
            AndroidPopupMenuRow(
                title: String(localized: "help", defaultValue: "Help"),
                icon: .system("questionmark.circle"),
                accessibilityIdentifier: "aiModelsHelpMenuItem"
            ) {
                showsOverflowMenu = false
                configurationDialog = .information(
                    title: String(localized: "help", defaultValue: "Help"),
                    message: String(
                        localized: "help_ai_models_text",
                        defaultValue: "Manage models for this provider. You can refresh the model list from the provider's API to pick up new releases, or add a model name manually if it is not in the fetched list."
                    )
                )
            }
        }
        .frame(width: 210)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .shadow(color: .black.opacity(0.28), radius: 10, x: 0, y: 5)
        .padding(.top, 8)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .zIndex(10)
    }

    /// Resolves the owning provider name without exposing credentials.
    private func providerName(for providerID: UUID) -> String {
        providers.first(where: { $0.id == providerID })?.displayName ?? "?"
    }

    /// Sums Android's per-device cumulative estimated cost for one configured model.
    private func cumulativeCost(for modelID: UUID) -> Double {
        usageRecords.lazy
            .filter { $0.configuredModelId == modelID }
            .reduce(0) { partial, record in
                let updated = partial + max(record.estimatedCostUSD, 0)
                return updated.isFinite ? updated : .greatestFiniteMagnitude
            }
    }
}

/** Pure row text and badge contract shared by the Models screen and package tests. */
struct AIModelListRowPresentation: Equatable {
    /// Exact provider model identifier shown as the row title.
    let modelID: String
    /// Owning provider display name.
    let providerName: String
    /// Whether Android prefixes the row with its default star.
    let isDefault: Bool
    /// Whether Android appends its supported check mark.
    let isSupported: Bool
    /// Provider/model summary with Android's optional compact input/output prices.
    let providerModelAndPricingSummary: String
    /// Android-formatted cumulative cost, or `nil` when no positive cost exists.
    let cumulativeCostText: String?

    /**
     Resolves one model row from non-secret persisted values.

     - Parameters:
       - modelID: Exact model identifier.
       - providerName: Owning provider's display name.
       - inputPricePerMillion: Persisted input rate.
       - outputPricePerMillion: Persisted output rate.
       - cumulativeCost: Sum of all per-device usage costs for this configured model.
       - isDefault: Whether this configured model is the current global default.
     - Side effects: None.
     - Failure modes: Non-finite or non-positive cumulative costs are omitted; pricing appears when
       either persisted rate is positive, matching Android.
     */
    init(
        modelID: String,
        providerName: String,
        inputPricePerMillion: Double,
        outputPricePerMillion: Double,
        cumulativeCost: Double,
        isDefault: Bool
    ) {
        self.modelID = modelID
        self.providerName = providerName
        self.isDefault = isDefault
        isSupported = AIModelCatalog.isSupported(modelID)

        var summary = "\(providerName) \u{2014} \(modelID)"
        if inputPricePerMillion > 0 || outputPricePerMillion > 0 {
            summary += " (\(AIModelPricePresentation.compact(inputPricePerMillion))/"
                + "\(AIModelPricePresentation.compact(outputPricePerMillion)))"
        }
        providerModelAndPricingSummary = summary

        cumulativeCostText = cumulativeCost.isFinite && cumulativeCost > 0
            ? AIModelPricePresentation.cumulativeCost(cumulativeCost)
            : nil
    }
}
