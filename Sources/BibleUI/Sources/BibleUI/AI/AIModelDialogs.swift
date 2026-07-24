// AIModelDialogs.swift -- Android-parity model management dialogs

import BibleCore
import SwiftData
import SwiftUI

/** Parent-owned states for Android's provider chooser, model editor, and deletion confirmation. */
enum AIModelDialog: Equatable {
    /// Provider selection shown only when more than one provider exists.
    case providerChooser
    /// New or existing model editor owned by the pushed Models screen.
    case editor(providerID: UUID, modelID: UUID?)
    /// Destructive confirmation opened from an existing model editor.
    case deleteConfirmation(modelID: UUID, displayName: String)
    /**
     Resolves Android's Add action from the currently configured provider identities.

     - Parameter providerIDs: Providers in persisted display order.
     - Returns: `nil` when none exist, a direct editor for one, or the app-owned chooser for many.
     - Side effects: None.
     - Failure modes: None.
     */
    static func addDestination(providerIDs: [UUID]) -> AIModelDialog? {
        guard let first = providerIDs.first else { return nil }
        return providerIDs.count == 1
            ? .editor(providerID: first, modelID: nil)
            : .providerChooser
    }
}

/**
 Blocking app-owned overlay for every Models-screen dialog.

 The pushed screen remains visible beneath Android's dimmer while dialog transitions replace the
 panel in place. No sheet, navigation editor, menu, or system confirmation participates.
 */
struct AIModelDialogOverlay: View {
    /// Current appearance used for Android's dimmer opacity.
    @Environment(\.colorScheme) private var colorScheme

    /// Parent-owned active dialog.
    @Binding var dialog: AIModelDialog?
    /// Providers in Android display order for the chooser.
    let providers: [LLMProviderConfig]
    /// Models-screen refresh callback after committed mutations.
    let onChanged: () -> Void

    var body: some View {
        AndroidDialogWindow(
            colorScheme: colorScheme,
            accessibilityIdentifier: "aiModelDialogOverlay",
            allowsOutsideDismissal: false,
            onOutsideTap: {}
        ) {
            dialogContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .zIndex(20)
    }

    /// Renders the exact app-owned panel represented by `dialog`.
    @ViewBuilder
    private var dialogContent: some View {
        switch dialog {
        case .providerChooser:
            AIModelProviderChooserDialog(
                providers: providers,
                onSelect: { providerID in
                    dialog = .editor(providerID: providerID, modelID: nil)
                },
                onCancel: dismiss
            )
        case .editor(let providerID, let modelID):
            AIModelEditorDialog(
                providerID: providerID,
                modelID: modelID,
                onCancel: dismiss,
                onSaved: {
                    onChanged()
                    dismiss()
                },
                onRequestDelete: { id, name in
                    dialog = .deleteConfirmation(modelID: id, displayName: name)
                }
            )
        case .deleteConfirmation(let modelID, let displayName):
            AIModelDeleteConfirmationDialog(
                modelID: modelID,
                displayName: displayName,
                onCancel: dismiss,
                onDeleted: {
                    onChanged()
                    dismiss()
                }
            )
        case nil:
            EmptyView()
        }
    }

    /// Closes the active model dialog without mutating settings.
    private func dismiss() {
        dialog = nil
    }
}

/** Android's provider-selection AlertDialog shown before adding a model. */
private struct AIModelProviderChooserDialog: View {
    /// Providers in persisted Android display order.
    let providers: [LLMProviderConfig]
    /// Selection callback that replaces this panel with the add-model editor.
    let onSelect: (UUID) -> Void
    /// Negative action callback.
    let onCancel: () -> Void

    var body: some View {
        AIAndroidDialogSurface(
            title: String(localized: "model_select_provider", defaultValue: "Provider")
        ) {
            AndroidAdaptiveDialogScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(providers) { provider in
                        Button {
                            onSelect(provider.id)
                        } label: {
                            Text(provider.displayName)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("aiModelProvider_\(provider.id.uuidString)")
                    }
                }
            }
        } actions: {
            Spacer()
            AIAndroidDialogAction(
                title: String(localized: "cancel", defaultValue: "Cancel"),
                action: onCancel
            )
            .accessibilityIdentifier("aiModelProviderCancelButton")
        }
        .androidDialogAccessibilityIdentity(accessibilityIdentifier: "aiModelProviderChooserDialog")
    }
}

/** Android's app-owned add/edit configured-model dialog. */
private struct AIModelEditorDialog: View {
    /// SwiftData context containing providers, models, usage, and global settings.
    @Environment(\.modelContext) private var modelContext
    /// Appearance used by shared app-owned dialog controls.
    @Environment(\.colorScheme) private var colorScheme

    /// Owning provider identity selected by the Models screen.
    let providerID: UUID
    /// Existing immutable model identity, or `nil` when adding.
    let modelID: UUID?
    /// Negative action callback.
    let onCancel: () -> Void
    /// Callback after model and default selection commit.
    let onSaved: () -> Void
    /// Neutral Delete transition callback for existing models.
    let onRequestDelete: (UUID, String) -> Void

    /// Whether provider, model, cache, and default state have loaded.
    @State private var isLoaded = false
    /// Dynamic cache or built-in fallback candidates.
    @State private var availableModels: [AIAvailableModel] = []
    /// Sanitized dynamic metadata across providers for Android's global known-price lookup.
    @State private var cachedPricingModels: [AIAvailableModel] = []
    /// Current slash-prefix category, or `nil` for Android's All option.
    @State private var selectedCategory: String?
    /// Whether unsupported models remain in the selectable list.
    @State private var includesUnsupported = true
    /// Selected known model identifier when adding.
    @State private var selectedModelID: String?
    /// Whether Android's trailing Custom choice is selected.
    @State private var usesCustomModel = false
    /// Custom add-model identifier, or immutable existing identifier after load.
    @State private var modelName = ""
    /// Editable input price for unknown/custom models.
    @State private var inputPrice = "0"
    /// Editable output price for unknown/custom models.
    @State private var outputPrice = "0"
    /// Existing persisted input price shown read-only for a known model.
    @State private var persistedInputPrice = 0.0
    /// Existing persisted output price shown read-only for a known model.
    @State private var persistedOutputPrice = 0.0
    /// Whether the existing identifier resolves to built-in or cached trusted pricing.
    @State private var existingModelHasKnownPricing = false
    /// Whether the model was the default when editing began.
    @State private var wasCurrentDefault = false
    /// Editable default checkbox state for an existing model.
    @State private var isDefault = false
    /// Credential-free loading or persistence failure text kept inside the app-owned dialog.
    @State private var failureMessage: String?

    /// SwiftData facade for model and global-default mutations.
    private var settingsStore: AISettingsStore { AISettingsStore(modelContext: modelContext) }
    /// Whether this dialog creates rather than edits a configured model.
    private var isNewModel: Bool { modelID == nil }
    /// Android categories derived from slash-prefixed available model IDs.
    private var categories: [String] { AIModelCatalog.categories(in: availableModels) }
    /// Current category/support-filtered model choices in Android price order.
    private var selectableModels: [AIAvailableModel] {
        AIModelCatalog.selectableModels(
            from: availableModels,
            category: selectedCategory,
            includesUnsupported: includesUnsupported
        )
    }
    /// Trusted price for the selected add-model choice, if one exists.
    private var selectedKnownPricing: AIModelPricing? {
        guard isNewModel else { return nil }
        let candidateID = usesCustomModel
            ? modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            : selectedModelID ?? ""
        guard !candidateID.isEmpty else { return nil }
        return AIModelCatalog.pricing(
            for: candidateID,
            dynamicModels: availableModels + cachedPricingModels
        )
    }
    /// Whether price fields must be replaced by Android's read-only pricing summary.
    private var pricesAreReadOnly: Bool {
        isNewModel ? selectedKnownPricing != nil : existingModelHasKnownPricing
    }
    /// Model identifier that will be persisted by a valid add operation.
    private var resolvedNewModelID: String {
        if usesCustomModel {
            return modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return selectedModelID ?? ""
    }

    var body: some View {
        AIAndroidDialogSurface(
            title: isNewModel
                ? String(localized: "add_model", defaultValue: "Add model")
                : String(localized: "edit_model_title", defaultValue: "Edit model")
        ) {
            AndroidAdaptiveDialogScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if isLoaded {
                        if isNewModel {
                            addModelSelection
                        } else {
                            existingModelIdentity
                        }

                        pricingFields

                        if !isNewModel {
                            AndroidCheckboxRow(
                                title: String(
                                    localized: "model_set_default",
                                    defaultValue: "Set as default model"
                                ),
                                isOn: $isDefault,
                                foregroundColor: AndroidDialogSurfacePalette.primaryText(for: colorScheme),
                                accentColor: AndroidDialogSurfacePalette.accent(for: colorScheme),
                                accessibilityIdentifier: "aiModelDefaultToggle"
                            )
                            .padding(.top, 4)
                        }
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                    }

                    if let failureMessage {
                        Text(failureMessage)
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("aiModelDialogError")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
        } actions: {
            if let modelID {
                AIAndroidDialogAction(
                    title: String(localized: "delete", defaultValue: "Delete"),
                    isDestructive: true,
                    action: { onRequestDelete(modelID, modelName) }
                )
                .accessibilityIdentifier("aiModelDeleteButton")
            }
            Spacer()
            AIAndroidDialogAction(
                title: String(localized: "cancel", defaultValue: "Cancel"),
                action: onCancel
            )
            .accessibilityIdentifier("aiModelCancelButton")
            AIAndroidDialogAction(
                title: String(localized: "okay", defaultValue: "OK"),
                isEnabled: canSave,
                action: saveModel
            )
            .accessibilityIdentifier("aiModelSaveButton")
        }
        .androidDialogAccessibilityIdentity(accessibilityIdentifier: "aiModelEditorDialog")
        .task { await load() }
    }

    /// Complete add-model selection controls, including categories, support filtering, and Custom.
    @ViewBuilder
    private var addModelSelection: some View {
        if !categories.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel(String(localized: "llm_openrouter_category", defaultValue: "Category"))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 18) {
                        categoryButton(
                            title: String(localized: "llm_openrouter_category_all", defaultValue: "All"),
                            category: nil
                        )
                        ForEach(categories, id: \.self) { category in
                            categoryButton(
                                title: category.prefix(1).uppercased() + String(category.dropFirst()),
                                category: category
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }

        if AIModelCatalog.showsUnsupportedToggle(in: availableModels) {
            AndroidCheckboxRow(
                title: String(
                    localized: "show_also_unsupported_models",
                    defaultValue: "Show also unsupported models"
                ),
                isOn: Binding(
                    get: { includesUnsupported },
                    set: updateUnsupportedVisibility
                ),
                foregroundColor: AndroidDialogSurfacePalette.primaryText(for: colorScheme),
                accentColor: AndroidDialogSurfacePalette.accent(for: colorScheme),
                accessibilityIdentifier: "aiModelUnsupportedToggle"
            )
        }

        VStack(alignment: .leading, spacing: 4) {
            fieldLabel(String(localized: "llm_openrouter_model", defaultValue: "Model"))
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(selectableModels.enumerated()), id: \.offset) { entry in
                    modelChoice(entry.element)
                }
                customModelChoice
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.secondary.opacity(0.28), lineWidth: 1)
            }
        }

        if usesCustomModel {
            labeledTextField(
                String(localized: "llm_custom_model_dialog_message", defaultValue: "Enter the model ID"),
                text: $modelName
            )
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .autocorrectionDisabled()
            .accessibilityIdentifier("aiCustomModelIDField")
        }
    }

    /// Immutable existing model ID plus Android's supported badge when applicable.
    private var existingModelIdentity: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(String(localized: "llm_openrouter_model", defaultValue: "Model"))
            Text(modelName)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 7)
                .overlay(alignment: .bottom) { Divider() }
                .accessibilityIdentifier("aiExistingModelID")

            if AIModelCatalog.isSupported(modelName) {
                Text(String(localized: "model_supported_badge", defaultValue: "✓ Supported"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
                .accessibilityIdentifier("aiModelSupportedBadge")
            }
        }
    }

    /// Read-only known pricing or editable unknown/custom input and output rates.
    @ViewBuilder
    private var pricingFields: some View {
        if pricesAreReadOnly {
            let pricing = readOnlyPricing
            VStack(alignment: .leading, spacing: 4) {
                fieldLabel(
                    String(
                        localized: "llm_custom_input_price_title",
                        defaultValue: "Input price ($/Mtoken)"
                    )
                )
                Text(
                    String(
                        format: String(
                            localized: "model_pricing_summary",
                            defaultValue: "%1$@ in / %2$@ out per Mtoken"
                        ),
                        AIModelPricePresentation.compact(pricing.input),
                        AIModelPricePresentation.compact(pricing.output)
                    )
                )
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("aiModelReadOnlyPricing")
            }
        } else {
            labeledPriceField(
                String(
                    localized: "llm_custom_input_price_title",
                    defaultValue: "Input price ($/Mtoken)"
                ),
                text: $inputPrice
            )
            .accessibilityIdentifier("aiModelInputPriceField")
            labeledPriceField(
                String(
                    localized: "llm_custom_output_price_title",
                    defaultValue: "Output price ($/Mtoken)"
                ),
                text: $outputPrice
            )
            .accessibilityIdentifier("aiModelOutputPriceField")
        }
    }

    /// Persisted edit prices or trusted selected add prices used by the read-only summary.
    private var readOnlyPricing: (input: Double, output: Double) {
        if isNewModel, let selectedKnownPricing {
            return (selectedKnownPricing.inputPerMillion, selectedKnownPricing.outputPerMillion)
        }
        return (persistedInputPrice, persistedOutputPrice)
    }

    /// Whether Android's positive action currently has a valid model identifier.
    private var canSave: Bool {
        guard isLoaded else { return false }
        return isNewModel ? !resolvedNewModelID.isEmpty : !modelName.isEmpty
    }

    /** Builds one app-owned category option and resets the model choice like Android's spinner. */
    private func categoryButton(title: String, category: String?) -> some View {
        Button {
            selectedCategory = category
            selectFirstVisibleModel()
        } label: {
            HStack(spacing: 5) {
                if selectedCategory == category {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                }
                Text(title)
                    .font(.subheadline.weight(selectedCategory == category ? .semibold : .regular))
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(selectedCategory == category ? "selected" : "")
    }

    /** Builds one radio-style model row with Android's supported mark and compact prices. */
    private func modelChoice(_ model: AIAvailableModel) -> some View {
        Button {
            usesCustomModel = false
            selectedModelID = model.id
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: selectedModelID == model.id && !usesCustomModel
                    ? "largecircle.fill.circle"
                    : "circle")
                    .frame(width: 18)

                if AIModelCatalog.isSupported(model.id) {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.green)
                        .accessibilityLabel(
                            String(localized: "model_supported_badge", defaultValue: "✓ Supported")
                        )
                }

                Text(model.id)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                if let pricing = model.pricing {
                    Text(
                        "\(AIModelPricePresentation.compact(pricing.inputPerMillion))/"
                            + AIModelPricePresentation.compact(pricing.outputPerMillion)
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("aiModelChoice_\(model.id)")
    }

    /// Android's trailing Custom model row.
    private var customModelChoice: some View {
        Button {
            usesCustomModel = true
            selectedModelID = nil
        } label: {
            HStack(spacing: 8) {
                Image(systemName: usesCustomModel ? "largecircle.fill.circle" : "circle")
                    .frame(width: 18)
                Text(String(localized: "llm_custom_model", defaultValue: "Custom…"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("aiCustomModelChoice")
    }

    /** Builds one Android-style plain text field with an underline. */
    private func labeledTextField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            fieldLabel(label)
            TextField(label, text: text)
                .textFieldStyle(.plain)
                .padding(.vertical, 7)
                .overlay(alignment: .bottom) { Divider() }
        }
    }

    /** Builds one decimal price field with platform-appropriate keyboard behavior. */
    private func labeledPriceField(_ label: String, text: Binding<String>) -> some View {
        labeledTextField(label, text: text)
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
    }

    /// Android-style caption label shared by identity, model, and pricing fields.
    private func fieldLabel(_ label: String) -> some View {
        Text(label)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /**
     Loads provider, cache, immutable model, pricing, and default state.

     - Side effects: Reads SwiftData on the main actor and sanitized dynamic cache through its actor.
     - Failure modes: Missing provider/model rows leave the dialog visible with credential-free text.
     */
    @MainActor
    private func load() async {
        do {
            guard let provider = try settingsStore.provider(id: providerID) else {
                throw AISettingsStoreError.providerNotFound(providerID)
            }
            let type = provider.provider
            let cached = await AIDynamicModelService.shared.cachedModels(for: type)
            let allCachedModels = await AIDynamicModelService.shared.cachedModelsAcrossProviders()
            let candidates = AIModelCatalog.availableModels(for: type, cachedModels: cached)

            availableModels = candidates
            cachedPricingModels = allCachedModels
            includesUnsupported = AIModelCatalog.initiallyIncludesUnsupported(in: candidates)

            if let modelID {
                guard let model = try settingsStore.model(id: modelID) else {
                    throw AISettingsStoreError.modelNotFound(modelID)
                }
                modelName = model.modelId
                inputPrice = String(model.inputPricePerMillion)
                outputPrice = String(model.outputPricePerMillion)
                persistedInputPrice = model.inputPricePerMillion
                persistedOutputPrice = model.outputPricePerMillion
                existingModelHasKnownPricing = AIModelCatalog.isKnownModel(
                    model.modelId,
                    dynamicModels: allCachedModels
                )
                let defaultModelID = try settingsStore.globalSettings().defaultModelId
                wasCurrentDefault = defaultModelID == model.id
                isDefault = wasCurrentDefault
            } else {
                selectFirstVisibleModel()
            }
            isLoaded = true
        } catch {
            isLoaded = true
            failureMessage = String(
                localized: "error_occurred",
                defaultValue: "An error has occurred"
            )
        }
    }

    /** Updates Android's unsupported filter and resets selection to the first visible model. */
    private func updateUnsupportedVisibility(_ isVisible: Bool) {
        includesUnsupported = isVisible
        selectFirstVisibleModel()
    }

    /** Selects the first filtered model, or Custom when no catalog row remains. */
    private func selectFirstVisibleModel() {
        if let first = selectableModels.first {
            selectedModelID = first.id
            usesCustomModel = false
        } else {
            selectedModelID = nil
            usesCustomModel = true
        }
    }

    /**
     Inserts or updates a model while preserving Android's default and pricing rules.

     Existing IDs and model identifiers never change. Trusted prices remain untouched. Unknown
     prices are editable, add initializes the default only when absent, and edit can explicitly clear
     the model that was current when the dialog opened.

     - Side effects: Mutates and saves SwiftData, then invokes `onSaved` after commit.
     - Failure modes: Missing rows, validation failures, and persistence errors retain the dialog and
       show credential-free localized error text.
     */
    private func saveModel() {
        guard canSave else { return }
        do {
            if let modelID {
                guard let model = try settingsStore.model(id: modelID) else {
                    throw AISettingsStoreError.modelNotFound(modelID)
                }
                if !existingModelHasKnownPricing {
                    model.inputPricePerMillion = AIModelEditorPolicy.sanitizedPrice(inputPrice)
                    model.outputPricePerMillion = AIModelEditorPolicy.sanitizedPrice(outputPrice)
                }

                let settings = try settingsStore.globalSettings()
                settings.defaultModelId = AIModelEditorPolicy.defaultModelIDAfterEditing(
                    modelID: model.id,
                    currentDefaultModelID: settings.defaultModelId,
                    wasCurrentDefault: wasCurrentDefault,
                    isChecked: isDefault
                )
                try settingsStore.save()
            } else {
                let pricing = selectedKnownPricing
                let model = LLMConfiguredModel(
                    providerConfigId: providerID,
                    modelId: resolvedNewModelID,
                    orderNumber: try settingsStore.models(providerConfigId: providerID).count,
                    inputPricePerMillion: pricing?.inputPerMillion
                        ?? AIModelEditorPolicy.sanitizedPrice(inputPrice),
                    outputPricePerMillion: pricing?.outputPerMillion
                        ?? AIModelEditorPolicy.sanitizedPrice(outputPrice),
                    cacheCreationPricePerMillion: pricing?.cacheCreationPerMillion ?? 0,
                    cacheReadPricePerMillion: pricing?.cacheReadPerMillion ?? 0
                )
                try settingsStore.insertModel(model)
                let settings = try settingsStore.globalSettings()
                let updatedDefault = AIModelEditorPolicy.defaultModelIDAfterAdding(
                    existingDefaultModelID: settings.defaultModelId,
                    newModelID: model.id
                )
                if updatedDefault != settings.defaultModelId {
                    settings.defaultModelId = updatedDefault
                    try settingsStore.save()
                }
            }
            onSaved()
        } catch {
            failureMessage = String(
                localized: "error_occurred",
                defaultValue: "An error has occurred"
            )
        }
    }

}

/** Android's app-owned configured-model deletion confirmation. */
private struct AIModelDeleteConfirmationDialog: View {
    /// SwiftData context containing the model graph and global default.
    @Environment(\.modelContext) private var modelContext

    /// Stable configured-model identity to remove.
    let modelID: UUID
    /// Immutable model identifier interpolated into Android's warning.
    let displayName: String
    /// Android's No action.
    let onCancel: () -> Void
    /// Callback after deletion and default promotion commit.
    let onDeleted: () -> Void

    /// Credential-free deletion failure text kept inside the app-owned confirmation.
    @State private var failureMessage: String?

    var body: some View {
        AIAndroidDialogSurface(
            title: String(localized: "delete", defaultValue: "Delete")
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    String(
                        format: String(
                            localized: "model_delete_confirm",
                            defaultValue: "Delete model \"%1$@\"?"
                        ),
                        displayName
                    )
                )
                .fixedSize(horizontal: false, vertical: true)

                if let failureMessage {
                    Text(failureMessage)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        } actions: {
            Spacer()
            AIAndroidDialogAction(
                title: String(localized: "no", defaultValue: "No"),
                action: onCancel
            )
            .accessibilityIdentifier("aiModelDeleteNoButton")
            AIAndroidDialogAction(
                title: String(localized: "yes", defaultValue: "Yes"),
                isDestructive: true,
                action: deleteModel
            )
            .accessibilityIdentifier("aiModelDeleteYesButton")
        }
        .androidDialogAccessibilityIdentity(accessibilityIdentifier: "aiModelDeleteConfirmationDialog")
    }

    /**
     Deletes one model through the shared store so dependent references and default failover agree.

     - Side effects: Mutates SwiftData and invokes `onDeleted` after commit.
     - Failure modes: Store errors retain this panel with credential-free localized error text.
     */
    private func deleteModel() {
        do {
            try AISettingsStore(modelContext: modelContext).deleteModel(id: modelID)
            onDeleted()
        } catch {
            failureMessage = String(
                localized: "error_occurred",
                defaultValue: "An error has occurred"
            )
        }
    }
}

/** Android-compatible price and cumulative-cost text used by model dialogs and list rows. */
enum AIModelPricePresentation {
    /** Formats a per-million rate like Android, including its sub-cent marker. */
    static func compact(_ pricePerMillion: Double) -> String {
        if pricePerMillion > 0, pricePerMillion < 0.01 {
            return "< $0.01"
        }
        return String(format: "$%.2f", pricePerMillion)
    }

    /** Formats cumulative cost with Android's extra precision below one cent. */
    static func cumulativeCost(_ cost: Double) -> String {
        if cost > 0, cost < 0.01 {
            return String(format: "$%.3f", cost)
        }
        return String(format: "$%.2f", cost)
    }
}

/** Pure default-selection and custom-price policy used by Android's model editor. */
enum AIModelEditorPolicy {
    /**
     Keeps an existing default when adding, or selects the new model when no default exists.

     - Parameters:
       - existingDefaultModelID: Current global selection before insertion.
       - newModelID: Newly inserted configured-model identity.
     - Returns: Android's post-add global default.
     - Side effects: None.
     - Failure modes: None.
     */
    static func defaultModelIDAfterAdding(
        existingDefaultModelID: UUID?,
        newModelID: UUID
    ) -> UUID {
        existingDefaultModelID ?? newModelID
    }

    /**
     Applies Android's existing-model default checkbox semantics.

     Checking always selects the edited model. Unchecking clears it only when that model was the
     default when editing began; otherwise the current global selection is retained.

     - Parameters:
       - modelID: Edited configured-model identity.
       - currentDefaultModelID: Global selection at save time.
       - wasCurrentDefault: Whether the edited model was selected when the dialog loaded.
       - isChecked: Saved checkbox state.
     - Returns: Android's post-edit global default, including explicit `nil` clear.
     - Side effects: None.
     - Failure modes: None.
     */
    static func defaultModelIDAfterEditing(
        modelID: UUID,
        currentDefaultModelID: UUID?,
        wasCurrentDefault: Bool,
        isChecked: Bool
    ) -> UUID? {
        if isChecked { return modelID }
        if wasCurrentDefault { return nil }
        return currentDefaultModelID
    }

    /**
     Parses Android's editable custom rate with invalid, negative, and non-finite values mapped to zero.

     - Parameter rawValue: Decimal text from one price field.
     - Returns: Finite non-negative rate in US dollars per million tokens.
     - Side effects: None.
     - Failure modes: Invalid input returns zero instead of throwing.
     */
    static func sanitizedPrice(_ rawValue: String) -> Double {
        guard let value = Double(rawValue), value.isFinite else { return 0 }
        return max(value, 0)
    }
}
