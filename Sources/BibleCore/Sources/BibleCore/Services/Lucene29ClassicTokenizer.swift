// Lucene29ClassicTokenizer.swift - exact Lucene 2.9 ClassicTokenizer DFA runner

import Foundation

/**
 Executes the generated scanner selected by Lucene 3.6.2 `StandardTokenizer(Version.LUCENE_29)`.

 JSword's Greek and Hebrew analyzers explicitly select Lucene 2.9 compatibility, which routes to
 `ClassicTokenizerImpl`. The bundled table is extracted from the official Lucene 3.6.2 class and
 contains its complete JFlex character map, transitions, accepting actions, and state attributes.
 */
enum Lucene29ClassicTokenizer {
    private static let scannerResult: Result<ScannerTables, Error> = Result {
        guard let url = Bundle.module.url(
            forResource: "lucene-classic-tokenizer-2.9",
            withExtension: "bin",
            subdirectory: "search"
        ), let data = try? Data(contentsOf: url) else {
            throw SearchIndexError.analyzerResourceUnavailable(
                name: "lucene-classic-tokenizer-2.9.bin"
            )
        }
        return try ScannerTables(data: data)
    }

    /**
     Returns every token emitted by Lucene's classic scanner, including legacy host and acronym
     behavior, while enforcing `StandardAnalyzer.DEFAULT_MAX_TOKEN_LENGTH` (255 UTF-16 units).

     - Parameter text: Source text passed to the JSword analyzer.
     - Returns: Scanner token text in source order.
     - Throws: `SearchIndexError.analyzerResourceUnavailable` if the pinned DFA is missing or
       malformed.
     */
    static func tokens(_ text: String) throws -> [String] {
        let tables = try scannerResult.get()
        let input = Array(text.utf16)
        var cursor = 0
        var result: [String] = []

        while cursor < input.count {
            let start = cursor
            var current = cursor
            var marked = cursor
            var state = 0
            var acceptingState = tables.attributes[state] & 1 == 1 ? state : -1

            while current < input.count {
                let characterClass = Int(tables.characterMap[Int(input[current])])
                current += 1
                let transitionIndex = tables.rowMap[state] + characterClass
                guard transitionIndex < tables.transitions.count else {
                    throw tables.resourceError
                }
                let nextState = tables.transitions[transitionIndex]
                if nextState < 0 { break }
                guard nextState < tables.attributes.count else {
                    throw tables.resourceError
                }
                state = nextState
                let attributes = tables.attributes[state]
                if attributes & 1 == 1 {
                    acceptingState = state
                    marked = current
                    if attributes & 8 == 8 { break }
                }
            }

            guard acceptingState >= 0, marked > start,
                  acceptingState < tables.actions.count else {
                throw tables.resourceError
            }
            cursor = marked
            let action = tables.actions[acceptingState]
            guard (1...10).contains(action) else {
                throw tables.resourceError
            }
            if action == 1 || marked - start > 255 { continue }

            var tokenUnits = Array(input[start..<marked])
            // Lucene 2.9+ reclassifies invalid trailing-dot acronyms as hosts and removes the dot.
            if action == 8, tokenUnits.last == 0x002E {
                tokenUnits.removeLast()
            }
            result.append(String(decoding: tokenUnits, as: UTF16.self))
        }
        return result
    }
}

private struct ScannerTables {
    let characterMap: [UInt8]
    let actions: [Int]
    let rowMap: [Int]
    let transitions: [Int]
    let attributes: [Int]

    var resourceError: SearchIndexError {
        .analyzerResourceUnavailable(name: "lucene-classic-tokenizer-2.9.bin")
    }

    init(data: Data) throws {
        var reader = BigEndianByteReader(data: data)
        guard try reader.readBytes(count: 4) == Array("L29C".utf8),
              try reader.readUInt32() == 1 else {
            throw SearchIndexError.analyzerResourceUnavailable(
                name: "lucene-classic-tokenizer-2.9.bin"
            )
        }

        characterMap = try reader.readByteArray(expectedCount: 65_536)
        actions = try reader.readSignedByteArray()
        rowMap = try reader.readUInt16Array()
        transitions = try reader.readSignedByteArray()
        attributes = try reader.readSignedByteArray()

        guard actions.count == 51,
              rowMap.count == 51,
              transitions.count == 658,
              attributes.count == 51,
              reader.isAtEnd else {
            throw resourceError
        }
    }
}

/** Bounds-checked decoder for the Java `DataOutputStream` tokenizer-table format. */
private struct BigEndianByteReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    var isAtEnd: Bool { offset == bytes.count }

    init(data: Data) {
        bytes = Array(data)
    }

    mutating func readBytes(count: Int) throws -> [UInt8] {
        guard count >= 0, offset <= bytes.count - count else { throw resourceError }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }

    mutating func readUInt32() throws -> UInt32 {
        let value = try readBytes(count: 4)
        return value.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    mutating func readByteArray(expectedCount: Int? = nil) throws -> [UInt8] {
        let count = try readCount()
        if let expectedCount, count != expectedCount { throw resourceError }
        return try readBytes(count: count)
    }

    mutating func readSignedByteArray() throws -> [Int] {
        try readByteArray().map { Int(Int8(bitPattern: $0)) }
    }

    mutating func readUInt16Array() throws -> [Int] {
        let count = try readCount()
        var result: [Int] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            let value = try readBytes(count: 2)
            result.append(Int(value[0]) << 8 | Int(value[1]))
        }
        return result
    }

    private mutating func readCount() throws -> Int {
        let value = try readUInt32()
        guard Int(value) <= bytes.count else { throw resourceError }
        return Int(value)
    }

    private var resourceError: SearchIndexError {
        .analyzerResourceUnavailable(name: "lucene-classic-tokenizer-2.9.bin")
    }
}
