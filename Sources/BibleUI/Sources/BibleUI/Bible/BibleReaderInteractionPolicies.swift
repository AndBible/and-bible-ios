// BibleReaderInteractionPolicies.swift - Pure reader gesture behavior policies

import BibleView

/// Horizontal swipe modes for Bible panes, mirroring the Android preference values.
private enum BibleSwipeMode: String {
    /// Swiping left or right changes chapter.
    case chapter = "CHAPTER"

    /// Swiping left or right scrolls by page height within the current document.
    case page = "PAGE"

    /// Horizontal swipe gestures are ignored.
    case none = "NONE"
}

/// Native action selected for a horizontal Bible-view swipe.
enum ReaderHorizontalSwipeAction: Equatable {
    case navigateNextChapter
    case navigatePreviousChapter
    case scrollPageDown
    case scrollPageUp
    case none
}

/// Resolves configured Bible-view swipe behavior without touching view or controller state.
enum ReaderHorizontalSwipePolicy {
    static func action(
        modeRawValue: String,
        direction: NativeHorizontalSwipeDirection,
        hasActiveSelection: Bool
    ) -> ReaderHorizontalSwipeAction {
        guard !hasActiveSelection else { return .none }

        switch BibleSwipeMode(rawValue: modeRawValue) ?? .chapter {
        case .chapter:
            return direction == .left ? .navigateNextChapter : .navigatePreviousChapter
        case .page:
            return direction == .left ? .scrollPageDown : .scrollPageUp
        case .none:
            return .none
        }
    }
}

/// Mutable scroll accumulation used by Android-style auto-fullscreen behavior.
struct ReaderAutoFullscreenTracking: Equatable {
    var directionDown: Bool? = nil
    var distance: Double = 0

    mutating func reset() {
        directionDown = nil
        distance = 0
    }
}

/// Native fullscreen action selected for a user-driven vertical scroll.
enum ReaderAutoFullscreenAction: Equatable {
    case enterFullscreen
    case exitFullscreen
    case none
}

/// Resolves auto-fullscreen threshold behavior without touching SwiftUI state.
enum ReaderAutoFullscreenPolicy {
    static let defaultScrollThreshold: Double = 56.0

    static func action(
        deltaY: Double,
        isEnabled: Bool,
        isFullScreen: Bool,
        fullscreenLockedByDoubleTap: Bool,
        threshold: Double = defaultScrollThreshold,
        tracking: inout ReaderAutoFullscreenTracking
    ) -> ReaderAutoFullscreenAction {
        guard isEnabled else {
            tracking.reset()
            return .none
        }
        guard deltaY != 0 else { return .none }

        let isDirectionDown = deltaY > 0
        if tracking.directionDown != isDirectionDown {
            tracking.directionDown = isDirectionDown
            tracking.distance = 0
        }

        tracking.distance += abs(deltaY)
        guard tracking.distance >= threshold else { return .none }
        tracking.distance = 0

        guard !fullscreenLockedByDoubleTap else { return .none }

        if !isFullScreen && isDirectionDown {
            return .enterFullscreen
        }
        if isFullScreen && !isDirectionDown {
            return .exitFullscreen
        }
        return .none
    }
}
