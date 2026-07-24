// AndroidPreferenceRows.swift -- Shared app-owned Android preference controls

import SwiftUI

/**
 Renders Android Preference's icon/title/summary label block from owner-supplied colors.

 Switch and action preferences share this exact leading layout so feature settings screens do not
 independently reconstruct preference padding, icon tint, or typography. Exact ported Android
 drawable assets are preferred through `AndroidPopupMenuIcon.asset`.

 Inputs: icon, localized title/summary, and owner palette

 Output: one presentation-only preference label

 Side effects: none

 Failure modes: missing optional icons collapse their reserved column
 */
private struct AndroidPreferenceLabel: View {
    let icon: AndroidPopupMenuIcon?
    let title: String
    let summary: String?
    let foregroundColor: Color
    let secondaryColor: Color

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            if let icon {
                iconView(icon)
                    .frame(width: 32, height: 32)
                    .foregroundStyle(AndroidResourcePalette.darkerGray)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(foregroundColor)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 14))
                        .foregroundStyle(secondaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Projects a shared exact Android asset or an explicitly temporary system fallback.
    @ViewBuilder
    private func iconView(_ icon: AndroidPopupMenuIcon) -> some View {
        switch icon {
        case .asset(let name):
            AndBibleIconView(name: name, size: 24)
        case .system(let name):
            Image(systemName: name)
                .font(.system(size: 22))
        }
    }
}

/**
 Renders a complete app-owned Android `SwitchPreferenceCompat` row.

 The full row is tappable and uses the shared switch indicator below instead of native iOS `Toggle`
 presentation. Owners supply exact Android resource text, ported icon, current value, and palette.

 Inputs: preference metadata, Boolean binding, enabled state, and owner colors

 Output: one full-width Android preference row

 Side effects: an enabled tap toggles the bound value once

 Failure modes: disabled rows ignore taps and render at reduced emphasis
 */
struct AndroidSwitchPreferenceRow: View {
    let icon: AndroidPopupMenuIcon?
    let title: String
    let summary: String?
    @Binding var isOn: Bool
    let isEnabled: Bool
    let foregroundColor: Color
    let secondaryColor: Color
    let accentColor: Color
    let accessibilityIdentifier: String

    /** Creates one reusable switch preference without mutating its binding. */
    init(
        icon: AndroidPopupMenuIcon? = nil,
        title: String,
        summary: String? = nil,
        isOn: Binding<Bool>,
        isEnabled: Bool = true,
        foregroundColor: Color,
        secondaryColor: Color,
        accentColor: Color,
        accessibilityIdentifier: String
    ) {
        self.icon = icon
        self.title = title
        self.summary = summary
        _isOn = isOn
        self.isEnabled = isEnabled
        self.foregroundColor = foregroundColor
        self.secondaryColor = secondaryColor
        self.accentColor = accentColor
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    var body: some View {
        Button {
            guard isEnabled else { return }
            isOn.toggle()
        } label: {
            HStack(spacing: 16) {
                AndroidPreferenceLabel(
                    icon: icon,
                    title: title,
                    summary: summary,
                    foregroundColor: foregroundColor,
                    secondaryColor: secondaryColor
                )

                AndroidSwitchIndicator(
                    isOn: isOn,
                    secondaryColor: secondaryColor,
                    accentColor: accentColor
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(title)
        .accessibilityValue(
            isOn
                ? String(localized: "on", defaultValue: "On")
                : String(localized: "off", defaultValue: "Off")
        )
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/**
 Renders an app-owned Android action/ListPreference row using the same preference label contract.

 A direct tap invokes the owner command; the row itself does not select values or present native
 menus. Callers use this for Android preferences that open shared dialogs.
 */
struct AndroidActionPreferenceRow: View {
    let icon: AndroidPopupMenuIcon?
    let title: String
    let summary: String?
    let isEnabled: Bool
    let foregroundColor: Color
    let secondaryColor: Color
    let accessibilityIdentifier: String
    let action: () -> Void

    /** Creates one reusable action preference without executing its command. */
    init(
        icon: AndroidPopupMenuIcon? = nil,
        title: String,
        summary: String? = nil,
        isEnabled: Bool = true,
        foregroundColor: Color,
        secondaryColor: Color,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.title = title
        self.summary = summary
        self.isEnabled = isEnabled
        self.foregroundColor = foregroundColor
        self.secondaryColor = secondaryColor
        self.accessibilityIdentifier = accessibilityIdentifier
        self.action = action
    }

    var body: some View {
        Button {
            guard isEnabled else { return }
            action()
        } label: {
            AndroidPreferenceLabel(
                icon: icon,
                title: title,
                summary: summary,
                foregroundColor: foregroundColor,
                secondaryColor: secondaryColor
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(title)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/**
 Draws the shared AppCompat switch track and thumb used by app-owned preference rows.

 Geometry follows Android's compact SwitchCompat control rather than iOS's native switch. The
 indicator is presentation-only; row ownership prevents nested controls or duplicate tap handling.
 */
private struct AndroidSwitchIndicator: View {
    let isOn: Bool
    let secondaryColor: Color
    let accentColor: Color

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? accentColor.opacity(0.5) : secondaryColor.opacity(0.38))
                .frame(width: 34, height: 14)

            Circle()
                .fill(isOn ? accentColor : secondaryColor)
                .frame(width: 20, height: 20)
                .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
        }
        .frame(width: 38, height: 32)
        .accessibilityHidden(true)
    }
}
