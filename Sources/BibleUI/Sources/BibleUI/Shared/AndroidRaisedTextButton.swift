// AndroidRaisedTextButton.swift -- Shared app-owned AppCompat text button

import SwiftUI

/**
 Renders the raised rectangular text command used by Android activity content.

 Feature screens supply their owner-resolved colors so the button follows the active application,
 workspace, or reader palette. Centralizing geometry and disabled treatment prevents Daily Reading,
 Backup/Restore, and future activity ports from drawing separate screenshot-matched substitutes.

 Inputs: localized title, optional shared Android icon, owner colors, enabled/in-flight state,
 identifier, and command closure

 Output: one app-owned AppCompat-style raised button

 Side effects: invokes `action` after an enabled, non-running tap

 Failure modes: none; disabled or running buttons ignore input
 */
struct AndroidRaisedTextButton: View {
    let title: String
    let icon: AndroidPopupMenuIcon?
    let foregroundColor: Color
    let backgroundColor: Color
    let isEnabled: Bool
    let isRunning: Bool
    let accessibilityIdentifier: String?
    let action: () -> Void

    /** Creates one reusable raised text button without performing its command. */
    init(
        title: String,
        icon: AndroidPopupMenuIcon? = nil,
        foregroundColor: Color,
        backgroundColor: Color,
        isEnabled: Bool = true,
        isRunning: Bool = false,
        accessibilityIdentifier: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.foregroundColor = foregroundColor
        self.backgroundColor = backgroundColor
        self.isEnabled = isEnabled
        self.isRunning = isRunning
        self.accessibilityIdentifier = accessibilityIdentifier
        self.action = action
    }

    var body: some View {
        Button {
            guard isEnabled, !isRunning else { return }
            action()
        } label: {
            HStack(spacing: 10) {
                if !isRunning, let icon {
                    buttonIcon(icon)
                        .frame(width: 24, height: 24)
                }

                Text(isRunning ? "…" : title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .frame(maxWidth: .infinity)
                .foregroundStyle(foregroundColor)
                .background(backgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                .shadow(color: Color.black.opacity(isEnabled ? 0.22 : 0.08), radius: 2, y: 2)
                .opacity(isEnabled ? 1 : 0.42)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isRunning)
        .accessibilityLabel(title)
        .modifier(AndroidRaisedTextButtonAccessibilityIdentifier(identifier: accessibilityIdentifier))
    }

    /** Renders an exact packaged Android drawable, retaining a fallback for legacy callers. */
    @ViewBuilder
    private func buttonIcon(_ icon: AndroidPopupMenuIcon) -> some View {
        switch icon {
        case .asset(let name):
            AndBibleIconView(name: name, size: 24)
        case .system(let name):
            Image(systemName: name)
                .font(.system(size: 24, weight: .medium))
        }
    }
}

/// Applies a UI-test identifier only when the reusable command caller supplied one.
private struct AndroidRaisedTextButtonAccessibilityIdentifier: ViewModifier {
    let identifier: String?

    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}
