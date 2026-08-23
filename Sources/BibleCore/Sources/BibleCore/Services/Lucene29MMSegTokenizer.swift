// Lucene29MMSegTokenizer.swift - mmseg4j 1.8.6 ComplexAnalyzer port

import Foundation

/**
 Direct Swift port of mmseg4j 1.8.6's `MMSeg` and `ComplexSeg` tokenization pipeline.

 The bundled `chars.dic`, `words.dic`, and `units.dic` files are byte-for-byte resources from
 `com.chenlb.mmseg4j:mmseg4j-dic:1.8.6`, the dependency selected by Android's pinned JSword build.
 Segmentation uses UTF-16 units because the source implementation operates on Java `char[]`.
 */
enum Lucene29MMSegTokenizer {
    private enum Nation {
        case english
        case russian
        case greek
        case unknown
    }

    /** Returns the mmseg4j `ComplexAnalyzer` token stream for arbitrary mixed text. */
    static func tokens(_ text: String) throws -> [String] {
        try tokenSpans(text).map(\.term)
    }

    /**
     Returns mmseg4j tokens with exact original UTF-16 source ranges.

     - Parameter text: Arbitrary mixed CJK/Latin/numeric source.
     - Returns: Normalized terms and half-open source ranges in mmseg emission order.
     - Side effects: Lazily loads immutable mmseg dictionaries and character tables.
     - Failure modes: Propagates missing or malformed resource errors without partial output.
     */
    static func tokenSpans(_ text: String) throws -> [LuceneSearchAnalyzer.TokenSpan] {
        let dictionary = try Lucene29MMSegDictionary.loaded()
        let characterTables = try Lucene29CharacterTables.loaded()
        let source = Array(text.utf16)
        var result: [LuceneSearchAnalyzer.TokenSpan] = []
        var index = 0

        while index < source.count {
            let tokenStart = index
            var unit = characterTables.lowercase(source[index])
            index += 1

            if characterTables.isCasedOrModifierLetter(unit) {
                unit = toASCII(unit)
                switch nation(of: unit) {
                case .english:
                    var buffer = [unit]
                    while index < source.count {
                        let next = toASCII(characterTables.lowercase(source[index]))
                        guard isASCIILetter(next) || characterTables.isDecimalDigit(next) else { break }
                        buffer.append(next)
                        index += 1
                    }
                    result.append(LuceneSearchAnalyzer.TokenSpan(
                        term: String(decoding: buffer, as: UTF16.self),
                        range: tokenStart..<index
                    ))
                case .russian:
                    var buffer = [unit]
                    while index < source.count {
                        let next = characterTables.lowercase(source[index])
                        guard isRussianLetter(next) else { break }
                        buffer.append(next)
                        index += 1
                    }
                    result.append(LuceneSearchAnalyzer.TokenSpan(
                        term: String(decoding: buffer, as: UTF16.self),
                        range: tokenStart..<index
                    ))
                case .greek:
                    var buffer = [unit]
                    while index < source.count {
                        let next = characterTables.lowercase(source[index])
                        guard isGreekLetter(next) else { break }
                        buffer.append(next)
                        index += 1
                    }
                    result.append(LuceneSearchAnalyzer.TokenSpan(
                        term: String(decoding: buffer, as: UTF16.self),
                        range: tokenStart..<index
                    ))
                case .unknown:
                    continue
                }
                continue
            }

            if characterTables.isOtherLetter(unit) {
                var sentence = [unit]
                while index < source.count {
                    let next = characterTables.lowercase(source[index])
                    guard characterTables.isOtherLetter(next) else { break }
                    sentence.append(next)
                    index += 1
                }
                var segmentOffset = tokenStart
                for segment in dictionary.segment(sentence) {
                    let length = segment.utf16.count
                    result.append(LuceneSearchAnalyzer.TokenSpan(
                        term: segment,
                        range: segmentOffset..<(segmentOffset + length)
                    ))
                    segmentOffset += length
                }
                continue
            }

            if characterTables.isDecimalDigit(unit) {
                var buffer = [toASCII(unit)]
                while index < source.count {
                    let next = toASCII(characterTables.lowercase(source[index]))
                    guard characterTables.isDecimalDigit(next) else { break }
                    buffer.append(next)
                    index += 1
                }

                if index < source.count {
                    let next = characterTables.lowercase(source[index])
                    if dictionary.isUnit(next) {
                        result.append(LuceneSearchAnalyzer.TokenSpan(
                            term: String(decoding: buffer, as: UTF16.self),
                            range: tokenStart..<index
                        ))
                        result.append(LuceneSearchAnalyzer.TokenSpan(
                            term: String(decoding: [next], as: UTF16.self),
                            range: index..<(index + 1)
                        ))
                        index += 1
                        continue
                    }
                }

                while index < source.count {
                    let next = toASCII(characterTables.lowercase(source[index]))
                    guard isASCIILetter(next) || characterTables.isDecimalDigit(next) else { break }
                    buffer.append(next)
                    index += 1
                }
                result.append(LuceneSearchAnalyzer.TokenSpan(
                    term: String(decoding: buffer, as: UTF16.self),
                    range: tokenStart..<index
                ))
                continue
            }

            if characterTables.isLetterNumber(unit) {
                result.append(LuceneSearchAnalyzer.TokenSpan(
                    term: String(decoding: [unit], as: UTF16.self),
                    range: tokenStart..<index
                ))
                continue
            }

            if characterTables.isOtherNumber(unit) {
                var buffer = [unit]
                while index < source.count {
                    let next = characterTables.lowercase(source[index])
                    guard characterTables.isOtherNumber(next) else { break }
                    buffer.append(next)
                    index += 1
                }
                result.append(LuceneSearchAnalyzer.TokenSpan(
                    term: String(decoding: buffer, as: UTF16.self),
                    range: tokenStart..<index
                ))
                continue
            }

        }

        return result
    }

    private static func nation(of unit: UInt16) -> Nation {
        if isASCIILetter(unit) { return .english }
        if isRussianLetter(unit) { return .russian }
        if isGreekLetter(unit) { return .greek }
        return .unknown
    }

    private static func toASCII(_ unit: UInt16) -> UInt16 {
        switch unit {
        case 0xFF10...0xFF19, 0xFF21...0xFF3A, 0xFF41...0xFF5A:
            return unit - 0xFEE0
        default:
            return unit
        }
    }

    private static func isASCIILetter(_ unit: UInt16) -> Bool {
        (0x0041...0x005A).contains(unit) || (0x0061...0x007A).contains(unit)
    }

    private static func isRussianLetter(_ unit: UInt16) -> Bool {
        (0x0410...0x044F).contains(unit) || unit == 0x0401 || unit == 0x0451
    }

    private static func isGreekLetter(_ unit: UInt16) -> Bool {
        (0x0391...0x03A9).contains(unit) || (0x03B1...0x03C9).contains(unit)
    }
}

/** Immutable mmseg4j trie, frequency table, unit table, and complex chunk selector. */
private final class Lucene29MMSegDictionary: @unchecked Sendable {
    private final class TrieNode {
        var children: [UInt16: TrieNode] = [:]
        var isLeaf = false
    }

    private final class HeadNode {
        let trie = TrieNode()
        var degree = -1
    }

    private struct Word {
        let units: [UInt16]
        let degree: Int

        var length: Int { units.count }
    }

    private struct Chunk {
        let words: [Word]

        var length: Int { words.reduce(0) { $0 + $1.length } }
        var averageLength: Double { Double(length) / Double(words.count) }
        var variance: Double {
            let average = averageLength
            return words.reduce(0) { $0 + pow(Double($1.length) - average, 2) } / Double(words.count)
        }
        var sumDegree: Int {
            words.reduce(0) { partial, word in
                word.degree > -1 ? partial + word.degree : partial
            }
        }
    }

    private static let loadResult: Result<Lucene29MMSegDictionary, Error> = Result {
        try Lucene29MMSegDictionary.loadResources()
    }

    private let heads: [UInt16: HeadNode]
    private let units: Set<UInt16>

    private init(heads: [UInt16: HeadNode], units: Set<UInt16>) {
        self.heads = heads
        self.units = units
    }

    static func loaded() throws -> Lucene29MMSegDictionary {
        try loadResult.get()
    }

    func isUnit(_ unit: UInt16) -> Bool {
        units.contains(unit)
    }

    /** Applies mmseg4j's four complex-segmentation rules in source insertion order. */
    func segment(_ sentence: [UInt16]) -> [String] {
        var result: [String] = []
        var offset = 0
        while offset < sentence.count {
            let firstTailLengths = matchingTailLengths(sentence, offset: offset)
            var candidates: [Chunk] = []
            var maximumLength = 0

            for firstTailLength in firstTailLengths.reversed() {
                let secondOffset = offset + firstTailLength + 1
                let secondTailLengths = matchingTailLengths(sentence, offset: secondOffset)
                for secondTailLength in secondTailLengths.reversed() {
                    let thirdOffset = secondOffset + secondTailLength + 1
                    let thirdTailLength = matchingTailLengths(sentence, offset: thirdOffset).last ?? 0
                    let tailLengths = [firstTailLength, secondTailLength, thirdTailLength]
                    let offsets = [offset, secondOffset, thirdOffset]
                    let sumLength = tailLengths.reduce(0) { $0 + $1 + 1 }
                    guard sumLength >= maximumLength else { continue }
                    maximumLength = sumLength

                    var words: [Word] = []
                    for index in 0..<3 where offsets[index] < sentence.count {
                        let length = tailLengths[index] + 1
                        let wordUnits = Array(sentence[offsets[index]..<(offsets[index] + length)])
                        let degree = length == 1 ? heads[sentence[offsets[index]]]?.degree ?? -1 : -1
                        words.append(Word(units: wordUnits, degree: degree))
                    }
                    if !words.isEmpty {
                        candidates.append(Chunk(words: words))
                    }
                }
            }

            let maximum = candidates.map(\.length).max() ?? 1
            candidates = candidates.filter { $0.length == maximum }
            if candidates.count > 1 {
                let largestAverage = candidates.map(\.averageLength).max() ?? 0
                candidates = candidates.filter { $0.averageLength == largestAverage }
            }
            if candidates.count > 1 {
                let smallestVariance = candidates.map(\.variance).min() ?? 0
                candidates = candidates.filter { $0.variance == smallestVariance }
            }
            if candidates.count > 1 {
                let largestDegree = candidates.map(\.sumDegree).max() ?? Int.min
                candidates = candidates.filter { $0.sumDegree == largestDegree }
            }

            guard let selected = candidates.first else {
                result.append(String(decoding: [sentence[offset]], as: UTF16.self))
                offset += 1
                continue
            }
            result.append(contentsOf: selected.words.map { String(decoding: $0.units, as: UTF16.self) })
            offset += maximum
        }
        return result
    }

    /** Returns `[0]` plus every dictionary tail length in ascending traversal order. */
    private func matchingTailLengths(_ sentence: [UInt16], offset: Int) -> [Int] {
        guard offset < sentence.count, let head = heads[sentence[offset]] else { return [0] }
        var result = [0]
        var node = head.trie
        guard offset + 1 < sentence.count else { return result }
        for index in (offset + 1)..<sentence.count {
            guard let next = node.children[sentence[index]] else { break }
            node = next
            if node.isLeaf {
                result.append(index - offset)
            }
        }
        return result
    }

    private static func loadResources() throws -> Lucene29MMSegDictionary {
        let chars = try resource(named: "chars")
        let words = try resource(named: "words")
        let unitText = try resource(named: "units")
        var heads: [UInt16: HeadNode] = [:]

        for line in chars.split(whereSeparator: \.isNewline) {
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let first = fields.first?.utf16.first else { continue }
            let head = heads[first] ?? HeadNode()
            if fields.count == 2, let frequency = Int(fields[1]) {
                head.degree = Int(log(Double(frequency)) * 100)
            }
            heads[first] = head
        }

        for line in words.split(whereSeparator: \.isNewline) {
            guard !line.hasPrefix("#") else { continue }
            let word = Array(line.utf16)
            guard word.count >= 2 else { continue }
            let head = heads[word[0]] ?? HeadNode()
            var node = head.trie
            for unit in word.dropFirst() {
                if let existing = node.children[unit] {
                    node = existing
                } else {
                    let created = TrieNode()
                    node.children[unit] = created
                    node = created
                }
            }
            node.isLeaf = true
            heads[word[0]] = head
        }

        let units = Set(unitText.split(whereSeparator: \.isNewline).compactMap { $0.utf16.first })
        return Lucene29MMSegDictionary(heads: heads, units: units)
    }

    private static func resource(named name: String) throws -> String {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: "dic",
            subdirectory: "search/mmseg4j"
        ), let value = try? String(contentsOf: url, encoding: .utf8) else {
            throw SearchIndexError.analyzerResourceUnavailable(name: "mmseg4j/\(name).dic")
        }
        return value
    }
}
