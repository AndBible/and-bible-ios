// SpeakSystemPresentationPolicy.swift -- Discrete-mode rules for system speech surfaces

import Foundation

/** Immutable Now Playing values that non-discrete speech may expose to the operating system. */
struct SpeakNowPlayingPresentation: Equatable, Sendable {
    /// Reader title, normally the current key or passage.
    let title: String

    /// Reader subtitle, normally the current module or book name.
    let artist: String

    /// Current playback rate reported to system media controls.
    let playbackRate: Double

    /** Creates a complete metadata value without performing system publication. */
    init(title: String, artist: String, playbackRate: Double) {
        self.title = title
        self.artist = artist
        self.playbackRate = playbackRate
    }
}

/**
 Enforces Android's runtime discrete-mode boundary for operating-system speech presentation.

 Android checks `CommonUtils.isDiscrete` whenever it builds speech notification state: audio remains
 functional, but the media session and passage identity are suppressed. iOS has no equivalent Speak
 notification, so this policy applies the same runtime preference to Now Playing metadata and remote
 command registration inside the single installed AndBible app.
 */
struct SpeakSystemPresentationPolicy: Equatable, Sendable {
    /// Whether the current runtime mode may expose Now Playing metadata and remote media commands.
    let exposesMediaSession: Bool

    /// Normal AndBible behavior with full system media integration.
    static let standard = SpeakSystemPresentationPolicy(exposesMediaSession: true)

    /// Runtime discrete behavior with no system media session or content metadata.
    static let discrete = SpeakSystemPresentationPolicy(exposesMediaSession: false)

    /**
     Resolves a policy from Android's runtime `discrete_mode` preference.

     - Parameter discreteModeEnabled: Whether runtime discrete mode is enabled.
     - Returns: Discrete policy when enabled, otherwise normal AndBible media behavior.
     - Side effects: none.
     - Failure modes: none.
     */
    static func resolve(discreteModeEnabled: Bool) -> SpeakSystemPresentationPolicy {
        discreteModeEnabled ? .discrete : .standard
    }

    /// Policy for the current persisted runtime mode.
    static var current: SpeakSystemPresentationPolicy {
        resolve(
            discreteModeEnabled: UserDefaults.standard.bool(
                forKey: AppPreferenceKey.discreteMode.rawValue
            )
        )
    }

    /**
     Builds metadata only when the active runtime mode is allowed to expose a media session.

     Spoken command text is deliberately not an input, so neither runtime mode can accidentally
     publish the current utterance through this boundary. Discrete mode always returns `nil` even when reader
     titles contain Bible identity.

     - Parameters:
       - title: Current reader title, or `nil` when unavailable.
       - subtitle: Current reader subtitle, or `nil` when unavailable.
       - playbackRate: Current playback rate.
     - Returns: Metadata with legacy fallbacks, or `nil` in discrete mode.
     - Side effects: none.
     - Failure modes: Missing metadata uses the existing Bible/AndBible fallback.
     */
    func nowPlayingPresentation(
        title: String?,
        subtitle: String?,
        playbackRate: Double
    ) -> SpeakNowPlayingPresentation? {
        guard exposesMediaSession else { return nil }
        return SpeakNowPlayingPresentation(
            title: title ?? "Bible",
            artist: subtitle ?? "AndBible",
            playbackRate: playbackRate
        )
    }
}
