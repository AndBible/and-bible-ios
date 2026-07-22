// CalculatorView.swift — Calculator disguise for discrete mode

import SwiftUI
import BibleCore
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

extension Color {
    /// Platform-specific secondary gray used for calculator digit buttons.
    static var systemGray2: Color {
        #if os(iOS)
        Color(uiColor: .systemGray2)
        #elseif os(macOS)
        Color(nsColor: .systemGray)
        #endif
    }
}

/**
 Stateless authorization rule for leaving the Calculator product's launch gate.

 Android authorizes only a direct PIN entry, not an arithmetic result or an attempt counter. The
 configured value must be nonempty and match the entered digits exactly. This value type owns no
 lifecycle state, so backgrounding, relaunching, and repeated wrong attempts cannot accumulate an
 alternate unlock condition.
 */
struct CalculatorUnlockPolicy {
    /**
     Tests one direct calculator entry against the configured security PIN.

     - Parameters:
       - enteredPIN: Exact digits present before the user taps equals.
       - configuredPIN: Persisted Calculator PIN; an empty value disables unlocking.
       - isDirectEntry: `true` only when the value was entered without arithmetic transformation.
     - Returns: `true` only for an exact, nonempty, direct PIN match.
     - Side effects: none.
     - Failure modes: Empty values, whitespace differences, arithmetic results, and wrong values
       all return `false`; there is no retry counter or fallback gesture.
     */
    static func allowsUnlock(
        enteredPIN: String,
        configuredPIN: String,
        isDirectEntry: Bool
    ) -> Bool {
        isDirectEntry && !configuredPIN.isEmpty && enteredPIN == configuredPIN
    }
}

/**
 Renders the discrete-mode calculator disguise used to protect access to the main app.

 The calculator behaves like a lightweight four-function calculator while exposing one unlock path:
 entering the exact configured nonempty PIN directly and pressing `=`. Arithmetic results and
 repeated incorrect attempts never authorize access.

 Data dependencies:
 - `calculatorPin` is loaded from the shared application-preference store
 - `onUnlock` is provided by the parent to reveal Bible content once the disguise is bypassed

 Side effects:
 - button taps mutate calculator state, including current input, pending operation, and display
 - successful direct PIN entry invokes `onUnlock`
 */
public struct CalculatorView: View {
    /// Current calculator display text.
    @State private var display = "0"

    /// Digits or decimal value currently being entered by the user.
    @State private var currentInput = ""

    /// Prior operand retained while a binary operation is pending.
    @State private var previousValue: Double = 0

    /// Active arithmetic operation awaiting completion with the next operand.
    @State private var currentOperation: Operation?

    /// Whether the current value consists only of direct keypad entry rather than calculation.
    @State private var isDirectPINEntry = true

    /// Whether the next digit should begin a fresh expression after equals was pressed.
    @State private var beginsNewInputAfterEquals = false

    /// Legacy state slot for conditional Bible presentation.
    @State private var shouldShowBible = false

    /// Configured discrete-mode PIN that can unlock the main app from calculator mode.
    @AppStorage(AppPreferenceKey.calculatorPin.rawValue)
    private var calculatorPin = AppPreferenceRegistry.stringDefault(for: .calculatorPin) ?? "1234"

    /**
     Supported binary operations for the calculator keypad.
     */
    enum Operation: String {
        /// Addition operation.
        case add = "+"
        /// Subtraction operation.
        case subtract = "-"
        /// Multiplication operation.
        case multiply = "×"
        /// Division operation.
        case divide = "÷"
    }

    /// Callback invoked when the disguise should transition back to Bible content.
    let onUnlock: () -> Void

    /**
     Creates the calculator disguise with an unlock callback supplied by the parent flow.

     - Parameter onUnlock: Callback invoked when the exact configured nonempty PIN unlocks the main
       application content.
     */
    public init(onUnlock: @escaping () -> Void) {
        self.onUnlock = onUnlock
    }

    /// Calculator keypad layout, including the wide zero-row button.
    private let buttons: [[String]] = [
        ["C", "±", "%", "÷"],
        ["7", "8", "9", "×"],
        ["4", "5", "6", "-"],
        ["1", "2", "3", "+"],
        ["0", ".", "="],
    ]

    /**
     Builds the calculator display and keypad layout as one discoverable accessibility container.

     The container identifier marks the active launch gate without replacing the labels or traits
     of the display and keypad controls that assistive technologies and UI automation operate.

     - Side effects: Button actions mutate calculator input and can invoke `onUnlock`.
     - Failure modes: Layout and accessibility construction do not fail.
     */
    public var body: some View {
        VStack(spacing: 12) {
            Spacer()

            Text(display)
                .font(.system(size: 60, weight: .light, design: .default))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 24)

            ForEach(buttons, id: \.self) { row in
                HStack(spacing: 12) {
                    ForEach(row, id: \.self) { button in
                        CalculatorButton(title: button, isWide: button == "0") {
                            handleButton(button)
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color.black)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calculatorGateRoot")
    }

    /**
     Handles one keypad tap, including arithmetic state and exact direct-PIN matching.

     - Parameter button: Key label that was tapped.

     Side effects:
     - mutates display, input, and arithmetic state
     - invokes `onUnlock` only when the configured nonempty PIN matches direct input exactly
     */
    private func handleButton(_ button: String) {
        switch button {
        case "0"..."9":
            if beginsNewInputAfterEquals {
                display = "0"
                currentInput = ""
                previousValue = 0
                currentOperation = nil
                isDirectPINEntry = true
                beginsNewInputAfterEquals = false
            }
            currentInput += button
            display = currentInput

        case ".":
            if beginsNewInputAfterEquals {
                display = "0"
                currentInput = ""
                previousValue = 0
                currentOperation = nil
                isDirectPINEntry = true
                beginsNewInputAfterEquals = false
            }
            if !currentInput.contains(".") {
                currentInput += currentInput.isEmpty ? "0." : "."
                display = currentInput
            }

        case "C":
            display = "0"
            currentInput = ""
            previousValue = 0
            currentOperation = nil
            isDirectPINEntry = true
            beginsNewInputAfterEquals = false

        case "±":
            if let value = Double(currentInput) {
                currentInput = String(-value)
                display = currentInput
                isDirectPINEntry = false
                beginsNewInputAfterEquals = false
            }

        case "%":
            if let value = Double(currentInput) {
                currentInput = String(value / 100)
                display = currentInput
                isDirectPINEntry = false
                beginsNewInputAfterEquals = false
            }

        case "+", "-", "×", "÷":
            if let value = Double(currentInput) {
                calculateResult()
                previousValue = Double(display) ?? value
            }
            currentOperation = Operation(rawValue: button)
            currentInput = ""
            isDirectPINEntry = false
            beginsNewInputAfterEquals = false

        case "=":
            let shouldUnlock = CalculatorUnlockPolicy.allowsUnlock(
                enteredPIN: currentInput,
                configuredPIN: calculatorPin,
                isDirectEntry: isDirectPINEntry && currentOperation == nil
            )
            calculateResult()
            currentOperation = nil
            beginsNewInputAfterEquals = true
            if shouldUnlock {
                onUnlock()
            }

        default:
            break
        }
    }

    /**
     Applies the pending arithmetic operation to the previous and current operands.

     Side effects:
     - updates the display, current input, and stored previous value with the calculated result

     Failure modes:
     - returns without mutating state when no operation is pending or the current operand cannot be
       parsed as a `Double`
     - division by zero yields `0` rather than surfacing an error
     */
    private func calculateResult() {
        guard let operation = currentOperation,
              let currentValue = Double(currentInput.isEmpty ? display : currentInput) else { return }

        let result: Double
        switch operation {
        case .add: result = previousValue + currentValue
        case .subtract: result = previousValue - currentValue
        case .multiply: result = previousValue * currentValue
        case .divide: result = currentValue != 0 ? previousValue / currentValue : 0
        }

        display = formatResult(result)
        currentInput = display
        previousValue = result
    }

    /**
     Formats a calculator result for display.

     - Parameter value: Numeric result to format.
     - Returns: An integer-formatted string for whole numbers in a safe magnitude range, or the
       default `Double` string representation otherwise.
     */
    private func formatResult(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(format: "%.0f", value)
        }
        return String(value)
    }
}

/**
 Renders one calculator keypad button.

 The button chooses its background color from the button title so operators and digit keys follow
 the expected calculator styling.
 */
struct CalculatorButton: View {
    /// Button label shown to the user.
    let title: String

    /// Whether this button should expand to fill extra horizontal space.
    let isWide: Bool

    /// Action invoked when the button is tapped.
    let action: () -> Void

    /**
     Creates one calculator keypad button.

     - Parameters:
       - title: Button label to display.
       - isWide: Whether the button should expand horizontally.
       - action: Callback invoked when the button is tapped.
     */
    init(title: String, isWide: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.isWide = isWide
        self.action = action
    }

    /// Background color selected from the button role.
    private var backgroundColor: Color {
        switch title {
        case "C", "±", "%": return Color(.darkGray)
        case "+", "-", "×", "÷", "=": return .orange
        default: return Color.systemGray2
        }
    }

    /**
     Builds the tappable keypad button surface.
     */
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 30, weight: .medium))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(height: 70)
                .background(backgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: 35))
        }
        .frame(maxWidth: isWide ? .infinity : nil)
    }
}
