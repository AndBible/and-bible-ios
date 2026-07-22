// SpeakSettings.swift -- Android-compatible speech settings contracts

import Foundation
import SwordKit

/**
 A serialized Android verse range used by speech repetition and bookmark resume.

 Android's `VerseRangeSerializer` stores a range as one JSON string in the form
 `versification::osisRef`. Keeping that exact wire representation prevents workspace and bookmark
 payloads from acquiring an iOS-only nested-object shape.
 */
public struct SpeakVerseRange: Codable, Sendable, Equatable, Hashable, CustomStringConvertible {
    private enum CodingKeys: String, CodingKey {
        case versification
        case osisRef
    }

    /// JSword/SWORD versification name owning the OSIS range.
    public let versification: String

    /// OSIS range, for example `Gen.1.1-Gen.1.5`.
    public let osisRef: String

    /// Exact Android wire representation.
    public var description: String { "\(versification)::\(osisRef)" }

    /**
     Creates a validated speech verse range.

     - Parameters:
       - versification: Non-empty JSword/SWORD versification name.
       - osisRef: Non-empty OSIS reference or range.
     - Side effects: none.
     - Failure modes: Returns `nil` when either component is empty after trimming.
     */
    public init?(versification: String, osisRef: String) {
        let normalizedVersification = versification.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedOSISRef = osisRef.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedVersification.isEmpty, !normalizedOSISRef.isEmpty else { return nil }
        self.versification = normalizedVersification
        self.osisRef = normalizedOSISRef
    }

    /**
     Parses Android's `VerseRangeSerializer` string without throwing.

     - Parameter androidString: Wire value in `versification::osisRef` form.
     - Returns: A validated range, or `nil` for a missing separator or empty component.
     - Side effects: none.
     - Failure modes: Malformed input returns `nil` so historical optional range fields can default
       without escaping a decoding error into SwiftData's transform decoder.
     */
    public init?(androidString: String) {
        guard let separator = androidString.range(of: "::") else { return nil }
        self.init(
            versification: String(androidString[..<separator.lowerBound]),
            osisRef: String(androidString[separator.upperBound...])
        )
    }

    /**
     Resolves both OSIS endpoints against the range's declared versification.

     Android's `VerseRangeSerializer` delegates parsing to JSword's owning `Versification`; this
     method applies the same ownership rule through SWORD's canon registry. It never treats a
     coordinate from one versification as though it belonged to another.

     - Returns: Validated inclusive start and end references, or `nil` when the OSIS shape, canon,
       endpoint ordering, or coordinates are invalid.
     - Side effects: Reads SWORD's compiled versification registry on its shared serialization queue.
     - Failure modes: Unknown versifications, non-verse references, reversed ranges, and malformed
       OSIS return `nil` without clamping or identity fallback.
     */
    public func validatedReferences() -> (
        start: SwordVersification.Reference,
        end: SwordVersification.Reference
    )? {
        let components = osisRef.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let start = components.first.flatMap({ Self.reference(fromOSIS: String($0)) }) else {
            return nil
        }
        let end = components.count == 2
            ? Self.reference(fromOSIS: String(components[1]))
            : start
        guard let end,
              let startIndex = SwordVersification.referenceIndex(
                  for: start,
                  versification: versification
              ),
              let endIndex = SwordVersification.referenceIndex(
                  for: end,
                  versification: versification
              ),
              startIndex <= endIndex else {
            return nil
        }
        return (start, end)
    }

    /** Parses one exact three-component OSIS verse without accepting partial or display references. */
    private static func reference(fromOSIS value: String) -> SwordVersification.Reference? {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              !components[0].isEmpty,
              let chapter = Int(components[1]),
              let verse = Int(components[2]),
              chapter > 0,
              verse >= 0 else {
            return nil
        }
        return SwordVersification.Reference(
            osisBookId: String(components[0]),
            chapter: chapter,
            verse: verse
        )
    }

    /**
     Decodes Android's string payload and SwiftData's historical keyed transform representation.

     SwiftData may materialize nested Codable values as dictionaries even when their wire encoder is
     single-valued. Trying the keyed shape first avoids its Objective-C force-cast trap while keeping
     Android JSON string-compatible.
     */
    public init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            guard let versification = try? container.decode(String.self, forKey: .versification),
                  let osisRef = try? container.decode(String.self, forKey: .osisRef),
                  let range = SpeakVerseRange(versification: versification, osisRef: osisRef) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Invalid keyed verse range")
                )
            }
            self = range
            return
        }
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let range = SpeakVerseRange(androidString: value) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Expected versification::osisRef")
            )
        }
        self = range
    }

    /** Encodes Android's single-string `VerseRangeSerializer` payload. */
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/**
 Complete Android `SpeakSettings` state.

 All fields are encoded, including values equal to Android defaults. This mirrors Android's
 `Json { encodeDefaults = true }` workspace and bookmark payloads. Decoding preserves sparse valid
 historical payloads, while any malformed known field applies Android's whole-object default.
 */
public struct SpeakSettings: Codable, Sendable, Equatable {
    /// Playback behavior and bookmark metadata.
    public var playbackSettings: PlaybackSettings

    /// Configured sleep duration in minutes; zero disables the timer.
    public var sleepTimer: Int

    /// Last positive duration selected in Android's timer picker.
    public var lastSleepTimer: Int

    /// Android general-book queue preference. The current Android provider preserves this field.
    public var queue: Bool

    /// Android general-book repeat preference. The current Android provider preserves this field.
    public var repeatPlayback: Bool

    /// Android resource identifier for the general-book page-count choice.
    public var numPagesToSpeakId: Int

    /// Decoder-only signal retained for containers that need Android's nested whole-object fallback.
    private(set) var decodedMalformedKnownField = false

    private enum CodingKeys: String, CodingKey {
        case playbackSettings
        case sleepTimer
        case lastSleepTimer
        case queue
        case repeatPlayback
        case numPagesToSpeakId
    }

    /** Android wire alias retained separately from SwiftData's composite-property name. */
    private enum AndroidCodingKeys: String, CodingKey {
        case repeatPlayback = "repeat"
    }

    /**
     Creates complete speech settings using Android defaults.

     - Parameters:
       - playbackSettings: Structured playback behavior.
       - sleepTimer: Configured sleep duration in minutes.
       - lastSleepTimer: Last positive timer-picker value.
       - queue: General-book queue preference.
       - repeatPlayback: General-book repeat preference.
       - numPagesToSpeakId: General-book page-count resource identifier.
     - Side effects: none.
     - Failure modes: Construction cannot fail.
     */
    public init(
        playbackSettings: PlaybackSettings = PlaybackSettings(),
        sleepTimer: Int = 0,
        lastSleepTimer: Int = 10,
        queue: Bool = true,
        repeatPlayback: Bool = false,
        numPagesToSpeakId: Int = 0
    ) {
        self.playbackSettings = playbackSettings
        self.sleepTimer = sleepTimer
        self.lastSleepTimer = lastSleepTimer
        self.queue = queue
        self.repeatPlayback = repeatPlayback
        self.numPagesToSpeakId = numPagesToSpeakId
        decodedMalformedKnownField = false
        self = normalized
    }

    /**
     Decodes sparse historical payloads and malformed Android payloads without throwing.

     Missing fields use Kotlin serializer defaults. Any present known field with an invalid type,
     including malformed nested playback settings, defaults the whole object exactly like Android's
     `SpeakSettings.fromJson`. The initializer remains nonthrowing for SwiftData safety.
     */
    public init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            self.init()
            decodedMalformedKnownField = true
            return
        }

        var malformed = false
        func required<Value: Decodable>(
            _ type: Value.Type,
            forKey key: CodingKeys,
            default defaultValue: Value
        ) -> Value {
            guard container.contains(key) else { return defaultValue }
            do {
                return try container.decode(type, forKey: key)
            } catch {
                malformed = true
                return defaultValue
            }
        }

        let playbackSettings = required(
            PlaybackSettings.self,
            forKey: .playbackSettings,
            default: PlaybackSettings()
        )
        if playbackSettings.decodedMalformedKnownField { malformed = true }
        let sleepTimer = required(Int.self, forKey: .sleepTimer, default: 0)
        let lastSleepTimer = required(Int.self, forKey: .lastSleepTimer, default: 10)
        let queue = required(Bool.self, forKey: .queue, default: true)
        let androidContainer = try? decoder.container(keyedBy: AndroidCodingKeys.self)
        let repeatPlayback: Bool
        if androidContainer?.contains(.repeatPlayback) == true {
            do {
                repeatPlayback = try androidContainer?.decode(Bool.self, forKey: .repeatPlayback)
                    ?? false
            } catch {
                malformed = true
                repeatPlayback = false
            }
        } else {
            repeatPlayback = required(Bool.self, forKey: .repeatPlayback, default: false)
        }
        let numPagesToSpeakId = required(Int.self, forKey: .numPagesToSpeakId, default: 0)

        guard !malformed else {
            self.init()
            decodedMalformedKnownField = true
            return
        }
        self.init(
            playbackSettings: playbackSettings,
            sleepTimer: sleepTimer,
            lastSleepTimer: lastSleepTimer,
            queue: queue,
            repeatPlayback: repeatPlayback,
            numPagesToSpeakId: numPagesToSpeakId
        )
    }

    /** Encodes every Android field, including defaults. */
    public func encode(to encoder: Encoder) throws {
        let value = normalized
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value.playbackSettings, forKey: .playbackSettings)
        try container.encode(value.sleepTimer, forKey: .sleepTimer)
        try container.encode(value.lastSleepTimer, forKey: .lastSleepTimer)
        try container.encode(value.queue, forKey: .queue)
        try container.encode(value.repeatPlayback, forKey: .repeatPlayback)
        try container.encode(value.numPagesToSpeakId, forKey: .numPagesToSpeakId)
    }

    /**
     Structured value retained exactly as Android serialized it.

     Runtime consumers interpret non-positive timer values as disabled and constrain speech rate
     only when adapting it to a platform synthesizer. Keeping the wire value unchanged is required
     for lossless Android backup and remote-sync round trips.
     */
    public var normalized: SpeakSettings {
        self
    }

    /** Compares Android speech behavior while ignoring decoder-only bookkeeping. */
    public static func == (lhs: SpeakSettings, rhs: SpeakSettings) -> Bool {
        lhs.playbackSettings == rhs.playbackSettings
            && lhs.sleepTimer == rhs.sleepTimer
            && lhs.lastSleepTimer == rhs.lastSleepTimer
            && lhs.queue == rhs.queue
            && lhs.repeatPlayback == rhs.repeatPlayback
            && lhs.numPagesToSpeakId == rhs.numPagesToSpeakId
    }

    /**
     Decodes Android-compatible speech JSON with Kotlin-compatible fallback semantics.

     - Parameter json: Raw `SpeakSettings` JSON.
     - Returns: Decoded sparse valid settings, or complete defaults when any known field or the root
       JSON is malformed.
     - Side effects: none.
     - Failure modes: Malformed known fields, malformed JSON, or a non-object root become complete
       defaults.
     */
    public static func fromAndroidJSON(_ json: String) -> SpeakSettings {
        guard let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(SpeakSettings.self, from: data) else {
            return SpeakSettings()
        }
        return value.normalized
    }

    /**
     Encodes the exact structured Android payload.

     - Returns: UTF-8 JSON containing every Android field.
     - Side effects: none.
     - Failure modes: Rethrows JSON encoding failures.
     */
    public func androidJSON() throws -> String {
        let value = normalized
        let object: [String: Any] = [
            CodingKeys.playbackSettings.rawValue: value.playbackSettings.androidJSONObject,
            CodingKeys.sleepTimer.rawValue: value.sleepTimer,
            CodingKeys.lastSleepTimer.rawValue: value.lastSleepTimer,
            CodingKeys.queue.rawValue: value.queue,
            AndroidCodingKeys.repeatPlayback.rawValue: value.repeatPlayback,
            CodingKeys.numPagesToSpeakId.rawValue: value.numPagesToSpeakId,
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let value = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: [], debugDescription: "SpeakSettings JSON was not UTF-8")
            )
        }
        return value
    }

}

/**
 Android's global advanced speech preferences.

 These values are global rather than workspace-scoped on Android. Persistence uses Android's exact
 preference keys so database/settings restore and native playback share one contract.
 */
public struct AdvancedSpeakSettings: Codable, Sendable, Equatable {
    /// Creates or moves the internal Speak bookmark when playback pauses or stops.
    public var autoBookmark: Bool

    /// Keeps the visible reader synchronized to provider progress.
    public var synchronize: Bool

    /// Applies locale-specific divine-name substitutions while parsing OSIS.
    public var replaceDivineName: Bool

    /// Applies playback settings stored on a resumed Speak bookmark.
    public var restoreSettingsFromBookmarks: Bool

    /** Creates advanced settings using Android defaults. */
    public init(
        autoBookmark: Bool = false,
        synchronize: Bool = true,
        replaceDivineName: Bool = false,
        restoreSettingsFromBookmarks: Bool = false
    ) {
        self.autoBookmark = autoBookmark
        self.synchronize = synchronize
        self.replaceDivineName = replaceDivineName
        self.restoreSettingsFromBookmarks = restoreSettingsFromBookmarks
    }

    /** Loads all advanced settings from Android-compatible keys. */
    public static func load(from store: SettingsStore) -> AdvancedSpeakSettings {
        AdvancedSpeakSettings(
            autoBookmark: store.getBool("speak_autoBookmark", default: false),
            synchronize: store.getBool("speak_synchronize", default: true),
            replaceDivineName: store.getBool("speak_replaceDivineName", default: false),
            restoreSettingsFromBookmarks: store.getBool(
                "speak_restoreSettingsFromBookmarks",
                default: false
            )
        )
    }

    /** Persists all advanced settings under Android-compatible keys. */
    public func save(to store: SettingsStore) {
        store.setBool("speak_autoBookmark", value: autoBookmark)
        store.setBool("speak_synchronize", value: synchronize)
        store.setBool("speak_replaceDivineName", value: replaceDivineName)
        store.setBool("speak_restoreSettingsFromBookmarks", value: restoreSettingsFromBookmarks)
    }
}
