// AIReaderTransientDialogs.swift -- Android AlertDialog parity for reader AI actions

import BibleCore
import Foundation
import SwiftUI

/**
 Presents Android's grouped, collapsible AI action chooser in the shared dialog window.

 The dialog preserves Android's Favorites-first grouping, per-context collapse preferences,
 inline favorite toggles, prompt descriptions, outside-tap cancellation, and source-aware prompt
 selection. It deliberately uses no native iOS list, navigation, menu, picker, or sheet primitive.

 Inputs: pane-scoped coordinator containing resolved prompt groups and favorite state

 Output: one app-owned Android prompt-selection dialog

 Side effects: persists collapse preferences locally, persists favorites through the coordinator,
 and selects a prompt after an explicit row tap

 Failure modes: coordinator persistence failures remain visible through its safe failure channel
 */
struct AIReaderPromptChooserDialog: View {
  @Bindable var coordinator: AIReaderRunCoordinator

  @Environment(\.colorScheme) private var colorScheme
  @State private var collapsedGroupIDs: Set<String> = []
  @State private var restoredCollapseState = false

  var body: some View {
    AndroidDialogWindow(
      colorScheme: colorScheme,
      accessibilityIdentifier: "aiReaderPromptChooserDialog",
      onOutsideTap: dismiss
    ) {
      AndroidDialogScaffold(
        title: String(localized: "select_llm_prompt", defaultValue: "Select AI Action")
      ) {
        AndroidAdaptiveDialogScrollView {
          LazyVStack(spacing: 0) {
            ForEach(coordinator.promptGroups) { group in
              promptGroup(group)
            }
          }
        }
      } actions: {
        AndroidDialogTextAction(
          title: String(localized: "cancel", defaultValue: "Cancel"),
          accessibilityIdentifier: "aiReaderPromptChooserCancelButton",
          action: dismiss
        )
      }
    }
    .onAppear(perform: restoreCollapsePreferences)
    .onChange(of: coordinator.promptGroups.map(\.id)) { _, identifiers in
      collapsedGroupIDs.formIntersection(identifiers)
      for group in coordinator.promptGroups where group.isFavorites {
        collapsedGroupIDs.remove(group.id)
      }
    }
  }

  /** Renders one expandable Android category header and its currently visible prompt children. */
  @ViewBuilder
  private func promptGroup(_ group: AIReaderPromptGroup) -> some View {
    let isCollapsed = collapsedGroupIDs.contains(group.id)
    Button {
      setCollapsed(!isCollapsed, group: group)
    } label: {
      HStack(spacing: 12) {
        Text(group.title)
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(AndroidDialogSurfacePalette.primaryText(for: colorScheme))
          .frame(maxWidth: .infinity, alignment: .leading)
        Text(String(group.prompts.count))
          .font(.system(size: 14))
          .foregroundStyle(AndroidDialogSurfacePalette.secondaryText(for: colorScheme))
        AndBibleIconView(
          name: isCollapsed ? "PromptExpandIndicator" : "PromptCollapseIndicator",
          size: 24
        )
        .foregroundStyle(AndroidDialogSurfacePalette.secondaryText(for: colorScheme))
      }
      .padding(.horizontal, 16)
      .frame(minHeight: 48)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("aiReaderPromptGroup::\(group.id)")

    if !isCollapsed {
      ForEach(group.prompts, id: \.prompt.id) { entry in
        promptRow(entry)
        Divider()
          .overlay(AndroidDialogSurfacePalette.secondaryText(for: colorScheme).opacity(0.20))
      }
    }
  }

  /** Renders Android's prompt name/description row with an independent favorite command. */
  private func promptRow(_ entry: ResolvedAgentPrompt) -> some View {
    let isFavorite = coordinator.favoritePromptIDs.contains(entry.prompt.id)
    return HStack(alignment: .center, spacing: 8) {
      Button {
        coordinator.selectPrompt(entry)
      } label: {
        VStack(alignment: .leading, spacing: 4) {
          Text(entry.prompt.name)
            .font(.system(size: 17))
            .foregroundStyle(AndroidDialogSurfacePalette.primaryText(for: colorScheme))
            .frame(maxWidth: .infinity, alignment: .leading)
          if let description = entry.prompt.promptDescription, !description.isEmpty {
            Text(description)
              .font(.system(size: 14))
              .foregroundStyle(AndroidDialogSurfacePalette.secondaryText(for: colorScheme))
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .padding(.leading, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("aiReaderPromptChoice::\(entry.prompt.id.uuidString)")

      Button {
        coordinator.togglePromptFavorite(entry.prompt.id)
      } label: {
        AndBibleIconView(
          name: isFavorite ? "PromptFavoriteFilled" : "PromptFavoriteOutline",
          size: 24
        )
        .foregroundStyle(
          isFavorite
            ? AndroidResourcePalette.promptFavoriteFilled
            : AndroidResourcePalette.promptFavoriteOutline
        )
        .frame(width: 48, height: 48)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(
        String(localized: "prompt_category_favorites", defaultValue: "Favorites")
      )
      .accessibilityAddTraits(isFavorite ? .isSelected : [])
      .accessibilityIdentifier("aiReaderPromptFavorite::\(entry.prompt.id.uuidString)")
    }
    .padding(.trailing, 4)
  }

  /** Restores Android's per-context category collapse choices and first-group fallback. */
  private func restoreCollapsePreferences() {
    guard !restoredCollapseState else { return }
    restoredCollapseState = true
    let context = coordinator.promptContext ?? .verseSelection
    collapsedGroupIDs = AIReaderPromptGroupCollapseStore.collapsedGroupIDs(
      groups: coordinator.promptGroups,
      context: context
    )
  }

  /** Applies one category state and persists non-Favorites state like Android. */
  private func setCollapsed(_ collapsed: Bool, group: AIReaderPromptGroup) {
    if collapsed {
      collapsedGroupIDs.insert(group.id)
    } else {
      collapsedGroupIDs.remove(group.id)
    }
    guard !group.isFavorites else { return }
    AIReaderPromptGroupCollapseStore.setCollapsed(
      collapsed,
      groupID: group.id,
      context: coordinator.promptContext ?? .verseSelection
    )
  }

  /// Clears the transient route without mutating prompt or favorite state.
  private func dismiss() {
    coordinator.presentation = nil
  }
}

/**
 Stores Android-compatible prompt-category collapse preferences outside synced user data.

 Inputs: prompt context and stable group identity

 Output: the set of groups that should begin collapsed

 Side effects: reads and writes local `UserDefaults`; Favorites is never persisted collapsed

 Failure modes: missing values default to expanded, and an all-collapsed chooser expands its first
 group so the dialog cannot open as an apparently empty surface
 */
enum AIReaderPromptGroupCollapseStore {
  /** Returns restored collapse state with Android's at-least-one-expanded fallback. */
  static func collapsedGroupIDs(
    groups: [AIReaderPromptGroup],
    context: PromptContext,
    defaults: UserDefaults = .standard
  ) -> Set<String> {
    var result = Set(
      groups.filter {
        !$0.isFavorites && defaults.bool(forKey: key(context: context, groupID: $0.id))
      }.map(\.id)
    )
    if !groups.isEmpty, groups.allSatisfy({ result.contains($0.id) }) {
      result.remove(groups[0].id)
    }
    return result
  }

  /** Persists one non-Favorites category collapse value. */
  static func setCollapsed(
    _ collapsed: Bool,
    groupID: String,
    context: PromptContext,
    defaults: UserDefaults = .standard
  ) {
    defaults.set(collapsed, forKey: key(context: context, groupID: groupID))
  }

  /// Mirrors Android's context/category preference-key partitioning.
  private static func key(context: PromptContext, groupID: String) -> String {
    "llm_cat_collapsed_\(context.rawValue)_\(groupID)"
  }
}

/**
 Presents Android's sequential specification and optional model-selection dialogs.

 Android never combines these controls into a native settings form: specification is confirmed
 first, then a model row starts the prompt immediately when model selection is required.

 Inputs: coordinator-owned specification, model choices, and set-default state

 Output: one shared Android dialog for the current preparation stage

 Side effects: mutates coordinator draft values and starts the selected prompt after confirmation

 Failure modes: empty required specifications and missing model choices cannot start a run
 */
struct AIReaderPromptPreparationDialog: View {
  private enum Stage { case specification, model }

  @Bindable var coordinator: AIReaderRunCoordinator
  @Environment(\.colorScheme) private var colorScheme
  @State private var stage: Stage = .specification

  var body: some View {
    Group {
      if stage == .specification, coordinator.promptRequiresSpecification {
        specificationDialog
      } else if coordinator.promptRequiresModel {
        AIReaderModelSelectionDialog(
          options: coordinator.modelChoices,
          persistSelection: coordinator.canPersistPromptModel
            ? $coordinator.persistSelectedModel
            : nil,
          onSelect: { modelID in
            coordinator.selectedModelID = modelID
            coordinator.startSelectedPrompt()
          },
          onCancel: dismiss
        )
      } else {
        specificationDialog
      }
    }
    .onAppear {
      stage = coordinator.promptRequiresSpecification ? .specification : .model
    }
  }

  /// Android's standalone specify-before-run text dialog.
  private var specificationDialog: some View {
    AndroidDialogWindow(
      colorScheme: colorScheme,
      accessibilityIdentifier: "aiReaderPromptSpecificationDialog",
      onOutsideTap: dismiss
    ) {
      AndroidDialogScaffold(
        title: String(localized: "specify_before_run_title", defaultValue: "Specify task")
      ) {
        AndroidDialogTextInput(
          placeholder: String(
            localized: "specify_before_run_hint",
            defaultValue: "Describe the specific task…"
          ),
          text: $coordinator.userSpecification,
          colorScheme: colorScheme,
          isMultiline: true,
          accessibilityIdentifier: "aiReaderPromptSpecificationInput"
        )
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
      } actions: {
        AndroidDialogTextAction(
          title: String(localized: "cancel", defaultValue: "Cancel"),
          action: dismiss
        )
        AndroidDialogTextAction(
          title: String(localized: "okay", defaultValue: "OK"),
          isEnabled: hasSpecification,
          accessibilityIdentifier: "aiReaderPromptSpecificationOkayButton",
          action: confirmSpecification
        )
      }
    }
  }

  /// Whether Android's required specification contains a non-whitespace instruction.
  private var hasSpecification: Bool {
    !coordinator.userSpecification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Advances to model selection or starts the prompt after the specification dialog.
  private func confirmSpecification() {
    guard hasSpecification else { return }
    if coordinator.promptRequiresModel {
      stage = .model
    } else {
      coordinator.startSelectedPrompt()
    }
  }

  /// Cancels the complete preparation flow like Android's negative button or outside tap.
  private func dismiss() {
    coordinator.presentation = nil
  }
}

/**
 Presents Android's optional regeneration instructions and checkboxes before model selection.

 Inputs: coordinator-owned regeneration drafts and configured model choices

 Output: one regeneration-options dialog followed, when required, by a model list dialog

 Side effects: updates drafts and starts regeneration after an explicit action/model choice

 Failure modes: a required model cannot start until the user selects one
 */
struct AIReaderRegenerationDialog: View {
  private enum Stage { case options, model }

  @Bindable var coordinator: AIReaderRunCoordinator
  @Environment(\.colorScheme) private var colorScheme
  @State private var stage: Stage = .options

  var body: some View {
    Group {
      if stage == .options {
        optionsDialog
      } else {
        AIReaderModelSelectionDialog(
          options: coordinator.modelChoices,
          persistSelection: nil,
          onSelect: { modelID in
            coordinator.regenerationModelID = modelID
            coordinator.startRegeneration()
          },
          onCancel: dismiss
        )
      }
    }
  }

  /// Android's first regeneration dialog containing instructions and two independent checkboxes.
  private var optionsDialog: some View {
    AndroidDialogWindow(
      colorScheme: colorScheme,
      accessibilityIdentifier: "aiReaderRegenerationDialog",
      onOutsideTap: dismiss
    ) {
      AndroidDialogScaffold(
        title: String(localized: "ai_regenerate_title", defaultValue: "Regenerate")
      ) {
        VStack(alignment: .leading, spacing: 8) {
          AndroidDialogTextInput(
            placeholder: String(
              localized: "ai_regenerate_instructions_hint",
              defaultValue: "Additional instructions (optional)"
            ),
            text: $coordinator.regenerationInstructions,
            colorScheme: colorScheme,
            isMultiline: true,
            accessibilityIdentifier: "aiReaderRegenerationInstructionsInput"
          )
          AndroidCheckboxRow(
            title: String(
              localized: "ai_regenerate_keep_previous",
              defaultValue: "Keep previous version"
            ),
            isOn: $coordinator.regenerationKeepsPrevious,
            foregroundColor: AndroidDialogSurfacePalette.primaryText(for: colorScheme),
            accentColor: AndroidDialogSurfacePalette.accent(for: colorScheme),
            accessibilityIdentifier: "aiReaderRegenerationKeepPreviousCheckbox"
          )
          AndroidCheckboxRow(
            title: String(
              localized: "ai_regenerate_fresh_run",
              defaultValue: "Fresh run (ignore previous result)"
            ),
            isOn: $coordinator.regenerationIsFresh,
            foregroundColor: AndroidDialogSurfacePalette.primaryText(for: colorScheme),
            accentColor: AndroidDialogSurfacePalette.accent(for: colorScheme),
            accessibilityIdentifier: "aiReaderRegenerationFreshRunCheckbox"
          )
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
      } actions: {
        AndroidDialogTextAction(
          title: String(localized: "cancel", defaultValue: "Cancel"),
          action: dismiss
        )
        AndroidDialogTextAction(
          title: String(
            localized: "ai_document_regenerate",
            defaultValue: "Regenerate"
          ),
          accessibilityIdentifier: "aiReaderRegenerationConfirmButton",
          action: confirmOptions
        )
      }
    }
  }

  /// Starts immediately or advances to Android's separate model list dialog.
  private func confirmOptions() {
    if coordinator.regenerationRequiresModel {
      stage = .model
    } else {
      coordinator.startRegeneration()
    }
  }

  /// Cancels whichever regeneration stage is currently visible.
  private func dismiss() {
    coordinator.presentation = nil
  }
}

/**
 Presents Android's plain configured-model list with the optional set-default checkbox.

 Inputs: Android-ordered model labels, optional persistence binding, selection and cancel commands

 Output: one shared app-owned model selection dialog

 Side effects: toggles the optional persistence draft and invokes `onSelect` immediately on a row

 Failure modes: empty model arrays show the localized unavailable message and only Cancel remains
 */
struct AIReaderModelSelectionDialog: View {
  let title: String
  let options: [AIReaderModelChoice]
  let persistSelection: Binding<Bool>?
  let onSelect: (UUID) -> Void
  let onCancel: () -> Void

  @Environment(\.colorScheme) private var colorScheme

  /** Creates one reusable plain-list model dialog without selecting or persisting a model. */
  init(
    title: String = String(
      localized: "select_model_before_run_title",
      defaultValue: "Select model"
    ),
    options: [AIReaderModelChoice],
    persistSelection: Binding<Bool>?,
    onSelect: @escaping (UUID) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.title = title
    self.options = options
    self.persistSelection = persistSelection
    self.onSelect = onSelect
    self.onCancel = onCancel
  }

  var body: some View {
    AndroidDialogWindow(
      colorScheme: colorScheme,
      accessibilityIdentifier: "aiReaderModelSelectionDialog",
      onOutsideTap: onCancel
    ) {
      AndroidDialogScaffold(title: title) {
        VStack(alignment: .leading, spacing: 0) {
          if options.isEmpty {
            Text(
              String(
                localized: "agent_log_model_not_configured",
                defaultValue: "No model configured"
              )
            )
            .font(.system(size: 16))
            .foregroundStyle(AndroidDialogSurfacePalette.secondaryText(for: colorScheme))
            .padding(22)
          } else {
            AndroidAdaptiveDialogScrollView {
              LazyVStack(spacing: 0) {
                ForEach(options) { option in
                  AndroidDialogListActionRow(
                    title: option.title,
                    accessibilityIdentifier: "aiReaderModelChoice::\(option.id.uuidString)"
                  ) {
                    onSelect(option.id)
                  }
                  Divider()
                    .overlay(
                      AndroidDialogSurfacePalette.secondaryText(for: colorScheme).opacity(0.20)
                    )
                }
              }
            }
          }

          if let persistSelection {
            AndroidCheckboxRow(
              title: String(
                localized: "set_default_model_for_prompt",
                defaultValue: "Set as default model for this prompt"
              ),
              isOn: persistSelection,
              foregroundColor: AndroidDialogSurfacePalette.primaryText(for: colorScheme),
              accentColor: AndroidDialogSurfacePalette.accent(for: colorScheme),
              accessibilityIdentifier: "aiReaderPersistPromptModelCheckbox"
            )
            .padding(.horizontal, 16)
            .padding(.top, 8)
          }
        }
      } actions: {
        AndroidDialogTextAction(
          title: String(localized: "cancel", defaultValue: "Cancel"),
          accessibilityIdentifier: "aiReaderModelSelectionCancelButton",
          action: onCancel
        )
      }
    }
  }
}

/**
 Presents Android's multi-marker generated-page chooser through a plain AlertDialog item list.

 Inputs: coordinator-owned ordered marker titles and exact document destinations

 Output: one shared app-owned item dialog without invented secondary metadata

 Side effects: opens the selected document marker or cancels on an outside tap

 Failure modes: empty marker arrays render no rows; the coordinator normally suppresses this route
 */
struct AIReaderDocumentMarkerDialog: View {
  @Bindable var coordinator: AIReaderRunCoordinator
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    AndroidDialogWindow(
      colorScheme: colorScheme,
      accessibilityIdentifier: "aiReaderDocumentMarkerDialog",
      onOutsideTap: dismiss
    ) {
      AndroidDialogScaffold(
        title: String(
          localized: "ai_doc_choose_page",
          defaultValue: "Choose AI document page"
        )
      ) {
        AndroidAdaptiveDialogScrollView {
          LazyVStack(spacing: 0) {
            ForEach(coordinator.documentMarkers) { marker in
              AndroidDialogListActionRow(
                title: marker.title,
                accessibilityIdentifier: "aiReaderDocumentMarker::\(marker.id)"
              ) {
                coordinator.openDocumentMarker(marker)
              }
              Divider()
                .overlay(
                  AndroidDialogSurfacePalette.secondaryText(for: colorScheme).opacity(0.20)
                )
            }
          }
        }
      } actions: {
        EmptyView()
      }
    }
  }

  /// Cancels the chooser without opening any generated document.
  private func dismiss() {
    coordinator.presentation = nil
  }
}
