// CalculatorView.swift — Calculator disguise for discrete mode

import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

extension Color {
    static var systemGray2: Color {
        #if os(iOS)
        Color(uiColor: .systemGray2)
        #elseif os(macOS)
        Color(nsColor: .systemGray)
        #endif
    }
}

/// A functional calculator that serves as a disguise for the Bible app.
/// Used in persecution-sensitive areas where owning a Bible app could be dangerous.
/// A specific gesture sequence switches to the Bible content.
public struct CalculatorView: View {
    @State private var display = "0"
    @State private var currentInput = ""
    @State private var previousValue: Double = 0
    @State private var currentOperation: Operation?
    @State private var secretTapCount = 0
    @State private var shouldShowBible = false

    private let secretTapThreshold = 7 // Taps on "=" to unlock Bible

    enum Operation: String {
        case add = "+"
        case subtract = "-"
        case multiply = "×"
        case divide = "÷"
    }

    let onUnlock: () -> Void

    public init(onUnlock: @escaping () -> Void) {
        self.onUnlock = onUnlock
    }

    private let buttons: [[String]] = [
        ["C", "±", "%", "÷"],
        ["7", "8", "9", "×"],
        ["4", "5", "6", "-"],
        ["1", "2", "3", "+"],
        ["0", ".", "="],
    ]

    public var body: some View {
        VStack(spacing: 12) {
            Spacer()

            // Display
            Text(display)
                .font(.system(size: 60, weight: .light, design: .default))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 24)

            // Button grid
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
    }

    private func handleButton(_ button: String) {
        switch button {
        case "0"..."9":
            if currentInput == "0" {
                currentInput = button
            } else {
                currentInput += button
            }
            display = currentInput
            secretTapCount = 0

        case ".":
            if !currentInput.contains(".") {
                currentInput += currentInput.isEmpty ? "0." : "."
                display = currentInput
            }

        case "C":
            display = "0"
            currentInput = ""
            previousValue = 0
            currentOperation = nil
            secretTapCount = 0

        case "±":
            if let value = Double(currentInput) {
                currentInput = String(-value)
                display = currentInput
            }

        case "%":
            if let value = Double(currentInput) {
                currentInput = String(value / 100)
                display = currentInput
            }

        case "+", "-", "×", "÷":
            if let value = Double(currentInput) {
                calculateResult()
                previousValue = Double(display) ?? value
            }
            currentOperation = Operation(rawValue: button)
            currentInput = ""

        case "=":
            calculateResult()
            currentOperation = nil

            // Secret unlock gesture: tap "=" multiple times
            secretTapCount += 1
            if secretTapCount >= secretTapThreshold {
                secretTapCount = 0
                onUnlock()
            }

        default:
            break
        }
    }

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

    private func formatResult(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(format: "%.0f", value)
        }
        return String(value)
    }
}

/// A single calculator button.
struct CalculatorButton: View {
    let title: String
    let isWide: Bool
    let action: () -> Void

    init(title: String, isWide: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.isWide = isWide
        self.action = action
    }

    private var backgroundColor: Color {
        switch title {
        case "C", "±", "%": return Color(.darkGray)
        case "+", "-", "×", "÷", "=": return .orange
        default: return Color.systemGray2
        }
    }

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
