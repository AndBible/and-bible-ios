// AIReaderRunViews.swift -- Reader-owned AI route composition

import BibleCore
import SwiftUI

/**
 Attaches the pane-scoped AI presentation state to one reader hierarchy.

 Android AlertDialog routes delegate to shared dialog windows, while the active run uses the
 embedded agent-log widget at the bottom of the reader. Full activities are rendered by their own
 shared activity shells. The host does not draw a feature-local scrim, card, or native iOS sheet.

 Inputs: pane coordinator, resolved reader/window palette, and Prompt Edit navigation callback

 Output: the currently selected app-owned AI dialog, widget, or navigation handoff

 Side effects: the Prompt Edit route clears coordinator presentation before invoking its callback

 Failure modes: navigation failures remain owned by the parent reader callback
 */
struct AIReaderCoordinatorHost: View {
  @Bindable var coordinator: AIReaderRunCoordinator

  /// Active pane palette used by Android's embedded agent-log widget and child activities.
  let surfacePalette: ReaderThemeSurfacePalette

  /**
   Escalates Android's full PromptEditActivity route to reader-owned navigation.

   The closure receives the prompt identity after this coordinator clears its transient route.
   It mutates the parent reader's navigation state; no persistence or asynchronous work occurs
   here. If the parent cannot present the destination, it owns the resulting navigation failure.
   */
  let onPresentPromptEditor: (UUID) -> Void

  var body: some View {
    presentedContent
  }

  /// Resolves one typed route without wrapping it in locally invented presentation chrome.
  @ViewBuilder
  private var presentedContent: some View {
    switch coordinator.presentation {
    case .promptChooser:
      AIReaderPromptChooserDialog(coordinator: coordinator)
    case .promptPreparation:
      AIReaderPromptPreparationDialog(coordinator: coordinator)
    case .run:
      AIReaderAgentLogWidget(
        coordinator: coordinator,
        surfacePalette: surfacePalette
      )
    case .regeneration:
      AIReaderRegenerationDialog(coordinator: coordinator)
    case .documentChooser:
      AIReaderDocumentMarkerDialog(coordinator: coordinator)
    case .promptEditor(_, let promptID):
      Color.clear
        .frame(width: 0, height: 0)
        .onAppear {
          AIReaderPromptEditorHandoff.perform(
            coordinator: coordinator,
            promptID: promptID,
            onPresent: onPresentPromptEditor
          )
        }
    case nil:
      EmptyView()
    }
  }
}

/**
 Performs the one-way transition from the pane-scoped AI coordinator to reader navigation.

 - Parameters:
   - coordinator: The transient AI route owner to clear before navigation.
   - promptID: The already-resolved prompt identity for the destination.
   - onPresent: Parent-reader callback that presents Prompt Edit for `promptID`.
 - Side effects: Clears `coordinator.presentation` and invokes `onPresent` synchronously.
 - Failure modes: The callback owns navigation failures; this helper does not persist or recover.
 */
enum AIReaderPromptEditorHandoff {
  @MainActor
  static func perform(
    coordinator: AIReaderRunCoordinator,
    promptID: UUID,
    onPresent: (UUID) -> Void
  ) {
    coordinator.presentation = nil
    onPresent(promptID)
  }
}
