import Foundation

/**
 Decodes the complete named-entity domain consumed by AOSP TagSoup in Android Search previews.

 Android's `Html.fromHtml` does not use Apache Commons' HTML 4 table: its bundled TagSoup
 `HTMLSchema` defines 2,111 case-sensitive names, including legacy Greek aliases and modern names.
 Keeping that generated table behind a preview-only decoder prevents UI compatibility from changing
 `SwordHTML4EntityDecoder`, whose narrower semantics belong to Android's OSIS serializer.
 */
enum SwordTagSoupEntityDecoder {
    /**
     Owns AOSP `HTMLScanner`'s persistent character-buffer capacity and current size.

     The scanner clears `theSize` after callbacks but retains a grown backing array for the rest of
     the document. That retained capacity determines later PCDATA chunk boundaries, so each parser
     state must share one instance rather than restarting at 200 characters per text slice.
     */
    struct ScannerBufferState {
        /// Current persistent AOSP scanner buffer capacity in Java UTF-16 code units.
        fileprivate(set) var capacity = 200
        /// Buffered Java UTF-16 units since the most recent scanner callback.
        fileprivate(set) var size = 0

        /**
         Records one complete non-PCDATA buffer run, growing instead of emitting at the threshold.

         - Parameter utf16Count: Number of Java `char` units saved before the state's callback.
         - Side effects: Doubles persistent capacity at every `capacity - 20` threshold and clears
           current size after the simulated callback.
         - Failure modes: Nonpositive counts are a no-op; integer overflow is impossible for a
           bounded in-memory verse preview.
         */
        mutating func observeNonPCDATARun(utf16Count: Int) {
            guard utf16Count > 0 else { return }
            for _ in 0..<utf16Count {
                saveNonPCDATAUnit()
            }
            clear()
        }

        /**
         Records one non-PCDATA Java char, retaining size and growing the backing array.

         - Side effects: Increments logical size and doubles capacity before a threshold-crossing
           save, exactly where AOSP grows rather than emits non-text state buffers.
         - Failure modes: None for bounded verse input.
         */
        fileprivate mutating func saveNonPCDATAUnit() {
            if size >= capacity - 20 { capacity *= 2 }
            size += 1
        }

        /**
         Clears a scanner callback's logical content without shrinking persistent capacity.

         - Side effects: Sets `size` to zero while preserving `capacity` for later text callbacks.
         - Failure modes: None; repeated clears are idempotent.
         */
        fileprivate mutating func clear() {
            size = 0
        }
    }

    /// Android 37's generated `HTMLSchema` cardinality, stable back through the app's minSdk 23.
    static let expectedBundledEntityCount = 2_111

    /// Validated generated entity table cached on first Search preview projection.
    private static let namedScalars: [String: UInt32] = {
        guard let url = Bundle.module.url(
                  forResource: "html-schema-android-37",
                  withExtension: "tsv",
                  subdirectory: "tagsoup"
              ),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return [:]
        }

        var result: [String: UInt32] = [:]
        for line in contents.split(whereSeparator: \.isNewline) {
            guard !line.hasPrefix("#") else { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 2,
                  !fields[0].isEmpty,
                  let value = UInt32(fields[1], radix: 16),
                  UnicodeScalar(value) != nil,
                  result[String(fields[0])] == nil else {
                return [:]
            }
            result[String(fields[0])] = value
        }
        guard result.count == expectedBundledEntityCount,
              result["Aacgr"] == 0x0386,
              result["apos"] == 0x0027,
              result["NewLine"] == 0x000A,
              result["NoBreak"] == 0x2060,
              result["Tab"] == 0x0009 else {
            return [:]
        }
        return result
    }()

    /// AOSP `HTMLScanner.theWinMap`, indexed by an input/entity value minus U+0080.
    private static let windows1252Scalars: [UInt32] = [
        0x20AC, 0xFFFD, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0xFFFD, 0x017D, 0xFFFD,
        0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0xFFFD, 0x017E, 0x0178,
    ]

    /// Test-visible integrity signal for the copied generated resource.
    static var bundledEntityCount: Int {
        namedScalars.count
    }

    /**
     Decodes scanner-terminated TagSoup entities exactly once in HTML text state.

     - Parameter text: One text-state segment from the tolerant Search preview tokenizer.
     - Returns: Text with pinned AOSP named/numeric references decoded one layer, including scanner
       termination and control remapping; unknown and malformed entities remain unchanged.
     - Side effects: Loads and validates the generated table once on first use.
     - Failure modes: A missing or invalid resource preserves named references verbatim; integrity
       tests make packaging drift fail. Invalid/zero numeric references remain literal.
     - Complexity: Linear in input characters with constant-time entity lookups.
     */
    static func decode(_ text: String) -> String {
        var bufferState = ScannerBufferState()
        return decodePCDATAEvents(text, bufferState: &bufferState).joined()
    }

    /**
     Decodes text while preserving each `HTMLScanner.A_ENTITY_START` PCDATA callback boundary.

     - Parameter text: One ordinary scanner-text range that may contain entity references.
     - Returns: Ordered decoded character callbacks; an ampersand starts a new callback even when
       the preceding callback is whitespace-only.
     - Side effects: Loads and validates the generated entity table once on first use.
     - Failure modes: Resource-invalid named references remain literal within their callback.
     */
    static func decodePCDATAEvents(_ text: String) -> [String] {
        var bufferState = ScannerBufferState()
        return decodePCDATAEvents(text, bufferState: &bufferState)
    }

    /**
     Decodes one PCDATA range against the document's persistent AOSP scanner buffer.

     - Parameters:
       - text: Scanner-normalized source range between markup tokens.
       - bufferState: Shared buffer capacity/size state for the complete HTML document.
     - Returns: Ordered decoded PCDATA callbacks with AOSP flush boundaries preserved.
     - Side effects: Mutates `bufferState`; entity states may grow capacity and every returned
       callback clears its logical size without shrinking the backing capacity.
     - Failure modes: Invalid entities remain literal; a corrupt named table fails closed as in the
       convenience overload.
     */
    static func decodePCDATAEvents(
        _ text: String,
        bufferState: inout ScannerBufferState
    ) -> [String] {
        let input = normalizedScannerScalars(text)
        var writer = PCDATAEventWriter(bufferState: bufferState)
        var cursor = 0
        while cursor < input.count {
            guard input[cursor].value == 0x26 else {
                writer.append(input[cursor])
                cursor += 1
                continue
            }

            writer.flush()
            let referenceStart = cursor
            let bodyStart = cursor + 1
            cursor = bodyStart
            if cursor < input.count, input[cursor].value == 0x23 {
                cursor += 1
                if cursor < input.count,
                   input[cursor].value == 0x78 || input[cursor].value == 0x58 {
                    cursor += 1
                    while cursor < input.count,
                          SwordJavaTextCompatibility.isHexDigit(input[cursor]) {
                        cursor += 1
                    }
                } else {
                    while cursor < input.count,
                          SwordJavaTextCompatibility.isDigit(input[cursor]) {
                        cursor += 1
                    }
                }
            } else {
                while cursor < input.count,
                      SwordJavaTextCompatibility.isLetterOrDigit(input[cursor]) {
                    cursor += 1
                }
            }

            let body = input[bodyStart..<cursor]
            let hasSemicolon = cursor < input.count && input[cursor].value == 0x3B
            writer.stageEntityReference(input[referenceStart..<cursor])
            if let value = entityValue(for: body) {
                var decoded = ""
                appendEntityValue(value, to: &decoded)
                writer.replaceStagedEntity(with: decoded)
            } else {
                writer.retainStagedEntity()
                if hasSemicolon {
                    writer.append(input[cursor])
                }
            }
            cursor = hasSemicolon ? cursor + 1 : cursor
        }
        writer.flush()
        bufferState = writer.bufferState
        return writer.events
    }

    /**
     Accumulates decoded output while preserving HTMLScanner callback and capacity boundaries.

     The writer owns no external resources. It mutates an in-memory callback list and a copied
     persistent buffer state; callers copy that state back after flushing. Invalid entities are
     staged as literal text instead of producing an error.
     */
    private struct PCDATAEventWriter {
        /// Completed nonempty callbacks in scanner order.
        var events: [String] = []
        /// Scanner output buffer after its most recent callback.
        private var current = ""
        /// Persistent scanner capacity and current logical size shared with non-PCDATA states.
        var bufferState: ScannerBufferState
        /// Raw entity reference saved while `A_ENTITY` decides whether it can be replaced.
        private var stagedEntity = ""

        /**
         Creates one callback writer from the document's current persistent scanner buffer.

         - Parameter bufferState: Capacity/size state immediately before the PCDATA range.
         - Side effects: None; state is copied and returned to the caller after decoding.
         - Failure modes: None.
         */
        init(bufferState: ScannerBufferState) {
            self.bufferState = bufferState
        }

        /**
         Saves one normalized PCDATA scalar, flushing at the current capacity-minus-20 threshold.

         - Parameter scalar: One scanner-normalized scalar in source order.
         - Side effects: Appends to the current callback or emits it and clears logical buffer size.
         - Failure modes: None; supplementary scalars count as two Java UTF-16 units.
         */
        mutating func append(_ scalar: UnicodeScalar) {
            if bufferState.size >= bufferState.capacity - 20 { flush() }
            current.unicodeScalars.append(scalar)
            bufferState.size += scalar.value > 0xFFFF ? 2 : 1
        }

        /**
         Saves decoded entity output through the same scanner buffer threshold.

         - Parameter value: Zero or more decoded visible scalars.
         - Side effects: Delegates each scalar to `append(_:)`, possibly emitting callbacks.
         - Failure modes: Empty values are ignored, matching dropped entity-control results.
         */
        mutating func append(_ value: String) {
            for scalar in value.unicodeScalars { append(scalar) }
        }

        /**
         Saves one raw entity reference in a non-PCDATA scanner state before resolution.

         - Parameter scalars: Ampersand plus the scanner-approved entity body, excluding terminator.
         - Side effects: Grows persistent capacity instead of flushing and records the exact raw
           reference for either replacement or preservation.
         - Failure modes: None; the caller supplies the bounded slice already consumed by scanner.
         */
        mutating func stageEntityReference(_ scalars: ArraySlice<UnicodeScalar>) {
            stagedEntity = ""
            for scalar in scalars {
                stagedEntity.unicodeScalars.append(scalar)
                let unitCount = scalar.value > 0xFFFF ? 2 : 1
                for _ in 0..<unitCount { bufferState.saveNonPCDATAUnit() }
            }
        }

        /**
         Replaces the staged entity buffer with its AOSP-decoded scanner output.

         - Parameter value: Decoded entity result after control/surrogate handling.
         - Side effects: Clears raw staged content, retains persistent capacity, and buffers the
           replacement for the next PCDATA callback.
         - Failure modes: Empty replacement leaves no buffered text.
         */
        mutating func replaceStagedEntity(with value: String) {
            current = ""
            bufferState.clear()
            for scalar in value.unicodeScalars {
                let unitCount = scalar.value > 0xFFFF ? 2 : 1
                for _ in 0..<unitCount { bufferState.saveNonPCDATAUnit() }
                current.unicodeScalars.append(scalar)
            }
            stagedEntity = ""
        }

        /**
         Retains an unresolved staged entity as literal PCDATA without clearing scanner size.

         - Side effects: Moves the staged raw reference into current callback content.
         - Failure modes: An unexpectedly empty stage remains empty; normal callers always stage
           ampersand plus body first.
         */
        mutating func retainStagedEntity() {
            current = stagedEntity
            stagedEntity = ""
        }

        /**
         Emits one nonempty PCDATA callback and resets logical scanner size.

         - Side effects: Appends to `events`, clears current text and size, and preserves capacity.
         - Failure modes: Empty current content is a no-op.
         */
        mutating func flush() {
            guard !current.isEmpty else { return }
            events.append(current)
            current = ""
            bufferState.clear()
        }
    }

    /**
     Normalizes one scanner CDATA range and preserves persistent text-buffer callback boundaries.

     - Parameters:
       - text: Literal script/style or CDATA text whose ampersands must not be interpreted.
       - bufferState: Shared scanner capacity/size state for the complete source document.
     - Returns: Ordered scanner-normalized callbacks.
     - Side effects: Mutates and clears `bufferState` at the same capacity thresholds as S_CDATA.
     - Failure modes: Discarded source controls produce no callback content.
     */
    static func normalizeRawScannerTextEvents(
        _ text: String,
        bufferState: inout ScannerBufferState
    ) -> [String] {
        var writer = PCDATAEventWriter(bufferState: bufferState)
        for scalar in normalizedScannerScalars(text) {
            writer.append(scalar)
        }
        writer.flush()
        bufferState = writer.bufferState
        return writer.events
    }

    /**
     Applies AOSP scanner input normalization without interpreting entity references.

     This is the CDATA text-state path: raw controls and Windows-1252 C1 bytes still pass through
     `HTMLScanner`, while ampersands remain literal because the scanner is not in `S_PCDATA`.
     */
    static func normalizeRawScannerText(_ text: String) -> String {
        var output = ""
        for scalar in normalizedScannerScalars(text) {
            output.unicodeScalars.append(scalar)
        }
        return output
    }

    /**
     Resolves one TagSoup entity body using the pinned named table or Java integer semantics.

     - Parameter body: Scanner-approved body excluding ampersand and optional semicolon.
     - Returns: Raw entity integer, or nil for empty, unknown, malformed, zero, or overflow input.
     - Side effects: Loads the generated entity table on first named lookup.
     - Failure modes: Unknown names and invalid numeric bodies remain literal through the caller.
     */
    private static func entityValue(
        for body: ArraySlice<UnicodeScalar>
    ) -> UInt32? {
        guard let first = body.first else { return nil }
        if first.value == 0x23 {
            var digits = body.dropFirst()
            var radix = 10
            if let marker = digits.first, marker.value == 0x78 || marker.value == 0x58 {
                radix = 16
                digits = digits.dropFirst()
            }
            return parseJavaInteger(digits, radix: radix)
        }
        return namedScalars[string(from: body)]
    }

    /**
     Parses scanner-approved Java digits without Swift's ASCII-only integer initializer.

     - Parameters:
       - digits: BMP decimal digits plus ASCII A-F when radix is hexadecimal.
       - radix: Ten or sixteen, selected by the numeric-reference prefix.
     - Returns: Positive Int32-range value, or nil for empty/invalid/zero/overflow input.
     - Side effects: Loads pinned Android digit values on first non-ASCII digit.
     - Failure modes: Nil causes the original reference to remain literal.
     */
    private static func parseJavaInteger(
        _ digits: ArraySlice<UnicodeScalar>,
        radix: Int
    ) -> UInt32? {
        guard !digits.isEmpty else { return nil }
        var result: Int64 = 0
        for scalar in digits {
            guard let digit = SwordJavaTextCompatibility.digitValue(scalar, radix: radix) else {
                return nil
            }
            guard result <= (Int64(Int32.max) - Int64(digit)) / Int64(radix) else {
                return nil
            }
            result = result * Int64(radix) + Int64(digit)
        }
        return result == 0 ? nil : UInt32(result)
    }

    /**
     Normalizes all raw input before entity-state classification, as AOSP's scanner does.

     - Parameter text: Untrusted preview-source text.
     - Returns: Scalar array after C1 mapping, CR normalization, and invalid-control removal.
     - Side effects: Allocates one bounded scalar buffer.
     - Failure modes: Discarded controls simply do not appear in the result.
     */
    private static func normalizedScannerScalars(_ text: String) -> [UnicodeScalar] {
        var output: [UnicodeScalar] = []
        output.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            guard let normalized = normalizedScannerScalar(scalar) else { continue }
            output.append(normalized)
        }
        return output
    }

    /**
     Normalizes one raw scalar with AOSP C1, CR, and control handling.

     - Parameter scalar: Source scalar before scanner state classification.
     - Returns: Normalized scalar or nil when HTMLScanner discards the control.
     - Side effects: None.
     - Failure modes: None; the Windows-1252 table covers the complete C1 range.
     */
    private static func normalizedScannerScalar(_ scalar: UnicodeScalar) -> UnicodeScalar? {
        var value = scalar.value
        if value >= 0x80, value <= 0x9F {
            value = windows1252Scalars[Int(value - 0x80)]
        } else if value == 0x0D {
            value = 0x0A
        }
        guard value >= 0x20 || value == 0x0A || value == 0x09 else { return nil }
        return UnicodeScalar(value)
    }

    /**
     Applies AOSP entity-result remapping before emitting visible UTF-16 content.

     - Parameters:
       - rawValue: Positive Int32-range entity result returned by the handler.
       - output: Mutable visible buffer receiving BMP or unchecked Java surrogate-form output.
     - Side effects: Appends zero, one, or two UTF-16-derived characters.
     - Failure modes: Controls below U+0020 and surrogate-range results are dropped; Java results
       above Unicode maximum are transcoded with replacement scalars rather than silently omitted.
     */
    private static func appendEntityValue(_ rawValue: UInt32, to output: inout String) {
        var value = rawValue
        if value >= 0x80, value <= 0x9F {
            value = windows1252Scalars[Int(value - 0x80)]
        }
        if value < 0x20 {
            return
        } else if value >= 0xD800, value <= 0xDFFF {
            return
        }
        if value <= 0xFFFF, let scalar = UnicodeScalar(value) {
            output.unicodeScalars.append(scalar)
            return
        }

        let adjusted = value &- 0x10000
        let high = UInt16(truncatingIfNeeded: (adjusted >> 10) &+ 0xD800)
        let low = UInt16(truncatingIfNeeded: (adjusted & 0x03FF) &+ 0xDC00)
        output += String(decoding: [high, low], as: UTF16.self)
    }

    /**
     Builds one scalar-preserving String for entity lookup without grapheme iteration.

     - Parameter scalars: Scanner-approved entity body.
     - Returns: Exact case-sensitive lookup key.
     - Side effects: Allocates a bounded string.
     - Failure modes: None.
     */
    private static func string(from scalars: ArraySlice<UnicodeScalar>) -> String {
        var result = ""
        append(scalars, to: &result)
        return result
    }

    /**
     Appends a source scalar slice verbatim for an unknown or invalid reference.

     - Parameters:
       - scalars: Exact normalized scanner slice.
       - output: Mutable destination string.
     - Side effects: Extends `output` in source order.
     - Failure modes: None.
     */
    private static func append(_ scalars: ArraySlice<UnicodeScalar>, to output: inout String) {
        for scalar in scalars {
            output.unicodeScalars.append(scalar)
        }
    }
}
