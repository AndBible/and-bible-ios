// AndroidToastFeedback.swift -- Android-style transient toast presentation

import Foundation
import SwiftUI

/**
 Namespace for Android toast timing constants used by SwiftUI hosts.

 Android's `ToastEvent` defaults to `Toast.LENGTH_SHORT` for successful module/document installs.
 iOS mirrors that with a short, non-blocking overlay instead of a modal alert so install success
 does not interrupt the user's current screen.
 */
public enum AndroidToastFeedback {
    /// Approximate duration of Android `Toast.LENGTH_SHORT` in seconds.
    public static let shortDuration: TimeInterval = 2.0
}

/**
 Android-style transient toast surface.

 The view is intentionally presentation-only: callers own message state, replacement policy, and
 dismissal scheduling so app-level and settings-level workflows can queue operations correctly.
 The visual treatment follows Android's small dark rounded toast rather than iOS alert/sheet chrome.
 */
public struct AndroidToastOverlay: View {
    /// User-visible toast message.
    private let message: String

    /// Distance from the bottom edge of the containing surface.
    private let bottomPadding: CGFloat

    /**
     Creates a toast overlay for a single message.

     - Parameters:
       - message: Localized text to show.
       - bottomPadding: Bottom offset that lets hosts keep the toast above tab bars or safe-area
         controls.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(message: String, bottomPadding: CGFloat = 80) {
        self.message = message
        self.bottomPadding = bottomPadding
    }

    /**
     Builds the Android-style toast capsule.

     - Returns: A non-interactive SwiftUI overlay that wraps long localized text.
     - Side effects: none.
     - Failure modes: none.
     */
    public var body: some View {
        Text(message)
            .font(.subheadline)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: 340)
            .background(
                Color.black.opacity(0.84),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
            .padding(.horizontal, 24)
            .padding(.bottom, bottomPadding)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityIdentifier("androidToastFeedback")
            .accessibilityAddTraits(.isStaticText)
            .allowsHitTesting(false)
    }
}

public extension View {
    /**
     Overlays Android-style transient toast feedback when `message` is non-nil.

     - Parameters:
       - message: Optional localized toast text. `nil` removes the overlay.
       - bottomPadding: Bottom offset passed to `AndroidToastOverlay`.
     - Returns: The original view with a bottom-aligned toast overlay attached.
     - Side effects: none; callers remain responsible for scheduling message dismissal.
     - Failure modes: none.
     */
    func androidToastFeedback(_ message: String?, bottomPadding: CGFloat = 80) -> some View {
        overlay(alignment: .bottom) {
            if let message {
                AndroidToastOverlay(message: message, bottomPadding: bottomPadding)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: message)
    }
}
