// AndroidActivityScreen.swift -- Shared app-owned secondary-activity surface

import SwiftUI

/**
 Composes the shared full-screen surface beneath every app-owned Android activity.

 Some activities use the standard `AndroidActivityScreen` app bar while selection activities swap
 between a normal bar and Android contextual action mode. Both still require identical palette,
 sizing, and native-navigation suppression. This lower-level surface accepts caller-owned chrome so
 those variants reuse the application structure instead of rebuilding the surrounding `VStack`.

 Inputs: owner-resolved palette, app-owned chrome, and feature content

 Output: one application-owned activity surface filling the available destination

 Side effects: none; interaction belongs to the supplied chrome and content

 Failure modes: none
 */
struct AndroidActivitySurface<Chrome: View, Content: View>: View {
    /// Application, workspace, or window palette selected by the activity owner.
    let palette: ReaderThemeSurfacePalette

    /// Standard app bar or caller-owned contextual action bar.
    private let chrome: Chrome

    /// Feature-owned content below the activity chrome.
    private let content: Content

    /** Creates the shared activity surface without invoking feature-owned commands. */
    init(
        palette: ReaderThemeSurfacePalette,
        @ViewBuilder chrome: () -> Chrome,
        @ViewBuilder content: () -> Content
    ) {
        self.palette = palette
        self.chrome = chrome()
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            chrome

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(palette.foregroundColor)
        .background(palette.backgroundColor.ignoresSafeArea())
        #if os(iOS)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }
}

/**
 Composes the common full-screen surface used by Android secondary activities.

 The screen owns the shared action bar, palette propagation, background, and native-navigation-bar
 suppression. Feature views continue to own their content, action ordering, transient overlays, and
 persistence. Keeping this shell shared prevents AI, workspace, document, and settings activities
 from rebuilding slightly different full-screen containers around the same application chrome.

 Inputs: localized activity title, owner-resolved palette, explicit Back action, toolbar actions,
 and feature content

 Output: one application-owned activity surface that fills its available destination

 Side effects: invokes the supplied Back or toolbar commands after explicit taps

 Failure modes: none; a nil Back action omits the navigation affordance
 */
struct AndroidActivityScreen<Actions: View, Content: View>: View {
    /// Localized Android activity title.
    let title: String

    /// Stable accessibility identity for the shared app bar.
    let accessibilityIdentifier: String

    /// Application, workspace, or window palette selected by the activity owner.
    let palette: ReaderThemeSurfacePalette

    /// Explicit Android Up command.
    let onBack: (() -> Void)?

    /// Feature-owned action-bar controls in Android menu order.
    private let actions: Actions

    /// Feature-owned activity content below the app bar.
    private let content: Content

    /** Creates the shared activity shell without invoking any supplied commands. */
    init(
        title: String,
        accessibilityIdentifier: String,
        palette: ReaderThemeSurfacePalette,
        onBack: (() -> Void)?,
        @ViewBuilder actions: () -> Actions,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.accessibilityIdentifier = accessibilityIdentifier
        self.palette = palette
        self.onBack = onBack
        self.actions = actions()
        self.content = content()
    }

    var body: some View {
        AndroidActivitySurface(palette: palette) {
            AndroidActivityTopAppBar(
                title: title,
                accessibilityIdentifier: accessibilityIdentifier,
                backgroundColor: palette.toolbarBackgroundColor,
                foregroundColor: palette.toolbarForegroundColor,
                onBack: onBack
            ) {
                actions
            }
        } content: {
            content
        }
    }
}
