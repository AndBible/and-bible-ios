// SpeakService.swift — Text-to-Speech integration

import Foundation
import AVFoundation
import Combine
import os.log

#if os(iOS)
import MediaPlayer
#endif

private let logger = Logger(subsystem: "org.andbible", category: "SpeakService")

/// Text-to-Speech service using AVSpeechSynthesizer.
///
/// Uses ObservableObject + @Published so SwiftUI views react to state changes.
/// Reports word-level progress via `onWordSpoken` for visual highlighting.
/// Integrates with Now Playing info center and remote command center on iOS.
public final class SpeakService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()

    /// Whether speech is currently playing.
    @Published public private(set) var isSpeaking = false

    /// Whether speech is paused.
    @Published public private(set) var isPaused = false

    /// User-facing speed (0.5x–2.0x). Persisted to SettingsStore.
    @Published public var userSpeed: Double = 1.0 {
        didSet {
            settingsStore?.setDouble("speak_speed", value: userSpeed)
        }
    }

    /// Computed AVSpeech rate from userSpeed.
    private var avRate: Float {
        let mapped = AVSpeechUtteranceDefaultSpeechRate * Float(userSpeed)
        return min(max(mapped, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
    }

    /// Sleep timer remaining seconds (nil = no timer).
    @Published public var sleepTimerRemaining: TimeInterval?

    /// Now Playing metadata — set by BibleReaderController before speak().
    @Published public var currentTitle: String?
    @Published public var currentSubtitle: String?

    /// Callback invoked when an utterance finishes naturally (not cancelled).
    public var onFinishedSpeaking: (() -> Void)?

    /// Callback for forward/backward navigation during speech.
    public var onRequestNext: (() -> Void)?
    public var onRequestPrevious: (() -> Void)?

    /// Called for each word about to be spoken: (word, characterRange in full text).
    public var onWordSpoken: ((String, NSRange) -> Void)?

    /// Called when speech stops (for clearing highlights).
    public var onSpeechStopped: (() -> Void)?

    /// Settings store for persisting speed and sleep timer. Wired by BibleReaderView.
    public var settingsStore: SettingsStore?

    /// The full text of the current utterance (for range lookups).
    private var currentText: String = ""

    /// Tracks whether the user explicitly stopped playback (vs. natural completion).
    private var userStopped = false

    /// Tracks whether playback was interrupted (phone call, etc.) for resume logic.
    private var wasInterrupted = false

    private var sleepTimer: Timer?

    public override init() {
        super.init()
        synthesizer.delegate = self
        #if os(iOS)
        setupRemoteCommandCenter()
        setupAudioNotifications()
        #endif
    }

    deinit {
        #if os(iOS)
        NotificationCenter.default.removeObserver(self)
        tearDownRemoteCommandCenter()
        #endif
    }

    /// Restore persisted settings (speed, last sleep timer). Call after wiring settingsStore.
    public func restoreSettings() {
        guard let store = settingsStore else { return }
        let savedSpeed = store.getDouble("speak_speed", default: 1.0)
        if savedSpeed >= 0.5 && savedSpeed <= 2.0 {
            userSpeed = savedSpeed
        }
    }

    /// Speak the given text.
    public func speak(text: String, language: String = "en-US") {
        stop()

        currentText = text
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = avRate
        utterance.voice = AVSpeechSynthesisVoice(language: language)

        configureAudioSession()

        userStopped = false
        wasInterrupted = false
        synthesizer.speak(utterance)
        isSpeaking = true
        isPaused = false

        #if os(iOS)
        updateNowPlayingInfo()
        #endif
    }

    /// Pause speech.
    public func pause() {
        synthesizer.pauseSpeaking(at: .word)
        isPaused = true
        #if os(iOS)
        updateNowPlayingInfo()
        #endif
    }

    /// Resume paused speech.
    public func resume() {
        configureAudioSession()
        synthesizer.continueSpeaking()
        isPaused = false
        #if os(iOS)
        updateNowPlayingInfo()
        #endif
    }

    /// Stop speech entirely.
    public func stop() {
        userStopped = true
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        isPaused = false
        cancelSleepTimer()
        onSpeechStopped?()
        #if os(iOS)
        clearNowPlayingInfo()
        #endif
    }

    /// Skip forward (delegate to controller).
    public func skipForward() {
        stop()
        onRequestNext?()
    }

    /// Skip backward (delegate to controller).
    public func skipBackward() {
        stop()
        onRequestPrevious?()
    }

    /// Set a sleep timer.
    public func setSleepTimer(minutes: Int?) {
        cancelSleepTimer()
        guard let minutes, minutes > 0 else { return }

        sleepTimerRemaining = TimeInterval(minutes * 60)
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let remaining = self.sleepTimerRemaining {
                self.sleepTimerRemaining = remaining - 1
                if remaining <= 0 {
                    self.stop()
                }
            }
        }
    }

    private func cancelSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepTimerRemaining = nil
    }

    private func configureAudioSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    // MARK: - Now Playing (iOS)

    #if os(iOS)
    private func updateNowPlayingInfo() {
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = currentTitle ?? "Bible"
        info[MPMediaItemPropertyArtist] = currentSubtitle ?? "AndBible"
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPaused ? 0.0 : userSpeed
        info[MPMediaItemPropertyPlaybackDuration] = 0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    #endif

    // MARK: - Remote Command Center (iOS)

    #if os(iOS)
    private func setupRemoteCommandCenter() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.isPaused {
                    self.resume()
                } else if self.isSpeaking {
                    self.pause()
                }
            }
            return .success
        }
        center.stopCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.stop() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.skipForward() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.skipBackward() }
            return .success
        }
    }

    private func tearDownRemoteCommandCenter() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.stopCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
    }
    #endif

    // MARK: - Audio Interruption & Route Change (iOS)

    #if os(iOS)
    private func setupAudioNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch type {
            case .began:
                if self.isSpeaking && !self.isPaused {
                    self.wasInterrupted = true
                    self.pause()
                }
            case .ended:
                if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                    if options.contains(.shouldResume) && self.wasInterrupted {
                        self.resume()
                    }
                }
                self.wasInterrupted = false
            @unknown default:
                break
            }
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if reason == .oldDeviceUnavailable {
                // Headphones disconnected — pause playback
                if self.isSpeaking && !self.isPaused {
                    self.pause()
                }
            }
        }
    }
    #endif

    // MARK: - AVSpeechSynthesizerDelegate

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        let text = currentText
        guard let range = Range(characterRange, in: text) else {
            logger.warning("willSpeak: could not convert range \(characterRange.location):\(characterRange.length)")
            return
        }
        let word = String(text[range])
        logger.info("willSpeak: '\(word)' at \(characterRange.location) callback=\(self.onWordSpoken != nil)")
        onWordSpoken?(word, characterRange)
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        isSpeaking = false
        isPaused = false
        onSpeechStopped?()
        #if os(iOS)
        clearNowPlayingInfo()
        #endif
        // Only auto-advance if the utterance finished naturally (not user-stopped)
        if !userStopped {
            onFinishedSpeaking?()
        }
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        isSpeaking = false
        isPaused = false
        onSpeechStopped?()
        #if os(iOS)
        clearNowPlayingInfo()
        #endif
    }
}
