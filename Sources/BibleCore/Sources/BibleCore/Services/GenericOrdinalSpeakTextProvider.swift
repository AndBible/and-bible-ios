// GenericOrdinalSpeakTextProvider.swift -- Lazy Android BookAndKey speech traversal

import Foundation

/** One lazily loaded generic key and its exact Android BVA ordinal commands. */
public struct GenericSpeakKeyContent: Sendable, Equatable {
    /// Exact persisted key.
    public let key: String
    /// User-visible key name.
    public let keyName: String
    /// Inclusive local BVA ordinal range.
    public let ordinalRange: ClosedRange<Int>
    /// Commands keyed by exact local BVA ordinal.
    public let commandsByOrdinal: [Int: [SpeakCommand]]

    /**
     Creates one validated generic-key payload.

     - Parameters describe the exact key, display name, local range, and commands.
     - Side effects: none.
     - Failure modes: Construction does not validate contiguity; providers reject missing ordinal
       commands when preparing or traversing the source.
     */
    public init(
        key: String,
        keyName: String,
        ordinalRange: ClosedRange<Int>,
        commandsByOrdinal: [Int: [SpeakCommand]]
    ) {
        self.key = key
        self.keyName = keyName
        self.ordinalRange = ordinalRange
        self.commandsByOrdinal = commandsByOrdinal
    }
}

/** Lazy generic-module boundary equivalent to Android's `BookAndKey` collection. */
public struct GenericSpeakOrdinalSource: @unchecked Sendable {
    /// Concrete source category.
    public let category: SpeakDocumentCategory
    /// Exact module or MyDocument initials.
    public let bookInitials: String
    /// User-visible source name.
    public let bookName: String
    /// BCP-47 source language.
    public let language: String
    /// Exact keys in provider traversal order.
    public let keys: [String]
    /// Lazy structured loader for one exact key.
    public let loadContent: (String) -> GenericSpeakKeyContent?

    /** Creates one immutable generic source description with a lazy key loader. */
    public init(
        category: SpeakDocumentCategory,
        bookInitials: String,
        bookName: String,
        language: String,
        keys: [String],
        loadContent: @escaping (String) -> GenericSpeakKeyContent?
    ) {
        self.category = category
        self.bookInitials = bookInitials
        self.bookName = bookName
        self.language = language
        self.keys = keys
        self.loadContent = loadContent
    }
}

/**
 Lazy generic provider preserving Android's exact `(module, key, ordinal)` cursor.

 The provider loads only keys reached by playback or transport. It advances individual BVA
 ordinals, crosses key boundaries without converting them to Bible chapters, wraps unbounded
 collections, stops at explicit selection bounds, and checkpoints exact source cursors for process
 reconstruction.
 */
public final class GenericOrdinalSpeakTextProvider: SpeakTextProviding {
    private struct Point: Equatable, Comparable {
        let keyIndex: Int
        let ordinal: Int

        static func < (lhs: Point, rhs: Point) -> Bool {
            lhs.keyIndex == rhs.keyIndex
                ? lhs.ordinal < rhs.ordinal
                : lhs.keyIndex < rhs.keyIndex
        }
    }

    public let category: SpeakDocumentCategory
    public let canAutoBookmark: Bool
    public let isMemorizationLoop = false
    public var availablePositions: [SpeakStreamPosition] {
        currentPosition.map { [$0] } ?? []
    }
    public var currentPosition: SpeakStreamPosition? {
        position(at: current)
    }

    private let source: GenericSpeakOrdinalSource
    private let configuredLower: Point?
    private let configuredUpper: Point?
    private var current: Point?
    private var transitionOrigin: Point?
    private var lastTitle: Point?
    private var cache: [String: GenericSpeakKeyContent] = [:]
    private var cacheOrder: [String] = []

    /**
     Creates a lazy provider at one exact generic cursor.

     - Parameters:
       - source: Category-correct generic source and lazy key loader.
       - startKey: Exact initial key.
       - startOrdinal: Exact initial local ordinal, or the key's first ordinal when omitted.
       - endKey: Exact terminal key for a bounded selection.
       - endOrdinal: Exact terminal local ordinal for a bounded selection.
     - Side effects: Loads only the initial and optional terminal key.
     - Failure modes: Returns `nil` for Bible/memorization/selection categories, absent keys,
       missing ordinal commands, reversed bounds, or an incomplete bounded endpoint.
     */
    public init?(
        source: GenericSpeakOrdinalSource,
        startKey: String,
        startOrdinal: Int? = nil,
        endKey: String? = nil,
        endOrdinal: Int? = nil
    ) {
        guard [.commentary, .dictionary, .generalBook, .myDocument].contains(source.category),
              let startKeyIndex = source.keys.firstIndex(of: startKey) else {
            return nil
        }
        self.source = source
        category = source.category

        guard let startContent = source.loadContent(startKey),
              startContent.key == startKey,
              Self.isComplete(startContent) else {
            return nil
        }
        cache[startKey] = startContent
        cacheOrder = [startKey]
        let requestedStart = startOrdinal ?? startContent.ordinalRange.lowerBound
        guard startContent.ordinalRange.contains(requestedStart),
              startContent.commandsByOrdinal[requestedStart] != nil else {
            return nil
        }
        let start = Point(keyIndex: startKeyIndex, ordinal: requestedStart)

        if endKey != nil || endOrdinal != nil {
            guard let endKey = endKey ?? Optional(startKey),
                  let requestedEnd = endOrdinal,
                  let endKeyIndex = source.keys.firstIndex(of: endKey),
                  let endContent = endKey == startKey ? startContent : source.loadContent(endKey),
                  endContent.key == endKey,
                  Self.isComplete(endContent),
                  endContent.ordinalRange.contains(requestedEnd),
                  endContent.commandsByOrdinal[requestedEnd] != nil else {
                return nil
            }
            if endKey != startKey {
                cache[endKey] = endContent
                cacheOrder.append(endKey)
            }
            let end = Point(keyIndex: endKeyIndex, ordinal: requestedEnd)
            guard start <= end else { return nil }
            configuredLower = start
            configuredUpper = end
            canAutoBookmark = false
        } else {
            configuredLower = nil
            configuredUpper = nil
            canAutoBookmark = true
        }
        current = start
    }

    /**
     Reconstructs a generic provider from one exact persisted checkpoint.

     - Parameters:
       - source: Category-correct source that owns every persisted cursor.
       - checkpoint: Current cursor and original collection or selection bounds.
     - Side effects: Loads only the current, lower-bound, and upper-bound keys.
     - Failure modes: Returns `nil` for schema/category/module mismatches, non-exact ordinals,
       missing commands, reversed bounds, or memorization checkpoints.
     */
    public init?(
        source: GenericSpeakOrdinalSource,
        checkpoint: SpeakProviderCheckpoint
    ) {
        guard checkpoint.version == 1,
              !checkpoint.isMemorizationLoop,
              checkpoint.current.category == source.category,
              checkpoint.lowerBound.category == source.category,
              checkpoint.upperBound.category == source.category,
              checkpoint.current.bookInitials == source.bookInitials,
              checkpoint.lowerBound.bookInitials == source.bookInitials,
              checkpoint.upperBound.bookInitials == source.bookInitials,
              [.commentary, .dictionary, .generalBook, .myDocument].contains(source.category) else {
            return nil
        }

        var loadedContent: [String: GenericSpeakKeyContent] = [:]
        var loadedKeys: [String] = []
        func point(for cursor: SpeakStreamCursor) -> Point? {
            guard cursor.versification == nil,
                  let ordinal = cursor.ordinalStart,
                  cursor.ordinalEnd == ordinal,
                  let keyIndex = source.keys.firstIndex(of: cursor.key) else {
                return nil
            }
            let content: GenericSpeakKeyContent
            if let cached = loadedContent[cursor.key] {
                content = cached
            } else {
                guard let loaded = source.loadContent(cursor.key),
                      loaded.key == cursor.key,
                      Self.isComplete(loaded) else {
                    return nil
                }
                loadedContent[cursor.key] = loaded
                loadedKeys.append(cursor.key)
                content = loaded
            }
            guard content.ordinalRange.contains(ordinal),
                  content.commandsByOrdinal[ordinal] != nil else {
                return nil
            }
            return Point(keyIndex: keyIndex, ordinal: ordinal)
        }

        guard let currentPoint = point(for: checkpoint.current),
              let lowerPoint = point(for: checkpoint.lowerBound),
              let upperPoint = point(for: checkpoint.upperBound),
              lowerPoint <= currentPoint,
              currentPoint <= upperPoint else {
            return nil
        }

        self.source = source
        category = source.category
        configuredLower = checkpoint.isBounded ? lowerPoint : nil
        configuredUpper = checkpoint.isBounded ? upperPoint : nil
        canAutoBookmark = !checkpoint.isBounded
        current = currentPoint
        cache = loadedContent
        cacheOrder = loadedKeys
    }

    /** Validates that the exact current and bounded cursors remain addressable. */
    public func prepare(settings: SpeakSettings) -> Bool {
        _ = settings
        guard let current, position(at: current) != nil else { return false }
        if let configuredLower, let configuredUpper {
            return configuredLower <= current
                && current <= configuredUpper
                && position(at: configuredLower) != nil
                && position(at: configuredUpper) != nil
        }
        return true
    }

    /** Captures exact source cursor and collection or selection limits. */
    public func checkpoint() -> SpeakProviderCheckpoint? {
        guard let current,
              let currentPosition = position(at: current),
              let lower = configuredLower ?? firstAddressablePoint(),
              let upper = configuredUpper ?? lastAddressablePoint(),
              let lowerPosition = position(at: lower),
              let upperPosition = position(at: upper) else {
            return nil
        }
        return SpeakProviderCheckpoint(
            current: SpeakStreamCursor(position: currentPosition),
            lowerBound: SpeakStreamCursor(position: lowerPosition),
            upperBound: SpeakStreamCursor(position: upperPosition),
            isBounded: configuredLower != nil,
            isMemorizationLoop: false
        )
    }

    /** Records the exact cursor that produced a title command for smart rewind. */
    public func didStart(command: SpeakCommand) {
        if case .heading = command { lastTitle = current }
    }

    /** Loads commands for the exact current local ordinal. */
    public func currentUnit(settings: SpeakSettings) -> SpeakStreamUnit? {
        guard let current,
              let position = position(at: current),
              let content = content(at: current.keyIndex),
              let commands = content.commandsByOrdinal[current.ordinal] else {
            return nil
        }
        var prefix: [SpeakCommand] = []
        if let transitionOrigin,
           transitionOrigin.keyIndex != current.keyIndex,
           settings.playbackSettings.speakChapterChanges {
            let chapter = String(localized: "speak_chapter_changed", defaultValue: "Chapter")
            prefix = [.announcement("\(chapter) \(position.keyName)."), .pause(milliseconds: 500)]
        }
        self.transitionOrigin = nil
        return SpeakStreamUnit(position: position, commands: prefix + commands)
    }

    /** Advances one exact ordinal, wrapping only an unbounded collection. */
    @discardableResult
    public func advance(settings: SpeakSettings) -> Bool {
        _ = settings
        guard let current else { return false }
        if let next = nextPoint(after: current, wrapping: false), withinBounds(next) {
            move(to: next, from: current)
            return true
        }
        guard configuredUpper == nil, let first = firstAddressablePoint() else { return false }
        move(to: first, from: current)
        return true
    }

    /** Moves backward by one exact ordinal or Android's title-aware smart distance. */
    @discardableResult
    public func rewind(_ amount: SpeakRewindAmount) -> Bool {
        guard let current else { return false }
        let target: Point?
        switch amount {
        case .none:
            target = current
        case .oneUnit:
            target = previousPoint(before: current, wrapping: configuredLower == nil)
        case .smart:
            if let lastTitle, lastTitle != current, withinBounds(lastTitle) {
                target = lastTitle
            } else if let content = content(at: current.keyIndex),
                      current.ordinal <= content.ordinalRange.lowerBound {
                let previous = previousPoint(
                    before: current,
                    wrapping: configuredLower == nil
                )
                target = previous.flatMap { withinBounds($0) ? $0 : nil }
            } else {
                target = moved(from: current, distance: -10)
            }
        }
        guard let target, target != current else { return false }
        move(to: target, from: nil)
        if let lastTitle, target < lastTitle { self.lastTitle = nil }
        return true
    }

    /** Moves forward by one exact ordinal or Android's ten-unit smart distance. */
    @discardableResult
    public func forward(_ amount: SpeakRewindAmount) -> Bool {
        guard let current else { return false }
        let target: Point?
        switch amount {
        case .none:
            target = current
        case .oneUnit:
            target = nextPoint(after: current, wrapping: configuredUpper == nil)
        case .smart:
            target = moved(from: current, distance: 10)
        }
        guard let target, target != current else { return false }
        move(to: target, from: nil)
        lastTitle = nil
        return true
    }

    /** Finds a bounded number of exact provider-unit steps in either direction. */
    private func moved(from start: Point, distance: Int) -> Point? {
        var candidate = start
        if distance < 0 {
            for _ in 0..<abs(distance) {
                guard let previous = previousPoint(
                    before: candidate,
                    wrapping: configuredLower == nil
                ), withinBounds(previous) else { return candidate }
                candidate = previous
            }
        } else {
            for _ in 0..<distance {
                guard let next = nextPoint(
                    after: candidate,
                    wrapping: configuredUpper == nil
                ), withinBounds(next) else { return candidate }
                candidate = next
            }
        }
        return candidate
    }

    /** Returns the next addressable local ordinal or key. */
    private func nextPoint(after point: Point, wrapping: Bool) -> Point? {
        if let content = content(at: point.keyIndex),
           point.ordinal < content.ordinalRange.upperBound {
            let candidate = Point(keyIndex: point.keyIndex, ordinal: point.ordinal + 1)
            if content.commandsByOrdinal[candidate.ordinal] != nil { return candidate }
        }
        if point.keyIndex + 1 < source.keys.count {
            for index in (point.keyIndex + 1)..<source.keys.count {
                if let candidate = firstPoint(in: index) { return candidate }
            }
        }
        return wrapping ? firstAddressablePoint() : nil
    }

    /** Returns the previous addressable local ordinal or key. */
    private func previousPoint(before point: Point, wrapping: Bool) -> Point? {
        if let content = content(at: point.keyIndex),
           point.ordinal > content.ordinalRange.lowerBound {
            let candidate = Point(keyIndex: point.keyIndex, ordinal: point.ordinal - 1)
            if content.commandsByOrdinal[candidate.ordinal] != nil { return candidate }
        }
        if point.keyIndex > 0 {
            for index in stride(from: point.keyIndex - 1, through: 0, by: -1) {
                if let candidate = lastPoint(in: index) { return candidate }
            }
        }
        return wrapping ? lastAddressablePoint() : nil
    }

    /** Builds stable provider metadata for one exact point. */
    private func position(at point: Point?) -> SpeakStreamPosition? {
        guard let point,
              let content = content(at: point.keyIndex),
              content.ordinalRange.contains(point.ordinal),
              content.commandsByOrdinal[point.ordinal] != nil else {
            return nil
        }
        return SpeakStreamPosition(
            id: "\(source.bookInitials):\(content.key):\(point.ordinal)",
            category: source.category,
            bookInitials: source.bookInitials,
            key: content.key,
            keyName: content.keyName,
            bookName: source.bookName,
            ordinalStart: point.ordinal,
            ordinalEnd: point.ordinal,
            groupIdentifier: content.key,
            language: source.language
        )
    }

    /** Loads and caches one exact key while keeping memory bounded. */
    private func content(at keyIndex: Int) -> GenericSpeakKeyContent? {
        guard source.keys.indices.contains(keyIndex) else { return nil }
        let key = source.keys[keyIndex]
        if let cached = cache[key] { return cached }
        guard let loaded = source.loadContent(key),
              loaded.key == key,
              Self.isComplete(loaded) else {
            return nil
        }
        cache[key] = loaded
        cacheOrder.append(key)
        while cacheOrder.count > 8 {
            let evicted = cacheOrder.removeFirst()
            let currentKey = current.flatMap { point in
                source.keys.indices.contains(point.keyIndex) ? source.keys[point.keyIndex] : nil
            }
            if evicted != currentKey { cache.removeValue(forKey: evicted) }
        }
        return loaded
    }

    /** First addressable point in one key. */
    private func firstPoint(in keyIndex: Int) -> Point? {
        guard let content = content(at: keyIndex) else { return nil }
        return content.ordinalRange.first(where: { content.commandsByOrdinal[$0] != nil }).map {
            Point(keyIndex: keyIndex, ordinal: $0)
        }
    }

    /** Last addressable point in one key. */
    private func lastPoint(in keyIndex: Int) -> Point? {
        guard let content = content(at: keyIndex) else { return nil }
        return content.ordinalRange.reversed().first(where: {
            content.commandsByOrdinal[$0] != nil
        }).map { Point(keyIndex: keyIndex, ordinal: $0) }
    }

    /** First addressable point in the collection. */
    private func firstAddressablePoint() -> Point? {
        for index in source.keys.indices {
            if let point = firstPoint(in: index) { return point }
        }
        return nil
    }

    /** Last addressable point in the collection. */
    private func lastAddressablePoint() -> Point? {
        for index in source.keys.indices.reversed() {
            if let point = lastPoint(in: index) { return point }
        }
        return nil
    }

    /** Whether one point remains inside an explicit bounded selection. */
    private func withinBounds(_ point: Point) -> Bool {
        if let configuredLower, point < configuredLower { return false }
        if let configuredUpper, point > configuredUpper { return false }
        return true
    }

    /** Updates exact cursor and transition state. */
    private func move(to point: Point, from previous: Point?) {
        current = point
        transitionOrigin = previous
    }

    /** Validates Android's one-addressable-command-array-per-local-ordinal source contract. */
    private static func isComplete(_ content: GenericSpeakKeyContent) -> Bool {
        content.ordinalRange.allSatisfy { content.commandsByOrdinal[$0] != nil }
    }
}
