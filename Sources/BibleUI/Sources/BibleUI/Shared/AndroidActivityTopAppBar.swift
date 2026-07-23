// AndroidActivityTopAppBar.swift -- Shared app-owned Android activity chrome

import SwiftUI

/**
 Renders the common Android secondary-activity action bar used by app-owned management routes.

 The component owns the repeated action-bar geometry, title treatment, and back-button hit target.
 Feature screens supply their Android menu actions and a palette resolved by the owning workspace or
 reader window; the component never invents a local black/white theme.

 Inputs:
 - localized title and stable accessibility identifiers
 - owner-resolved background and foreground colors
 - an optional back action and caller-supplied trailing action buttons

 Output: one fixed-height, app-owned action bar

 Side effects: invokes `onBack` and caller-provided action closures after explicit taps

 Failure modes: none; a nil back action simply omits the navigation affordance
 */
struct AndroidActivityTopAppBar<Actions: View>: View {
    /// Localized activity title.
    let title: String

    /// Stable accessibility identifier for the complete bar.
    let accessibilityIdentifier: String

    /// Optional semantic state exported by the isolated bar marker.
    let accessibilityValue: String?

    /// Palette-owned action-bar background.
    let backgroundColor: Color

    /// Palette-owned title and action tint.
    let foregroundColor: Color

    /// Optional Android Up action.
    let onBack: (() -> Void)?

    /// Shared icon used by the navigation action, normally Android Up or contextual Close.
    let navigationIcon: AndroidPopupMenuIcon

    /// Localized accessibility label for the navigation action.
    let navigationAccessibilityLabel: String

    /// Feature-specific Android menu actions.
    private let actions: Actions

    /**
     Creates a shared Android activity action bar.

     - Parameters:
       - title: Localized title rendered on one line.
       - accessibilityIdentifier: Stable UI-test identifier for the complete bar.
       - accessibilityValue: Optional semantic state exported without modifying child controls.
       - backgroundColor: Workspace/window-resolved action-bar background.
       - foregroundColor: Workspace/window-resolved title and icon color.
       - onBack: Optional Android Up action.
       - navigationIcon: Shared icon for the navigation action; defaults to Android Up.
       - navigationAccessibilityLabel: Localized navigation action label; defaults to Back.
       - actions: Caller-supplied action buttons in Android menu order.
     - Side effects: none until a supplied action is tapped.
     - Failure modes: none.
     */
    init(
        title: String,
        accessibilityIdentifier: String,
        accessibilityValue: String? = nil,
        backgroundColor: Color,
        foregroundColor: Color,
        onBack: (() -> Void)?,
        navigationIcon: AndroidPopupMenuIcon = .asset("ActivityBack"),
        navigationAccessibilityLabel: String = String(localized: "back", defaultValue: "Back"),
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.accessibilityIdentifier = accessibilityIdentifier
        self.accessibilityValue = accessibilityValue
        self.backgroundColor = backgroundColor
        self.foregroundColor = foregroundColor
        self.onBack = onBack
        self.navigationIcon = navigationIcon
        self.navigationAccessibilityLabel = navigationAccessibilityLabel
        self.actions = actions()
    }

    /**
     Builds the shared app bar while isolating its automation identity from child actions.

     - Returns: Fixed-height app-owned Android chrome with independently discoverable controls.
     - Side effects: Supplied actions run only after their corresponding control is tapped.
     - Failure modes: Long titles truncate to one line, matching the prior activity-bar contract.
    */
    var body: some View {
        AndroidActivityTopAppBarLayout(
            accessibilityTitle: title,
            accessibilityIdentifier: accessibilityIdentifier,
            accessibilityValue: accessibilityValue,
            backgroundColor: backgroundColor,
            foregroundColor: foregroundColor,
            onBack: onBack,
            navigationIcon: navigationIcon,
            navigationAccessibilityLabel: navigationAccessibilityLabel
        ) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, onBack == nil ? 16 : 8)
        } actions: {
            actions
        }
    }
}

/**
 Owns the common Android activity-bar geometry for standard and feature-specific title content.

 `AndroidActivityTopAppBar` supplies the normal text title. Activities such as Daily Reading use
 this same owner for interactive title regions instead of reconstructing toolbar `HStack`s that
 bypass the shared palette, navigation target, and isolated accessibility marker.

 Inputs: localized accessibility title, stable identifiers, owner palette, optional navigation
 action, configurable bar height, feature title content, and trailing action content

 Output: one app-owned Android action bar with independently discoverable child controls

 Side effects: invokes the supplied navigation and action closures after explicit taps

 Failure modes: none; feature title content owns its own truncation policy
 */
struct AndroidActivityTopAppBarLayout<TitleContent: View, Actions: View>: View {
    let accessibilityTitle: String
    let accessibilityIdentifier: String
    let accessibilityValue: String?
    let backgroundColor: Color
    let foregroundColor: Color
    let onBack: (() -> Void)?
    let navigationIcon: AndroidPopupMenuIcon
    let navigationAccessibilityLabel: String
    let navigationAccessibilityIdentifier: String
    let barHeight: CGFloat
    let contentSpacing: CGFloat

    private let titleContent: TitleContent
    private let actions: Actions

    /**
     Creates a shared action-bar layout around caller-owned title and action regions.

     - Parameters:
       - accessibilityTitle: Localized activity name exported by the isolated bar marker.
       - accessibilityIdentifier: Stable identity for the complete bar.
       - accessibilityValue: Optional semantic state exported by the isolated marker.
       - backgroundColor: Owner-resolved toolbar background.
       - foregroundColor: Owner-resolved title and action tint.
       - onBack: Optional Android Up or contextual-close action.
       - navigationIcon: Shared navigation drawable.
       - navigationAccessibilityLabel: Localized navigation label.
       - navigationAccessibilityIdentifier: Optional stable identity when a legacy activity already
         exposes a navigation-button contract; defaults to the shared bar convention.
       - barHeight: Activity-specific toolbar height; defaults to Android's 56-point projection.
       - contentSpacing: Horizontal spacing between navigation, title, and action regions.
       - titleContent: Caller-owned visible title region.
       - actions: Caller-owned trailing actions in Android menu order.
     - Side effects: none until a supplied control is activated.
     - Failure modes: none.
     */
    init(
        accessibilityTitle: String,
        accessibilityIdentifier: String,
        accessibilityValue: String? = nil,
        backgroundColor: Color,
        foregroundColor: Color,
        onBack: (() -> Void)?,
        navigationIcon: AndroidPopupMenuIcon = .asset("ActivityBack"),
        navigationAccessibilityLabel: String = String(localized: "back", defaultValue: "Back"),
        navigationAccessibilityIdentifier: String? = nil,
        barHeight: CGFloat = 56,
        contentSpacing: CGFloat = 4,
        @ViewBuilder titleContent: () -> TitleContent,
        @ViewBuilder actions: () -> Actions
    ) {
        self.accessibilityTitle = accessibilityTitle
        self.accessibilityIdentifier = accessibilityIdentifier
        self.accessibilityValue = accessibilityValue
        self.backgroundColor = backgroundColor
        self.foregroundColor = foregroundColor
        self.onBack = onBack
        self.navigationIcon = navigationIcon
        self.navigationAccessibilityLabel = navigationAccessibilityLabel
        self.navigationAccessibilityIdentifier = navigationAccessibilityIdentifier
            ?? "\(accessibilityIdentifier)BackButton"
        self.barHeight = barHeight
        self.contentSpacing = contentSpacing
        self.titleContent = titleContent()
        self.actions = actions()
    }

    /** Builds the shared visible bar and its non-masking automation marker. */
    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: contentSpacing) {
                if let onBack {
                    AndroidActivityTopAppBarActionButton(
                        icon: navigationIcon,
                        accessibilityLabel: navigationAccessibilityLabel,
                        accessibilityIdentifier: navigationAccessibilityIdentifier,
                        foregroundColor: foregroundColor,
                        action: onBack
                    )
                }

                titleContent

                HStack(spacing: 0) {
                    actions
                }
            }
            .frame(height: barHeight)
            .padding(.horizontal, 8)
            .foregroundStyle(foregroundColor)
            .background(backgroundColor)

            if UITestRuntimeConfiguration.enablesDetailedAccessibilityExports {
                AndroidActivityAccessibilityMarker(
                    label: accessibilityTitle,
                    accessibilityIdentifier: accessibilityIdentifier,
                    accessibilityValue: accessibilityValue,
                    surfaceColor: backgroundColor
                )
            }
        }
        .frame(height: barHeight)
        .accessibilityElement(children: .contain)
    }
}

/**
 Renders one icon action in `AndroidActivityTopAppBar` with Android's minimum touch target.

 Inputs are a shared Android icon source, localized accessibility label, stable identifier, owner
 tint, and tap action. Exact packaged Android assets are preferred; the system-symbol case exists
 only for controls whose Android drawable has not yet been ported. The button has no presentation
 state or persistence side effects of its own.
 */
struct AndroidActivityTopAppBarActionButton: View {
    /// Shared exact-asset or explicit fallback icon source.
    let icon: AndroidPopupMenuIcon

    /// Localized VoiceOver label.
    let accessibilityLabel: String

    /// Stable UI-test identifier.
    let accessibilityIdentifier: String

    /// Owner-resolved action tint.
    let foregroundColor: Color

    /// Command invoked after a direct tap.
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            iconView
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(foregroundColor)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    /// Renders the shared icon source without reconstructing feature-local vector geometry.
    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .asset(let name):
            AndBibleIconView(name: name, size: 24)
        case .system(let name):
            Image(systemName: name)
                .font(.system(size: 24, weight: .medium))
        }
    }
}

/**
 Renders Android's text-bearing `SHOW_AS_ACTION_ALWAYS` command in a shared activity top bar.

 Android uses this treatment for quick document abbreviations such as KJV and commentary initials.
 Feature owners supply the already-shortened label and command while this component owns the common
 touch target, typography, tint, and accessibility treatment.
 */
struct AndroidActivityTopAppBarTextActionButton: View {
    /// Visible compact Android action label.
    let title: String

    /// Localized VoiceOver description of the represented command.
    let accessibilityLabel: String

    /// Stable UI-test identity.
    let accessibilityIdentifier: String

    /// Owner-resolved action tint.
    let foregroundColor: Color

    /// Parent-owned action.
    let action: () -> Void

    /**
     Builds one compact text action with Android's minimum interactive height.

     - Returns: Plain app-owned toolbar button.
     - Side effects: Invokes `action` after a direct tap.
     - Failure modes: Long input is truncated by the feature's Android character-budget policy.
     */
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 5)
                .frame(minWidth: 38, minHeight: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(foregroundColor)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(title)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/**
 Renders Android's `always|withText` action containing an exact drawable and compact label.

 SearchResults uses this for the selected-document action. The feature supplies the localized
 abbreviation summary and packaged icon while the shared bar owns minimum touch geometry,
 truncation, palette tint, and accessibility.
 */
struct AndroidActivityTopAppBarIconTextActionButton: View {
    let title: String
    let icon: AndroidPopupMenuIcon
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let foregroundColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                iconView
                    .frame(width: 24, height: 24)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.horizontal, 4)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(foregroundColor)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(title)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    /// Renders the exact asset or explicit fallback carried by the shared icon contract.
    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .asset(let name):
            AndBibleIconView(name: name, size: 24)
        case .system(let name):
            Image(systemName: name)
                .font(.system(size: 24, weight: .medium))
        }
    }
}
