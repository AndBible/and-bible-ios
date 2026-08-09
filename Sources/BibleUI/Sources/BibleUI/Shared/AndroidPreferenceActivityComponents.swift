// AndroidPreferenceActivityComponents.swift -- Shared app-owned preference activity controls

import SwiftUI

/**
 Renders one Android `PreferenceCategory` using the shared settings grid and owner palette.

 The category owns only its heading, row stack, and separators. Feature screens retain ordering,
 visibility, persistence, and commands. This prevents Sync, Color, Speak, and application settings
 from separately approximating Android preference geometry.
 */
struct AndroidPreferenceSection<Content: View>: View {
    let title: String?
    let palette: ReaderThemeSurfacePalette
    private let content: Content

    /** Creates one category with optional localized heading and caller-owned rows. */
    init(
        title: String? = nil,
        palette: ReaderThemeSurfacePalette,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.palette = palette
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title, !title.isEmpty {
                AndBibleSettingsSectionHeader(
                    title: title,
                    accentColor: palette.controlAccentColor
                )
            }
            content
        }
        .padding(.bottom, AndBibleSettingsPreferenceLayout.sectionBottomPadding)
    }
}

/** Shared inset divider aligned with Android's preference text column. */
struct AndroidPreferenceDivider: View {
    let palette: ReaderThemeSurfacePalette

    var body: some View {
        Divider()
            .overlay(palette.inactiveBorderColor)
            .padding(.leading, AndBibleSettingsPreferenceLayout.dividerLeadingInset)
    }
}

/**
 Renders a complete app-owned Android switch preference using an exact catalog drawable.

 The full row owns the tap, while the shared switch indicator is presentation-only. This avoids
 nesting a native iOS toggle inside another row and keeps one deterministic accessibility action.
 */
struct AndroidCatalogSwitchPreferenceRow: View {
    let title: String
    let summary: String?
    let detail: String?
    let icon: AndBibleIcon?
    @Binding var isOn: Bool
    let isEnabled: Bool
    let palette: ReaderThemeSurfacePalette
    let accessibilityIdentifier: String

    /** Creates one catalog-backed switch row without changing its binding. */
    init(
        title: String,
        summary: String? = nil,
        detail: String? = nil,
        icon: AndBibleIcon? = nil,
        isOn: Binding<Bool>,
        isEnabled: Bool = true,
        palette: ReaderThemeSurfacePalette,
        accessibilityIdentifier: String
    ) {
        self.title = title
        self.summary = summary
        self.detail = detail
        self.icon = icon
        _isOn = isOn
        self.isEnabled = isEnabled
        self.palette = palette
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    var body: some View {
        Button {
            guard isEnabled else { return }
            isOn.toggle()
        } label: {
            HStack(spacing: AndBibleSettingsPreferenceLayout.accessorySpacing) {
                label
                AndroidPreferenceSwitchIndicator(
                    isOn: isOn,
                    secondaryColor: palette.secondaryForegroundColor,
                    accentColor: palette.controlAccentColor
                )
            }
            .padding(.horizontal, AndBibleSettingsPreferenceLayout.rowHorizontalPadding)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.55)
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

    private var label: some View {
        AndBibleSettingsRowLabel(
            title: title,
            summary: summary,
            detail: detail,
            icon: icon,
            isEnabled: isEnabled,
            foregroundColor: palette.foregroundColor,
            secondaryColor: palette.secondaryForegroundColor,
            iconColor: palette.secondaryForegroundColor
        )
    }
}

/**
 Renders an app-owned Android action or ListPreference row from exact catalog metadata.

 An optional trailing value mirrors Android summaries and selection values without invoking native
 `Menu`, `Picker`, or `NavigationLink` presentation.
 */
struct AndroidCatalogActionPreferenceRow: View {
    let title: String
    let summary: String?
    let detail: String?
    let icon: AndBibleIcon?
    /// Optional semantic tint supplied by Android XML, such as the disclaimer warning red.
    let iconColor: Color?
    let trailingValue: String?
    let isEnabled: Bool
    let palette: ReaderThemeSurfacePalette
    let accessibilityIdentifier: String
    let action: () -> Void

    /** Creates one catalog-backed action row without invoking its command. */
    init(
        title: String,
        summary: String? = nil,
        detail: String? = nil,
        icon: AndBibleIcon? = nil,
        iconColor: Color? = nil,
        trailingValue: String? = nil,
        isEnabled: Bool = true,
        palette: ReaderThemeSurfacePalette,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.summary = summary
        self.detail = detail
        self.icon = icon
        self.iconColor = iconColor
        self.trailingValue = trailingValue
        self.isEnabled = isEnabled
        self.palette = palette
        self.accessibilityIdentifier = accessibilityIdentifier
        self.action = action
    }

    var body: some View {
        Button {
            guard isEnabled else { return }
            action()
        } label: {
            HStack(spacing: AndBibleSettingsPreferenceLayout.accessorySpacing) {
                AndBibleSettingsRowLabel(
                    title: title,
                    summary: summary,
                    detail: detail,
                    icon: icon,
                    isEnabled: isEnabled,
                    foregroundColor: palette.foregroundColor,
                    secondaryColor: palette.secondaryForegroundColor,
                    iconColor: iconColor ?? palette.secondaryForegroundColor
                )

                if let trailingValue, !trailingValue.isEmpty {
                    Text(trailingValue)
                        .font(.system(size: 14))
                        .foregroundStyle(palette.secondaryForegroundColor)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(3)
                }
            }
            .padding(.horizontal, AndBibleSettingsPreferenceLayout.rowHorizontalPadding)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(title)
        .accessibilityValue(trailingValue ?? detail ?? "")
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/** Noninteractive Android preference row for status and explanatory values. */
struct AndroidCatalogValuePreferenceRow: View {
    let title: String
    let summary: String?
    let detail: String?
    let icon: AndBibleIcon?
    let trailingValue: String?
    let palette: ReaderThemeSurfacePalette
    let accessibilityIdentifier: String

    var body: some View {
        HStack(spacing: AndBibleSettingsPreferenceLayout.accessorySpacing) {
            AndBibleSettingsRowLabel(
                title: title,
                summary: summary,
                detail: detail,
                icon: icon,
                foregroundColor: palette.foregroundColor,
                secondaryColor: palette.secondaryForegroundColor,
                iconColor: palette.secondaryForegroundColor
            )
            if let trailingValue, !trailingValue.isEmpty {
                Text(trailingValue)
                    .font(.system(size: 14))
                    .foregroundStyle(palette.secondaryForegroundColor)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(4)
            }
        }
        .padding(.horizontal, AndBibleSettingsPreferenceLayout.rowHorizontalPadding)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/** App-owned Android color preference row with a live opaque color swatch. */
struct AndroidColorPreferenceRow: View {
    let title: String
    let colorARGB: Int
    let palette: ReaderThemeSurfacePalette
    let accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AndBibleSettingsPreferenceLayout.accessorySpacing) {
                AndBibleSettingsRowLabel(
                    title: title,
                    foregroundColor: palette.foregroundColor,
                    secondaryColor: palette.secondaryForegroundColor
                )
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(argbInt: colorARGB))
                    .frame(width: 34, height: 34)
                    .overlay {
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(palette.inactiveBorderColor, lineWidth: 1)
                    }
            }
            .padding(.horizontal, AndBibleSettingsPreferenceLayout.rowHorizontalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(AndroidOpaqueHSVColor(argb: colorARGB).rgbHex)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/** Complete app-owned Android `SeekBarPreference` row with current numeric value. */
struct AndroidSeekBarPreferenceRow: View {
    let title: String
    let summary: String?
    let icon: AndBibleIcon?
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let palette: ReaderThemeSurfacePalette
    let accessibilityIdentifier: String

    /**
     Creates one shared Android seekbar preference with optional catalog icon metadata.

     Existing iconless callers retain their compact text geometry; catalog-backed application
     preferences opt into the same icon column used by action and switch rows.
     */
    init(
        title: String,
        summary: String? = nil,
        icon: AndBibleIcon? = nil,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        palette: ReaderThemeSurfacePalette,
        accessibilityIdentifier: String
    ) {
        self.title = title
        self.summary = summary
        self.icon = icon
        _value = value
        self.range = range
        self.step = step
        self.palette = palette
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    var body: some View {
        HStack(alignment: .top, spacing: AndBibleSettingsPreferenceLayout.contentSpacing) {
            if let icon {
                AndBibleIconView(name: icon.assetName, size: AndBibleSettingsPreferenceLayout.iconSize)
                    .foregroundStyle(palette.secondaryForegroundColor)
                    .frame(width: AndBibleSettingsPreferenceLayout.iconColumnWidth)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.system(size: 16))
                        .foregroundStyle(palette.foregroundColor)
                    Spacer()
                    Text("\(Int(value.rounded()))")
                        .font(.system(size: 14))
                        .foregroundStyle(palette.secondaryForegroundColor)
                        .monospacedDigit()
                }
                AndroidSeekBar(
                    value: $value,
                    range: range,
                    step: step,
                    palette: palette,
                    accessibilityIdentifier: accessibilityIdentifier,
                    accessibilityLabel: title
                )
                if let summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 14))
                        .foregroundStyle(palette.secondaryForegroundColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, AndBibleSettingsPreferenceLayout.rowHorizontalPadding)
        .padding(.vertical, AndBibleSettingsPreferenceLayout.rowVerticalPadding)
    }
}

/**
 App-owned equivalent of Android's `SeekBarPreference`.

 The track and thumb are owned SwiftUI geometry driven by a zero-distance drag gesture. Values are
 clamped and snapped to `step` before the binding is written.
 */
struct AndroidSeekBar: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let palette: ReaderThemeSurfacePalette
    let accessibilityIdentifier: String

    /// Human-readable VoiceOver label; identifiers are automation-facing and must not be spoken.
    let accessibilityLabel: String

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let progress = normalizedProgress
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(palette.inactiveBorderColor)
                    .frame(height: 4)
                Capsule()
                    .fill(palette.controlAccentColor)
                    .frame(width: max(0, width * progress), height: 4)
                Circle()
                    .fill(palette.controlAccentColor)
                    .frame(width: 20, height: 20)
                    .offset(x: max(0, width * progress - 10))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                updateValue(for: gesture.location.x, width: width)
            })
        }
        .frame(height: 36)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue("\(value)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                value = min(value + step, range.upperBound)
            case .decrement:
                value = max(value - step, range.lowerBound)
            @unknown default:
                break
            }
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var normalizedProgress: Double {
        guard range.upperBound > range.lowerBound else { return 0 }
        return min(max((value - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
    }

    /** Converts one pointer coordinate into a clamped, stepped value. */
    private func updateValue(for x: CGFloat, width: CGFloat) {
        let progress = min(max(Double(x / width), 0), 1)
        let rawValue = range.lowerBound + progress * (range.upperBound - range.lowerBound)
        let stepped = ((rawValue - range.lowerBound) / step).rounded() * step + range.lowerBound
        value = min(max(stepped, range.lowerBound), range.upperBound)
    }
}

/** Shared compact Android switch geometry for catalog-backed preference rows. */
private struct AndroidPreferenceSwitchIndicator: View {
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
