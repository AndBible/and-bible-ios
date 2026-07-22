// JSwordVersificationMapping.swift - Android's resource-driven KJVA mapping contract

import Foundation
import SwordKit

/**
 Applies Android JSword's versification `.properties` rules around the KJVA intermediate canon.

 JSword does not use coordinate identity whenever a target canon happens to contain the same
 chapter and verse. It first consults a canon-specific mapping resource, preserves verse-part
 qualifiers through the KJVA intermediate, and only then applies identity for an otherwise
 unmapped coordinate. This implementation ports that contract for single-reference conversion.

 Mapping resources are loaded lazily per canon and expanded through the bundled JSword canon
 fixture. Both artifacts come from the same pinned Android dependency revision, so a SWORD canon
 dimension cannot shift an otherwise valid mapping endpoint into an adjacent chapter. A malformed
 bundled resource fails closed so callers cannot persist relabeled source ordinals.
 */
enum JSwordVersificationMapping {
    struct StrictConversion {
        let reference: SwordVersification.Reference
        let usedExplicitMapping: Bool
    }

    struct Coordinate: Hashable {
        let index: Int
        let part: String?

        var whole: Coordinate { Coordinate(index: index, part: nil) }
    }

    /**
     Preserves the shape of one JSword `QualifiedKey` while it crosses the KJVA intermediate.

     A source verse can map to a single qualified verse, a whole verse range, or a named section
     absent from KJVA. JSword deliberately keeps ranges intact until the target mapper sees them;
     flattening them verse by verse changes one-to-many conversions.
     */
    private enum IntermediateKey: Hashable {
        case verse(Coordinate)
        case range(ClosedRange<Int>)
        case section(String)
    }

    private struct IndexedReference {
        let coordinate: Coordinate
        let verse: Int
    }

    private struct Mapping {
        var forward: [Int: [IntermediateKey]] = [:]
        var reverse: [IntermediateKey: [Int]] = [:]
        var absentInSource: Set<Int> = []

        mutating func addForward(source: IndexedReference, target: IntermediateKey) {
            appendUnique(target, to: &forward[source.coordinate.index, default: []])
        }

        mutating func addReverse(source: IndexedReference, target: IntermediateKey) {
            appendUnique(source.coordinate.index, to: &reverse[target, default: []])
            if case .verse(let coordinate) = target, coordinate.part != nil {
                appendUnique(
                    source.coordinate.index,
                    to: &reverse[.verse(coordinate.whole), default: []]
                )
            }
        }

        mutating func add(source: IndexedReference, target: IntermediateKey) {
            addForward(source: source, target: target)
            addReverse(source: source, target: target)
        }

        private func appendUnique<Element: Equatable>(_ value: Element, to values: inout [Element]) {
            if !values.contains(value) {
                values.append(value)
            }
        }
    }

    private enum Availability {
        case mapping(Mapping)
        case missing
        case invalid
    }

    private struct IntermediateProjection {
        let keys: [IntermediateKey]
        let usedExplicitMapping: Bool
    }

    private enum ParseError: Error {
        case malformedLine(Int)
        case malformedReference(String)
        case invalidRange(String)
        case cardinalityMismatch(Int)
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Availability] = [:]

        func availability(for versification: String) -> Availability {
            lock.lock()
            defer { lock.unlock() }
            if let cached = values[versification] {
                return cached
            }
            let loaded = JSwordVersificationMapping.loadMapping(for: versification)
            values[versification] = loaded
            return loaded
        }
    }

    private static let cache = Cache()

    /**
     Converts one source reference to the first Android-equivalent target reference.

     JSword can map one source verse to multiple qualified KJVA verses and then to multiple target
     verses. Android's single-verse conversion reads the first verse from that canonical passage;
     this method therefore returns the lowest target canon index after preserving qualifiers.

     - Parameters:
       - reference: Coordinates in `sourceVersification`.
       - sourceVersification: Source canon name. Empty uses KJV; unknown names fail closed so an
         unsupported source cannot be relabeled as KJV.
       - targetVersification: Target canon name. Empty means KJV; unknown targets fail.
     - Returns: First mapped target reference, or `nil` when the source is invalid, explicitly
       absent, the target lacks an equivalent, or a bundled resource is malformed.
     - Side effects: Lazily reads and caches the source and target JSword resource tables.
     - Failure modes: Returns `nil` without applying identity after an explicit or parse failure.
     */
    static func convertStrictly(
        reference: SwordVersification.Reference,
        from sourceVersification: String,
        to targetVersification: String
    ) -> StrictConversion? {
        guard let sourceName = effectiveSourceName(sourceVersification) else {
            return nil
        }
        let targetName = targetVersification.isEmpty ? "KJV" : targetVersification
        guard JSwordCanon.normalizedName(targetName) != nil,
              let sourceIndex = JSwordCanon.referenceIndex(
                  for: reference,
                  versification: sourceName
              ) else {
            return nil
        }
        if sourceName == targetName {
            return StrictConversion(reference: reference, usedExplicitMapping: false)
        }

        guard let projection = mapToKJVA(
            sourceReference: reference,
            sourceIndex: sourceIndex,
            sourceVersification: sourceName
        ) else {
            return nil
        }
        return mapFromKJVA(projection, to: targetName)
    }

    private static func effectiveSourceName(_ name: String) -> String? {
        JSwordCanon.normalizedName(name)
    }

    private static func mapToKJVA(
        sourceReference: SwordVersification.Reference,
        sourceIndex: Int,
        sourceVersification: String
    ) -> IntermediateProjection? {
        switch cache.availability(for: sourceVersification) {
        case .mapping(let mapping):
            if let explicit = mapping.forward[sourceIndex] {
                return IntermediateProjection(keys: explicit, usedExplicitMapping: true)
            }
        case .invalid:
            return nil
        case .missing:
            break
        }

        guard let kjvaIndex = JSwordCanon.referenceIndex(
            for: sourceReference,
            versification: "KJVA"
        ) else {
            return nil
        }
        return IntermediateProjection(
            keys: [.verse(Coordinate(index: kjvaIndex, part: nil))],
            usedExplicitMapping: false
        )
    }

    private static func mapFromKJVA(
        _ projection: IntermediateProjection,
        to targetVersification: String
    ) -> StrictConversion? {
        let availability = cache.availability(for: targetVersification)
        if case .invalid = availability {
            return nil
        }

        var targetIndexes: Set<Int> = []
        var usedExplicitMapping = projection.usedExplicitMapping
        for key in projection.keys {
            switch availability {
            case .mapping(let mapping):
                let mapped = mapping.reverse[key]
                if let mapped {
                    targetIndexes.formUnion(mapped)
                    usedExplicitMapping = true
                    continue
                }
                if case .verse(let coordinate) = key,
                   mapping.absentInSource.contains(coordinate.index) {
                    continue
                }
            case .missing:
                break
            case .invalid:
                return nil
            }

            switch key {
            case .verse(let coordinate):
                guard let kjvaReference = JSwordCanon.reference(
                    forIndex: coordinate.index,
                    versification: "KJVA"
                ), let targetIndex = JSwordCanon.referenceIndex(
                    for: kjvaReference,
                    versification: targetVersification
                ) else {
                    continue
                }
                targetIndexes.insert(targetIndex)
            case .range(let range):
                guard let targetIndex = identityRangeStartIndex(
                    range,
                    targetVersification: targetVersification,
                    validatesEveryVerse: {
                        if case .mapping = availability { return true }
                        return false
                    }()
                ) else {
                    continue
                }
                targetIndexes.insert(targetIndex)
            case .section:
                continue
            }
        }

        guard let first = targetIndexes.min() else { return nil }
        guard let reference = JSwordCanon.reference(
            forIndex: first,
            versification: targetVersification
        ) else {
            return nil
        }
        return StrictConversion(
            reference: reference,
            usedExplicitMapping: usedExplicitMapping
        )
    }

    private static func identityRangeStartIndex(
        _ range: ClosedRange<Int>,
        targetVersification: String,
        validatesEveryVerse: Bool
    ) -> Int? {
        if !validatesEveryVerse {
            guard let firstReference = JSwordCanon.reference(
                forIndex: range.lowerBound,
                versification: "KJVA"
            ), let firstTargetIndex = JSwordCanon.referenceIndex(
                for: firstReference,
                versification: targetVersification
            ), let lastReference = JSwordCanon.reference(
                forIndex: range.upperBound,
                versification: "KJVA"
            ), JSwordCanon.referenceIndex(
                for: lastReference,
                versification: targetVersification
            ) != nil else {
                return nil
            }
            return firstTargetIndex
        }

        var firstTargetIndex: Int?
        for index in range {
            guard let kjvaReference = JSwordCanon.reference(
                forIndex: index,
                versification: "KJVA"
            ), let targetIndex = JSwordCanon.referenceIndex(
                for: kjvaReference,
                versification: targetVersification
            ) else {
                return nil
            }
            if firstTargetIndex == nil {
                firstTargetIndex = targetIndex
            }
        }
        return firstTargetIndex
    }

    private static func loadMapping(for versification: String) -> Availability {
        guard let data = JSwordVersificationRegistry.mappingResourceData(for: versification) else {
            return .missing
        }
        guard let contents = String(data: data, encoding: .utf8) else {
            return .invalid
        }
        do {
            return .mapping(try parse(contents, versification: versification))
        } catch {
            return .invalid
        }
    }

    private static func parse(_ contents: String, versification: String) throws -> Mapping {
        var mapping = Mapping()
        for (zeroBasedLine, rawLine) in contents.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), line != "!zerosUnmapped" else {
                continue
            }
            guard let separator = line.firstIndex(of: "=") else {
                throw ParseError.malformedLine(zeroBasedLine + 1)
            }
            let sourceText = String(line[..<separator])
            let targetText = String(line[line.index(after: separator)...])

            if sourceText.hasPrefix("?") {
                let targets = try parseRange(targetText, versification: "KJVA")
                mapping.absentInSource.formUnion(targets.map(\.coordinate.index))
                continue
            }

            let sources = try parseRange(sourceText, versification: versification)
            if targetText.hasPrefix("?") {
                let section = IntermediateKey.section(String(targetText.dropFirst()))
                for source in sources {
                    mapping.add(source: source, target: section)
                }
                continue
            }
            let targets = try parseRange(targetText, versification: "KJVA")
            try addRule(
                sources: sources,
                targets: targets,
                line: zeroBasedLine + 1,
                mapping: &mapping
            )
        }
        return mapping
    }

    private static func parseRange(
        _ text: String,
        versification: String
    ) throws -> [IndexedReference] {
        let endpoints = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let firstText = endpoints.first, !firstText.isEmpty else {
            throw ParseError.malformedReference(text)
        }
        let parsedFirst = try parseReference(String(firstText), versification: versification)
        let parsedLast = endpoints.count == 2
            ? try parseReference(String(endpoints[1]), versification: versification)
            : parsedFirst
        // JSword's VerseRange constructor canonicalizes reversed endpoints. Its checked-in
        // Synodal resources rely on that behavior for one historical Psalm mapping typo.
        let first = parsedFirst.coordinate.index <= parsedLast.coordinate.index
            ? parsedFirst
            : parsedLast
        let last = parsedFirst.coordinate.index <= parsedLast.coordinate.index
            ? parsedLast
            : parsedFirst

        var values: [IndexedReference] = []
        values.reserveCapacity(last.coordinate.index - first.coordinate.index + 1)
        for index in first.coordinate.index...last.coordinate.index {
            guard let reference = JSwordCanon.reference(
                forIndex: index,
                versification: versification
            ) else {
                throw ParseError.invalidRange(text)
            }
            // JSword stores a multi-verse range as `getWhole()`, so endpoint qualifiers are not
            // retained when the range is expanded. A one-verse key keeps its qualifier.
            let isSingleOrdinal = first.coordinate.index == last.coordinate.index
            let part = isSingleOrdinal ? first.coordinate.part : nil
            values.append(
                IndexedReference(
                    coordinate: Coordinate(index: index, part: part),
                    verse: isSingleOrdinal ? first.verse : reference.verse
                )
            )
        }
        return values
    }

    private static func parseReference(
        _ text: String,
        versification: String
    ) throws -> IndexedReference {
        let qualified = text.split(separator: "!", maxSplits: 1, omittingEmptySubsequences: false)
        let components = qualified[0].split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              let chapter = Int(components[1]),
              let verse = Int(components[2]) else {
            throw ParseError.malformedReference(text)
        }
        let reference = SwordVersification.Reference(
            osisBookId: String(components[0]),
            chapter: chapter,
            verse: verse
        )
        guard let index = JSwordCanon.mappingReferenceIndex(
            for: reference,
            versification: versification
        ) else {
            throw ParseError.malformedReference(text)
        }
        let part = qualified.count == 2 && !qualified[1].isEmpty ? String(qualified[1]) : nil
        return IndexedReference(
            coordinate: Coordinate(index: index, part: part),
            verse: verse
        )
    }

    private static func addRule(
        sources: [IndexedReference],
        targets: [IndexedReference],
        line: Int,
        mapping: inout Mapping
    ) throws {
        guard !sources.isEmpty, !targets.isEmpty else {
            throw ParseError.cardinalityMismatch(line)
        }
        if sources.count == 1 {
            if targets.count == 1 {
                mapping.add(source: sources[0], target: .verse(targets[0].coordinate))
            } else {
                let range = targets[0].coordinate.index...targets[targets.count - 1].coordinate.index
                mapping.addForward(source: sources[0], target: .range(range))
                for target in targets {
                    mapping.addReverse(
                        source: sources[0],
                        target: .verse(target.coordinate.whole)
                    )
                }
            }
            return
        }
        if targets.count == 1 {
            for source in sources {
                mapping.add(source: source, target: .verse(targets[0].coordinate))
            }
            return
        }

        let difference = abs(sources.count - targets.count)
        guard difference <= 1 else {
            throw ParseError.cardinalityMismatch(line)
        }
        let skipsVerseZero = difference == 1
        var sourceIndex = 0
        var targetIndex = 0
        while sourceIndex < sources.count {
            guard targetIndex < targets.count else {
                throw ParseError.cardinalityMismatch(line)
            }
            var source = sources[sourceIndex]
            sourceIndex += 1
            var target = targets[targetIndex]
            targetIndex += 1

            if skipsVerseZero, source.verse == 0 {
                mapping.add(source: source, target: .verse(target.coordinate.whole))
                guard sourceIndex < sources.count else {
                    throw ParseError.cardinalityMismatch(line)
                }
                source = sources[sourceIndex]
                sourceIndex += 1
            }
            if skipsVerseZero, target.verse == 0 {
                mapping.add(source: source, target: .verse(target.coordinate.whole))
                guard targetIndex < targets.count else {
                    throw ParseError.cardinalityMismatch(line)
                }
                target = targets[targetIndex]
                targetIndex += 1
            }
            mapping.add(source: source, target: .verse(target.coordinate.whole))
        }
        guard targetIndex == targets.count else {
            throw ParseError.cardinalityMismatch(line)
        }
    }
}
