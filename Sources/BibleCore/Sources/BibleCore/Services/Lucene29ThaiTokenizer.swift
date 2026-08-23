// Lucene29ThaiTokenizer.swift - pinned Lucene/OpenJDK Thai word-break port

import Foundation

/**
 Reproduces JSword's Lucene 2.9 `StandardTokenizer` plus `ThaiWordFilter` chain.

 Lucene delegates Thai word boundaries to `BreakIterator.getWordInstance(Locale("th"))`. To avoid
 silently changing index semantics with the host iOS release, this implementation reads the exact
 Temurin 17.0.19 rule and dictionary binaries used by the pinned Java oracle. The state-machine and
 dictionary traversal below are direct Swift ports of OpenJDK's `RuleBasedBreakIterator`,
 `DictionaryBasedBreakIterator`, and `BreakDictionary` forward-iteration paths.
 */
enum Lucene29ThaiTokenizer {
    /** Returns the ordered token stream emitted by JSword's pinned Thai analyzer chain. */
    static func tokens(_ text: String) throws -> [String] {
        try tokenSpans(text).map(\.term)
    }

    /**
     Returns the Thai analyzer stream with exact source UTF-16 ranges.

     - Parameter text: Original mixed Thai/non-Thai source.
     - Returns: Lowercased analyzer terms and half-open source ranges in token order.
     - Side effects: Lazily loads the pinned OpenJDK break resources.
     - Failure modes: Propagates resource/state errors without returning partial ranges.
     */
    static func tokenSpans(_ text: String) throws -> [LuceneSearchAnalyzer.TokenSpan] {
        let breaker = try OpenJDKThaiWordBreaker.loaded()
        let tables = try Lucene29CharacterTables.loaded()
        var standardTokens: [(units: [UInt16], range: Range<Int>)] = []
        var current: [UInt16] = []
        var tokenStart = 0
        var cursor = 0

        func flush() {
            guard !current.isEmpty else { return }
            standardTokens.append((current, tokenStart..<cursor))
            current.removeAll(keepingCapacity: true)
        }

        // This is the Lucene 2.9 StandardTokenizer ALPHANUM path exercised by the Thai chain.
        for unit in text.utf16 {
            let isThaiBlock = (0x0E00...0x0E7F).contains(unit)
            if isThaiBlock || tables.isLetter(unit) || tables.isDecimalDigit(unit) {
                if current.isEmpty { tokenStart = cursor }
                current.append(tables.lowercase(unit))
            } else {
                flush()
            }
            cursor += 1
        }
        flush()

        var output: [LuceneSearchAnalyzer.TokenSpan] = []
        for token in standardTokens {
            guard let first = token.units.first, (0x0E00...0x0E7F).contains(first) else {
                output.append(LuceneSearchAnalyzer.TokenSpan(
                    term: String(decoding: token.units, as: UTF16.self),
                    range: token.range
                ))
                continue
            }
            let boundaries = try breaker.boundaries(in: token.units)
            for pair in zip(boundaries, boundaries.dropFirst()) where pair.0 < pair.1 {
                output.append(LuceneSearchAnalyzer.TokenSpan(
                    term: String(decoding: token.units[pair.0..<pair.1], as: UTF16.self),
                    range: (token.range.lowerBound + pair.0)..<(token.range.lowerBound + pair.1)
                ))
            }
        }
        return output
    }
}

/** Immutable forward-only port of OpenJDK's Thai dictionary break iterator. */
private final class OpenJDKThaiWordBreaker: @unchecked Sendable {
    private static let loadResult: Result<OpenJDKThaiWordBreaker, Error> = Result {
        guard let ruleURL = Bundle.module.url(
            forResource: "WordBreakIteratorData_th",
            withExtension: nil,
            subdirectory: "search/openjdk17"
        ), let dictionaryURL = Bundle.module.url(
            forResource: "thai_dict",
            withExtension: nil,
            subdirectory: "search/openjdk17"
        ) else {
            throw SearchIndexError.analyzerResourceUnavailable(name: "openjdk17 Thai break resources")
        }
        return try OpenJDKThaiWordBreaker(
            ruleData: Data(contentsOf: ruleURL),
            dictionaryData: Data(contentsOf: dictionaryURL)
        )
    }

    private let rules: OpenJDKBreakRules
    private let dictionary: OpenJDKBreakDictionary

    /** Loads and validates the pinned rule and dictionary resources exactly once. */
    static func loaded() throws -> OpenJDKThaiWordBreaker {
        try loadResult.get()
    }

    private init(ruleData: Data, dictionaryData: Data) throws {
        rules = try OpenJDKBreakRules(data: ruleData)
        dictionary = try OpenJDKBreakDictionary(data: dictionaryData)
    }

    /** Returns UTF-16 word boundaries, including zero and the source length. */
    func boundaries(in source: [UInt16]) throws -> [Int] {
        guard !source.isEmpty else { return [0] }
        var boundaries = [0]
        var start = 0
        while start < source.count {
            let tentative = try rules.nextBoundary(in: source, from: start)
            let nextBoundaries: [Int]
            if tentative.dictionaryCharacterCount > 1, tentative.end - start > 1 {
                nextBoundaries = try divideDictionaryRange(
                    source,
                    start: start,
                    end: tentative.end
                )
            } else {
                nextBoundaries = [start, tentative.end]
            }

            for boundary in nextBoundaries.dropFirst() where boundary > boundaries.last ?? -1 {
                boundaries.append(boundary)
            }
            guard tentative.end > start else {
                throw SearchIndexError.analyzerResourceUnavailable(name: "openjdk17 Thai break progress")
            }
            start = tentative.end
        }
        return boundaries
    }

    /**
     Ports OpenJDK `DictionaryBasedBreakIterator.divideUpDictionaryRange` without backward APIs.

     - Parameters:
       - source: Complete UTF-16 token supplied to Java's word `BreakIterator`.
       - start: Tentative rule boundary at which dictionary subdivision begins.
       - end: Tentative rule boundary after the dictionary run.
     - Returns: Ordered boundaries including `start` and `end`.
     - Side effects: none; all traversal stacks are local to this invocation.
     - Failure modes: Throws an analyzer-resource error if pinned tables yield an invalid state.
     */
    private func divideDictionaryRange(
        _ source: [UInt16],
        start: Int,
        end: Int
    ) throws -> [Int] {
        var cursor = start
        var character = codePoint(in: source, at: cursor) ?? OpenJDKCharacterIterator.done
        var category = try rules.category(of: character)
        while category == OpenJDKBreakRules.ignore || !rules.isDictionaryCategory(category) {
            character = advance(in: source, cursor: &cursor)
            guard character != OpenJDKCharacterIterator.done else { return [start, end] }
            category = try rules.category(of: character)
        }

        var currentBreakPositions: [Int] = []
        var possibleBreakPositions: [Int] = []
        var wrongBreakPositions = Set<Int>()
        var state = 0
        var farthestEndPoint = cursor
        var bestBreakPositions: [Int]?

        while true {
            if try dictionary.nextState(row: state, column: 0) == -1 {
                possibleBreakPositions.append(cursor)
            }

            state = try dictionary.nextState(row: state, character: character)
            if state == -1 {
                currentBreakPositions.append(cursor)
                break
            } else if state == 0 || cursor >= end {
                if cursor > farthestEndPoint {
                    farthestEndPoint = cursor
                    bestBreakPositions = currentBreakPositions
                }

                while let possible = possibleBreakPositions.last,
                      wrongBreakPositions.contains(possible) {
                    possibleBreakPositions.removeLast()
                }

                if possibleBreakPositions.isEmpty {
                    if let bestBreakPositions {
                        currentBreakPositions = bestBreakPositions
                        if farthestEndPoint < end {
                            cursor = min(farthestEndPoint + 1, source.count)
                        } else {
                            break
                        }
                    } else {
                        if currentBreakPositions.last != cursor, cursor != start {
                            currentBreakPositions.append(cursor)
                        }
                        _ = advance(in: source, cursor: &cursor)
                        currentBreakPositions.append(cursor)
                    }
                } else if let possible = possibleBreakPositions.popLast() {
                    while let current = currentBreakPositions.last, possible < current {
                        wrongBreakPositions.insert(currentBreakPositions.removeLast())
                    }
                    currentBreakPositions.append(possible)
                    cursor = possible
                }

                character = codePoint(in: source, at: cursor) ?? OpenJDKCharacterIterator.done
                if cursor >= end { break }
                state = 0
            } else {
                character = advance(in: source, cursor: &cursor)
            }
        }

        if !currentBreakPositions.isEmpty {
            currentBreakPositions.removeLast()
        }
        currentBreakPositions.append(end)
        return [start] + currentBreakPositions
    }

    /** Advances like OpenJDK's UTF-16 `CharacterIterator`, retaining the last index at DONE. */
    private func advance(in source: [UInt16], cursor: inout Int) -> Int {
        guard let (_, width) = codePointAndWidth(in: source, at: cursor) else {
            return OpenJDKCharacterIterator.done
        }
        let next = cursor + width
        guard next < source.count else { return OpenJDKCharacterIterator.done }
        cursor = next
        return codePoint(in: source, at: cursor) ?? OpenJDKCharacterIterator.done
    }

    private func codePoint(in source: [UInt16], at index: Int) -> Int? {
        codePointAndWidth(in: source, at: index)?.codePoint
    }

    private func codePointAndWidth(
        in source: [UInt16],
        at index: Int
    ) -> (codePoint: Int, width: Int)? {
        guard source.indices.contains(index) else { return nil }
        let first = source[index]
        if (0xD800...0xDBFF).contains(first), index + 1 < source.count {
            let second = source[index + 1]
            if (0xDC00...0xDFFF).contains(second) {
                let high = Int(first - 0xD800)
                let low = Int(second - 0xDC00)
                return (0x10000 + (high << 10) + low, 2)
            }
        }
        return (Int(first), 1)
    }
}

/** Parsed OpenJDK `WordBreakIteratorData_th` forward state machine. */
private struct OpenJDKBreakRules: Sendable {
    static let ignore = -1

    private let stateTable: [Int]
    private let endStates: [Bool]
    private let lookaheadStates: [Bool]
    private let categories: OpenJDKCompactByteTable
    private let supplementaryCategories: OpenJDKSupplementaryTable
    private let dictionaryCategoryFlags: [Bool]
    private let categoryCount: Int

    init(data: Data) throws {
        var reader = OpenJDKDataReader(data: data, resourceName: "WordBreakIteratorData_th")
        let label = try reader.readBytes(count: 7)
        guard label == Array("BIdata\0".utf8), try reader.readUInt8() == 1 else {
            throw reader.resourceError
        }
        let payloadLength = Int(try reader.readUInt32())
        guard reader.offset + payloadLength == data.count else { throw reader.resourceError }

        let stateLength = Int(try reader.readUInt32())
        let backwardsLength = Int(try reader.readUInt32())
        let endLength = Int(try reader.readUInt32())
        let lookaheadLength = Int(try reader.readUInt32())
        let bmpDataLength = Int(try reader.readUInt32())
        let supplementaryLength = Int(try reader.readUInt32())
        let additionalLength = Int(try reader.readUInt32())
        _ = try reader.readUInt64() // OpenJDK checksum; resource SHA-256 is pinned in provenance.

        stateTable = try reader.readInt16s(count: stateLength)
        _ = try reader.readInt16s(count: backwardsLength)
        endStates = try reader.readBytes(count: endLength).map { $0 == 1 }
        lookaheadStates = try reader.readBytes(count: lookaheadLength).map { $0 == 1 }
        let indices = try reader.readUInt16s(count: 512).map(Int.init)
        let values = try reader.readBytes(count: bmpDataLength)
        categories = try OpenJDKCompactByteTable(indices: indices, values: values, resourceName: reader.resourceName)
        supplementaryCategories = OpenJDKSupplementaryTable(
            values: try reader.readInt32s(count: supplementaryLength)
        )
        dictionaryCategoryFlags = try reader.readBytes(count: additionalLength).map { $0 == 1 }
        guard reader.isAtEnd, !endStates.isEmpty, stateTable.count.isMultiple(of: endStates.count) else {
            throw reader.resourceError
        }
        categoryCount = stateTable.count / endStates.count
    }

    /** Runs the forward rule state machine once and counts dictionary-category characters. */
    func nextBoundary(
        in source: [UInt16],
        from start: Int
    ) throws -> (end: Int, dictionaryCharacterCount: Int) {
        guard start < source.count else { return (source.count, 0) }
        var cursor = start
        var result = min(start + OpenJDKCharacterIterator.width(in: source, at: start), source.count)
        var lookaheadResult = 0
        var state = 1
        var dictionaryCharacterCount = 0

        while cursor < source.count, state != 0 {
            guard let (character, width) = OpenJDKCharacterIterator.codePoint(in: source, at: cursor) else {
                break
            }
            let category = try category(of: character)
            let nextIndex = min(cursor + width, source.count)
            if category != Self.ignore {
                if isDictionaryCategory(category) { dictionaryCharacterCount += 1 }
                let tableIndex = state * categoryCount + category
                guard stateTable.indices.contains(tableIndex) else {
                    throw SearchIndexError.analyzerResourceUnavailable(name: "openjdk17 Thai rule state")
                }
                state = stateTable[tableIndex]
            }
            guard endStates.indices.contains(state), lookaheadStates.indices.contains(state) else {
                throw SearchIndexError.analyzerResourceUnavailable(name: "openjdk17 Thai rule transition")
            }
            if lookaheadStates[state] {
                if endStates[state] {
                    result = lookaheadResult
                } else {
                    lookaheadResult = nextIndex
                }
            } else if endStates[state] {
                result = nextIndex
            }
            cursor = nextIndex
        }

        if cursor == source.count, lookaheadResult == source.count {
            result = lookaheadResult
        }
        guard result > start, result <= source.count else {
            throw SearchIndexError.analyzerResourceUnavailable(name: "openjdk17 Thai rule boundary")
        }
        return (result, dictionaryCharacterCount)
    }

    /** Returns the rule category for one Unicode code point. */
    func category(of character: Int) throws -> Int {
        if character < 0x10000 {
            return try categories.value(at: character)
        }
        return try supplementaryCategories.value(at: character)
    }

    /** Returns whether a rule category is marked for dictionary subdivision. */
    func isDictionaryCategory(_ category: Int) -> Bool {
        dictionaryCategoryFlags.indices.contains(category) && dictionaryCategoryFlags[category]
    }
}

/** Parsed OpenJDK `thai_dict` compressed trie/state table. */
private struct OpenJDKBreakDictionary: Sendable {
    private let columnMap: OpenJDKCompactByteTable
    private let supplementaryColumnMap: OpenJDKSupplementaryTable
    private let columnCount: Int
    private let rowIndex: [Int]
    private let rowIndexFlagsIndex: [Int]
    private let rowIndexFlags: [UInt32]
    private let rowIndexShifts: [Int]
    private let table: [Int]

    init(data: Data) throws {
        var reader = OpenJDKDataReader(data: data, resourceName: "thai_dict")
        guard try reader.readUInt32() == 1 else { throw reader.resourceError }
        let payloadLength = Int(try reader.readUInt32())
        guard reader.offset + payloadLength == data.count else { throw reader.resourceError }

        let indexCount = Int(try reader.readUInt32())
        let indices = try reader.readUInt16s(count: indexCount).map(Int.init)
        let valueCount = Int(try reader.readUInt32())
        columnMap = try OpenJDKCompactByteTable(
            indices: indices,
            values: reader.readBytes(count: valueCount),
            resourceName: reader.resourceName
        )
        columnCount = Int(try reader.readUInt32())
        _ = try reader.readUInt32() // Number of 32-column flag groups; indexes encode its use.

        rowIndex = try reader.readLengthPrefixedInt16s()
        rowIndexFlagsIndex = try reader.readLengthPrefixedInt16s()
        let flagCount = Int(try reader.readUInt32())
        rowIndexFlags = try (0..<flagCount).map { _ in try reader.readUInt32() }
        let shiftCount = Int(try reader.readUInt32())
        rowIndexShifts = try reader.readBytes(count: shiftCount).map { Int(Int8(bitPattern: $0)) }
        table = try reader.readLengthPrefixedInt16s()
        supplementaryColumnMap = OpenJDKSupplementaryTable(
            values: try reader.readLengthPrefixedInt32s()
        )
        guard reader.isAtEnd else { throw reader.resourceError }
    }

    /** Maps a character through the dictionary column table before transitioning state. */
    func nextState(row: Int, character: Int) throws -> Int {
        let column = character < 0x10000
            ? try columnMap.value(at: character)
            : try supplementaryColumnMap.value(at: character)
        return try nextState(row: row, column: column)
    }

    /** Returns the next compressed dictionary state for one logical row and column. */
    func nextState(row: Int, column: Int) throws -> Int {
        guard rowIndexFlagsIndex.indices.contains(row), rowIndex.indices.contains(row),
              rowIndexShifts.indices.contains(row), column >= 0 else {
            throw SearchIndexError.analyzerResourceUnavailable(name: "openjdk17 Thai dictionary state")
        }
        let flagIndex = rowIndexFlagsIndex[row]
        let populated: Bool
        if flagIndex < 0 {
            populated = column == -flagIndex
        } else {
            let index = flagIndex + (column >> 5)
            guard rowIndexFlags.indices.contains(index) else {
                throw SearchIndexError.analyzerResourceUnavailable(name: "openjdk17 Thai dictionary flags")
            }
            populated = rowIndexFlags[index] & (UInt32(1) << UInt32(column & 0x1F)) != 0
        }
        guard populated else { return 0 }

        let physicalColumn = column + rowIndexShifts[row]
        let tableIndex = rowIndex[row] * columnCount + physicalColumn
        guard table.indices.contains(tableIndex) else {
            throw SearchIndexError.analyzerResourceUnavailable(name: "openjdk17 Thai dictionary table")
        }
        return table[tableIndex]
    }
}

/** OpenJDK's 512-block compact byte lookup representation. */
private struct OpenJDKCompactByteTable: Sendable {
    private let indices: [Int]
    private let values: [UInt8]
    private let resourceName: String

    init(indices: [Int], values: [UInt8], resourceName: String) throws {
        guard indices.count == 512 else {
            throw SearchIndexError.analyzerResourceUnavailable(name: resourceName)
        }
        self.indices = indices
        self.values = values
        self.resourceName = resourceName
    }

    func value(at character: Int) throws -> Int {
        guard (0...0xFFFF).contains(character) else {
            throw SearchIndexError.analyzerResourceUnavailable(name: resourceName)
        }
        let offset = indices[character >> 7] + (character & 0x7F)
        guard values.indices.contains(offset) else {
            throw SearchIndexError.analyzerResourceUnavailable(name: resourceName)
        }
        return Int(Int8(bitPattern: values[offset]))
    }
}

/** OpenJDK's range-compressed supplementary-code-point lookup representation. */
private struct OpenJDKSupplementaryTable: Sendable {
    let values: [Int]

    func value(at character: Int) throws -> Int {
        guard values.count >= 2 else {
            throw SearchIndexError.analyzerResourceUnavailable(name: "openjdk17 Thai supplementary table")
        }
        var lower = 0
        var upper = values.count - 1
        while lower < upper - 1 {
            let middle = (lower + upper) / 2
            if character < values[middle] >> 8 {
                upper = middle
            } else {
                lower = middle
            }
        }
        let start = values[lower] >> 8
        let end = values[lower + 1] >> 8
        guard character >= start, character < end else {
            throw SearchIndexError.analyzerResourceUnavailable(name: "openjdk17 Thai supplementary value")
        }
        let value = values[lower] & 0xFF
        return value == 0xFF ? OpenJDKBreakRules.ignore : value
    }
}

/** Minimal UTF-16 helpers matching OpenJDK `CharacterIterator` code-point traversal. */
private enum OpenJDKCharacterIterator {
    static let done = 0xFFFF

    static func width(in source: [UInt16], at index: Int) -> Int {
        codePoint(in: source, at: index)?.width ?? 1
    }

    static func codePoint(
        in source: [UInt16],
        at index: Int
    ) -> (codePoint: Int, width: Int)? {
        guard source.indices.contains(index) else { return nil }
        let first = source[index]
        if (0xD800...0xDBFF).contains(first), index + 1 < source.count {
            let second = source[index + 1]
            if (0xDC00...0xDFFF).contains(second) {
                return (
                    0x10000 + (Int(first - 0xD800) << 10) + Int(second - 0xDC00),
                    2
                )
            }
        }
        return (Int(first), 1)
    }
}

/** Bounds-checked big-endian reader for OpenJDK's serialized break resources. */
private struct OpenJDKDataReader {
    let bytes: [UInt8]
    let resourceName: String
    var offset = 0

    init(data: Data, resourceName: String) {
        bytes = Array(data)
        self.resourceName = resourceName
    }

    var isAtEnd: Bool { offset == bytes.count }
    var resourceError: SearchIndexError { .analyzerResourceUnavailable(name: resourceName) }

    mutating func readUInt8() throws -> UInt8 {
        guard bytes.indices.contains(offset) else { throw resourceError }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readBytes(count: Int) throws -> [UInt8] {
        guard count >= 0, offset + count <= bytes.count else { throw resourceError }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }

    mutating func readUInt16() throws -> UInt16 {
        let value = try readBytes(count: 2)
        return (UInt16(value[0]) << 8) | UInt16(value[1])
    }

    mutating func readUInt32() throws -> UInt32 {
        let value = try readBytes(count: 4)
        return value.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    mutating func readUInt64() throws -> UInt64 {
        let value = try readBytes(count: 8)
        return value.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    mutating func readUInt16s(count: Int) throws -> [UInt16] {
        try (0..<count).map { _ in try readUInt16() }
    }

    mutating func readInt16s(count: Int) throws -> [Int] {
        try readUInt16s(count: count).map { Int(Int16(bitPattern: $0)) }
    }

    mutating func readInt32s(count: Int) throws -> [Int] {
        try (0..<count).map { _ in Int(Int32(bitPattern: try readUInt32())) }
    }

    mutating func readLengthPrefixedInt16s() throws -> [Int] {
        try readInt16s(count: Int(readUInt32()))
    }

    mutating func readLengthPrefixedInt32s() throws -> [Int] {
        try readInt32s(count: Int(readUInt32()))
    }
}
