// AIReaderAgentLogWidget.swift -- Android embedded agent-log parity

import BibleCore
import SwiftUI

/**
 Renders Android's `AgentLogWidget` as an embedded reader panel instead of a modal card.

 The collapsed header, expandable 200-point log, model selector, stop/close command, exact Android
 icon assets, fixed log colors, and window-owned content palette mirror Android's reader hierarchy.
 Permission and continuation decisions use shared AlertDialog windows above the panel; raw logs open
 through the shared full-activity shell. No scrim is present while the ordinary widget is visible.

 Inputs: pane-scoped coordinator and active window theme palette

 Output: a bottom-anchored app-owned agent-log widget plus transient app-owned child routes

 Side effects: toggles local expansion, selects the global default model, answers suspended agent
 decisions, stops or closes the run, and opens/closes the live raw-log activity

 Failure modes: persistence/execution failures are reported by the coordinator and retained in log
 */
struct AIReaderAgentLogWidget: View {
  @Bindable var coordinator: AIReaderRunCoordinator
  let surfacePalette: ReaderThemeSurfacePalette

  @State private var isExpanded = false
  @State private var showsModelSelector = false
  @State private var permanentPermissionConfirmationID: UUID?
  @State private var rawLogSnapshot: AIReaderLiveRawLogSnapshot?

  var body: some View {
    ZStack(alignment: .bottom) {
      Color.clear
        .allowsHitTesting(false)

      widgetPanel

      if showsModelSelector {
        AIReaderModelSelectionDialog(
          title: String(
            localized: "agent_log_select_model",
            defaultValue: "Select default model"
          ),
          options: coordinator.modelChoices,
          persistSelection: nil,
          onSelect: { modelID in
            coordinator.selectDefaultModel(modelID)
            showsModelSelector = false
          },
          onCancel: { showsModelSelector = false }
        )
      }

      if let permission = coordinator.pendingPermission {
        if permanentPermissionConfirmationID == permission.id {
          permanentPermissionConfirmation(permission)
        } else {
          AIReaderAgentPermissionDialog(
            permission: permission,
            onGrant: handlePermissionGrant
          )
        }
      }

      if let continuation = coordinator.pendingIterationContinuation {
        iterationContinuationDialog(continuation)
      }

      if let rawLogSnapshot {
        AIReaderLiveRawLogView(
          snapshot: rawLogSnapshot,
          surfacePalette: surfacePalette,
          onBack: { self.rawLogSnapshot = nil }
        )
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    .accessibilityIdentifier("aiReaderAgentLogPresentation")
  }

  /// Android's visible widget panel; unlike a modal, it never dims or blocks the reader above it.
  private var widgetPanel: some View {
    VStack(spacing: 0) {
      Rectangle()
        .fill(surfacePalette.inactiveBorderColor)
        .frame(height: 1)

      header

      if isExpanded {
        expandedLog
          .frame(height: 200)
      }
    }
    .frame(maxWidth: .infinity)
    .background(surfacePalette.backgroundColor)
    .shadow(color: Color.black.opacity(0.28), radius: 8, y: -3)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("aiReaderAgentLogWidget")
  }

  /// Collapsed Android header with independent expand and stop/close hit targets.
  private var header: some View {
    HStack(spacing: 8) {
      Button(action: toggleExpanded) {
        AndBibleIconView(
          name: isExpanded ? "PromptCollapseIndicator" : "PromptExpandIndicator",
          size: 24
        )
        .frame(width: 48, height: 44)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(surfacePalette.foregroundColor)
      .accessibilityLabel(
        String(
          localized: "agent_log_expand",
          defaultValue: "Expand/collapse agent log"
        )
      )
      .accessibilityIdentifier("aiReaderAgentLogExpandButton")

      Button(action: toggleExpanded) {
        HStack(spacing: 8) {
          AndBibleIconView(name: "LabelIconRobot", size: 24)
            .foregroundStyle(AndroidResourcePalette.agentLogInformation)
          Text(latestStatusText)
            .font(.system(size: 14))
            .foregroundStyle(surfacePalette.foregroundColor)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      Button(action: stopOrClose) {
        AndBibleIconView(
          name: coordinator.isRunning ? "SpeakStop" : "ActivityClose",
          size: 24
        )
        .frame(width: 48, height: 44)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(
        coordinator.isRunning
          ? AndroidResourcePalette.grey500
          : surfacePalette.foregroundColor
      )
      .accessibilityLabel(
        coordinator.isRunning
          ? String(localized: "agent_log_stop", defaultValue: "Stop AI")
          : String(localized: "agent_log_close", defaultValue: "Close agent log")
      )
      .accessibilityIdentifier("aiReaderAgentLogStopCloseButton")
    }
    .padding(.horizontal, 2)
    .padding(.vertical, 4)
  }

  /// Expanded Android RecyclerView equivalent, including its synthetic model-selector row.
  private var expandedLog: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 0) {
          if !coordinator.modelChoices.isEmpty {
            modelSelectorRow
          }

          ForEach(coordinator.runLog) { entry in
            AIReaderAgentLogEntryRow(
              entry: entry,
              surfacePalette: surfacePalette
            )
            .id(entry.id)
            Divider()
              .overlay(surfacePalette.inactiveBorderColor)
          }

          if let liveRawLog = coordinator.liveRawLog {
            Button {
              rawLogSnapshot = liveRawLog
            } label: {
              Text(
                String(
                  localized: "agent_log_view_raw",
                  defaultValue: "View raw LLM log"
                )
              )
              .font(.system(size: 14))
              .foregroundStyle(AndroidResourcePalette.agentLogInformation)
              .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
              .padding(.horizontal, 16)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("aiReaderAgentLogViewRawButton")
          }
        }
      }
      .onChange(of: coordinator.runLog.last?.id) { _, latestID in
        guard isExpanded, let latestID else { return }
        proxy.scrollTo(latestID, anchor: .bottom)
      }
    }
    .background(surfacePalette.backgroundColor)
  }

  /// Synthetic first row used by Android to change the global default model from the panel.
  private var modelSelectorRow: some View {
    Button {
      showsModelSelector = true
    } label: {
      HStack(spacing: 12) {
        AndBibleIconView(name: "LabelIconRobot", size: 24)
          .foregroundStyle(AndroidResourcePalette.agentLogInformation)
        Text(defaultModelSelectorTitle)
          .font(.system(size: 14))
          .foregroundStyle(AndroidResourcePalette.agentLogInformation)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.horizontal, 16)
      .frame(minHeight: 48)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("aiReaderAgentLogModelSelector")
  }

  /// Latest meaningful Android header message, preferring actions/comments over generic info.
  private var latestStatusText: String {
    coordinator.runLog.last(where: { $0.kind == .action || $0.kind == .response })?.message
      ?? coordinator.runLog.last(where: { $0.kind != .information })?.message
      ?? coordinator.runLog.last?.message
      ?? String(localized: "agent_log_idle", defaultValue: "AI Assistant")
  }

  /// Localized synthetic model row with only Android's model identifier in the current-value slot.
  private var defaultModelSelectorTitle: String {
    let current = coordinator.modelChoices.first(where: { $0.id == coordinator.defaultModelID })?
      .modelName
      ?? String(
        localized: "agent_log_model_not_configured",
        defaultValue: "No model configured"
      )
    return String(
      format: String(
        localized: "agent_log_model_selector",
        defaultValue: "Change default model (currently: %1$@)"
      ),
      current
    )
  }

  /// Toggles only the widget's local RecyclerView visibility.
  private func toggleExpanded() {
    isExpanded.toggle()
  }

  /// Matches Android's running Stop and idle Close semantics.
  private func stopOrClose() {
    if coordinator.isRunning {
      coordinator.cancelRun()
    } else {
      coordinator.dismissCompletedRun()
    }
  }

  /// Routes Always Allow through Android's second confirmation dialog; other grants resolve now.
  private func handlePermissionGrant(_ grant: AgentPermissionGrant) {
    if grant == .allowAlways, let permission = coordinator.pendingPermission {
      permanentPermissionConfirmationID = permission.id
    } else {
      coordinator.answerPermission(grant)
    }
  }

  /// Android `simpleQuestion` confirmation before persisting a permanent tool grant.
  private func permanentPermissionConfirmation(
    _ permission: AIReaderPendingPermission
  ) -> some View {
    AndroidDecisionDialog(
      title: String(
        localized: "permission_always_allow_confirm_title",
        defaultValue: "Always allow?"
      ),
      message: String(
        format: String(
          localized: "permission_always_allow_confirm",
          defaultValue: "Are you sure you want to permanently allow \"%1$@\"?"
        ),
        permission.toolTitle
      ) + "\n\n" + String(
        localized: "permission_always_allow_confirm_reset_hint",
        defaultValue: "You can reset this in AI Settings."
      ),
      actions: [
        .init(
          id: "cancel",
          title: String(localized: "cancel", defaultValue: "Cancel"),
          style: .normal
        ) {
          permanentPermissionConfirmationID = nil
          coordinator.answerPermission(.allowOnce)
        },
        .init(
          id: "okay",
          title: String(localized: "okay", defaultValue: "OK"),
          style: .normal
        ) {
          permanentPermissionConfirmationID = nil
          coordinator.answerPermission(.allowAlways)
        },
      ],
      accessibilityIdentifier: "aiReaderPermanentPermissionConfirmationDialog"
    )
  }

  /// Android `simpleQuestion` shown after the configured iteration block is exhausted.
  private func iterationContinuationDialog(
    _ continuation: AIReaderPendingIterationContinuation
  ) -> some View {
    AndroidDecisionDialog(
      title: String(localized: "llm_continue_iterations_title", defaultValue: "Continue?"),
      message: String(
        format: String(
          localized: "llm_continue_iterations_message",
          defaultValue:
            "The AI agent has reached its limit of %1$d iterations without completing. Continue for %2$d more iterations?"
        ),
        continuation.currentIteration,
        continuation.increment
      ),
      actions: [
        .init(
          id: "cancel",
          title: String(localized: "cancel", defaultValue: "Cancel"),
          style: .normal
        ) {
          coordinator.answerIterationContinuation(false)
        },
        .init(
          id: "okay",
          title: String(localized: "okay", defaultValue: "OK"),
          style: .normal
        ) {
          coordinator.answerIterationContinuation(true)
        },
      ],
      accessibilityIdentifier: "aiReaderIterationContinuationDialog"
    )
  }
}

/**
 Renders Android's custom five-choice agent permission AlertDialog.

 Inputs: localized tool/action description and grant callback

 Output: one shared dialog window with sentence-case full-width permission commands

 Side effects: invokes exactly one grant; outside taps resolve Deny like Android cancellation

 Failure modes: none; continuation lifecycle remains owned by the coordinator
 */
private struct AIReaderAgentPermissionDialog: View {
  let permission: AIReaderPendingPermission
  let onGrant: (AgentPermissionGrant) -> Void

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    AndroidDialogWindow(
      colorScheme: colorScheme,
      accessibilityIdentifier: "aiReaderAgentPermissionDialog",
      onOutsideTap: { onGrant(.deny) }
    ) {
      AndroidDialogScaffold(
        title: String(localized: "agent_permission_title", defaultValue: "Agent Permission")
      ) {
        VStack(spacing: 0) {
          AndroidAdaptiveDialogScrollView {
            Text(permissionMessage)
              .font(.system(size: 16))
              .foregroundStyle(AndroidDialogSurfacePalette.primaryText(for: colorScheme))
              .frame(maxWidth: .infinity, alignment: .leading)
              .fixedSize(horizontal: false, vertical: true)
              .padding(.horizontal, 24)
              .padding(.top, 16)
              .padding(.bottom, 8)
          }

          VStack(spacing: 0) {
            permissionAction(
              String(localized: "permission_allow_once", defaultValue: "Allow once"),
              id: "allowOnce",
              grant: .allowOnce
            )
            permissionAction(
              String(
                localized: "permission_allow_for_session",
                defaultValue: "Allow for this session"
              ),
              id: "allowForSession",
              grant: .allowForRun
            )
            permissionAction(
              String(
                localized: "permission_allow_all_session",
                defaultValue: "Allow all tools this session"
              ),
              id: "allowAllSession",
              grant: .allowAllToolsForRun
            )
            permissionAction(
              String(
                format: String(
                  localized: "permission_allow_always",
                  defaultValue: "Always allow \"%1$@\""
                ),
                permission.toolTitle
              ),
              id: "allowAlways",
              grant: .allowAlways
            )
            AndroidDialogListActionRow(
              title: String(localized: "permission_deny", defaultValue: "Deny"),
              isDestructive: true,
              accessibilityIdentifier: "aiReaderPermissionAction::deny"
            ) {
              onGrant(.deny)
            }
          }
          .padding(.horizontal, 8)
          .padding(.bottom, 8)
        }
      } actions: {
        EmptyView()
      }
    }
  }

  /// Exact Android permission message, preferring the formatted concrete action when available.
  private var permissionMessage: String {
    if let action = permission.actionDescription, !action.isEmpty {
      return String(
        format: String(
          localized: "agent_permission_message_with_action",
          defaultValue: "The AI assistant wants to:\n\n%1$@"
        ),
        action
      )
    }
    return String(
      format: String(
        localized: "agent_permission_message",
        defaultValue: "The AI assistant wants to use \"%1$@\":\n\n%2$@"
      ),
      permission.toolTitle,
      permission.toolDescription
    )
  }

  /// Creates one shared permission row bound to the caller's suspended decision.
  private func permissionAction(
    _ title: String,
    id: String,
    grant: AgentPermissionGrant
  ) -> some View {
    AndroidDialogListActionRow(
      title: title,
      accessibilityIdentifier: "aiReaderPermissionAction::\(id)"
    ) {
      onGrant(grant)
    }
  }
}

/** One Android-colored agent log row using packaged source drawables instead of SF facsimiles. */
private struct AIReaderAgentLogEntryRow: View {
  let entry: AIReaderRunLogEntry
  let surfacePalette: ReaderThemeSurfacePalette

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      AndBibleIconView(name: iconName, size: 24)
        .foregroundStyle(iconColor)
        .frame(width: 28, height: 28)
      Text(entry.message)
        .font(.system(size: 14))
        .foregroundStyle(surfacePalette.foregroundColor)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  /// Exact Android drawable asset selected for the coordinator's bounded log kind.
  private var iconName: String {
    switch entry.kind {
    case .information: "AgentLogInfo"
    case .action: "AgentLogAction"
    case .response: "AgentLogComment"
    case .failure: "AgentLogError"
    }
  }

  /// Exact named Android log resource color selected for the row kind.
  private var iconColor: Color {
    switch entry.kind {
    case .information: AndroidResourcePalette.agentLogInformation
    case .action: AndroidResourcePalette.agentLogAction
    case .response: AndroidResourcePalette.agentLogComment
    case .failure: AndroidResourcePalette.agentLogError
    }
  }
}
