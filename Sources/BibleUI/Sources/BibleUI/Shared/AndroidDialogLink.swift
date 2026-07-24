// AndroidDialogLink.swift — AppCompat URLSpan visual parity for app-owned dialogs

import SwiftUI

/**
 Renders an app-owned dialog hyperlink with Android `URLSpan` semantics.

 Android's HTML-backed AlertDialog messages use `URLSpan`, which combines the active AppCompat
 link/accent color with an underline. Callers can independently preserve Android's surrounding
 `<i>` markup without rebuilding the shared interactive styling.

 Inputs: localized visible title, trusted destination, and optional italic HTML emphasis

 Output: an underlined link whose color matches the shared Android dialog action accent

 Side effects: opens `destination` through SwiftUI's environment after the user activates the link

 Failure modes: none; callers own destination validation before constructing this view
 */
struct AndroidDialogLink: View {
    /// Localized text exposed as the link label.
    private let title: String

    /// Caller-validated external destination.
    private let destination: URL

    /// Whether Android's source HTML wraps this link in `<i>`.
    private let isItalic: Bool

    /// Active AppCompat DayNight appearance used by both links and positive actions.
    @Environment(\.colorScheme) private var colorScheme

    /**
     Creates a URLSpan-equivalent link for one app-owned dialog.

     - Parameters:
       - title: Localized visible label.
       - destination: Trusted URL opened after activation.
       - isItalic: Whether to retain Android's separate italic HTML emphasis.
     - Side effects: none until the link is activated.
     - Failure modes: none.
     */
    init(
        _ title: String,
        destination: URL,
        isItalic: Bool = false
    ) {
        self.title = title
        self.destination = destination
        self.isItalic = isItalic
    }

    var body: some View {
        Link(destination: destination) {
            styledTitle
                .foregroundStyle(AndroidDialogSurfacePalette.accent(for: colorScheme))
        }
    }

    /// Label preserving Android's optional `<i>` markup while always applying URLSpan underline.
    private var styledTitle: Text {
        let underlinedTitle = Text(title).underline()
        return isItalic ? underlinedTitle.italic() : underlinedTitle
    }
}
