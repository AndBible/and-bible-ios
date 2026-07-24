// AndroidActivityAccessibilityMarker.swift -- Stable app-owned activity accessibility marker

import SwiftUI

/**
 Exposes one app-owned Android activity route without applying its identifier to visible children.

 SwiftUI can propagate an accessibility identifier attached to a composite container into nested
 controls. That makes child activity roots and dialog actions undiscoverable even though they are
 visible and interactive. App-owned activity owners place this noninteractive marker beside their
 content so route-level automation remains stable while every real control keeps its own identity.

 Inputs: localized route label, stable route identifier, optional semantic state, and owner surface
 color

 Output: a one-point, visually transparent accessibility element

 Side effects: none; the marker never participates in hit testing

 Failure modes: none; an absent value is exported as an empty accessibility value
 */
public struct AndroidActivityAccessibilityMarker: View {
    /// Localized route name announced by accessibility tooling.
    let label: String

    /// Stable route identity used by UI automation.
    let accessibilityIdentifier: String

    /// Optional compact semantic state exported by the route owner.
    let accessibilityValue: String?

    /// Owner surface color used to keep the marker visually indistinguishable from its activity.
    let surfaceColor: Color

    /**
     Creates one stable app-owned activity marker.

     - Parameters:
       - label: Localized route name.
       - accessibilityIdentifier: Stable route identity.
       - accessibilityValue: Optional compact semantic state for automation.
       - surfaceColor: Owner activity background color.
     - Side effects: none.
     - Failure modes: none.
     */
    public init(
        label: String,
        accessibilityIdentifier: String,
        accessibilityValue: String? = nil,
        surfaceColor: Color
    ) {
        self.label = label
        self.accessibilityIdentifier = accessibilityIdentifier
        self.accessibilityValue = accessibilityValue
        self.surfaceColor = surfaceColor
    }

    public var body: some View {
        Rectangle()
            .fill(surfaceColor.opacity(0.001))
            .frame(width: 1, height: 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityIdentifier(accessibilityIdentifier)
            .accessibilityValue(accessibilityValue ?? "")
            .allowsHitTesting(false)
    }
}

extension View {
    /**
     Adds a stable route or dialog identity as a sibling overlay instead of modifying a composite.

     - Parameters:
       - label: Localized semantic name announced for the owning surface.
       - accessibilityIdentifier: Stable route or dialog identity used by UI automation.
       - accessibilityValue: Optional compact owner state.
       - surfaceColor: Owner-resolved color used by the visually negligible marker.
     - Returns: The original view with one noninteractive accessibility sibling.
     - Side effects: none; the marker never participates in hit testing.
     - Failure modes: none; omitted values export an empty accessibility value.
     */
    func androidAccessibilityIdentityMarker(
        label: String,
        accessibilityIdentifier: String,
        accessibilityValue: String? = nil,
        surfaceColor: Color
    ) -> some View {
        overlay(alignment: .topLeading) {
            AndroidActivityAccessibilityMarker(
                label: label,
                accessibilityIdentifier: accessibilityIdentifier,
                accessibilityValue: accessibilityValue,
                surfaceColor: surfaceColor
            )
        }
    }

    /**
     Adds a stable dialog identity without allowing a composite identifier to replace child IDs.

     - Parameters:
       - label: Optional localized semantic name for the dialog.
       - accessibilityIdentifier: Stable dialog identity used by UI automation.
       - accessibilityValue: Optional compact dialog state.
     - Returns: The original dialog content with a sibling marker using the global dialog palette.
     - Side effects: none; the marker never receives input.
     - Failure modes: none; missing labels and values export as empty strings.
     */
    func androidDialogAccessibilityIdentity(
        label: String = "",
        accessibilityIdentifier: String,
        accessibilityValue: String? = nil
    ) -> some View {
        modifier(
            AndroidDialogAccessibilityIdentityModifier(
                label: label,
                accessibilityIdentifier: accessibilityIdentifier,
                accessibilityValue: accessibilityValue
            )
        )
    }
}

/** Resolves the shared dialog palette before installing a noninteractive sibling identity marker. */
private struct AndroidDialogAccessibilityIdentityModifier: ViewModifier {
    /// Current appearance used by the globally managed Android dialog surface.
    @Environment(\.colorScheme) private var colorScheme

    /// Localized semantic dialog name.
    let label: String

    /// Stable UI-automation identity.
    let accessibilityIdentifier: String

    /// Optional compact state exported by the dialog owner.
    let accessibilityValue: String?

    /**
     Installs the marker without modifying the accessibility tree of `content`.

     - Parameter content: Composite dialog content retaining all descendant identifiers.
     - Returns: Content with one palette-aligned, noninteractive sibling marker.
     - Side effects: none.
     - Failure modes: none.
     */
    func body(content: Content) -> some View {
        content.androidAccessibilityIdentityMarker(
            label: label,
            accessibilityIdentifier: accessibilityIdentifier,
            accessibilityValue: accessibilityValue,
            surfaceColor: AndroidDialogSurfacePalette.background(for: colorScheme)
        )
    }
}
