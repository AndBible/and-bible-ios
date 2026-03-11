import Foundation
import SwordKit

struct NormalizedStrongsQueryOptions: Equatable {
    let entryAttributeQueries: [String]
}

struct StrongsSearchVerseHit: Equatable {
    let book: String
    let chapter: Int
    let verse: Int
    let previewText: String

    var reference: String { "\(book) \(chapter):\(verse)" }
}

enum StrongsSearchSupport {
    static func normalizedQueryOptions(for query: String) -> NormalizedStrongsQueryOptions? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var candidate = trimmed.uppercased()
        if candidate.hasPrefix("LEMMA:STRONG:") {
            candidate = String(candidate.dropFirst("LEMMA:STRONG:".count))
        } else if candidate.hasPrefix("STRONG:") {
            candidate = String(candidate.dropFirst("STRONG:".count))
        } else if candidate.hasPrefix("LEMMA:") {
            candidate = String(candidate.dropFirst("LEMMA:".count))
        }

        guard let prefix = candidate.first, prefix == "H" || prefix == "G" else { return nil }
        let digitsRaw = String(candidate.dropFirst())
        guard !digitsRaw.isEmpty, digitsRaw.allSatisfy(\.isNumber) else { return nil }

        let stripped = String(digitsRaw.drop(while: { $0 == "0" }))
        let normalizedDigits = stripped.isEmpty ? "0" : stripped
        // SWORD ENTRYATTR query format: "Word//Lemma./value"
        // Value is substring-matched (case-insensitive) by SWORD, so
        // "H08414" matches "strong:H08414" stored in the Lemma attribute.
        var entryAttributeQueries: [String] = []
        entryAttributeQueries.append("Word//Lemma./\(prefix)\(digitsRaw)")
        if normalizedDigits != digitsRaw {
            entryAttributeQueries.append("Word//Lemma./\(prefix)\(normalizedDigits)")
        }

        return NormalizedStrongsQueryOptions(
            entryAttributeQueries: orderedUnique(entryAttributeQueries)
        )
    }

    static func parseVerseKey(_ key: String) -> (book: String, chapter: Int, verse: Int)? {
        if let parsed = parseHumanVerseKey(key) {
            return parsed
        }
        if let parsed = parseOsisVerseKey(key) {
            return parsed
        }
        return nil
    }

    static func searchVerseHits(
        in module: SwordModule,
        queryOptions: NormalizedStrongsQueryOptions,
        scope: String? = nil
    ) -> [StrongsSearchVerseHit] {
        for query in queryOptions.entryAttributeQueries {
            let options = SearchOptions(
                query: query,
                searchType: .entryAttribute,
                caseInsensitive: true,
                scope: scope
            )
            let swordResults = module.search(options)
            let hits: [StrongsSearchVerseHit] = swordResults.results.prefix(5000).compactMap { result in
                guard let parsed = parseVerseKey(result.key) else { return nil }
                return StrongsSearchVerseHit(
                    book: parsed.book,
                    chapter: parsed.chapter,
                    verse: parsed.verse,
                    previewText: result.previewText
                )
            }
            if !hits.isEmpty {
                return hits
            }
        }
        return []
    }

    private static func parseHumanVerseKey(_ key: String) -> (book: String, chapter: Int, verse: Int)? {
        guard let colonIdx = key.lastIndex(of: ":") else { return nil }
        let verseStr = String(key[key.index(after: colonIdx)...])
        let beforeColon = String(key[..<colonIdx])
        guard let spaceIdx = beforeColon.lastIndex(of: " ") else { return nil }
        let chapterStr = String(beforeColon[beforeColon.index(after: spaceIdx)...])
        let bookPart = String(beforeColon[..<spaceIdx])
        guard let chapter = Int(chapterStr), let verse = Int(verseStr) else { return nil }
        return (bookPart, chapter, verse)
    }

    private static func parseOsisVerseKey(_ key: String) -> (book: String, chapter: Int, verse: Int)? {
        let base = key.split(separator: "!", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? key
        let parts = base.split(separator: ".")
        guard parts.count >= 3 else { return nil }

        guard let chapter = Int(parts[parts.count - 2]),
              let verse = Int(parts[parts.count - 1]) else {
            return nil
        }

        let osisId = String(parts[parts.count - 3])
        let bookName = BibleReaderController.bookName(forOsisId: osisId) ?? osisId
        return (bookName, chapter, verse)
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }
}
