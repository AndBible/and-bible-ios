// SpeakSystemPresentationPolicy.swift -- Product-boundary rules for system speech surfaces

import Foundation

/** Immutable Now Playing values that standard-product speech may expose to the operating system. */
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
 Enforces the Calculator product boundary for operating-system speech presentation.

 Android's discrete flavor keeps speech audio functional but does not attach a media session and
 replaces notification content with calculator-safe presentation. iOS has no Speak notification;
 its equivalent external surfaces are Now Playing metadata and remote-command registration. The
 policy is resolved once from the signed app bundle and then injected immutably into `SpeakService`.
 */
struct SpeakSystemPresentationPolicy: Equatable, Sendable {
    /// Existing app Info.plist contract populated by each Xcode product configuration.
    static let buildIdentityInfoKey = "AndBibleBuildIdentity"

    /// Whether this product may expose Now Playing metadata and remote media commands.
    let exposesMediaSession: Bool

    /// Standard AndBible behavior with full system media integration.
    static let standard = SpeakSystemPresentationPolicy(exposesMediaSession: true)

    /// Calculator behavior with no system media session or content metadata.
    static let calculator = SpeakSystemPresentationPolicy(exposesMediaSession: false)

    /**
     Resolves a product policy from immutable bundle metadata.

     - Parameter infoDictionary: App bundle metadata containing `AndBibleBuildIdentity`.
     - Returns: Standard policy only for the exact `standard` marker; every other value suppresses
       system media exposure.
     - Side effects: none.
     - Failure modes: Missing, unresolved, or malformed values fail closed to Calculator policy.
     */
    static func resolve(from infoDictionary: [String: Any]?) -> SpeakSystemPresentationPolicy {
        guard let identity = infoDictionary?[buildIdentityInfoKey] as? String,
              identity == "standard" else {
            return .calculator
        }
        return .standard
    }

    /// Policy for the currently executing app bundle, evaluated when a service is constructed.
    static var current: SpeakSystemPresentationPolicy {
        resolve(from: Bundle.main.infoDictionary)
    }

    /**
     Builds metadata only when the active product is allowed to expose a media session.

     Spoken command text is deliberately not an input, so neither product can accidentally publish
     the current utterance through this boundary. Calculator builds always return `nil` even when
     reader titles contain Bible identity.

     - Parameters:
       - title: Current reader title, or `nil` when unavailable.
       - subtitle: Current reader subtitle, or `nil` when unavailable.
       - playbackRate: Current standard-product playback rate.
     - Returns: Standard-product metadata with legacy fallbacks, or `nil` for Calculator.
     - Side effects: none.
     - Failure modes: Missing standard-product metadata uses the existing Bible/AndBible fallback.
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
