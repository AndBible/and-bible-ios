// SpeakService.swift -- Provider-driven text-to-speech integration

import AVFoundation
import Combine
import Foundation
import os.log

#if os(iOS)
import MediaPlayer
#endif

private let logger = Logger(subsystem: "org.andbible", category: "SpeakService")

/** Session-owned callbacks that cannot be retargeted while an older provider is stopping. */
public struct SpeakSessionCallbacks {
    /// Called after natural provider exhaustion.
    public var onFinished: (() -> Void)?
    /// Called for each spoken word in the current command.
    public var onWordSpoken: ((String, NSRange, UInt64) -> Void)?
    /// Called when the provider enters an exact stream position.
    public var onPositionChanged: ((SpeakStreamPosition, UInt64) -> Void)?
    /// Called before a session generation is invalidated during stop.
    public var onStopped: ((UInt64) -> Void)?

    /** Creates a generation-scoped callback bundle. */
    public init(
        onFinished: (() -> Void)? = nil,
        onWordSpoken: ((String, NSRange, UInt64) -> Void)? = nil,
        onPositionChanged: ((SpeakStreamPosition, UInt64) -> Void)? = nil,
        onStopped: ((UInt64) -> Void)? = nil
    ) {
        self.onFinished = onFinished
        self.onWordSpoken = onWordSpoken
        self.onPositionChanged = onPositionChanged
        self.onStopped = onStopped
    }
}

/** Complete reader-owned session state returned during checkpoint reconstruction. */
public struct SpeakSessionReconstruction {
    /// Exact category provider rebuilt from persisted source cursors.
    public let provider: SpeakTextProviding
    /// Generation-scoped reader callbacks for highlights and synchronized navigation.
    public let callbacks: SpeakSessionCallbacks?
    /// Optional Now Playing title restored by the reader source.
    public let title: String?
    /// Optional Now Playing subtitle restored by the reader source.
    public let subtitle: String?

    /** Creates one reconstructed session without starting synthesis. */
    public init(
        provider: SpeakTextProviding,
        callbacks: SpeakSessionCallbacks? = nil,
        title: String? = nil,
        subtitle: String? = nil
    ) {
        self.provider = provider
        self.callbacks = callbacks
        self.title = title
        self.subtitle = subtitle
    }
}

/** Synchronous reasons the first requested utterance could not be submitted. */
public enum SpeakStartupFailure: Error, Equatable, LocalizedError, Sendable {
    /// Provider positions or settings could not be prepared consistently.
    case preparationFailed
    /// The provider exhausted without producing one audible command.
    case noSpeakableContent
    /// A reconstructed semantic cursor did not match freshly materialized commands.
    case invalidResumeCursor
    /// No installed platform voice can speak the first audible command's language.
    case unsupportedLanguage(String)

    /// Stable user-facing fallback used by callers that need to surface startup failure immediately.
    public var errorDescription: String? {
        switch self {
        case .preparationFailed:
            return String(localized: "error_occurred", defaultValue: "An error occurred.")
        case .noSpeakableContent:
            return String(localized: "error_no_content", defaultValue: "No content.")
        case .invalidResumeCursor:
            return String(localized: "error_occurred", defaultValue: "An error occurred.")
        case .unsupportedLanguage:
            return String(
                localized: "tts_lang_not_available",
                defaultValue: "Language is not available."
            )
        }
    }
}

/** Typed result of synchronously preparing and submitting the first speech utterance. */
public enum SpeakStartResult: Equatable, Sendable {
    /// A replacement session submitted its first utterance under this generation.
    case started(generation: UInt64)
    /// A queue request appended complete passages without replacing the active generation.
    case queued(generation: UInt64)
    /// No utterance was submitted; the associated failure is safe to surface or retry.
    case failed(SpeakStartupFailure)

    /// Whether the request started or appended speech successfully.
    public var succeeded: Bool {
        switch self {
        case .started, .queued: true
        case .failed: false
        }
    }

    /// Active generation for successful requests, or `nil` when startup failed.
    public var generation: UInt64? {
        switch self {
        case .started(let generation), .queued(let generation): generation
        case .failed: nil
        }
    }
}

/** Internal outcome while searching a provider for its next audible command. */
private enum SpeakLoadResult {
    case started
    case exhausted
    case failed(SpeakStartupFailure)
}

private struct AndroidSpeakOrdinalRange: Codable {
    let start: Int
    let end: Int?

    private enum CodingKeys: String, CodingKey {
        case start
        case end
    }

    /** Decodes Android's nullable ordinal endpoint while accepting historical omitted nulls. */
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = try container.decode(Int.self, forKey: .start)
        end = try container.decodeIfPresent(Int.self, forKey: .end)
    }

    /** Creates one exact Android ordinal cursor without inferring provider bounds. */
    init(start: Int, end: Int?) {
        self.start = start
        self.end = end
    }

    /** Emits Android's explicit nullable `end` field for kotlinx-serialization parity. */
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(start, forKey: .start)
        if let end {
            try container.encode(end, forKey: .end)
        } else {
            try container.encodeNil(forKey: .end)
        }
    }
}

private struct AndroidGeneralSpeakCursor: Codable {
    let key: String
    let document: String
    let ordinalRange: AndroidSpeakOrdinalRange?
    let htmlId: String?

    private enum CodingKeys: String, CodingKey {
        case key
        case document
        case ordinalRange
        case htmlId
    }

    /** Decodes Android's generic cursor while accepting historical omitted nullable fields. */
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        document = try container.decode(String.self, forKey: .document)
        ordinalRange = try container.decodeIfPresent(AndroidSpeakOrdinalRange.self, forKey: .ordinalRange)
        htmlId = try container.decodeIfPresent(String.self, forKey: .htmlId)
    }

    /** Creates one Android `BookAndKeySerialized` compatibility payload. */
    init(
        key: String,
        document: String,
        ordinalRange: AndroidSpeakOrdinalRange?,
        htmlId: String?
    ) {
        self.key = key
        self.document = document
        self.ordinalRange = ordinalRange
        self.htmlId = htmlId
    }

    /** Emits explicit nulls because Android's shared JSON encoder keeps nullable fields. */
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(document, forKey: .document)
        if let ordinalRange {
            try container.encode(ordinalRange, forKey: .ordinalRange)
        } else {
            try container.encodeNil(forKey: .ordinalRange)
        }
        if let htmlId {
            try container.encode(htmlId, forKey: .htmlId)
        } else {
            try container.encodeNil(forKey: .htmlId)
        }
    }
}

protocol SpeechSynthesizing: AnyObject {
    var delegate: AVSpeechSynthesizerDelegate? { get set }
    func speak(_ utterance: AVSpeechUtterance)
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool
    func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool
    func continueSpeaking() -> Bool
}

extension AVSpeechSynthesizer: SpeechSynthesizing {}

protocol SpeakTimerToken: AnyObject {
    func invalidate()
}

protocol SpeakTimerScheduling {
    func scheduleRepeating(every interval: TimeInterval, _ action: @escaping () -> Void) -> SpeakTimerToken
}

/** Media-session commands whose queued delivery must remain bound to one speech generation. */
enum SpeakRemoteCommand {
    case play
    case pause
    case togglePlayPause
    case stop
    case nextTrack
    case previousTrack
}

private final class FoundationSpeakTimerToken: SpeakTimerToken {
    private let timer: Timer

    init(timer: Timer) {
        self.timer = timer
    }

    func invalidate() {
        timer.invalidate()
    }
}

private struct FoundationSpeakTimerScheduler: SpeakTimerScheduling {
    func scheduleRepeating(every interval: TimeInterval, _ action: @escaping () -> Void) -> SpeakTimerToken {
        FoundationSpeakTimerToken(
            timer: Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in action() }
        )
    }
}

/**
 Provider-driven text-to-speech service aligned with Android's SpeakControl architecture.

 The active `SpeakTextProviding` instance owns stream position and semantic transport. This service
 owns AVFoundation utterances, structured settings, timer lifecycle, bookmark persistence, and media
 controls. Commands are consumed one at a time so headings, footnotes, pauses, exclusions, and
 provider repetition remain observable and testable instead of being flattened into one chapter.

 Side effects:
 - configures the platform playback audio session
 - persists Android-shaped `SpeakSettings` and advanced preferences through `SettingsStore`
 - creates or moves Speak-label bookmarks through `SpeakBookmarkManaging`
 - publishes Now Playing metadata and remote-command handlers on iOS

 Failure modes:
 - empty providers stop without invoking the speech engine
 - malformed OSIS is handled by `SpeakCommandBuilder` before commands reach this service
 - unsupported languages stop before synthesis and publish a user-observable failure status
 - platform speech-control failures leave state paused/stopped without corrupting provider position
 */
public final class SpeakService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private static let settingsKey = "SpeakSettings"
    private static let legacySpeedKey = "speak_speed"
    private static let pausedCheckpointKey = "SpeakProviderCheckpoint"
    private static let lastCheckpointKey = "SpeakLastProviderCheckpoint"
    private static let persistLocaleKey = "SpeakLocale"
    private static let persistBibleProviderKey = "SpeakBibleProvider"
    private static let persistBibleBookKey = "SpeakBibleBook"
    private static let persistBibleVerseKey = "SpeakBibleVerse"
    private static let persistGeneralBookKey = "SpeakGenBook"
    private static let persistGeneralKey = "SpeakGenKey"

    private let synthesizer: SpeechSynthesizing
    private let timerScheduler: SpeakTimerScheduling
    private let voiceResolver: SpeechVoiceResolving
    private let deviceLocale: Locale
    private var systemPresentationPolicy: SpeakSystemPresentationPolicy
    private let observesRuntimeDiscreteMode: Bool

    /// Whether a provider session is active, including paused playback.
    @Published public private(set) var isSpeaking = false

    /// Whether the active provider is paused.
    @Published public private(set) var isPaused = false

    /// Whether the current provider is Android memorization-loop mode.
    @Published public private(set) var isMemorizationLoop = false

    /// Complete workspace-compatible Android speech settings.
    @Published public private(set) var settings = SpeakSettings()

    /// Complete global Android advanced speech settings.
    @Published public private(set) var advancedSettings = AdvancedSpeakSettings()

    /// Current timer countdown for UI display; `nil` means no timer task is running.
    @Published public private(set) var sleepTimerRemaining: TimeInterval?

    /// Current provider position.
    @Published public private(set) var currentPosition: SpeakStreamPosition?

    /// Most recent user-observable failure; successful synthesis clears the value.
    @Published public private(set) var lastFailure: SpeakServiceFailure?

    /// Most recent synchronous provider-start failure, including preparation and empty content.
    @Published public private(set) var lastStartupFailure: SpeakStartupFailure?

    /// Android Speak-label bookmarks available to the resume picker.
    @Published public private(set) var resumeBookmarks: [SpeakResumeBookmark] = []

    /// Current Now Playing title.
    @Published public var currentTitle: String?

    /// Current Now Playing subtitle.
    @Published public var currentSubtitle: String?

    /**
     Compatibility speed surface expressed as a multiplier.

     Android persists percentage values. Reads and writes translate directly to `speed / 100`
     without maintaining a second preference that can drift from workspace/sync state.
     */
    public var userSpeed: Double {
        get { Double(settings.playbackSettings.speed) / 100.0 }
        set {
            var playback = settings.playbackSettings
            playback.speed = Int((newValue * 100).rounded())
            updatePlaybackSettings(playback)
        }
    }

    /// Called after a provider reaches its terminal position naturally.
    public var onFinishedSpeaking: (() -> Void)?

    /// Legacy callback retained for source compatibility; provider transport no longer calls it.
    public var onRequestNext: (() -> Void)?

    /// Legacy callback retained for source compatibility; provider transport no longer calls it.
    public var onRequestPrevious: (() -> Void)?

    /// Called before each spoken word with its UTF-16 range in the current command text.
    public var onWordSpoken: ((String, NSRange) -> Void)?

    /// Called whenever the provider enters a new stream position.
    public var onPositionChanged: ((SpeakStreamPosition) -> Void)?

    /// Called when playback stops and reader highlights should be cleared.
    public var onSpeechStopped: (() -> Void)?

    /// Called when structured settings change so the active workspace can persist them.
    public var onSettingsChanged: ((SpeakSettings) -> Void)?

    /// Called when global advanced settings change.
    public var onAdvancedSettingsChanged: ((AdvancedSpeakSettings) -> Void)?

    /// Called when a resume-picker row is selected; the reader reconstructs its category provider.
    public var onRequestResumeBookmark: ((SpeakResumeBookmark) -> Void)?

    /** Supplies the visible Bible position for Android's stopped-settings bookmark update. */
    public var onRequestStoppedBibleBookmarkPosition: (() -> SpeakStreamPosition?)?

    /** Reconstructs an exact persisted provider after process death or stopped remote Play. */
    public var onRequestProviderReconstruction: ((SpeakProviderCheckpoint) -> SpeakTextProviding?)? {
        didSet { reconstructPersistedPauseIfPossible() }
    }

    /** Reconstructs a provider together with its generation-scoped reader callbacks and metadata. */
    public var onRequestSessionReconstruction: ((SpeakProviderCheckpoint) -> SpeakSessionReconstruction?)? {
        didSet { reconstructPersistedPauseIfPossible() }
    }

    /// Builds the reader's default category provider when remote Play has no last checkpoint.
    public var onRequestDefaultProvider: (() -> SpeakTextProviding?)?

    /// Builds the reader's complete default session when remote Play has no persisted checkpoint.
    public var onRequestDefaultSession: (() -> SpeakSessionReconstruction?)?

    /// Settings persistence supplied by the reader shell.
    public var settingsStore: SettingsStore?

    /// Speak-label bookmark persistence supplied by the active reader controller.
    public weak var bookmarkManager: SpeakBookmarkManaging? {
        didSet { reloadResumeBookmarks() }
    }

    /// Active provider category exposed for UI and contract tests.
    public var activeProviderCategory: SpeakDocumentCategory? { provider?.category }

    /// Bible positions available to Android's two-stage repeated-range editor.
    public var availableBiblePositions: [SpeakStreamPosition] {
        guard provider?.category == .bible else { return [] }
        return provider?.availablePositions ?? []
    }

    /// Whether the active provider accepts Android's repeated Bible range editor.
    public var supportsVerseRangeEditing: Bool {
        provider?.supportsVerseRangeEditing == true
    }

    /// Monotonic identity used to reject callbacks and queued synchronization from replaced sessions.
    public private(set) var currentSessionGeneration: UInt64 = 0

    private var provider: SpeakTextProviding?
    private var currentUnit: SpeakStreamUnit?
    private var commandIndex = 0
    private var pendingPause: TimeInterval = 0
    private var currentText = ""
    private var currentCommandText = ""
    private var activeCommandIndex: Int?
    private var currentCommandBaseOffset = 0
    private var currentCommandCharacterOffset = 0
    private var pendingResumePlaybackCursor: SpeakPlaybackCursor?
    private var currentUtterance: AVSpeechUtterance?
    private var currentUtteranceGeneration: UInt64?
    private var acceptedFirstUtteranceGeneration: UInt64?
    private var ignoredCancelledUtterances = Set<ObjectIdentifier>()
    private var sleepTimerToken: SpeakTimerToken?
    /// Monotonic timer ownership used to reject callbacks already queued before invalidation.
    private var sleepTimerGeneration: UInt64 = 0
    private var applyingSettings = false
    private var userStopped = false
    private var wasInterrupted = false
    private var activeCallbacks: SpeakSessionCallbacks?
    private var bookmarkPersistedForPausedTransition = false
    private var pendingPersistedPauseCheckpoint: SpeakProviderCheckpoint?
    private var lastPersistedPosition: SpeakStreamPosition?

    #if os(iOS)
    private var remoteCommandHandlingEnabled = false
    private var remoteCommandsRegistered = false

    /// Whether this service currently owns system remote-command handlers.
    var hasRegisteredRemoteCommands: Bool { remoteCommandsRegistered }
    #endif

    /** Creates a service backed by the platform speech synthesizer and timer. */
    public override convenience init() {
        self.init(
            synthesizer: AVSpeechSynthesizer(),
            timerScheduler: FoundationSpeakTimerScheduler(),
            voiceResolver: SystemSpeechVoiceResolver(),
            deviceLocale: .current,
            systemPresentationPolicy: .current,
            observesRuntimeDiscreteMode: true
        )
    }

    /**
     Creates an injectable service for deterministic audio and clock tests.

     - Parameters:
       - synthesizer: Speech engine or deterministic test double.
       - timerScheduler: Repeating timer scheduler or controllable test clock.
       - voiceResolver: Installed-voice resolver that rejects unrelated language fallbacks.
       - deviceLocale: Immutable locale used for Android's regional voice preference.
       - systemPresentationPolicy: Initial runtime boundary for Now Playing and media commands.
       - observesRuntimeDiscreteMode: Whether UserDefaults changes should re-resolve that boundary.
     - Side effects: Assigns the speech delegate and registers iOS audio and preference notifications.
     - Failure modes: Construction cannot fail; unavailable voices are handled when synthesis starts.
     */
    init(
        synthesizer: SpeechSynthesizing,
        timerScheduler: SpeakTimerScheduling = FoundationSpeakTimerScheduler(),
        voiceResolver: SpeechVoiceResolving = SystemSpeechVoiceResolver(),
        deviceLocale: Locale = .current,
        systemPresentationPolicy: SpeakSystemPresentationPolicy = .current,
        observesRuntimeDiscreteMode: Bool = false
    ) {
        self.synthesizer = synthesizer
        self.timerScheduler = timerScheduler
        self.voiceResolver = voiceResolver
        self.deviceLocale = deviceLocale
        self.systemPresentationPolicy = systemPresentationPolicy
        self.observesRuntimeDiscreteMode = observesRuntimeDiscreteMode
        super.init()
        self.synthesizer.delegate = self
        #if os(iOS)
        setRemoteCommandHandlingEnabled(AppPreferenceRegistry.boolDefault(for: .enableBluetoothPref) ?? true)
        setupAudioNotifications()
        if observesRuntimeDiscreteMode {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleRuntimePreferencesChanged(_:)),
                name: UserDefaults.didChangeNotification,
                object: UserDefaults.standard
            )
        }
        #endif
    }

    deinit {
        sleepTimerToken?.invalidate()
        #if os(iOS)
        NotificationCenter.default.removeObserver(self)
        tearDownRemoteCommandCenter()
        #endif
    }

    /**
     Restores global speech state after `settingsStore` is assigned.

     Structured Android JSON is authoritative. The historical multiplier is migrated only when no
     structured payload exists, then immediately persisted in the complete schema.
     */
    public func restoreSettings() {
        guard let store = settingsStore else { return }
        let restored = restoredStructuredSettings(from: store)
        advancedSettings = AdvancedSpeakSettings.load(from: store)
        applySettings(
            restored.settings,
            persist: restored.shouldPersistMigration,
            notifyWorkspace: false,
            updateBookmark: false,
            restartPlayback: true
        )
        applyBehaviorPreferences()
        pendingPersistedPauseCheckpoint = persistedCheckpoint(forKey: Self.pausedCheckpointKey)
            ?? importedAndroidPauseCheckpoint()
        reconstructPersistedPauseIfPossible()
    }

    /** Applies workspace-restored structured settings to synthesis and persistence. */
    public func applySettings(_ value: SpeakSettings, persist: Bool = true) {
        applySettings(
            value,
            persist: persist,
            notifyWorkspace: persist,
            updateBookmark: false,
            restartPlayback: true
        )
    }

    /** Applies a workspace switch without writing the new settings back into the old workspace. */
    public func applyWorkspaceSettings(_ value: SpeakSettings) {
        applySettings(
            value,
            persist: true,
            notifyWorkspace: false,
            updateBookmark: false,
            restartPlayback: true
        )
    }

    /**
     Reloads restored global preferences, then reapplies the active workspace's structured state.

     Active providers receive restored advanced settings immediately. Playing sessions restart at
     their exact provider checkpoint so command synthesis reflects restored exclusions and divine-
     name behavior; paused sessions remain paused and use the restored settings when resumed.
     */
    public func reloadAfterBackupRestore(activeWorkspaceSettings: SpeakSettings?) {
        guard let store = settingsStore else { return }
        let previousPlaybackSettings = settings.playbackSettings
        let previousAdvancedSettings = advancedSettings
        let restored = restoredStructuredSettings(from: store)
        advancedSettings = AdvancedSpeakSettings.load(from: store)
        applySettings(
            activeWorkspaceSettings ?? restored.settings,
            persist: true,
            notifyWorkspace: false,
            updateBookmark: false,
            restartPlayback: false
        )
        applyBehaviorPreferences()
        if let indexed = provider as? IndexedSpeakTextProvider {
            indexed.advancedSettings = advancedSettings
        }
        let synthesisChanged = previousPlaybackSettings != settings.playbackSettings
            || previousAdvancedSettings != advancedSettings
        if synthesisChanged, isSpeaking, !isPaused {
            checkpointAndRestartActiveSession()
        } else if synthesisChanged, isPaused,
                  provider?.prepare(settings: effectiveSettings) != true {
            stopInternal(persistPosition: false, clearProvider: true, notifyStopped: true)
        } else if provider == nil {
            pendingPersistedPauseCheckpoint = persistedCheckpoint(forKey: Self.pausedCheckpointKey)
                ?? importedAndroidPauseCheckpoint()
            reconstructPersistedPauseIfPossible()
        }
    }

    /** Updates only Android's playback settings while preserving timer/general fields. */
    public func updatePlaybackSettings(_ value: PlaybackSettings) {
        var updated = settings
        updated.playbackSettings = value.normalized
        applySettings(
            updated,
            persist: true,
            notifyWorkspace: true,
            updateBookmark: true,
            restartPlayback: true
        )
    }

    /** Updates and persists all global advanced speech settings. */
    public func updateAdvancedSettings(_ value: AdvancedSpeakSettings) {
        advancedSettings = value
        if let store = settingsStore { value.save(to: store) }
        if let indexed = provider as? IndexedSpeakTextProvider {
            indexed.advancedSettings = value
        }
        onAdvancedSettingsChanged?(value)
        if isSpeaking, !isPaused {
            checkpointAndRestartActiveSession()
        }
    }

    /** Reapplies Bluetooth/media-control behavior after app preference changes. */
    public func applyBehaviorPreferences() {
        #if os(iOS)
        let enabled = settingsStore?.getBool(.enableBluetoothPref)
            ?? (AppPreferenceRegistry.boolDefault(for: .enableBluetoothPref) ?? true)
        setRemoteCommandHandlingEnabled(enabled)
        #endif
    }

    /**
     Applies a runtime speech-presentation boundary after discrete mode changes.

     - Parameter policy: Newly resolved normal or discrete-mode policy.
     - Side effects: Tears down or restores remote commands and clears or republishes Now Playing
       metadata for the active speech session.
     - Failure modes: Missing Bluetooth preference state falls back to Android's enabled default.
     */
    func applySystemPresentationPolicy(_ policy: SpeakSystemPresentationPolicy) {
        guard systemPresentationPolicy != policy else { return }
        systemPresentationPolicy = policy
        #if os(iOS)
        let bluetoothEnabled = settingsStore?.getBool(.enableBluetoothPref)
            ?? (AppPreferenceRegistry.boolDefault(for: .enableBluetoothPref) ?? true)
        setRemoteCommandHandlingEnabled(bluetoothEnabled)
        if policy.exposesMediaSession, isSpeaking || isPaused {
            updateNowPlayingInfo()
        } else if !policy.exposesMediaSession {
            clearNowPlayingInfo()
        }
        #endif
    }

    /**
     Starts a category-aware provider stream.

     With `queue` enabled, a running unpaused passage-list provider appends the incoming semantic
     passages without replacing the active generation. Other requests persist and stop existing
     playback first. Bookmark settings may then replace active playback fields when Android's
     restore-from-bookmark preference is enabled.

     - Parameters:
       - newProvider: Fully resolved provider to start or append.
       - callbacks: Generation-scoped reader callbacks for a replacement session.
       - queue: Android legacy key-list queue behavior; only compatible active passage providers append.
     - Returns: Typed synchronous first-utterance, append, or failure result.
     - Side effects: May append provider state, replace active synthesis, configure audio, and persist
       the previous provider position.
     - Failure modes: Preparation, empty content, invalid resume state, and unavailable voice fail
       synchronously without reporting a successful start.
     */
    @discardableResult
    public func start(
        provider newProvider: SpeakTextProviding,
        callbacks: SpeakSessionCallbacks? = nil,
        queue: Bool = false
    ) -> SpeakStartResult {
        if queue,
           isSpeaking,
           !isPaused,
           acceptedFirstUtteranceGeneration == currentSessionGeneration,
           let activePassageProvider = provider as? BiblePassageListSpeakTextProvider,
           let incomingPassageProvider = newProvider as? BiblePassageListSpeakTextProvider {
            guard activePassageProvider.append(incomingPassageProvider) else {
                return .failed(.preparationFailed)
            }
            lastStartupFailure = nil
            return .queued(generation: currentSessionGeneration)
        }

        stopInternal(persistPosition: true, clearProvider: true, notifyStopped: true)
        currentSessionGeneration &+= 1
        let generation = currentSessionGeneration
        activeCallbacks = callbacks ?? legacyCallbackSnapshot()
        provider = newProvider
        lastPersistedPosition = nil
        if let indexed = newProvider as? IndexedSpeakTextProvider {
            indexed.advancedSettings = advancedSettings
        }
        isMemorizationLoop = newProvider.isMemorizationLoop
        userStopped = false
        wasInterrupted = false
        bookmarkPersistedForPausedTransition = false
        pendingResumePlaybackCursor = newProvider.resumePlaybackCursor
        clearPersistedPauseCheckpoint()

        guard newProvider.prepare(settings: effectiveSettings) else {
            let failure: SpeakStartupFailure = newProvider.currentPosition == nil
                ? .noSpeakableContent
                : .preparationFailed
            failStartup(failure)
            return .failed(failure)
        }

        if newProvider.canAutoBookmark,
           let position = newProvider.currentPosition {
            let restored = bookmarkManager?.playbackSettingsForSpeakBookmark(at: position)
            if advancedSettings.restoreSettingsFromBookmarks,
               var restored {
                restored.bookId = nil
                restored.bookmarkWasCreated = nil
                var updated = settings
                updated.playbackSettings = restored
                applySettings(
                    updated,
                    persist: true,
                    notifyWorkspace: true,
                    updateBookmark: false,
                    restartPlayback: false
                )
            }
        }

        guard newProvider.prepare(settings: effectiveSettings) else {
            let failure: SpeakStartupFailure = newProvider.currentPosition == nil
                ? .noSpeakableContent
                : .preparationFailed
            failStartup(failure)
            return .failed(failure)
        }

        isSpeaking = true
        isPaused = false
        configureAudioSession()
        activateConfiguredSleepTimer()
        switch loadCurrentUnitAndSpeak() {
        case .started:
            lastStartupFailure = nil
            return .started(generation: generation)
        case .exhausted:
            publishStartupFailure(.noSpeakableContent)
            return .failed(.noSpeakableContent)
        case .failed(let failure):
            lastStartupFailure = failure
            return .failed(failure)
        }
    }

    /**
     Compatibility start API returning only the resulting generation.

     New callers that must distinguish preparation, no-content, and voice failures use `start`.

     - Parameters:
       - newProvider: Provider that replaces the active session.
       - callbacks: Generation-scoped reader callbacks.
     - Returns: Successful generation, or the post-failure service generation for source compatibility.
     - Side effects: Delegates all playback mutation to `start(provider:callbacks:queue:)`.
     - Failure modes: The scalar return intentionally does not encode startup failure; callers making
       user-visible decisions must use the typed API.
     */
    @discardableResult
    public func speak(
        provider newProvider: SpeakTextProviding,
        callbacks: SpeakSessionCallbacks? = nil
    ) -> UInt64 {
        start(provider: newProvider, callbacks: callbacks).generation ?? currentSessionGeneration
    }

    /** Starts a one-unit native selection provider. */
    public func speak(text: String, language: String = "en-US") {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            stop()
            return
        }
        speak(provider: SelectionSpeakTextProvider(text: text, language: language))
    }

    /** Starts a repeating one-unit memorization provider for source compatibility. */
    public func speakMemorizationLoop(text: String, language: String = "en-US") {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            stop()
            return
        }
        speak(
            provider: SelectionSpeakTextProvider(
                text: text,
                language: language,
                repeatPlayback: true
            )
        )
    }

    /** Persists the provider checkpoint, destroys the utterance, and enters Android pause state. */
    public func pause() {
        guard isSpeaking, !isPaused else { return }
        let checkpoint = currentProviderCheckpoint()
        pendingResumePlaybackCursor = checkpoint?.playbackCursor
        cancelCurrentUtteranceForReplacement()
        currentUnit = nil
        commandIndex = 0
        pendingPause = 0
        isPaused = true
        cancelSleepTimer(clearRemaining: true)
        persistPausedCheckpoint(checkpoint)
        if !bookmarkPersistedForPausedTransition {
            persistCurrentPosition()
            bookmarkPersistedForPausedTransition = true
        }
        #if os(iOS)
        updateNowPlayingInfo()
        #endif
    }

    /** Reconstructs speech from the provider checkpoint and restarts the configured timer duration. */
    public func resume() {
        if provider == nil { reconstructPersistedPauseIfPossible() }
        guard isSpeaking, isPaused, let provider else { return }
        guard provider.prepare(settings: effectiveSettings) else {
            stopInternal(persistPosition: false, clearProvider: true, notifyStopped: true)
            return
        }
        configureAudioSession()
        isPaused = false
        bookmarkPersistedForPausedTransition = false
        clearPersistedPauseCheckpoint()
        activateConfiguredSleepTimer()
        currentUnit = nil
        commandIndex = 0
        pendingPause = 0
        _ = loadCurrentUnitAndSpeak()
        #if os(iOS)
        updateNowPlayingInfo()
        #endif
    }

    /** Android Play behavior: resume pause state, reconstruct the last source, or start the default. */
    public func play() {
        if isPaused {
            resume()
            return
        }
        guard !isSpeaking else { return }
        if let checkpoint = persistedCheckpoint(forKey: Self.lastCheckpointKey),
           let reconstruction = requestedReconstruction(for: checkpoint) {
            currentTitle = reconstruction.title
            currentSubtitle = reconstruction.subtitle
            speak(provider: reconstruction.provider, callbacks: reconstruction.callbacks)
            return
        }
        if let defaultSession = onRequestDefaultSession?() {
            currentTitle = defaultSession.title
            currentSubtitle = defaultSession.subtitle
            speak(provider: defaultSession.provider, callbacks: defaultSession.callbacks)
        } else if let defaultProvider = onRequestDefaultProvider?() {
            speak(provider: defaultProvider)
        }
    }

    /** Stops immediately, persists provider position, and clears transient playback state. */
    public func stop() {
        stopInternal(persistPosition: true, clearProvider: true, notifyStopped: true)
    }

    /** Android previous transport: move exactly one provider unit. */
    public func previousUnit() {
        moveProvider { $0.rewind(.oneUnit) }
    }

    /** Android next transport: move exactly one provider unit. */
    public func nextUnit() {
        moveProvider { $0.forward(.oneUnit) }
    }

    /** Android rewind transport: provider-defined smart movement. */
    public func rewind() {
        moveProvider { $0.rewind(.smart) }
    }

    /** Android forward transport: provider-defined smart movement. */
    public func forward() {
        moveProvider { $0.forward(.smart) }
    }

    /// Compatibility alias now mapped to one provider unit instead of reader chapter navigation.
    public func skipBackward() { previousUnit() }

    /// Compatibility alias now mapped to one provider unit instead of reader chapter navigation.
    public func skipForward() { nextUnit() }

    /**
     Configures Android's persisted sleep timer.

     Positive selections update both `sleepTimer` and `lastSleepTimer`. Clearing updates only
     `sleepTimer`, preserving the next picker default. A running session starts a fresh countdown.
     */
    public func setSleepTimer(minutes: Int?) {
        var updated = settings
        if let minutes, minutes > 0 {
            updated.sleepTimer = minutes
            updated.lastSleepTimer = minutes
        } else {
            updated.sleepTimer = 0
        }
        applySettings(
            updated,
            persist: true,
            notifyWorkspace: true,
            updateBookmark: false,
            restartPlayback: false
        )
        if isSpeaking, !isPaused {
            activateConfiguredSleepTimer()
        } else {
            cancelSleepTimer(clearRemaining: true)
        }
    }

    /** Reloads Android Speak-label bookmarks for the picker. */
    public func reloadResumeBookmarks() {
        resumeBookmarks = bookmarkManager?.speakResumeBookmarks() ?? []
    }

    /** Routes a picker selection back to the active reader for provider reconstruction. */
    public func resume(from bookmark: SpeakResumeBookmark) {
        onRequestResumeBookmark?(bookmark)
    }

    /** Returns whether a queued callback still belongs to the active provider session. */
    public func isCurrentSession(_ generation: UInt64) -> Bool {
        generation == currentSessionGeneration && provider != nil
    }

    /**
     Returns whether queued reader cleanup still belongs to the latest stopped generation.

     `stopInternal` advances the generation once after invoking `onStopped`. A replacement `speak`
     advances it again and installs a provider, so delayed cleanup from the old session is rejected
     before it can clear the new session's highlights.
     */
    public func mayApplyStoppedSessionCleanup(_ generation: UInt64) -> Bool {
        provider == nil && currentSessionGeneration == generation &+ 1
    }

    /**
     Applies one media command only while its event still belongs to the captured speech generation.

     - Parameters:
       - command: Android-equivalent media-session action.
       - expectedSessionGeneration: Generation captured when the platform delivered the event.
     - Returns: `true` when the command was accepted; `false` when a replacement session made it stale.
     - Side effects: May start, pause, resume, stop, or smart-move the active provider.
     - Failure modes: Stale events are ignored without mutating the replacement session.
     */
    @discardableResult
    func performRemoteCommand(
        _ command: SpeakRemoteCommand,
        expectedSessionGeneration: UInt64
    ) -> Bool {
        guard currentSessionGeneration == expectedSessionGeneration else { return false }
        switch command {
        case .play:
            play()
        case .pause:
            pause()
        case .togglePlayPause:
            if isPaused {
                resume()
            } else if isSpeaking {
                pause()
            } else {
                play()
            }
        case .stop:
            stop()
        case .nextTrack:
            forward()
        case .previousTrack:
            rewind()
        }
        return true
    }

    /** Stores or clears Android's repeated Bible range from two exact provider positions. */
    @discardableResult
    public func setVerseRange(
        start: SpeakStreamPosition?,
        end: SpeakStreamPosition?
    ) -> Bool {
        guard provider?.supportsVerseRangeEditing == true else { return false }
        var playback = settings.playbackSettings
        guard let start, let end else {
            playback.verseRange = nil
            updatePlaybackSettings(playback)
            return true
        }
        guard start.category == .bible,
              end.category == .bible,
              start.bookInitials == end.bookInitials,
              let versification = start.versification,
              versification == end.versification,
              let startReference = start.osisRef,
              let endReference = end.osisRef,
              let positions = provider?.availablePositions,
              let startIndex = positions.firstIndex(of: start),
              let endIndex = positions.firstIndex(of: end),
              endIndex > startIndex,
              let range = SpeakVerseRange(
                  versification: versification,
                  osisRef: "\(startReference)-\(endReference)"
              ) else {
            return false
        }
        playback.verseRange = range
        updatePlaybackSettings(playback)
        return provider?.prepare(settings: effectiveSettings) == true
    }

    /**
     Clears Android's repeated-passage mode when default Bible Speak starts outside its range.

     Android applies this policy only to page/default Speak before provider setup. Explicit bridge
     selections continue to use the provider's `limitToRange` behavior and start at the saved range.

     - Parameter candidateProvider: Newly built default Bible provider at the visible verse.
     - Returns: `true` when an incompatible or out-of-range setting was cleared and persisted.
     - Side effects: Updates structured settings and the active workspace without restarting an old
       provider or mutating a Speak bookmark.
     - Failure modes: Non-Bible providers and sessions without a repeated range are unchanged.
     */
    @discardableResult
    public func resetPassageRepeatIfOutsideRange(
        for candidateProvider: SpeakTextProviding
    ) -> Bool {
        guard let range = settings.playbackSettings.verseRange,
              let bibleProvider = candidateProvider as? BibleSpeakTextProvider,
              !bibleProvider.requestedStartIsInside(range) else {
            return false
        }
        var updated = settings
        updated.playbackSettings.verseRange = nil
        applySettings(
            updated,
            persist: true,
            notifyWorkspace: true,
            updateBookmark: false,
            restartPlayback: false
        )
        return true
    }

    private var effectiveSettings: SpeakSettings {
        guard provider?.isMemorizationLoop == true else { return settings }
        var value = settings
        value.playbackSettings.speakChapterChanges = false
        value.playbackSettings.speakTitles = false
        value.playbackSettings.speakFootnotes = false
        value.playbackSettings.isMemorizationLoop = true
        return value
    }

    private var avRate: Float {
        let mapped = AVSpeechUtteranceDefaultSpeechRate * Float(userSpeed)
        return min(max(mapped, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
    }

    private func legacyCallbackSnapshot() -> SpeakSessionCallbacks {
        let finished = onFinishedSpeaking
        let word = onWordSpoken
        let position = onPositionChanged
        let stopped = onSpeechStopped
        return SpeakSessionCallbacks(
            onFinished: finished,
            onWordSpoken: { spokenWord, range, _ in word?(spokenWord, range) },
            onPositionChanged: { value, _ in position?(value) },
            onStopped: { _ in stopped?() }
        )
    }

    private func applySettings(
        _ value: SpeakSettings,
        persist: Bool,
        notifyWorkspace: Bool,
        updateBookmark: Bool,
        restartPlayback: Bool
    ) {
        guard !applyingSettings else { return }
        applyingSettings = true
        let oldPlayback = settings.playbackSettings
        settings = value.normalized
        applyingSettings = false

        if persist { persistSettings(notifyWorkspace: notifyWorkspace) }
        let bookmarkUpdatePosition: SpeakStreamPosition?
        if isPaused {
            bookmarkUpdatePosition = provider?.currentPosition
        } else if !isSpeaking,
                  let visibleBiblePosition = onRequestStoppedBibleBookmarkPosition?(),
                  visibleBiblePosition.category == .bible {
            bookmarkUpdatePosition = visibleBiblePosition
        } else {
            bookmarkUpdatePosition = nil
        }
        if updateBookmark,
           oldPlayback != settings.playbackSettings,
           let position = bookmarkUpdatePosition {
            bookmarkManager?.updateSpeakBookmarkPlaybackSettings(
                at: position,
                settings: settings.playbackSettings
            )
            reloadResumeBookmarks()
        }
        if restartPlayback, oldPlayback != settings.playbackSettings, isSpeaking, !isPaused {
            checkpointAndRestartActiveSession()
        } else if oldPlayback != settings.playbackSettings,
                  let provider,
                  !provider.prepare(settings: effectiveSettings) {
            stopInternal(persistPosition: false, clearProvider: true, notifyStopped: true)
        }
    }

    private func persistSettings(notifyWorkspace: Bool) {
        if let json = try? settings.androidJSON() {
            settingsStore?.setString(Self.settingsKey, value: json)
        }
        settingsStore?.setDouble(Self.legacySpeedKey, value: userSpeed)
        if notifyWorkspace { onSettingsChanged?(settings) }
    }

    /** Decodes structured settings or performs the one-time legacy speed migration. */
    private func restoredStructuredSettings(
        from store: SettingsStore
    ) -> (settings: SpeakSettings, shouldPersistMigration: Bool) {
        if let json = store.getString(Self.settingsKey), !json.isEmpty {
            return (SpeakSettings.fromAndroidJSON(json), false)
        }
        var migrated = SpeakSettings()
        let legacySpeed = store.getDouble(Self.legacySpeedKey, default: 1.0)
        if (0.5...2.0).contains(legacySpeed) {
            migrated.playbackSettings.speed = Int((legacySpeed * 100).rounded())
        }
        return (migrated.normalized, true)
    }

    /** Loads provider units until one exact audible command starts or the bounded stream exhausts. */
    @discardableResult
    private func loadCurrentUnitAndSpeak() -> SpeakLoadResult {
        guard let provider else {
            finishProviderNaturally()
            return .exhausted
        }
        var visited = Set<String>()
        while let unit = provider.currentUnit(settings: effectiveSettings) {
            currentUnit = unit
            currentPosition = unit.position
            commandIndex = 0
            currentTitle = unit.position.keyName.isEmpty ? unit.position.bookName : unit.position.keyName
            currentSubtitle = unit.position.bookName.isEmpty ? unit.position.bookInitials : unit.position.bookName
            activeCallbacks?.onPositionChanged?(unit.position, currentSessionGeneration)
            #if os(iOS)
            updateNowPlayingInfo()
            #endif

            if unit.commands.contains(where: { $0.spokenText != nil }) {
                if let failure = applyPendingResumeCursor(to: unit) {
                    failStartup(failure)
                    return .failed(failure)
                }
                return startNextAudibleCommand()
            }
            guard visited.insert(unit.position.id).inserted,
                  provider.advance(settings: effectiveSettings) else {
                finishProviderNaturally()
                return .exhausted
            }
        }
        finishProviderNaturally()
        return .exhausted
    }

    /** Submits the next audible command while preserving pauses and optional exact resume progress. */
    @discardableResult
    private func startNextAudibleCommand() -> SpeakLoadResult {
        guard isSpeaking, !isPaused else { return .exhausted }
        guard let unit = currentUnit else {
            return loadCurrentUnitAndSpeak()
        }

        while commandIndex < unit.commands.count {
            let currentIndex = commandIndex
            let command = unit.commands[currentIndex]
            commandIndex += 1
            switch command {
            case .pause(let milliseconds):
                pendingPause += TimeInterval(max(milliseconds, 0)) / 1_000
            case .verseNumber, .excluded:
                continue
            case .text, .heading, .footnote, .announcement:
                guard let fullText = command.spokenText else { continue }
                let resumeOffset: Int
                if let resumeCursor = pendingResumePlaybackCursor {
                    guard resumeCursor.commandIndex == currentIndex else {
                        failStartup(.invalidResumeCursor)
                        return .failed(.invalidResumeCursor)
                    }
                    if provider?.checkpoint()?.version == 2 {
                        resumeOffset = resumeCursor.characterOffset
                    } else {
                        guard let legacyOffset = legacySentenceResumeOffset(
                            in: fullText,
                            beforeUTF16Offset: resumeCursor.characterOffset
                        ) else {
                            failStartup(.invalidResumeCursor)
                            return .failed(.invalidResumeCursor)
                        }
                        resumeOffset = legacyOffset
                    }
                } else {
                    resumeOffset = 0
                }
                guard let text = textSuffix(fullText, fromUTF16Offset: resumeOffset),
                      !text.isEmpty else {
                    failStartup(.invalidResumeCursor)
                    return .failed(.invalidResumeCursor)
                }
                guard let voice = voiceResolver.resolveVoice(
                    for: unit.position.language,
                    deviceLocale: deviceLocale
                ) else {
                    let failure = SpeakStartupFailure.unsupportedLanguage(unit.position.language)
                    failStartup(failure)
                    return .failed(failure)
                }
                lastFailure = nil
                lastStartupFailure = nil
                provider?.didStart(command: command)
                activeCommandIndex = currentIndex
                currentCommandText = fullText
                currentCommandBaseOffset = resumeOffset
                currentCommandCharacterOffset = resumeOffset
                pendingResumePlaybackCursor = nil
                currentText = text
                let utterance = AVSpeechUtterance(string: text)
                utterance.rate = avRate
                utterance.voice = voice
                utterance.preUtteranceDelay = pendingPause
                if case .heading = command {
                    utterance.postUtteranceDelay = 0.5
                }
                pendingPause = 0
                currentUtterance = utterance
                currentUtteranceGeneration = currentSessionGeneration
                synthesizer.speak(utterance)
                if acceptedFirstUtteranceGeneration != currentSessionGeneration {
                    acceptedFirstUtteranceGeneration = currentSessionGeneration
                }
                return .started
            }
        }

        guard provider?.advance(settings: effectiveSettings) == true else {
            finishProviderNaturally()
            return .exhausted
        }
        currentUnit = nil
        return loadCurrentUnitAndSpeak()
    }

    /** Validates a reconstructed version-2 cursor against freshly materialized command text. */
    private func applyPendingResumeCursor(to unit: SpeakStreamUnit) -> SpeakStartupFailure? {
        guard let cursor = pendingResumePlaybackCursor else { return nil }
        guard unit.commands.indices.contains(cursor.commandIndex),
              let text = unit.commands[cursor.commandIndex].spokenText,
              text.utf16.count == cursor.commandTextLength,
              cursor.characterOffset >= 0,
              cursor.characterOffset < cursor.commandTextLength,
              cursor.characterFraction.isFinite,
              abs(
                  cursor.characterFraction
                      - Double(cursor.characterOffset) / Double(cursor.commandTextLength)
              ) < 0.000_001,
              textSuffix(text, fromUTF16Offset: cursor.characterOffset) != nil else {
            return .invalidResumeCursor
        }
        commandIndex = cursor.commandIndex
        return nil
    }

    /** Converts one validated UTF-16 speech-engine offset to a Swift string suffix. */
    private func textSuffix(_ text: String, fromUTF16Offset offset: Int) -> String? {
        guard offset >= 0, offset < text.utf16.count else { return nil }
        let utf16Index = text.utf16.index(text.utf16.startIndex, offsetBy: offset)
        guard let stringIndex = String.Index(utf16Index, within: text) else { return nil }
        return String(text[stringIndex...])
    }

    /**
     Finds Android legacy playback's previous sentence boundary for a persisted progress offset.

     Android stores the exact fraction reported by its speech engine, then calls
     `BreakIterator.preceding` before replaying the current chunk. Keeping the raw offset in the
     checkpoint preserves exact progress across process death while this conversion intentionally
     repeats the containing sentence when synthesis resumes.

     - Parameters:
       - text: Full command text used to create the persisted cursor.
       - offset: Exact UTF-16 speech-engine progress offset in `text`.
     - Returns: The greatest sentence-start offset strictly before `offset`, or zero when progress
       remains in the first sentence or has not started.
     - Side effects: Enumerates localized Foundation sentence boundaries without mutating playback.
     - Failure modes: Returns `nil` for an offset outside the full command or a boundary that cannot
       be represented in UTF-16.
     */
    private func legacySentenceResumeOffset(
        in text: String,
        beforeUTF16Offset offset: Int
    ) -> Int? {
        guard !text.isEmpty,
              offset >= 0,
              offset < text.utf16.count else {
            return nil
        }
        guard offset > 0 else { return 0 }

        var previousBoundary = 0
        var conversionFailed = false
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.bySentences, .substringNotRequired]
        ) { _, sentenceRange, _, stop in
            guard let utf16Start = sentenceRange.lowerBound.samePosition(in: text.utf16) else {
                conversionFailed = true
                stop = true
                return
            }
            let boundary = text.utf16.distance(
                from: text.utf16.startIndex,
                to: utf16Start
            )
            guard boundary < offset else {
                stop = true
                return
            }
            previousBoundary = boundary
        }
        return conversionFailed ? nil : previousBoundary
    }

    /**
     Stops the active provider before synthesis and exposes a stable failure through observed status.

     - Parameter failure: Typed reason synthesis cannot begin.
     - Side effects: Stops and clears the provider, removes system media metadata, updates
       `lastFailure`, and replaces the in-app speech status title with the error description.
     - Failure modes: Missing localized descriptions fall back to a generic speech failure label.
     */
    private func failStartup(_ failure: SpeakStartupFailure) {
        logger.error("Speech stopped before synthesis: \(failure.localizedDescription, privacy: .public)")
        stopInternal(persistPosition: false, clearProvider: true, notifyStopped: true)
        publishStartupFailure(failure)
    }

    /**
     Publishes a synchronous startup failure after any required session teardown completes.

     - Parameter failure: Typed preparation, content, cursor, or voice failure to expose.
     - Side effects: Updates observable failure state and replaces stale speech metadata with the
       localized failure description.
     - Failure modes: Missing localized descriptions use a stable generic speech fallback.
     */
    private func publishStartupFailure(_ failure: SpeakStartupFailure) {
        if case .unsupportedLanguage(let language) = failure {
            lastFailure = .unsupportedLanguage(language)
        } else {
            lastFailure = nil
        }
        lastStartupFailure = failure
        currentTitle = failure.errorDescription ?? "Speech is unavailable."
        currentSubtitle = nil
    }

    private func moveProvider(_ movement: (SpeakTextProviding) -> Bool) {
        guard let provider, isSpeaking else { return }
        guard provider.prepare(settings: effectiveSettings) else {
            stopInternal(persistPosition: false, clearProvider: true, notifyStopped: true)
            return
        }
        let wasPaused = isPaused
        cancelCurrentUtteranceForReplacement()
        pendingResumePlaybackCursor = nil
        _ = movement(provider)
        currentUnit = nil
        commandIndex = 0
        pendingPause = 0
        if wasPaused {
            isPaused = true
            if let unit = provider.currentUnit(settings: effectiveSettings) {
                currentUnit = unit
                currentPosition = unit.position
                currentTitle = unit.position.keyName
                currentSubtitle = unit.position.bookName
                activeCallbacks?.onPositionChanged?(unit.position, currentSessionGeneration)
                persistPausedCheckpoint()
            }
        } else {
            isPaused = false
            _ = loadCurrentUnitAndSpeak()
        }
    }

    private func checkpointAndRestartActiveSession() {
        guard isSpeaking, !isPaused, let provider else { return }
        let checkpoint = currentProviderCheckpoint()
        pendingResumePlaybackCursor = checkpoint?.playbackCursor
        cancelCurrentUtteranceForReplacement()
        currentUnit = nil
        commandIndex = 0
        pendingPause = 0
        guard provider.prepare(settings: effectiveSettings) else {
            stopInternal(persistPosition: false, clearProvider: true, notifyStopped: true)
            return
        }
        persistPausedCheckpoint(checkpoint)
        persistCurrentPosition()
        bookmarkPersistedForPausedTransition = true
        clearPersistedPauseCheckpoint()
        bookmarkPersistedForPausedTransition = false
        _ = loadCurrentUnitAndSpeak()
    }

    private func cancelCurrentUtteranceForReplacement() {
        if let currentUtterance {
            ignoredCancelledUtterances.insert(ObjectIdentifier(currentUtterance))
        }
        _ = synthesizer.stopSpeaking(at: .immediate)
        currentUtterance = nil
        currentUtteranceGeneration = nil
        activeCommandIndex = nil
        currentCommandText = ""
        currentCommandBaseOffset = 0
        currentCommandCharacterOffset = 0
    }

    private func stopInternal(
        persistPosition: Bool,
        clearProvider: Bool,
        notifyStopped: Bool
    ) {
        let hadSession = isSpeaking || isPaused || provider != nil
        let stoppedGeneration = currentSessionGeneration
        if hadSession { persistLastCheckpoint() }
        if persistPosition, hadSession, !bookmarkPersistedForPausedTransition {
            persistCurrentPosition()
        }
        userStopped = true
        cancelCurrentUtteranceForReplacement()
        cancelSleepTimer(clearRemaining: true)
        isSpeaking = false
        isPaused = false
        isMemorizationLoop = false
        currentUnit = nil
        commandIndex = 0
        pendingPause = 0
        currentText = ""
        currentCommandText = ""
        activeCommandIndex = nil
        currentCommandBaseOffset = 0
        currentCommandCharacterOffset = 0
        pendingResumePlaybackCursor = nil
        acceptedFirstUtteranceGeneration = nil
        currentPosition = nil
        if clearProvider { provider = nil }
        clearPersistedPauseCheckpoint()
        if notifyStopped, hadSession { activeCallbacks?.onStopped?(stoppedGeneration) }
        activeCallbacks = nil
        bookmarkPersistedForPausedTransition = false
        if hadSession { currentSessionGeneration &+= 1 }
        #if os(iOS)
        clearNowPlayingInfo()
        #endif
    }

    private func finishProviderNaturally() {
        let shouldNotifyFinished = isSpeaking && !userStopped
        let finished = activeCallbacks?.onFinished
        stopInternal(persistPosition: true, clearProvider: true, notifyStopped: true)
        if shouldNotifyFinished { finished?() }
    }

    private func persistCurrentPosition() {
        guard let provider,
              provider.canAutoBookmark,
              !provider.isMemorizationLoop,
              let position = provider.currentPosition else { return }
        lastPersistedPosition = position
        bookmarkManager?.persistSpeakBookmark(
            at: position,
            settings: effectiveSettings.playbackSettings,
            autoBookmark: advancedSettings.autoBookmark
        )
        reloadResumeBookmarks()
    }

    private func persistPausedCheckpoint(_ suppliedCheckpoint: SpeakProviderCheckpoint? = nil) {
        guard let checkpoint = suppliedCheckpoint ?? currentProviderCheckpoint() else { return }
        pendingPersistedPauseCheckpoint = checkpoint
        persist(checkpoint, forKey: Self.pausedCheckpointKey)
        persist(checkpoint, forKey: Self.lastCheckpointKey)
        persistAndroidProviderState(checkpoint)
        persistAndroidLastPosition(checkpoint.current)
    }

    private func persistLastCheckpoint() {
        guard let checkpoint = currentProviderCheckpoint() else { return }
        persist(checkpoint, forKey: Self.lastCheckpointKey)
        persistAndroidLastPosition(checkpoint.current)
    }

    /** Attaches the active utterance cursor to semantic version-2 provider state. */
    private func currentProviderCheckpoint() -> SpeakProviderCheckpoint? {
        guard let checkpoint = provider?.checkpoint() else { return nil }
        guard checkpoint.version == 2 else { return checkpoint }
        if let activeCommandIndex, !currentCommandText.isEmpty {
            let textLength = currentCommandText.utf16.count
            guard textLength > 0,
                  currentCommandCharacterOffset >= 0,
                  currentCommandCharacterOffset < textLength else {
                return checkpoint.withPlaybackCursor(nil)
            }
            let cursor = SpeakPlaybackCursor(
                commandIndex: activeCommandIndex,
                characterOffset: currentCommandCharacterOffset,
                commandTextLength: textLength,
                characterFraction: Double(currentCommandCharacterOffset) / Double(textLength)
            )
            return checkpoint.withPlaybackCursor(cursor)
        }
        if let unit = currentUnit,
           let nextCommandIndex = unit.commands.indices.first(where: {
               $0 >= commandIndex && unit.commands[$0].spokenText != nil
           }),
           let text = unit.commands[nextCommandIndex].spokenText,
           !text.isEmpty {
            return checkpoint.withPlaybackCursor(
                SpeakPlaybackCursor(
                    commandIndex: nextCommandIndex,
                    characterOffset: 0,
                    commandTextLength: text.utf16.count,
                    characterFraction: 0
                )
            )
        }
        return checkpoint.withPlaybackCursor(pendingResumePlaybackCursor)
    }

    private func persist(_ checkpoint: SpeakProviderCheckpoint, forKey key: String) {
        guard let data = try? JSONEncoder().encode(checkpoint),
              let json = String(data: data, encoding: .utf8) else { return }
        settingsStore?.setString(key, value: json)
    }

    private func persistedCheckpoint(forKey key: String) -> SpeakProviderCheckpoint? {
        guard let json = settingsStore?.getString(key),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SpeakProviderCheckpoint.self, from: data)
    }

    private func persistAndroidProviderState(_ checkpoint: SpeakProviderCheckpoint) {
        guard let store = settingsStore else { return }
        let cursor = checkpoint.current
        store.setString(Self.persistLocaleKey, value: currentPosition?.language ?? Locale.current.identifier)
        let isBible = cursor.category == .bible || cursor.category == .memorization
        store.setBool(Self.persistBibleProviderKey, value: isBible)
        if isBible {
            store.setString(Self.persistBibleBookKey, value: cursor.bookInitials)
            store.setString(Self.persistBibleVerseKey, value: currentPosition?.osisRef ?? cursor.key)
            store.remove(Self.persistGeneralBookKey)
            store.remove(Self.persistGeneralKey)
        } else {
            store.setString(Self.persistGeneralBookKey, value: cursor.bookInitials)
            if let json = androidGeneralCursorJSON(cursor) {
                store.setString(Self.persistGeneralKey, value: json)
            }
            store.remove(Self.persistBibleBookKey)
            store.remove(Self.persistBibleVerseKey)
        }
    }

    private func persistAndroidLastPosition(_ cursor: SpeakStreamCursor) {
        guard let store = settingsStore else { return }
        store.setString("lastSpeakBook", value: cursor.bookInitials)
        if cursor.category == .bible || cursor.category == .memorization {
            let reference = currentPosition?.osisRef ?? cursor.key
            store.setString("lastSpeakRef", value: reference)
        } else if let json = androidGeneralCursorJSON(cursor) {
            store.setString("lastSpeakRef", value: json)
        }
    }

    private func androidGeneralCursorJSON(_ cursor: SpeakStreamCursor) -> String? {
        let payload = AndroidGeneralSpeakCursor(
            key: cursor.key,
            document: cursor.bookInitials,
            ordinalRange: cursor.ordinalStart.map {
                AndroidSpeakOrdinalRange(start: $0, end: nil)
            },
            htmlId: nil
        )
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func clearPersistedPauseCheckpoint() {
        pendingPersistedPauseCheckpoint = nil
        guard let store = settingsStore else { return }
        store.remove(Self.pausedCheckpointKey)
        store.remove(Self.persistLocaleKey)
        store.remove(Self.persistBibleBookKey)
        store.remove(Self.persistBibleVerseKey)
        store.remove(Self.persistGeneralBookKey)
        store.remove(Self.persistGeneralKey)
    }

    private func importedAndroidPauseCheckpoint() -> SpeakProviderCheckpoint? {
        guard let store = settingsStore else { return nil }
        if store.getBool(Self.persistBibleProviderKey, default: true),
           let book = store.getString(Self.persistBibleBookKey),
           !book.isEmpty,
           let verse = store.getString(Self.persistBibleVerseKey),
           !verse.isEmpty {
            let cursor = SpeakStreamCursor(
                category: .bible,
                bookInitials: book,
                key: verse,
                ordinalStart: nil,
                ordinalEnd: nil,
                versification: nil
            )
            return SpeakProviderCheckpoint(
                version: 0,
                current: cursor,
                lowerBound: cursor,
                upperBound: cursor,
                isBounded: false,
                isMemorizationLoop: false
            )
        }
        guard let book = store.getString(Self.persistGeneralBookKey),
              !book.isEmpty,
              let json = store.getString(Self.persistGeneralKey),
              let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(AndroidGeneralSpeakCursor.self, from: data) else {
            return nil
        }
        let cursor = SpeakStreamCursor(
            category: .generalBook,
            bookInitials: payload.document.isEmpty ? book : payload.document,
            key: payload.key,
            ordinalStart: payload.ordinalRange?.start,
            ordinalEnd: payload.ordinalRange?.end ?? payload.ordinalRange?.start,
            versification: nil
        )
        return SpeakProviderCheckpoint(
            version: 0,
            current: cursor,
            lowerBound: cursor,
            upperBound: cursor,
            isBounded: false,
            isMemorizationLoop: false
        )
    }

    private func reconstructPersistedPauseIfPossible() {
        guard provider == nil,
              !isSpeaking,
              !isPaused,
              let checkpoint = pendingPersistedPauseCheckpoint,
              let reconstruction = requestedReconstruction(for: checkpoint),
              checkpoint.version != 2 || reconstruction.provider.resumePlaybackCursor != nil,
              reconstruction.provider.prepare(settings: settings) else {
            return
        }
        currentSessionGeneration &+= 1
        activeCallbacks = reconstruction.callbacks ?? legacyCallbackSnapshot()
        provider = reconstruction.provider
        if let indexed = reconstruction.provider as? IndexedSpeakTextProvider {
            indexed.advancedSettings = advancedSettings
        }
        isMemorizationLoop = reconstruction.provider.isMemorizationLoop
        isSpeaking = true
        isPaused = true
        userStopped = false
        bookmarkPersistedForPausedTransition = true
        pendingResumePlaybackCursor = reconstruction.provider.resumePlaybackCursor
        commandIndex = 0
        pendingPause = 0
        currentUnit = reconstruction.provider.currentUnit(settings: effectiveSettings)
        currentPosition = reconstruction.provider.currentPosition
        currentTitle = reconstruction.title ?? reconstruction.provider.currentPosition?.keyName
        currentSubtitle = reconstruction.subtitle ?? reconstruction.provider.currentPosition?.bookName
    }

    /** Uses the richer reader reconstruction contract, then falls back to the provider-only API. */
    private func requestedReconstruction(
        for checkpoint: SpeakProviderCheckpoint
    ) -> SpeakSessionReconstruction? {
        if let reconstruction = onRequestSessionReconstruction?(checkpoint) {
            return reconstruction
        }
        guard let provider = onRequestProviderReconstruction?(checkpoint) else { return nil }
        return SpeakSessionReconstruction(provider: provider)
    }

    private func activateConfiguredSleepTimer() {
        cancelSleepTimer(clearRemaining: true)
        let minutes = settings.sleepTimer
        guard minutes > 0 else { return }
        sleepTimerRemaining = TimeInterval(minutes * 60)
        let generation = sleepTimerGeneration
        sleepTimerToken = timerScheduler.scheduleRepeating(every: 1) { [weak self] in
            self?.tickSleepTimer(generation: generation)
        }
    }

    /** Advances only the currently scheduled timer, rejecting callbacks queued before cancellation. */
    private func tickSleepTimer(generation: UInt64) {
        guard generation == sleepTimerGeneration else { return }
        guard let remaining = sleepTimerRemaining else { return }
        let next = max(remaining - 1, 0)
        sleepTimerRemaining = next
        guard next <= 0 else { return }

        // Android pauses first, then clears only sleepTimer while preserving lastSleepTimer.
        pause()
        var updated = settings
        updated.sleepTimer = 0
        applySettings(
            updated,
            persist: true,
            notifyWorkspace: true,
            updateBookmark: false,
            restartPlayback: false
        )
        cancelSleepTimer(clearRemaining: true)
    }

    private func cancelSleepTimer(clearRemaining: Bool) {
        sleepTimerGeneration &+= 1
        sleepTimerToken?.invalidate()
        sleepTimerToken = nil
        if clearRemaining { sleepTimerRemaining = nil }
    }

    private func configureAudioSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    #if os(iOS)
    private func updateNowPlayingInfo() {
        guard let presentation = systemPresentationPolicy.nowPlayingPresentation(
            title: currentTitle,
            subtitle: currentSubtitle,
            playbackRate: isPaused ? 0.0 : userSpeed
        ) else {
            clearNowPlayingInfo()
            return
        }
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = presentation.title
        info[MPMediaItemPropertyArtist] = presentation.artist
        info[MPNowPlayingInfoPropertyPlaybackRate] = presentation.playbackRate
        info[MPMediaItemPropertyPlaybackDuration] = 0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func setRemoteCommandHandlingEnabled(_ enabled: Bool) {
        let effectiveValue = enabled && systemPresentationPolicy.exposesMediaSession
        if !effectiveValue {
            remoteCommandHandlingEnabled = false
            tearDownRemoteCommandCenter()
            if !systemPresentationPolicy.exposesMediaSession {
                clearNowPlayingInfo()
            }
            return
        }
        guard !remoteCommandHandlingEnabled else { return }
        remoteCommandHandlingEnabled = true
        setupRemoteCommandCenter()
    }

    private func setupRemoteCommandCenter() {
        guard systemPresentationPolicy.exposesMediaSession,
              !remoteCommandsRegistered else { return }
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.stopCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true

        center.playCommand.addTarget { [weak self] _ in
            self?.enqueueRemoteCommand(.play)
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.enqueueRemoteCommand(.pause)
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.enqueueRemoteCommand(.togglePlayPause)
            return .success
        }
        center.stopCommand.addTarget { [weak self] _ in
            self?.enqueueRemoteCommand(.stop)
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.enqueueRemoteCommand(.nextTrack)
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.enqueueRemoteCommand(.previousTrack)
            return .success
        }
        remoteCommandsRegistered = true
    }

    /** Captures media-event ownership before dispatching the command onto the service queue. */
    private func enqueueRemoteCommand(_ command: SpeakRemoteCommand) {
        let generation = currentSessionGeneration
        DispatchQueue.main.async { [weak self] in
            _ = self?.performRemoteCommand(
                command,
                expectedSessionGeneration: generation
            )
        }
    }

    private func tearDownRemoteCommandCenter() {
        guard remoteCommandsRegistered else { return }
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.stopCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        center.playCommand.isEnabled = false
        center.pauseCommand.isEnabled = false
        center.togglePlayPauseCommand.isEnabled = false
        center.stopCommand.isEnabled = false
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
        remoteCommandsRegistered = false
    }

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

    /** Re-resolves system speech exposure after an AppStorage-backed preference changes. */
    @objc private func handleRuntimePreferencesChanged(_ notification: Notification) {
        guard observesRuntimeDiscreteMode else { return }
        let applyPolicy: () -> Void = { [weak self] in
            self?.applySystemPresentationPolicy(.current)
        }
        if Thread.isMainThread {
            applyPolicy()
        } else {
            DispatchQueue.main.async(execute: applyPolicy)
        }
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        let generation = currentSessionGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentSessionGeneration == generation else { return }
            switch type {
            case .began:
                if self.isSpeaking && !self.isPaused {
                    self.wasInterrupted = true
                    self.pause()
                }
            case .ended:
                let raw = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                if AVAudioSession.InterruptionOptions(rawValue: raw).contains(.shouldResume),
                   self.wasInterrupted {
                    self.resume()
                }
                self.wasInterrupted = false
            @unknown default:
                break
            }
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
        let generation = currentSessionGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentSessionGeneration == generation else { return }
            if self.isSpeaking, !self.isPaused { self.pause() }
        }
    }
    #endif

    /** Forwards AVFoundation word progress for the current provider command. */
    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        guard currentUtterance === utterance,
              currentUtteranceGeneration == currentSessionGeneration,
              let range = Range(characterRange, in: currentText) else { return }
        currentCommandCharacterOffset = min(
            currentCommandBaseOffset + characterRange.location,
            max(currentCommandText.utf16.count - 1, 0)
        )
        activeCallbacks?.onWordSpoken?(
            String(currentText[range]),
            characterRange,
            currentSessionGeneration
        )
    }

    /** Advances the provider command stream after one utterance finishes. */
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard currentUtterance === utterance,
              currentUtteranceGeneration == currentSessionGeneration else { return }
        currentUtterance = nil
        currentUtteranceGeneration = nil
        activeCommandIndex = nil
        currentCommandText = ""
        currentCommandBaseOffset = 0
        currentCommandCharacterOffset = 0
        guard !userStopped else { return }
        _ = startNextAudibleCommand()
    }

    /** Ignores replacement cancellations and stops only for unexpected platform cancellation. */
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let identity = ObjectIdentifier(utterance)
        if ignoredCancelledUtterances.remove(identity) != nil { return }
        guard currentUtterance === utterance else { return }
        currentUtterance = nil
        currentUtteranceGeneration = nil
        stopInternal(persistPosition: true, clearProvider: true, notifyStopped: true)
    }
}
