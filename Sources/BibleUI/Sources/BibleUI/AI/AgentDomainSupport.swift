// AgentDomainSupport.swift -- Bounded serialization and scripture coordinates for AI tools

import BibleCore
import Foundation
import SwordKit

/** One concrete real verse in Android's canonical KJVA address space. */
struct BibleUIAgentKJVAVerse: Equatable, Sendable {
    let osisBookID: String
    let chapter: Int
    let verse: Int
    let ordinal: Int

    var osisReference: String {
        "\(osisBookID).\(chapter).\(verse)"
    }

    var displayName: String {
        let book = JSwordKJVAVersification.localizedLongBookName(osisId: osisBookID)
            ?? osisBookID
        return "\(book) \(chapter):\(verse)"
    }

    var swordReference: VerseKeyReference {
        VerseKeyReference(
            osisBookId: osisBookID,
            chapter: chapter,
            verse: verse,
            ordinal: ordinal
        )
    }
}

/**
 Strict parser for the OSIS chapter, verse, range, and list forms advertised by Android's tools.

 Expansion uses the pinned JSword KJVA table, skips introduction ordinals, returns canonical source
 order, and rejects oversized passages before document I/O. It does not reinterpret KJVA ordinals
 in a divergent installed module.
 */
enum BibleUIAgentKJVAReferenceParser {
    static let maximumVerses = 500

    /**
     Expands an OSIS reference into unique canonical KJVA verses.

     - Parameters:
       - value: OSIS verse, chapter, range, or comma/semicolon-separated list.
       - maximum: Maximum number of real verses accepted.
     - Returns: Concrete verses in canonical KJVA source order.
     - Side effects: Reads immutable bundled JSword versification data.
     - Failure modes: Throws `INVALID_REFERENCE` or `LIMIT_EXCEEDED` without reflecting content.
     */
    static func parse(
        _ value: String,
        maximum: Int = maximumVerses
    ) throws -> [BibleUIAgentKJVAVerse] {
        let segments = value
            .split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !segments.isEmpty else { throw invalidReference() }

        var versesByOrdinal: [Int: BibleUIAgentKJVAVerse] = [:]
        for segment in segments {
            for verse in try expand(segment, maximum: maximum) {
                versesByOrdinal[verse.ordinal] = verse
                guard versesByOrdinal.count <= maximum else {
                    throw BibleUIAgentDomainError(
                        code: "LIMIT_EXCEEDED",
                        message: "The requested passage contains too many verses."
                    )
                }
            }
        }
        return versesByOrdinal.values.sorted { $0.ordinal < $1.ordinal }
    }

    /** Returns only Android's first contiguous range for bookmark creation. */
    static func firstRange(_ value: String) throws -> [BibleUIAgentKJVAVerse] {
        guard let first = value.split(whereSeparator: { $0 == "," || $0 == ";" }).first else {
            throw invalidReference()
        }
        return try expand(
            String(first).trimmingCharacters(in: .whitespacesAndNewlines),
            maximum: maximumVerses
        )
    }

    private struct Coordinate {
        let osisBookID: String
        let chapter: Int
        let verse: Int?
    }

    private static func expand(_ segment: String, maximum: Int) throws
        -> [BibleUIAgentKJVAVerse] {
        let endpoints = segment.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let firstText = endpoints.first, !firstText.isEmpty else { throw invalidReference() }
        let start = try coordinate(String(firstText), relativeTo: nil)
        let end = endpoints.count == 2
            ? try coordinate(String(endpoints[1]), relativeTo: start)
            : start

        let startVerse = try concreteStart(start)
        let endVerse = try concreteEnd(end)
        guard endVerse.ordinal >= startVerse.ordinal else { throw invalidReference() }

        var result: [BibleUIAgentKJVAVerse] = []
        var ordinal = startVerse.ordinal
        while ordinal <= endVerse.ordinal {
            if let reference = JSwordKJVAVersification.verseReference(ordinal: ordinal) {
                result.append(BibleUIAgentKJVAVerse(
                    osisBookID: reference.osisId,
                    chapter: reference.chapter,
                    verse: reference.verse,
                    ordinal: reference.ordinal
                ))
                guard result.count <= maximum else {
                    throw BibleUIAgentDomainError(
                        code: "LIMIT_EXCEEDED",
                        message: "The requested passage contains too many verses."
                    )
                }
            }
            ordinal += 1
        }
        guard !result.isEmpty else { throw invalidReference() }
        return result
    }

    private static func coordinate(
        _ rawValue: String,
        relativeTo basis: Coordinate?
    ) throws -> Coordinate {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Int(value), let basis, number > 0 {
            return Coordinate(
                osisBookID: basis.osisBookID,
                chapter: basis.verse == nil ? number : basis.chapter,
                verse: basis.verse == nil ? nil : number
            )
        }

        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              let chapter = Int(parts[1]), chapter > 0 else {
            throw invalidReference()
        }
        let osisBookID = String(parts[0])
        guard JSwordKJVAVersification.lastChapter(osisId: osisBookID).map({ chapter <= $0 }) == true else {
            throw invalidReference()
        }
        let verse: Int?
        if parts.count == 3 {
            guard let parsedVerse = Int(parts[2]), parsedVerse > 0,
                  JSwordKJVAVersification.verseCount(
                    osisId: osisBookID,
                    chapter: chapter
                  ).map({ parsedVerse <= $0 }) == true else {
                throw invalidReference()
            }
            verse = parsedVerse
        } else {
            verse = nil
        }
        return Coordinate(osisBookID: osisBookID, chapter: chapter, verse: verse)
    }

    private static func concreteStart(_ coordinate: Coordinate) throws -> BibleUIAgentKJVAVerse {
        try concrete(coordinate, verse: coordinate.verse ?? 1)
    }

    private static func concreteEnd(_ coordinate: Coordinate) throws -> BibleUIAgentKJVAVerse {
        let verse = coordinate.verse
            ?? JSwordKJVAVersification.verseCount(
                osisId: coordinate.osisBookID,
                chapter: coordinate.chapter
            )
        guard let verse else { throw invalidReference() }
        return try concrete(coordinate, verse: verse)
    }

    private static func concrete(
        _ coordinate: Coordinate,
        verse: Int
    ) throws -> BibleUIAgentKJVAVerse {
        guard let ordinal = JSwordKJVAVersification.verseOrdinal(
            osisId: coordinate.osisBookID,
            chapter: coordinate.chapter,
            verse: verse
        ) else {
            throw invalidReference()
        }
        return BibleUIAgentKJVAVerse(
            osisBookID: coordinate.osisBookID,
            chapter: coordinate.chapter,
            verse: verse,
            ordinal: ordinal
        )
    }

    private static func invalidReference() -> BibleUIAgentDomainError {
        BibleUIAgentDomainError(
            code: "INVALID_REFERENCE",
            message: "The verse reference is invalid."
        )
    }
}

/** Deterministic Android-shaped JSON helpers with one auditable response bound. */
enum BibleUIAgentJSON {
    static let maximumResponseBytes = 400_000

    static func object(_ pairs: (String, JSONValue?)...) -> JSONValue {
        var values: [String: JSONValue] = [:]
        for (key, value) in pairs {
            if let value { values[key] = value }
        }
        return .object(values)
    }

    static func array(_ values: [JSONValue]) -> JSONValue {
        .array(values)
    }

    static func string(_ value: String?) -> JSONValue? {
        value.map(JSONValue.string)
    }

    static func integer(_ value: Int) -> JSONValue {
        .number(Double(value))
    }

    static func optionalInteger(_ value: Int?) -> JSONValue? {
        value.map { .number(Double($0)) }
    }

    static func milliseconds(_ date: Date) -> JSONValue {
        .number((date.timeIntervalSince1970 * 1_000).rounded(.towardZero))
    }

    static func uuid(_ value: UUID) -> JSONValue {
        .string(value.uuidString.lowercased())
    }

    static func optionalUUID(_ value: UUID?) -> JSONValue? {
        value.map(uuid)
    }

    static func encodedPathComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.formUnion(CharacterSet(charactersIn: "_-!.~'()*"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    static func swordURL(initials: String, key: String) -> String {
        "sword://\(encodedPathComponent(initials))/\(encodedPathComponent(key))"
    }

    static func success(
        _ data: JSONValue,
        completion: AgentExecutionOutput? = nil,
        createdPageIDs: Set<UUID> = []
    ) throws -> AgentToolResult {
        guard try data.encodedData().count <= maximumResponseBytes else {
            throw BibleUIAgentDomainError(
                code: "RESPONSE_TOO_LARGE",
                message: "The requested result is too large. Narrow the request and try again."
            )
        }
        return AgentToolResult(
            data: data,
            completion: completion,
            createdPageIds: createdPageIDs
        )
    }

    static func boundedText(_ value: String) throws -> String {
        guard value.utf8.count <= maximumResponseBytes else {
            throw BibleUIAgentDomainError(
                code: "RESPONSE_TOO_LARGE",
                message: "The requested content is too large. Narrow the request and try again."
            )
        }
        return value
    }

    static func plainText(_ source: String) -> String {
        source
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
