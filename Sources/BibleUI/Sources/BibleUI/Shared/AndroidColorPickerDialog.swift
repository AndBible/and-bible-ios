// AndroidColorPickerDialog.swift -- Shared app-owned opaque color picker

import Foundation
import SwiftUI

/// Applies the input traits supported by the active Apple platform to RGB hex entry.
private struct AndroidHexInputBehavior: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
        #else
        content
        #endif
    }
}

/**
 Pure value conversion for Android's opaque HSV color-picker contract.

 Android `LabelEditActivity` removes alpha after selection. This value therefore accepts signed
 ARGB input but always emits an `0xFF` alpha byte. It is UI-framework independent except for the
 final SwiftUI preview color.
 */
struct AndroidOpaqueHSVColor: Equatable {
    /// Hue in the closed 0...1 range.
    var hue: Double

    /// Saturation in the closed 0...1 range.
    var saturation: Double

    /// Brightness/value in the closed 0...1 range.
    var brightness: Double

    /** Creates HSV components from Android's signed ARGB integer representation. */
    init(argb: Int) {
        let bits = UInt32(bitPattern: Int32(truncatingIfNeeded: argb))
        let red = Double((bits >> 16) & 0xFF) / 255
        let green = Double((bits >> 8) & 0xFF) / 255
        let blue = Double(bits & 0xFF) / 255
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum

        if delta == 0 {
            hue = 0
        } else if maximum == red {
            hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6) / 6
        } else if maximum == green {
            hue = (((blue - red) / delta) + 2) / 6
        } else {
            hue = (((red - green) / delta) + 4) / 6
        }
        if hue < 0 { hue += 1 }
        saturation = maximum == 0 ? 0 : delta / maximum
        brightness = maximum
    }

    /** Creates normalized HSV components directly. */
    init(hue: Double, saturation: Double, brightness: Double) {
        self.hue = Self.clamp(hue)
        self.saturation = Self.clamp(saturation)
        self.brightness = Self.clamp(brightness)
    }

    /// SwiftUI preview color for the current HSV components.
    var color: Color {
        Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    /// Opaque signed ARGB value shared with Android Room and Vue.
    var argb: Int {
        let chroma = brightness * saturation
        let sector = hue * 6
        let intermediate = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let match = brightness - chroma
        let rgb: (Double, Double, Double)
        switch sector {
        case 0..<1: rgb = (chroma, intermediate, 0)
        case 1..<2: rgb = (intermediate, chroma, 0)
        case 2..<3: rgb = (0, chroma, intermediate)
        case 3..<4: rgb = (0, intermediate, chroma)
        case 4..<5: rgb = (intermediate, 0, chroma)
        default: rgb = (chroma, 0, intermediate)
        }
        let red = UInt32(((rgb.0 + match) * 255).rounded())
        let green = UInt32(((rgb.1 + match) * 255).rounded())
        let blue = UInt32(((rgb.2 + match) * 255).rounded())
        return Int(Int32(bitPattern: 0xFF00_0000 | red << 16 | green << 8 | blue))
    }

    /// Six-digit RGB hex text displayed by Android-style color editors.
    var rgbHex: String {
        String(format: "%06X", UInt32(bitPattern: Int32(truncatingIfNeeded: argb)) & 0x00FF_FFFF)
    }

    /** Parses six-digit RGB text and preserves Android's forced opaque alpha. */
    static func parseRGBHex(_ value: String) -> AndroidOpaqueHSVColor? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard normalized.count == 6, let rgb = UInt32(normalized, radix: 16) else { return nil }
        return AndroidOpaqueHSVColor(argb: Int(Int32(bitPattern: 0xFF00_0000 | rgb)))
    }

    /// Clamps user-driven components to their valid unit interval.
    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

/**
 Canonical app-owned equivalent of Android's `ColorPickerDialog` with alpha disabled.

 The dialog composes the shared Android window/palette and provides an HSV saturation/value field,
 hue strip, RGB hex entry, live preview, and explicit Cancel/OK actions. It never invokes the native
 iOS `ColorPicker`, so presentation remains application-owned.

 Inputs: initial signed ARGB value and cancel/selection callbacks

 Output: one opaque signed ARGB value after explicit confirmation

 Side effects: invokes only the caller callback selected by the user

 Failure modes: incomplete or invalid hex input remains visible and does not change the selection
 */
struct AndroidColorPickerDialog: View {
    /// Caller-owned cancel action.
    let onCancel: () -> Void

    /// Caller-owned opaque ARGB selection action.
    let onSelect: (Int) -> Void

    /// Active application scheme for shared dialog colors.
    @Environment(\.colorScheme) private var colorScheme

    /// Current normalized picker value.
    @State private var selection: AndroidOpaqueHSVColor

    /// Editable six-digit RGB text.
    @State private var hexText: String

    /// Whether the current hex text is incomplete or invalid.
    @State private var hasInvalidHex = false

    /** Creates one picker initialized from Android's signed ARGB value. */
    init(initialColor: Int, onCancel: @escaping () -> Void, onSelect: @escaping (Int) -> Void) {
        let initial = AndroidOpaqueHSVColor(argb: initialColor)
        self.onCancel = onCancel
        self.onSelect = onSelect
        _selection = State(initialValue: initial)
        _hexText = State(initialValue: initial.rgbHex)
    }

    var body: some View {
        AndroidDialogWindow(
            colorScheme: colorScheme,
            accessibilityIdentifier: "androidColorPickerDialog",
            onOutsideTap: onCancel
        ) {
            VStack(alignment: .leading, spacing: 18) {
                Text(String(localized: "select_color", defaultValue: "Select color"))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(AndroidDialogSurfacePalette.primaryText(for: colorScheme))

                saturationBrightnessField
                    .frame(height: 220)

                hueField
                    .frame(height: 34)

                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(selection.color)
                        .frame(width: 48, height: 48)
                        .overlay {
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(AndroidDialogSurfacePalette.secondaryText(for: colorScheme), lineWidth: 1)
                        }

                    Text("#")
                        .foregroundStyle(AndroidDialogSurfacePalette.secondaryText(for: colorScheme))
                    TextField("RRGGBB", text: $hexText)
                        .modifier(AndroidHexInputBehavior())
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(AndroidDialogSurfacePalette.primaryText(for: colorScheme))
                        .padding(.vertical, 8)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(hasInvalidHex
                                    ? Color.red
                                    : AndroidDialogSurfacePalette.accent(for: colorScheme))
                                .frame(height: 1)
                        }
                        .onSubmit(applyHexText)
                        .onChange(of: hexText) { _, newValue in
                            if newValue.trimmingCharacters(in: CharacterSet(charactersIn: "#")).count == 6 {
                                applyHexText()
                            }
                        }
                        .accessibilityIdentifier("androidColorPickerHexField")
                }

                HStack(spacing: 20) {
                    Spacer()
                    Button(String(localized: "cancel"), action: onCancel)
                        .buttonStyle(.plain)
                        .foregroundStyle(AndroidDialogSurfacePalette.accent(for: colorScheme))
                        .accessibilityIdentifier("androidColorPickerCancelButton")
                    Button(String(localized: "okay", defaultValue: "OK")) {
                        onSelect(selection.argb)
                    }
                    .buttonStyle(.plain)
                    .fontWeight(.semibold)
                    .foregroundStyle(AndroidDialogSurfacePalette.accent(for: colorScheme))
                    .accessibilityIdentifier("androidColorPickerConfirmButton")
                }
            }
            .padding(22)
            .frame(maxWidth: 520)
        }
    }

    /// Saturation/value plane with a position indicator and continuous drag selection.
    private var saturationBrightnessField: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                LinearGradient(
                    colors: [.white, Color(hue: selection.hue, saturation: 1, brightness: 1)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)

                Circle()
                    .strokeBorder(.white, lineWidth: 2)
                    .background(Circle().strokeBorder(.black.opacity(0.7), lineWidth: 1))
                    .frame(width: 22, height: 22)
                    .offset(
                        x: selection.saturation * max(proxy.size.width - 22, 0),
                        y: (1 - selection.brightness) * max(proxy.size.height - 22, 0)
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                selection.saturation = min(max(value.location.x / max(proxy.size.width, 1), 0), 1)
                selection.brightness = 1 - min(max(value.location.y / max(proxy.size.height, 1), 0), 1)
                syncHexFromSelection()
            })
        }
        .accessibilityIdentifier("androidColorPickerSaturationBrightnessField")
    }

    /// Full hue spectrum with continuous drag selection.
    private var hueField: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                LinearGradient(
                    colors: stride(from: 0.0, through: 1.0, by: 1.0 / 12.0).map {
                        Color(hue: $0, saturation: 1, brightness: 1)
                    },
                    startPoint: .leading,
                    endPoint: .trailing
                )
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(.white, lineWidth: 2)
                    .background(RoundedRectangle(cornerRadius: 3).strokeBorder(.black.opacity(0.7), lineWidth: 1))
                    .frame(width: 16, height: proxy.size.height + 4)
                    .offset(x: selection.hue * max(proxy.size.width - 16, 0))
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                selection.hue = min(max(value.location.x / max(proxy.size.width, 1), 0), 1)
                syncHexFromSelection()
            })
        }
        .accessibilityIdentifier("androidColorPickerHueField")
    }

    /** Applies valid RGB text to the picker while retaining invalid input for correction. */
    private func applyHexText() {
        guard let parsed = AndroidOpaqueHSVColor.parseRGBHex(hexText) else {
            hasInvalidHex = true
            return
        }
        selection = parsed
        hexText = parsed.rgbHex
        hasInvalidHex = false
    }

    /** Refreshes canonical RGB text after a pointer-driven HSV change. */
    private func syncHexFromSelection() {
        hexText = selection.rgbHex
        hasInvalidHex = false
    }
}
