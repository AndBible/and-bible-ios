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

/// Rendered Vue document kind currently hosted by a native reader pane.
enum ReaderRenderedDocumentKind: Equatable {
    /// Standard Bible, commentary, auxiliary, or transient document content.
    case standard

    /// Android-style StudyPad document rendered inside the shared Vue reader.
    case studyPad

    /// Android-style Memorize document rendered inside the shared Vue reader.
    case memorize

    /**
     Whether native chapter/document swipes may leave this rendered document.

     Android refuses page-next/page-previous gestures for StudyPad and Memorize fake documents.
     Keeping that gate on the rendered document kind prevents the host gesture recognizer from
     escaping special Vue documents that manage their own internal interaction.
     */
    var allowsHorizontalDocumentNavigation: Bool {
        switch self {
        case .standard:
            return true
        case .studyPad, .memorize:
            return false
        }
    }
}

/// Resolves configured Bible-view swipe behavior without touching view or controller state.
enum ReaderHorizontalSwipePolicy {
    /**
     Maps a native horizontal swipe into the reader action allowed by the current pane state.

     - Parameters:
       - modeRawValue: Stored `bible_view_swipe_mode` preference value; unknown values use the
         Android-compatible chapter-navigation default.
       - direction: Native swipe direction reported by the web-view wrapper.
       - hasActiveSelection: Whether the pane currently owns a text selection that should keep
         swipe gestures from navigating away.
       - hasOpenModal: Whether the Vue reader client reports an open modal for the pane.
       - allowsDocumentNavigation: Whether the current rendered document may be replaced by a
         horizontal chapter/document navigation action.
     - Returns: The navigation, page-scroll, or no-op action the host should execute.

     Side effects:
     - none; callers execute the returned action.

     Failure modes:
     - returns `.none` when a selection or Vue modal owns interaction, or when the preference
       explicitly disables horizontal swipe handling.
     - returns `.none` for chapter-navigation swipes when the current rendered document does not
       allow horizontal document navigation.
     */
    static func action(
        modeRawValue: String,
        direction: NativeHorizontalSwipeDirection,
        hasActiveSelection: Bool,
        hasOpenModal: Bool,
        allowsDocumentNavigation: Bool = true
    ) -> ReaderHorizontalSwipeAction {
        guard !hasOpenModal else { return .none }
        guard !hasActiveSelection else { return .none }

        switch BibleSwipeMode(rawValue: modeRawValue) ?? .chapter {
        case .chapter:
            guard allowsDocumentNavigation else { return .none }
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
