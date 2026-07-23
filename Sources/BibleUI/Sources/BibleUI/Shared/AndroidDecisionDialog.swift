// AndroidDecisionDialog.swift -- Shared Android decision dialog

import SwiftUI

/**
 Renders the application's canonical Android AlertDialog decision surface.

 This component is shared by settings, repositories, reading plans, documents, bookmarks, AI,
 speech, and backup flows. It composes `AndroidDialogWindow` so callers use one scrim, AppCompat
 palette, geometry, and adaptive action treatment instead of feature-local material cards.

 Inputs: localized title/message, ordered semantic actions, and a stable accessibility identifier

 Output: a non-sheet app-owned decision dialog

 Side effects: invokes only the explicitly tapped action closure

 Failure modes: none; callers own state dismissal in their action closures
 */
public struct AndroidDecisionDialog: View {
    /// One ordered Android dialog action.
    public struct Action: Identifiable {
        /// AlertDialog button group used to preserve Android's neutral/decision separation.
        public enum Placement { case neutral, decision }

        /// Semantic action emphasis.
        public enum Style { case normal, destructive }

        /// Stable action identity.
        public let id: String

        /// Localized action title.
        public let title: String

        /// Semantic emphasis used for destructive operations.
        public let style: Style

        /// Android button group; existing callers remain trailing decisions by default.
        public let placement: Placement

        /// Caller-owned command.
        public let perform: () -> Void

        /**
         Creates one semantic Android dialog action.

         - Parameters:
           - id: Stable automation identity.
           - title: Localized visible button label.
           - style: Semantic emphasis for destructive commands.
           - placement: AlertDialog button group. Neutral actions lead; decisions trail.
           - perform: Caller-owned command invoked by a tap.
         - Side effects: none until `perform` is invoked by the rendered button.
         - Failure modes: none.
         */
        public init(
            id: String,
            title: String,
            style: Style,
            placement: Placement = .decision,
            perform: @escaping () -> Void
        ) {
            self.id = id
            self.title = title
            self.style = style
            self.placement = placement
            self.perform = perform
        }
    }

    /// Localized dialog title.
    let title: String

    /// Optional localized explanation.
    let message: String?

    /// Ordered Android actions.
    let actions: [Action]

    /// Stable UI-test identifier.
    let accessibilityIdentifier: String

    /// Active scheme used by the central AppCompat palette.
    @Environment(\.colorScheme) private var colorScheme

    /**
     Creates one canonical Android decision dialog.

     - Parameters:
       - title: Localized heading.
       - message: Optional localized body.
       - actions: Ordered semantic actions; each closure must dismiss owner state when appropriate.
       - accessibilityIdentifier: Stable UI-test identifier, preserving the established automation
         value by default.
     - Side effects: none until an action is tapped.
     - Failure modes: none.
     */
    public init(
        title: String,
        message: String?,
        actions: [Action],
        accessibilityIdentifier: String = "androidMyDocumentDecisionDialog"
    ) {
        self.title = title
        self.message = message
        self.actions = actions
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    public var body: some View {
        AndroidDialogWindow(
            colorScheme: colorScheme,
            accessibilityIdentifier: accessibilityIdentifier,
            allowsOutsideDismissal: false,
            onOutsideTap: {}
        ) {
            AndroidDialogScaffold(title: title) {
                if let message, !message.isEmpty {
                    ScrollView {
                        Text(message)
                            .font(.system(size: 17))
                            .foregroundStyle(AndroidDialogSurfacePalette.secondaryText(for: colorScheme))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, title.isEmpty ? 22 : 0)
                    .padding(.bottom, 8)
                }
            } actions: {
                ViewThatFits(in: .horizontal) {
                    horizontalActions
                    verticalActions
                }
            }
        }
    }

    /// Android's usual trailing action row when every localized label fits without compression.
    private var horizontalActions: some View {
        HStack(spacing: 18) {
            ForEach(neutralActions) { action in
                actionButton(action)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Spacer(minLength: 0)
            ForEach(decisionActions) { action in
                actionButton(action)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    /// Accessible fallback for three actions or longer translated labels on narrow devices.
    private var verticalActions: some View {
        VStack(alignment: .trailing, spacing: 14) {
            ForEach(neutralActions) { action in
                actionButton(action)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(decisionActions) { action in
                actionButton(action)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /** Neutral Android actions rendered at the leading edge in caller-provided order. */
    private var neutralActions: [Action] {
        actions.filter { $0.placement == .neutral }
    }

    /** Negative and positive Android decisions rendered at the trailing edge in order. */
    private var decisionActions: [Action] {
        actions.filter { $0.placement == .decision }
    }

    /** Builds one owner-command button with shared semantic color and automation identity. */
    private func actionButton(_ action: Action) -> some View {
        AndroidDialogTextAction(
            title: action.title,
            isDestructive: action.style == .destructive,
            accessibilityIdentifier: "\(accessibilityIdentifier)Action::\(action.id)",
            action: action.perform
        )
    }
}
