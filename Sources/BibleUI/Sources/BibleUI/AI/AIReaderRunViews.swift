// AIReaderRunViews.swift -- Native Android-compatible AI action and execution surfaces

import BibleCore
import SwiftUI
import SwordKit

/// Attaches the pane-scoped AI presentation state to one reader hierarchy.
struct AIReaderCoordinatorHost: View {
  @Bindable var coordinator: AIReaderRunCoordinator
  let swordManager: SwordManager?

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
      .sheet(item: $coordinator.presentation) { route in
        destination(for: route)
      }
  }

  /** Builds the exact native surface associated with a coordinator route. */
  @ViewBuilder
  private func destination(for route: AIReaderPresentationRoute) -> some View {
    switch route {
    case .promptChooser:
      AIReaderPromptChooserView(coordinator: coordinator)
    case .promptPreparation:
      AIReaderPromptPreparationView(coordinator: coordinator)
    case .run:
      AIReaderRunActivityView(coordinator: coordinator)
    case .regeneration:
      AIReaderRegenerationView(coordinator: coordinator)
    case .documentChooser:
      AIReaderDocumentMarkerChooserView(coordinator: coordinator)
    case .promptEditor(_, let promptID):
      NavigationStack {
        AIPromptEditorView(
          promptID: promptID,
          swordManager: swordManager,
          onChanged: {}
        )
      }
    }
  }
}

/// Grouped prompt chooser matching Android's context-filtered action dialog.
private struct AIReaderPromptChooserView: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var coordinator: AIReaderRunCoordinator

  var body: some View {
    NavigationStack {
      List {
        ForEach(coordinator.promptGroups) { group in
          Section(group.title) {
            ForEach(group.prompts, id: \.prompt.id) { entry in
              Button {
                coordinator.selectPrompt(entry)
              } label: {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                  Image(systemName: group.isFavorites ? "star.fill" : "sparkles")
                    .foregroundStyle(group.isFavorites ? .yellow : .secondary)
                    .accessibilityHidden(true)
                  VStack(alignment: .leading, spacing: 3) {
                    Text(entry.prompt.name)
                      .foregroundStyle(.primary)
                    if let description = entry.prompt.promptDescription,
                      !description.isEmpty
                    {
                      Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                  }
                }
              }
            }
          }
        }
      }
      .navigationTitle(String(localized: "select_llm_prompt", defaultValue: "Select AI Action"))
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(String(localized: "cancel", defaultValue: "Cancel")) {
            coordinator.presentation = nil
            dismiss()
          }
        }
      }
    }
  }
}

/// Collects optional specification and model selection before a prompt starts.
private struct AIReaderPromptPreparationView: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var coordinator: AIReaderRunCoordinator

  var body: some View {
    NavigationStack {
      Form {
        if coordinator.promptRequiresSpecification {
          Section(String(localized: "specify_before_run_title", defaultValue: "Specify task")) {
            TextEditor(text: $coordinator.userSpecification)
              .frame(minHeight: 120)
          }
        }

        if coordinator.promptRequiresModel {
          Section(String(localized: "prompt_model_override", defaultValue: "Model")) {
            Picker(
              String(localized: "prompt_model_override", defaultValue: "Model"),
              selection: $coordinator.selectedModelID
            ) {
              Text(String(localized: "select_model_before_run_title", defaultValue: "Select model"))
                .tag(UUID?.none)
              ForEach(coordinator.modelChoices) { model in
                Text(model.title).tag(Optional(model.id))
              }
            }

            if coordinator.canPersistPromptModel {
              Toggle(
                String(
                  localized: "set_default_model_for_prompt",
                  defaultValue: "Set as default model for this prompt"
                ),
                isOn: $coordinator.persistSelectedModel
              )
            }
          }
        }
      }
      .navigationTitle(coordinator.selectedPrompt?.prompt.name ?? "")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(String(localized: "cancel", defaultValue: "Cancel")) {
            coordinator.presentation = nil
            dismiss()
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button {
            coordinator.startSelectedPrompt()
          } label: {
            Label(String(localized: "okay", defaultValue: "OK"), systemImage: "play.fill")
          }
          .disabled(!canStart)
          .help(String(localized: "okay", defaultValue: "OK"))
        }
      }
    }
  }

  private var canStart: Bool {
    let hasSpecification = !coordinator.userSpecification
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .isEmpty
    return (!coordinator.promptRequiresSpecification || hasSpecification)
      && (!coordinator.promptRequiresModel || coordinator.selectedModelID != nil)
  }
}

/// Visible activity log and permission suspension surface for one active run.
private struct AIReaderRunActivityView: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var coordinator: AIReaderRunCoordinator
  @State private var permanentPermissionConfirmationID: UUID?

  var body: some View {
    NavigationStack {
      List {
        if let permission = coordinator.pendingPermission {
          permissionSection(permission)
        }

        if let continuation = coordinator.pendingIterationContinuation {
          iterationContinuationSection(continuation)
        }

        if let failure = coordinator.failureMessage {
          Section {
            Label(failure, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
          }
        }

        Section(String(localized: "agent_log_idle", defaultValue: "AI Assistant")) {
          if coordinator.runLog.isEmpty {
            HStack(spacing: 10) {
              ProgressView()
              Text(
                String(
                  localized: "ai_agent_notification_running",
                  defaultValue: "AI agent working…"
                )
              )
              .foregroundStyle(.secondary)
            }
          } else {
            ForEach(coordinator.runLog) { entry in
              Label(entry.message, systemImage: icon(for: entry.kind))
                .foregroundStyle(color(for: entry.kind))
                .font(.callout)
                .textSelection(.enabled)
            }
          }
        }
      }
      .navigationTitle(coordinator.runTitle)
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .interactiveDismissDisabled(coordinator.isRunning)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          if coordinator.isRunning {
            Button(role: .destructive) {
              coordinator.cancelRun()
            } label: {
              Label(String(localized: "cancel", defaultValue: "Cancel"), systemImage: "stop.fill")
            }
            .help(String(localized: "cancel", defaultValue: "Cancel"))
          } else {
            Button(String(localized: "done", defaultValue: "Done")) {
              coordinator.dismissCompletedRun()
              dismiss()
            }
          }
        }
      }
    }
  }

  /** Presents all five Android permission decisions for one concrete write operation. */
  private func permissionSection(_ permission: AIReaderPendingPermission) -> some View {
    Section(String(localized: "agent_permission_title", defaultValue: "Agent Permission")) {
      Label(permission.toolTitle, systemImage: "hand.raised.fill")
        .font(.headline)
      Text(permission.toolDescription)
        .font(.callout)
      if let action = permission.actionDescription {
        Text(action)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      permissionButton(
        String(localized: "permission_deny", defaultValue: "Deny"),
        icon: "xmark",
        grant: .deny,
        role: .destructive
      )
      permissionButton(
        String(localized: "permission_allow_once", defaultValue: "Allow once"),
        icon: "checkmark",
        grant: .allowOnce
      )
      permissionButton(
        String(localized: "permission_allow_for_session", defaultValue: "Allow for this session"),
        icon: "play",
        grant: .allowForRun
      )
      permissionButton(
        String(
          localized: "permission_allow_all_session",
          defaultValue: "Allow all tools this session"
        ),
        icon: "checkmark.shield",
        grant: .allowAllToolsForRun
      )
      if permanentPermissionConfirmationID == permission.id {
        Text(
          String(
            format: String(
              localized: "permission_always_allow_confirm",
              defaultValue: "Are you sure you want to permanently allow \"%1$@\"?"
            ),
            permission.toolTitle
          )
        )
        Text(
          String(
            localized: "permission_always_allow_confirm_reset_hint",
            defaultValue: "You can reset this in AI Settings."
          )
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        Button(role: .cancel) {
          permanentPermissionConfirmationID = nil
          coordinator.answerPermission(.allowOnce)
        } label: {
          Label(String(localized: "no", defaultValue: "No"), systemImage: "xmark")
        }
        Button {
          permanentPermissionConfirmationID = nil
          coordinator.answerPermission(.allowAlways)
        } label: {
          Label(String(localized: "yes", defaultValue: "Yes"), systemImage: "checkmark")
        }
      } else {
        Button {
          permanentPermissionConfirmationID = permission.id
        } label: {
          Label(
            String(
              localized: "permission_option_always_allow",
              defaultValue: "Always allow"
            ),
            systemImage: "lock.open"
          )
        }
      }
    }
  }

  /** Presents Android's explicit decision after a configured iteration block is exhausted. */
  private func iterationContinuationSection(
    _ continuation: AIReaderPendingIterationContinuation
  ) -> some View {
    Section(String(localized: "llm_continue_iterations_title", defaultValue: "Continue?")) {
      Text(
        String(
          format: String(
            localized: "llm_continue_iterations_message",
            defaultValue:
              "The AI agent has reached its limit of %1$d iterations without completing. Continue for %2$d more iterations?"
          ),
          continuation.currentIteration,
          continuation.increment
        )
      )
      Button(role: .cancel) {
        coordinator.answerIterationContinuation(false)
      } label: {
        Label(String(localized: "no", defaultValue: "No"), systemImage: "xmark")
      }
      Button {
        coordinator.answerIterationContinuation(true)
      } label: {
        Label(String(localized: "yes", defaultValue: "Yes"), systemImage: "checkmark")
      }
    }
  }

  /** Creates one explicit command button for a permission grant. */
  private func permissionButton(
    _ title: String,
    icon: String,
    grant: AgentPermissionGrant,
    role: ButtonRole? = nil
  ) -> some View {
    Button(role: role) {
      coordinator.answerPermission(grant)
    } label: {
      Label(title, systemImage: icon)
    }
  }

  private func icon(for kind: AIReaderRunLogEntry.Kind) -> String {
    switch kind {
    case .information: "info.circle"
    case .action: "gearshape"
    case .response: "text.bubble"
    case .failure: "exclamationmark.triangle"
    }
  }

  private func color(for kind: AIReaderRunLogEntry.Kind) -> Color {
    kind == .failure ? .red : .primary
  }
}

/// Collects Android's keep/fresh/instruction/model regeneration choices.
private struct AIReaderRegenerationView: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var coordinator: AIReaderRunCoordinator

  var body: some View {
    NavigationStack {
      Form {
        Section(
          String(
            localized: "ai_regenerate_instructions_hint",
            defaultValue: "Additional instructions (optional)"
          )
        ) {
          TextEditor(text: $coordinator.regenerationInstructions)
            .frame(minHeight: 100)
        }
        Section {
          Toggle(
            String(localized: "ai_regenerate_keep_previous", defaultValue: "Keep previous version"),
            isOn: $coordinator.regenerationKeepsPrevious
          )
          Toggle(
            String(
              localized: "ai_regenerate_fresh_run",
              defaultValue: "Fresh run (ignore previous result)"
            ),
            isOn: $coordinator.regenerationIsFresh
          )
        }
        if coordinator.regenerationRequiresModel {
          Section(String(localized: "prompt_model_override", defaultValue: "Model")) {
            Picker(
              String(localized: "prompt_model_override", defaultValue: "Model"),
              selection: $coordinator.regenerationModelID
            ) {
              Text(String(localized: "select_model_before_run_title", defaultValue: "Select model"))
                .tag(UUID?.none)
              ForEach(coordinator.modelChoices) { model in
                Text(model.title).tag(Optional(model.id))
              }
            }
          }
        }
      }
      .navigationTitle(String(localized: "ai_regenerate_title", defaultValue: "Regenerate"))
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(String(localized: "cancel", defaultValue: "Cancel")) {
            coordinator.presentation = nil
            dismiss()
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button {
            coordinator.startRegeneration()
          } label: {
            Label(
              String(localized: "ai_document_regenerate", defaultValue: "Regenerate"),
              systemImage: "arrow.clockwise"
            )
          }
          .disabled(coordinator.regenerationRequiresModel && coordinator.regenerationModelID == nil)
          .help(String(localized: "ai_document_regenerate", defaultValue: "Regenerate"))
        }
      }
    }
  }
}

/// Chooses one generated My Documents destination when a source has several markers.
private struct AIReaderDocumentMarkerChooserView: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var coordinator: AIReaderRunCoordinator

  var body: some View {
    NavigationStack {
      List(coordinator.documentMarkers) { marker in
        Button {
          coordinator.openDocumentMarker(marker)
          dismiss()
        } label: {
          VStack(alignment: .leading, spacing: 3) {
            Text(marker.title)
              .foregroundStyle(.primary)
            Text(marker.documentInitials)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      .navigationTitle(
        String(localized: "ai_doc_choose_page", defaultValue: "Choose AI document page")
      )
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(String(localized: "cancel", defaultValue: "Cancel")) {
            coordinator.presentation = nil
            dismiss()
          }
        }
      }
    }
  }
}
